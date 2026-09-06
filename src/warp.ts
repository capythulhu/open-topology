import type { SlangModule } from './program';

export type WarpState = {
  x: number;
  y: number;
  scaleX: number;
  scaleY: number;
  quarter: number;
  tilt: number;
  mirrorX: boolean;
  mirrorY: boolean;
};

export const WARP_DEFAULT: WarpState = { x: 0, y: 0, scaleX: 1, scaleY: 1, quarter: 0, tilt: 0, mirrorX: false, mirrorY: false };

export const angleOf = (state: WarpState) => state.quarter * 90 + state.tilt;

export class Warp {
  readonly frame: GPUTexture;

  private readonly device: GPUDevice;
  private readonly pipeline: GPURenderPipeline;
  private readonly bindGroup: GPUBindGroup;
  private readonly uniform: GPUBuffer;
  private readonly data = new Float32Array(8);

  constructor(device: GPUDevice, slang: SlangModule, format: GPUTextureFormat, width: number, height: number) {
    this.device = device;
    this.frame = device.createTexture({
      size: [width, height],
      format,
      usage: GPUTextureUsage.RENDER_ATTACHMENT | GPUTextureUsage.TEXTURE_BINDING,
    });
    this.uniform = device.createBuffer({ size: 32, usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST });

    const module = device.createShaderModule({ code: slang.code });
    this.pipeline = device.createRenderPipeline({
      layout: 'auto',
      vertex: { module, entryPoint: 'vertexMain' },
      fragment: { module, entryPoint: 'fragmentMain', targets: [{ format }] },
    });

    const index = (name: string) => slang.reflection.parameters.find((p) => p.name === name)!.binding.index!;
    this.bindGroup = device.createBindGroup({
      layout: this.pipeline.getBindGroupLayout(0),
      entries: [
        { binding: index('warp'), resource: { buffer: this.uniform } },
        { binding: index('frame'), resource: this.frame.createView() },
        { binding: index('smooth'), resource: device.createSampler({ magFilter: 'linear', minFilter: 'linear' }) },
      ],
    });
  }

  set(state: WarpState) {
    const radians = (angleOf(state) * Math.PI) / 180;
    this.data.set([
      state.x * 2,
      -state.y * 2,
      state.scaleX,
      state.scaleY,
      radians,
      this.frame.width / this.frame.height,
      state.mirrorX ? -1 : 1,
      state.mirrorY ? -1 : 1,
    ]);
    this.device.queue.writeBuffer(this.uniform, 0, this.data);
  }

  draw(pass: GPURenderPassEncoder) {
    pass.setPipeline(this.pipeline);
    pass.setBindGroup(0, this.bindGroup);
    pass.draw(3);
  }

  destroy() {
    this.frame.destroy();
    this.uniform.destroy();
  }
}
