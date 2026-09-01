import { createCamera } from './camera';
import { createDepth, initGpu } from './gpu';
import { renderPanel } from './panel';
import { Program, type SlangModule } from './program';
import { fitGround, spreadAgainst } from './sources/ground';
import { bridgeReady, streamDepth, type DepthStream } from './sources/kinect';
import * as noise from './sources/noise.slang';
import * as kinect from './sources/kinect.slang';
import * as clusters from './effects/clusters.slang';
import * as contours from './effects/contours.slang';
import * as normals from './effects/normals.slang';
import * as water from './effects/water.slang';

const ENGINE_BYTES = 48;
const DEPTH_BYTES = 640 * 480 * 2;

// The plane takes the aspect ratio of its resolution, so a 4:3 field matches what
// the sensor actually sees instead of cropping it to a square.
const FIELDS: Record<string, { columns: number; rows: number }> = {
  '256 x 256': { columns: 256, rows: 256 },
  '320 x 240': { columns: 320, rows: 240 },
  '480 x 360': { columns: 480, rows: 360 },
  '640 x 480': { columns: 640, rows: 480 },
};

const SOURCES: Record<string, SlangModule> = { noise, kinect };
const EFFECTS: Record<string, SlangModule> = { contours, water, clusters, normals };

async function main() {
  const canvas = document.querySelector<HTMLCanvasElement>('#view')!;
  const panel = document.querySelector<HTMLElement>('#panel')!;
  const { device, context, format } = await initGpu(canvas);
  const camera = createCamera(canvas);

  const engine = device.createBuffer({
    size: ENGINE_BYTES,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const depth = device.createBuffer({
    size: DEPTH_BYTES,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });
  const groundBuffer = device.createBuffer({
    size: 32,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  const reference = device.createBuffer({
    size: DEPTH_BYTES,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });

  let fieldName = '256 x 256';
  let field = FIELDS[fieldName];
  let heights = device.createBuffer({
    size: field.columns * field.rows * 4,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });

  const build = (modules: Record<string, SlangModule>) => {
    const shared = { engine, heights, depth, ground: groundBuffer, reference };
    const cells = field.columns * field.rows;
    return Object.fromEntries(
      Object.entries(modules).map(([name, module]) => [name, new Program(device, module, shared, cells, format)]),
    );
  };

  let sources = build(SOURCES);
  let effects = build(EFFECTS);

  // Changing resolution means new buffers and new bind groups, so the programs
  // are rebuilt; carrying the slider values across keeps that invisible.
  const setField = (name: string) => {
    const settings = [...Object.values(sources), ...Object.values(effects)].map((program) =>
      program.params.map((p) => [p.name, p.value] as const),
    );

    fieldName = name;
    field = FIELDS[name];
    heights.destroy();
    heights = device.createBuffer({
      size: field.columns * field.rows * 4,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
    });

    sources = build(SOURCES);
    effects = build(EFFECTS);
    [...Object.values(sources), ...Object.values(effects)].forEach((program, i) => {
      for (const [key, value] of settings[i] ?? []) program.setParam(key, value);
    });

    ground.spread = 0;
    draw();
  };

  let activeSource = 'noise';
  let activeEffect = 'contours';
  let notice = '';
  let stream: DepthStream | null = null;
  let latest: Uint8Array<ArrayBuffer> | null = null;
  const view = { heightScale: 0.9 };

  const draw = () => {
    renderPanel(panel, {
      fields: Object.keys(FIELDS),
      field: fieldName,
      onField: setField,
      sources: Object.keys(sources),
      source: activeSource,
      onSource: (name) => selectSource(name),
      effects: Object.keys(effects),
      effect: activeEffect,
      onEffect: (name) => {
        activeEffect = name;
        draw();
      },
      notice,
      actions:
        activeSource !== 'kinect'
          ? []
          : captured
            ? [
                { label: 'recalibrate on the flat surface', onClick: calibrate },
                { label: 'clear calibration', onClick: clearCalibration },
              ]
            : [{ label: 'calibrate on the flat surface', onClick: calibrate }],
      groups: [
        { title: activeSource, params: sources[activeSource].params, onChange: (n, v) => sources[activeSource].setParam(n, v) },
        { title: activeEffect, params: effects[activeEffect].params, onChange: (n, v) => effects[activeEffect].setParam(n, v) },
        {
          title: 'view',
          params: [{ name: 'heightScale', offset: 0, value: view.heightScale, lo: 0, hi: 3 }],
          onChange: (_, value) => { view.heightScale = value; },
        },
      ],
    });
  };

  // Height is read against the plane that best fits the frame, refitted as it
  // changes, so nothing needs calibrating and a tilted sensor cancels out.
  const groundData = new Float32Array(8);
  const ground = { a: 0, b: 0, c: 0, spread: 0 };
  let captured: Uint16Array | null = null;

  const measure = (frame: Uint8Array<ArrayBuffer>) => {
    const samples = new Uint16Array(frame.buffer);
    const value = (name: string) => sources.kinect.params.find((p) => p.name === name)?.value ?? 0.5;
    const crop = { x: value('cropX'), y: value('cropY'), size: value('cropSize') };
    const reading = captured
      ? spreadAgainst(samples, captured, crop)
      : fitGround(samples, crop);
    const coverage = reading.coverage;
    const fitted = 'ground' in reading ? reading.ground : { a: 0, b: 0, c: 0, spread: reading.spread };

    // Anything nearer than about half a metre returns nothing at all on a v1, so
    // thin coverage almost always means the sensor is mounted too close.
    const complaint =
      coverage < 0.25
        ? `sensor is reading only ${Math.round(coverage * 100)}% of the view — a kinect v1 sees nothing closer than ~50cm, try mounting it further back`
        : '';
    if (complaint !== notice) {
      notice = complaint;
      draw();
    }
    if (!fitted || fitted.spread === 0) return;

    const ease = ground.spread === 0 ? 1 : 0.1;
    ground.a += (fitted.a - ground.a) * ease;
    ground.b += (fitted.b - ground.b) * ease;
    ground.c += (fitted.c - ground.c) * ease;
    ground.spread += (fitted.spread - ground.spread) * ease;

    groundData[0] = ground.a;
    groundData[1] = ground.b;
    groundData[2] = ground.c;
    groundData[3] = ground.spread;
    groundData[4] = captured ? 1 : 0;
    device.queue.writeBuffer(groundBuffer, 0, groundData);
  };

  // Optional: the plane fit already works untouched. Capturing an empty, flat
  // surface additionally cancels whatever the sensor gets wrong pixel by pixel.
  const calibrate = () => {
    if (!latest) return;
    captured = new Uint16Array(latest.slice().buffer);
    device.queue.writeBuffer(reference, 0, latest);
    ground.spread = 0;
    draw();
  };

  const clearCalibration = () => {
    captured = null;
    ground.spread = 0;
    draw();
  };

  const selectSource = async (name: string) => {
    stream?.stop();
    stream = null;
    latest = null;
    activeSource = name;
    notice = '';

    // Otherwise cells the new source never writes — sensor holes, mostly — keep
    // showing the old source's terrain.
    device.queue.writeBuffer(heights, 0, new Float32Array(field.columns * field.rows));
    draw();

    if (name !== 'kinect') return;

    if (!(await bridgeReady())) {
      notice = 'kinect bridge not built — run: npm run kinect:setup';
      draw();
      return;
    }

    // A wedged sensor is reset over usb before it streams, which takes a good
    // fifteen seconds — say so rather than look hung.
    notice = 'waiting for the kinect...';
    draw();

    stream = streamDepth(
      (frame) => {
        const first = latest === null;
        latest = frame;
        device.queue.writeBuffer(depth, 0, frame);
        measure(frame);
        if (first) {
          notice = '';
          draw();
        }
      },
      (reason) => {
        notice = reason;
        draw();
      },
    );
  };

  draw();

  const engineData = new ArrayBuffer(ENGINE_BYTES);
  const sizes = new Uint32Array(engineData);
  const values = new Float32Array(engineData);


  let depthTexture = createDepth(device, 1, 1);
  let width = 0;
  let height = 0;

  const resize = () => {
    const w = Math.max(1, Math.floor(canvas.clientWidth * devicePixelRatio));
    const h = Math.max(1, Math.floor(canvas.clientHeight * devicePixelRatio));
    if (w === width && h === height) return;
    canvas.width = w;
    canvas.height = h;
    depthTexture.destroy();
    depthTexture = createDepth(device, w, h);
    width = w;
    height = h;
  };

  const start = performance.now();

  const frame = () => {
    resize();

    sizes[0] = field.columns;
    sizes[1] = field.rows;
    values[2] = view.heightScale;
    values[3] = (performance.now() - start) / 1000;
    values[4] = camera.yaw;
    values[5] = camera.pitch;
    values[6] = camera.zoom;
    values[7] = width / height;
    // Exaggerating the relief compresses what a unit of height is worth in mm,
    // which keeps a contour interval honest.
    const param = (name: string) => sources[activeSource].params.find((p) => p.name === name)?.value;
    values[8] =
      activeSource === 'kinect'
        ? Math.max(1, (2 * ground.spread) / Math.max(param('height') ?? 1, 0.01))
        : (param('relief') ?? 200);
    device.queue.writeBuffer(engine, 0, engineData);

    const effect = effects[activeEffect];
    const encoder = device.createCommandEncoder();
    const columns = Math.ceil(field.columns / 8);
    const rows = Math.ceil(field.rows / 8);
    sources[activeSource].compute(encoder, columns, rows);
    effect.compute(encoder, columns, rows);

    const pass = encoder.beginRenderPass({
      colorAttachments: [
        {
          view: context.getCurrentTexture().createView(),
          clearValue: { r: 0.055, g: 0.06, b: 0.07, a: 1 },
          loadOp: 'clear',
          storeOp: 'store',
        },
      ],
      depthStencilAttachment: {
        view: depthTexture.createView(),
        depthClearValue: 1,
        depthLoadOp: 'clear',
        depthStoreOp: 'store',
      },
    });
    effect.draw(pass, (field.columns - 1) * (field.rows - 1) * 6);
    pass.end();

    device.queue.submit([encoder.finish()]);
    requestAnimationFrame(frame);
  };

  requestAnimationFrame(frame);
}

main().catch((error) => {
  document.body.innerHTML = `<pre style="padding:24px;color:#ff9b9b">${error.message}</pre>`;
});
