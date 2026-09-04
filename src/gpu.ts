export type Gpu = {
  device: GPUDevice;
  context: GPUCanvasContext;
  format: GPUTextureFormat;
};

export async function initGpu(canvas: HTMLCanvasElement): Promise<Gpu> {
  const adapter = await navigator.gpu?.requestAdapter();
  if (!adapter) throw new Error('WebGPU unavailable — open this in Chrome or Edge.');

  // The default is eight storage buffers per stage, which a real effect walks
  // into quickly. Ask for whatever this adapter can actually do.
  const device = await adapter.requestDevice({
    requiredLimits: {
      maxStorageBuffersPerShaderStage: adapter.limits.maxStorageBuffersPerShaderStage,
    },
  });
  const context = canvas.getContext('webgpu');
  if (!context) throw new Error('Could not create a WebGPU canvas context.');

  const format = navigator.gpu.getPreferredCanvasFormat();
  context.configure({ device, format, alphaMode: 'opaque' });
  return { device, context, format };
}

export function createDepth(device: GPUDevice, width: number, height: number): GPUTexture {
  return device.createTexture({
    size: [width, height],
    format: 'depth24plus',
    usage: GPUTextureUsage.RENDER_ATTACHMENT,
  });
}
