export type Attrib = { name: string; arguments: number[] };

export type EntryPoint = {
  name: string;
  stage: 'vertex' | 'fragment' | 'compute';
  userAttribs?: Attrib[];
};

export type ReflectionParam = {
  name: string;
  binding: { kind: string; index?: number; offset?: number };
  userAttribs?: Attrib[];
};

export type Reflection = { entryPoints: EntryPoint[]; parameters: ReflectionParam[] };

export type SlangModule = { code: string; reflection: Reflection };

export type Param = { name: string; offset: number; value: number; lo: number; hi: number };

const PARAMS = 'globalParams';
const ALL_STAGES = GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE;
const BINDING = /@binding\((\d+)\)\s+@group\(0\)\s+var<\s*(uniform|storage)\s*(?:,\s*(read|read_write)\s*)?>\s*(\w+)/g;

type Slot = { name: string; index: number; type: GPUBufferBindingType };

function slotsOf(code: string): Slot[] {
  return [...code.matchAll(BINDING)].map((m) => ({
    index: Number(m[1]),
    name: m[4].replace(/_\d+$/, ''),
    type: m[2] === 'uniform' ? 'uniform' : m[3] === 'read_write' ? 'storage' : 'read-only-storage',
  }));
}

function paramsOf(reflection: Reflection): Param[] {
  const params: Param[] = [];
  for (const p of reflection.parameters) {
    const attr = p.userAttribs?.find((a) => a.name === 'Param');
    if (!attr || p.binding.kind !== 'uniform') continue;
    const [value, lo, hi] = attr.arguments;
    params.push({ name: p.name, offset: p.binding.offset ?? 0, value, lo, hi });
  }
  return params;
}

function iterationsOf(entry: EntryPoint): number {
  return entry.userAttribs?.find((a) => a.name === 'Iterations')?.arguments[0] ?? 1;
}

export class Program {
  readonly params: Param[];

  private readonly device: GPUDevice;
  private readonly bindGroup: GPUBindGroup;
  private readonly computePasses: { pipeline: GPUComputePipeline; iterations: number }[] = [];
  private readonly renderPipeline: GPURenderPipeline | null = null;
  private readonly perCell: number | null = null;
  private readonly paramsBuffer: GPUBuffer | null = null;
  private readonly paramsData: Float32Array<ArrayBuffer>;

  constructor(
    device: GPUDevice,
    slang: SlangModule,
    shared: Record<string, GPUBuffer>,
    cells: number,
    format: GPUTextureFormat,
  ) {
    this.device = device;
    this.params = paramsOf(slang.reflection);
    const bytes = this.params.reduce((max, p) => Math.max(max, p.offset + 4), 16);
    this.paramsData = new Float32Array(new ArrayBuffer(Math.ceil(bytes / 16) * 16));
    for (const p of this.params) this.paramsData[p.offset / 4] = p.value;

    const slots = slotsOf(slang.code);
    const buffers: Record<string, GPUBuffer> = { ...shared };

    for (const slot of slots) {
      if (buffers[slot.name]) continue;
      const size = slot.name === PARAMS ? this.paramsData.byteLength : cells * 16;
      const usage =
        slot.type === 'uniform'
          ? GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
          : GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST;
      buffers[slot.name] = device.createBuffer({ size, usage });
    }
    this.paramsBuffer = buffers[PARAMS] ?? null;

    // read_write storage is illegal in the vertex stage, so those bindings skip it.
    const layout = device.createBindGroupLayout({
      entries: slots.map((s) => ({
        binding: s.index,
        visibility: s.type === 'storage' ? ALL_STAGES & ~GPUShaderStage.VERTEX : ALL_STAGES,
        buffer: { type: s.type },
      })),
    });

    this.bindGroup = device.createBindGroup({
      layout,
      entries: slots.map((s) => ({ binding: s.index, resource: { buffer: buffers[s.name] } })),
    });

    const module = device.createShaderModule({ code: slang.code });
    const pipelineLayout = device.createPipelineLayout({ bindGroupLayouts: [layout] });

    for (const entry of slang.reflection.entryPoints) {
      if (entry.stage !== 'compute') continue;
      this.computePasses.push({
        pipeline: device.createComputePipeline({
          layout: pipelineLayout,
          compute: { module, entryPoint: entry.name },
        }),
        iterations: iterationsOf(entry),
      });
    }

    const vertex = slang.reflection.entryPoints.find((e) => e.stage === 'vertex');
    const fragment = slang.reflection.entryPoints.find((e) => e.stage === 'fragment');
    if (vertex && fragment) {
      const points = vertex.userAttribs?.some((a) => a.name === 'Points') ?? false;
      this.perCell = vertex.userAttribs?.find((a) => a.name === 'PerCell')?.arguments[0] ?? null;
      this.renderPipeline = device.createRenderPipeline({
        layout: pipelineLayout,
        vertex: { module, entryPoint: vertex.name },
        fragment: { module, entryPoint: fragment.name, targets: [{ format }] },
        primitive: { topology: points ? 'point-list' : 'triangle-list' },
        depthStencil: { format: 'depth24plus', depthWriteEnabled: true, depthCompare: 'less' },
      });
    }

    this.writeParams();
  }

  setParam(name: string, value: number) {
    const param = this.params.find((p) => p.name === name);
    if (!param) return;
    param.value = value;
    this.paramsData[param.offset / 4] = value;
    this.writeParams();
  }

  writeParams() {
    if (this.paramsBuffer) this.device.queue.writeBuffer(this.paramsBuffer, 0, this.paramsData);
  }

  compute(encoder: GPUCommandEncoder, columns: number, rows: number) {
    if (this.computePasses.length === 0) return;
    const pass = encoder.beginComputePass();
    pass.setBindGroup(0, this.bindGroup);
    for (const { pipeline, iterations } of this.computePasses) {
      pass.setPipeline(pipeline);
      for (let i = 0; i < iterations; i++) pass.dispatchWorkgroups(columns, rows);
    }
    pass.end();
  }

  draw(pass: GPURenderPassEncoder, columns: number, rows: number) {
    if (!this.renderPipeline) return;
    const vertices =
      this.perCell === null ? (columns - 1) * (rows - 1) * 6 : columns * rows * this.perCell;
    pass.setPipeline(this.renderPipeline);
    pass.setBindGroup(0, this.bindGroup);
    pass.draw(vertices);
  }
}
