import { createCamera } from './camera';
import { createDepth, initGpu } from './gpu';
import { renderPanel } from './panel';
import { Program, type SlangModule } from './program';
import { fitGround, spreadAgainst } from './sources/ground';
import { createStabilizer, drawLabels, parseLabels, LABELS_BYTES } from './labels';
import { createPreview } from './sources/preview';
import * as gridModule from './grid.slang';
import { bridgeReady, streamDepth, type DepthStream } from './sources/kinect';
import * as noise from './sources/noise.slang';
import * as bumps from './sources/bumps.slang';
import * as kinect from './sources/kinect.slang';
import * as contours from './effects/contours.slang';
import * as normals from './effects/normals.slang';
import * as sparks from './effects/sparks.slang';
import * as raw from './effects/raw.slang';
import * as measure from './effects/measure.slang';
import * as cage from './effects/cage.slang';
import * as wind from './effects/wind.slang';
import * as tomography from './effects/tomography.slang';
import * as water from './effects/water.slang';

const ENGINE_BYTES = 48;
const DEPTH_BYTES = 640 * 480 * 2;

const FIELDS: Record<string, { columns: number; rows: number }> = {
  '256 x 256': { columns: 256, rows: 256 },
  '320 x 240': { columns: 320, rows: 240 },
  '480 x 360': { columns: 480, rows: 360 },
  '640 x 480': { columns: 640, rows: 480 },
};

const SOURCES: Record<string, SlangModule> = { bumps, noise, kinect };
const EFFECTS: Record<string, SlangModule> = { contours, measure, cage, tomography, wind, water, sparks, normals, raw };

