import { createCamera } from './camera';
import { createDepth, initGpu } from './gpu';
import { renderPanel } from './panel';
import { Program, type SlangModule } from './program';
import { bridgeReady, streamDepth, type DepthStream } from './sources/kinect';
import * as noise from './sources/noise.slang';
import * as kinect from './sources/kinect.slang';
import * as clusters from './effects/clusters.slang';
import * as contours from './effects/contours.slang';
import * as normals from './effects/normals.slang';

const SIZE = 256;
const GROUPS = Math.ceil(SIZE / 8);
const VERTICES = (SIZE - 1) * (SIZE - 1) * 6;
const ENGINE_BYTES = 48;
const DEPTH_BYTES = 640 * 480 * 2;

const SOURCES: Record<string, SlangModule> = { noise, kinect };
const EFFECTS: Record<string, SlangModule> = { contours, normals, clusters };

async function main() {
  const canvas = document.querySelector<HTMLCanvasElement>('#view')!;
  const panel = document.querySelector<HTMLElement>('#panel')!;
  const { device, context, format } = await initGpu(canvas);
  const camera = createCamera(canvas);

  const engine = device.createBuffer({
    size: ENGINE_BYTES,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });
  const heights = device.createBuffer({
    size: SIZE * SIZE * 4,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });
  const depth = device.createBuffer({
    size: DEPTH_BYTES,
    usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
  });
  const bounds = device.createBuffer({
    size: 16,
    usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
  });

  const shared = { engine, heights, depth, bounds };
  const build = (modules: Record<string, SlangModule>) =>
    Object.fromEntries(
      Object.entries(modules).map(([name, module]) => [name, new Program(device, module, shared, SIZE * SIZE, format)]),
    );

  const sources = build(SOURCES);
  const effects = build(EFFECTS);

  let activeSource = 'noise';
  let activeEffect = 'contours';
  let notice = '';
  let stream: DepthStream | null = null;
  let latest: Uint8Array<ArrayBuffer> | null = null;
  const view = { heightScale: 0.9 };

  const draw = () => {
    renderPanel(panel, {
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
        activeSource === 'kinect'
          ? []
          : [],
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

  // Whatever is in frame defines the scale: nearest reading is the top of the
  // palette, furthest is the bottom. Percentiles rather than raw min and max, so
  // one stray pixel cannot set the range, and eased over time so a passing hand
  // does not rescale the whole scene.
  const boundsData = new Float32Array(4);
  const scale = { near: 0, far: 0 };

  const measure = (frame: Uint8Array<ArrayBuffer>) => {
    const samples = new Uint16Array(frame.buffer);
    const crop = (name: string) => sources.kinect.params.find((p) => p.name === name)?.value ?? 0.5;
    const cx = crop('cropX') * 640;
    const cy = crop('cropY') * 480;
    const half = (crop('cropSize') * 480) / 2;

    const valid: number[] = [];
    let looked = 0;
    for (let y = Math.max(0, cy - half) | 0; y < Math.min(480, cy + half); y += 3) {
      for (let x = Math.max(0, cx - half) | 0; x < Math.min(640, cx + half); x += 3) {
        const value = samples[y * 640 + x];
        looked++;
        if (value > 0) valid.push(value);
      }
    }

    // Anything nearer than about half a metre returns nothing at all on a v1, so
    // thin coverage almost always means the sensor is mounted too close.
    const covered = looked > 0 ? valid.length / looked : 0;
    const complaint =
      covered < 0.25 ? `sensor is reading only ${Math.round(covered * 100)}% of the view — a kinect v1 sees nothing closer than ~50cm, try mounting it further back` : '';
    if (complaint !== notice) {
      notice = complaint;
      draw();
    }

    if (valid.length < 64) return;

    valid.sort((a, b) => a - b);
    const near = valid[Math.floor(valid.length * 0.02)];
    const far = valid[Math.floor(valid.length * 0.98)];

    const ease = scale.far === 0 ? 1 : 0.1;
    scale.near += (near - scale.near) * ease;
    scale.far += (far - scale.far) * ease;

    boundsData[0] = scale.near;
    boundsData[1] = scale.far;
    device.queue.writeBuffer(bounds, 0, boundsData);
  };

  const selectSource = async (name: string) => {
    stream?.stop();
    stream = null;
    latest = null;
    activeSource = name;
    notice = '';

    // Otherwise cells the new source never writes — sensor holes, mostly — keep
    // showing the old source's terrain.
    device.queue.writeBuffer(heights, 0, new Float32Array(SIZE * SIZE));
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
  sizes[0] = SIZE;
  sizes[1] = SIZE;

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

    values[2] = view.heightScale;
    values[3] = (performance.now() - start) / 1000;
    values[4] = camera.yaw;
    values[5] = camera.pitch;
    values[6] = camera.zoom;
    values[7] = width / height;
    values[8] =
      activeSource === 'kinect'
        ? Math.max(1, scale.far - scale.near)
        : (sources[activeSource].params.find((p) => p.name === 'relief')?.value ?? 200);
    device.queue.writeBuffer(engine, 0, engineData);

    const effect = effects[activeEffect];
    const encoder = device.createCommandEncoder();
    sources[activeSource].compute(encoder, GROUPS);
    effect.compute(encoder, GROUPS);

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
    effect.draw(pass, VERTICES);
    pass.end();

    device.queue.submit([encoder.finish()]);
    requestAnimationFrame(frame);
  };

  requestAnimationFrame(frame);
}

main().catch((error) => {
  document.body.innerHTML = `<pre style="padding:24px;color:#ff9b9b">${error.message}</pre>`;
});
