import { createCamera } from './camera';
import { createDepth, initGpu } from './gpu';
import { renderPanel } from './panel';
import { Program, type SlangModule } from './program';
import * as noise from './sources/noise.slang';
import * as clusters from './effects/clusters.slang';
import * as contours from './effects/contours.slang';
import * as normals from './effects/normals.slang';

const SIZE = 256;
const GROUPS = Math.ceil(SIZE / 8);
const VERTICES = (SIZE - 1) * (SIZE - 1) * 6;
const ENGINE_BYTES = 32;

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

  const shared = { engine, heights };
  const source = new Program(device, noise, shared, SIZE * SIZE, format);
  const effects = Object.fromEntries(
    Object.entries(EFFECTS).map(([name, mod]) => [name, new Program(device, mod, shared, SIZE * SIZE, format)]),
  );

  let active = 'contours';
  const view = { heightScale: 0.9 };

  const draw = () => {
    renderPanel(panel, Object.keys(effects), active, (name) => {
      active = name;
      draw();
    }, [
      { title: 'terrain', params: source.params, onChange: (n, v) => source.setParam(n, v) },
      { title: active, params: effects[active].params, onChange: (n, v) => effects[active].setParam(n, v) },
      {
        title: 'view',
        params: [{ name: 'heightScale', offset: 0, value: view.heightScale, lo: 0, hi: 3 }],
        onChange: (_, v) => { view.heightScale = v; },
      },
    ]);
  };
  draw();

  const engineData = new ArrayBuffer(ENGINE_BYTES);
  const sizes = new Uint32Array(engineData);
  const values = new Float32Array(engineData);
  sizes[0] = SIZE;
  sizes[1] = SIZE;

  let depth = createDepth(device, 1, 1);
  let depthWidth = 0;
  let depthHeight = 0;

  const resize = () => {
    const width = Math.max(1, Math.floor(canvas.clientWidth * devicePixelRatio));
    const height = Math.max(1, Math.floor(canvas.clientHeight * devicePixelRatio));
    if (width === depthWidth && height === depthHeight) return;
    canvas.width = width;
    canvas.height = height;
    depth.destroy();
    depth = createDepth(device, width, height);
    depthWidth = width;
    depthHeight = height;
  };

  const start = performance.now();

  const frame = () => {
    resize();

    values[2] = view.heightScale;
    values[3] = (performance.now() - start) / 1000;
    values[4] = camera.yaw;
    values[5] = camera.pitch;
    values[6] = camera.zoom;
    values[7] = depthWidth / depthHeight;
    device.queue.writeBuffer(engine, 0, engineData);

    const effect = effects[active];
    const encoder = device.createCommandEncoder();
    source.compute(encoder, GROUPS);
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
        view: depth.createView(),
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