async function main() {
  const canvas = document.querySelector<HTMLCanvasElement>('#view')!;
  const overlay = document.querySelector<HTMLCanvasElement>('#labels')!;
  const lettering = overlay.getContext('2d')!;
  const panel = document.querySelector<HTMLElement>('#panel')!;
  const { device, context, format } = await initGpu(canvas);
  const camera = createCamera(canvas);
  device.addEventListener('uncapturederror', (event) => {
    console.error('[gpu]', (event as GPUUncapturedErrorEvent).error.message);
  });

  const engine = device.createBuffer({
    size: ENGINE_BYTES,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const depth = device.createBuffer({
    size: DEPTH_BYTES,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });
  const staging = device.createBuffer({
    size: LABELS_BYTES,
    usage: GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST,
  });
  let reading = false;
  const stabilize = createStabilizer();

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
  const fieldBuffer = () =>
    device.createBuffer({
      size: field.columns * field.rows * 4,
      usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC,
    });
  let heights = fieldBuffer();
  let rawHeights = fieldBuffer();

  const build = (modules: Record<string, SlangModule>) => {
    const shared = { engine, heights, rawHeights, depth, ground: groundBuffer, reference };
    const cells = field.columns * field.rows;
    return Object.fromEntries(
      Object.entries(modules).map(([name, module]) => [name, new Program(device, module, shared, cells, format)]),
    );
  };

  let sources = build(SOURCES);
  let effects = build(EFFECTS);
  let grid = build({ grid: gridModule }).grid;

  const setField = (name: string) => {
    const settings = [...Object.values(sources), ...Object.values(effects), grid].map((program) =>
      program.params.map((p) => [p.name, p.value] as const),
    );

    fieldName = name;
    field = FIELDS[name];
    heights.destroy();
    rawHeights.destroy();
    heights = fieldBuffer();
    rawHeights = fieldBuffer();

    sources = build(SOURCES);
    effects = build(EFFECTS);
    grid = build({ grid: gridModule }).grid;
    [...Object.values(sources), ...Object.values(effects), grid].forEach((program, i) => {
      for (const [key, value] of settings[i] ?? []) program.setParam(key, value);
    });

    ground.spread = 0;
    draw();
  };

  let activeSource = 'bumps';
  let activeEffect = 'contours';
  let notice = '';
  const preview = createPreview();
  let shown = 0;
  let stream: DepthStream | null = null;
  let latest: Uint8Array<ArrayBuffer> | null = null;
  const view = { heightScale: 0.9, spin: 0 };

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
      preview: activeSource === 'kinect' ? preview.element : null,
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
          params: [
            { name: 'heightScale', offset: 0, value: view.heightScale, lo: 0, hi: 3 },
            { name: 'spin', offset: 0, value: view.spin, lo: -1, hi: 1 },
          ],
          onChange: (name, value) => {
            if (name === 'heightScale') view.heightScale = value;
            if (name === 'spin') view.spin = value;
          },
        },
        { title: 'grid', params: grid.params, onChange: (n, v) => grid.setParam(n, v) },
      ],
    });
  };

  const groundData = new Float32Array(8);
  const ground = { a: 0, b: 0, c: 0, spread: 0 };
  let captured: Uint16Array | null = null;
  let sceneDepth = 1000;

  const measure = (frame: Uint8Array<ArrayBuffer>) => {
    const samples = new Uint16Array(frame.buffer);
    const value = (name: string) => sources.kinect.params.find((p) => p.name === name)?.value ?? 0.5;
    const crop = { x: value('cropX'), y: value('cropY'), size: value('cropSize') };
    const reading = captured
      ? spreadAgainst(samples, captured, crop)
      : fitGround(samples, crop);
    const coverage = reading.coverage;
    const fitted = 'ground' in reading ? reading.ground : { a: 0, b: 0, c: 0, spread: reading.spread };

    const complaint =
      coverage < 0.25
        ? `sensor is reading only ${Math.round(coverage * 100)}% of the view — a kinect v1 sees nothing closer than ~50cm, try mounting it further back`
        : '';
    if (complaint !== notice) {
      notice = complaint;
      draw();
    }
    if (!fitted || fitted.spread === 0) return;

    if (!captured) sceneDepth = fitted.a * 320 + fitted.b * 240 + fitted.c;

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

    const blank = new Float32Array(field.columns * field.rows);
    device.queue.writeBuffer(heights, 0, blank);
    device.queue.writeBuffer(rawHeights, 0, blank);
    draw();

    if (name !== 'kinect') return;

    if (!(await bridgeReady())) {
      notice = 'kinect bridge not built — run: npm run kinect:setup';
      draw();
      return;
    }

    notice = 'waiting for the kinect...';
    draw();

    stream = streamDepth(
      (frame) => {
        const first = latest === null;
        latest = frame;
        device.queue.writeBuffer(depth, 0, frame);
        measure(frame);

        if (shown++ % 6 === 0) {
          const value = (name: string) => sources.kinect.params.find((p) => p.name === name)?.value ?? 0.5;
          preview.draw(frame, {
            x: value('cropX'),
            y: value('cropY'),
            size: value('cropSize'),
            aspect: field.columns / field.rows,
          });
        }
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
    overlay.width = w;
    overlay.height = h;
    depthTexture.destroy();
    depthTexture = createDepth(device, w, h);
    width = w;
    height = h;
  };

  const start = performance.now();
  let previous = start;

  const frame = () => {
    resize();

    const now = performance.now();
    camera.yaw += view.spin * (now - previous) / 1000;
    previous = now;

    sizes[0] = field.columns;
    sizes[1] = field.rows;
    values[2] = view.heightScale;
    values[3] = (performance.now() - start) / 1000;
    values[4] = camera.yaw;
    values[5] = camera.pitch;
    values[6] = camera.zoom;
    values[7] = width / height;
    const param = (name: string) => sources[activeSource].params.find((p) => p.name === name)?.value;
    values[8] =
      activeSource === 'kinect'
        ? Math.max(1, (2 * ground.spread) / Math.max(param('height') ?? 1, 0.01))
        : (param('relief') ?? 200);

    values[9] =
      activeSource === 'kinect'
        ? ((param('cropSize') ?? 0.9) * 480 / field.rows) * sceneDepth * 0.001697
        : 400 / field.columns;
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
    grid.draw(pass, field.columns, field.rows);
    effect.draw(pass, field.columns, field.rows);
    pass.end();

    const wantsLabels = effect.labels !== null && !reading;
    if (wantsLabels) encoder.copyBufferToBuffer(effect.labels!, 0, staging, 0, LABELS_BYTES);

    device.queue.submit([encoder.finish()]);

    if (wantsLabels) {
      reading = true;
      void staging.mapAsync(GPUMapMode.READ).then(() => {
        const labels = stabilize(parseLabels(staging.getMappedRange().slice(0)));
        staging.unmap();
        reading = false;
        drawLabels(lettering, labels, projectCell);
      });
    } else if (effect.labels === null) {
      lettering.clearRect(0, 0, overlay.width, overlay.height);
    }

    requestAnimationFrame(frame);
  };

  const projectCell = (cell: [number, number], h: number) => {
    const longest = Math.max(field.columns, field.rows);
    const wx = (cell[0] / (field.columns - 1) - 0.5) * (field.columns / longest);
    const wy = h * view.heightScale;
    const wz = (cell[1] / (field.rows - 1) - 0.5) * (field.rows / longest);

    const cy = Math.cos(camera.yaw), sy = Math.sin(camera.yaw);
    const ax = wx * cy - wz * sy;
    const az = wx * sy + wz * cy;
    const cp = Math.cos(camera.pitch), sp = Math.sin(camera.pitch);
    const rx = ax;
    const ry = wy * cp + az * sp;

    const clipX = (rx * camera.zoom) / (width / height);
    const clipY = ry * camera.zoom;
    return {
      x: ((clipX + 1) / 2) * overlay.clientWidth,
      y: ((1 - clipY) / 2) * overlay.clientHeight,
    };
  };

  requestAnimationFrame(frame);
}

main().catch((error) => {
  document.body.innerHTML = `<pre style="padding:24px;color:#ff9b9b">${error.message}</pre>`;
});
