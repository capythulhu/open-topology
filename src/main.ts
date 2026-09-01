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
const ENGINE_BYTES = 32;
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

  const shared = { engine, heights, depth };
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

  const selectSource = async (name: string) => {
    stream?.stop();
    stream = null;
    activeSource = name;
    notice = '';
    draw();

    if (name !== 'kinect') return;

    if (!(await bridgeReady())) {
      notice = 'kinect bridge not built — run: npm run kinect:setup';
      draw();
      return;
    }

    stream = streamDepth(
      (frame) => device.queue.writeBuffer(depth, 0, frame),
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
