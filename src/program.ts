export type Attrib = { name: string; arguments: (number | string)[] };

export type EntryPoint = {
  name: string;
  stage: 'vertex' | 'fragment' | 'compute';
  userAttribs?: Attrib[];
};

type ElementType = {
  kind?: string;
  elementCount?: number;
  sizes?: { value: number }[];
  fields?: { binding: { offset: number; size: number } }[];
};

export type ReflectionParam = {
  name: string;
  binding: { kind: string; index?: number; offset?: number };
  type?: { resultType?: ElementType };
  userAttribs?: Attrib[];
};

export type Reflection = { entryPoints: EntryPoint[]; parameters: ReflectionParam[] };

export type SlangModule = { code: string; reflection: Reflection };

export type Param = { name: string; offset: number; value: number; lo: number; hi: number };

const PARAMS = 'globalParams';
export const MAX_LABELS = 64;
const ALL_STAGES = GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE;
const BINDING = /@binding\((\d+)\)\s+@group\(0\)\s+var<\s*(uniform|storage)\s*(?:,\s*(read|read_write)\s*)?>\s*(\w+)/g;

type Slot = { name: string; symbol: string; index: number; type: GPUBufferBindingType };

function slotsOf(code: string): Slot[] {
  return [...code.matchAll(BINDING)].map((m) => ({
    index: Number(m[1]),
    symbol: m[4],
    name: m[4].replace(/_\d+$/, ''),
    type: m[2] === 'uniform' ? 'uniform' : m[3] === 'read_write' ? 'storage' : 'read-only-storage',
  }));
}

// Each stage may only see so many storage buffers, and the count is taken from
// the layout, not from what a shader touches. Reflection lists every global for
// every entry point, so usage has to come from the WGSL: walk each entry
// point's call graph and note which buffers it actually reaches.
function bodiesOf(code: string): Map<string, string> {
  const bodies = new Map<string, string>();
  const heads = /\bfn\s+(\w+)\s*\(/g;
  for (const head of code.matchAll(heads)) {
    let at = code.indexOf('{', head.index);
    if (at < 0) continue;
    let depth = 0;
    const start = at;
    for (; at < code.length; at++) {
      if (code[at] === '{') depth++;
      else if (code[at] === '}' && --depth === 0) break;
    }
    bodies.set(head[1], code.slice(start, at + 1));
  }
  return bodies;
}

function visibilityOf(code: string, slots: Slot[], entries: EntryPoint[]): Map<number, number> {
  const bodies = bodiesOf(code);
  const stageBit = { vertex: GPUShaderStage.VERTEX, fragment: GPUShaderStage.FRAGMENT, compute: GPUShaderStage.COMPUTE };
  const visible = new Map<number, number>();

  for (const entry of entries) {
    const reached = new Set<string>();
    const pending = [entry.name];
    while (pending.length > 0) {
      const name = pending.pop()!;
      if (reached.has(name)) continue;
      reached.add(name);
      const body = bodies.get(name) ?? '';
      for (const call of body.matchAll(/\b(\w+)\s*\(/g)) if (bodies.has(call[1])) pending.push(call[1]);
    }
    const touched = [...reached].map((name) => bodies.get(name) ?? '').join('\n');
    for (const slot of slots) {
      if (new RegExp(`\\b${slot.symbol}\\b`).test(touched)) {
        visible.set(slot.index, (visible.get(slot.index) ?? 0) | stageBit[entry.stage]);
      }
    }
  }
  return visible;
}

function paramsOf(reflection: Reflection): Param[] {
  const params: Param[] = [];
  for (const p of reflection.parameters) {
    const attr = p.userAttribs?.find((a) => a.name === 'Param');
    if (!attr || p.binding.kind !== 'uniform') continue;
    const [value, lo, hi] = attr.arguments.map(Number);
    params.push({ name: p.name, offset: p.binding.offset ?? 0, value, lo, hi });
  }
  return params;
}

function iterationsOf(entry: EntryPoint): number {
  return Number(entry.userAttribs?.find((a) => a.name === 'Iterations')?.arguments[0] ?? 1);
}

// The wasm build's reflection reports struct fields but not the struct's own
// size, and nothing at all for scalars, so this pieces the stride together.
// Over-allocating is harmless; under-allocating rejects every command buffer.
function elementBytes(reflection: Reflection, name: string): number {
  const element = reflection.parameters.find((p) => p.name === name)?.type?.resultType;
  if (!element) return 16;
  if (element.sizes?.[0]) return element.sizes[0].value;
  if (element.fields?.length) {
    const end = Math.max(...element.fields.map((f) => f.binding.offset + f.binding.size));
    return Math.ceil(end / 16) * 16;
  }
  if (element.kind === 'vector') return element.elementCount === 2 ? 8 : 16;
  return 4;
}

function hasAttribute(reflection: Reflection, name: string, attribute: string): boolean {
  return reflection.parameters.find((p) => p.name === name)?.userAttribs?.some((a) => a.name === attribute) ?? false;
}

function snapshotsOf(reflection: Reflection): { from: string; to: string }[] {
  const pairs: { from: string; to: string }[] = [];
  for (const p of reflection.parameters) {
    const attr = p.userAttribs?.find((a) => a.name === 'Snapshot');
    if (attr) pairs.push({ from: String(attr.arguments[0]), to: p.name });
  }
  return pairs;
}

export class Program {
  readonly params: Param[];
  readonly labels: GPUBuffer | null = null;

  private readonly device: GPUDevice;
  private readonly bindGroup: GPUBindGroup;
  private readonly computePasses: { pipeline: GPUComputePipeline; iterations: number }[] = [];
  private readonly renderPipeline: GPURenderPipeline | null = null;
  private readonly perCell: number | null = null;
  private readonly fixedVertices: number | null = null;
  private readonly paramsBuffer: GPUBuffer | null = null;
  private readonly snapshots: { from: GPUBuffer; to: GPUBuffer }[] = [];
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
      const labels = hasAttribute(slang.reflection, slot.name, 'Labels');
      const size =
        slot.name === PARAMS
          ? this.paramsData.byteLength
          : (labels ? MAX_LABELS : cells) * elementBytes(slang.reflection, slot.name);
      const usage =
        slot.type === 'uniform'
          ? GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST
          : GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST | GPUBufferUsage.COPY_SRC;
      buffers[slot.name] = device.createBuffer({ size, usage });
      if (labels) this.labels = buffers[slot.name];
    }
    this.paramsBuffer = buffers[PARAMS] ?? null;

    for (const { from, to } of snapshotsOf(slang.reflection)) {
      if (buffers[from] && buffers[to]) this.snapshots.push({ from: buffers[from], to: buffers[to] });
    }

    // read_write storage is illegal in the vertex stage, so those bindings skip it.
    const visible = visibilityOf(slang.code, slots, slang.reflection.entryPoints);
    const layout = device.createBindGroupLayout({
      entries: slots.map((s) => ({
        binding: s.index,
        visibility:
          (visible.get(s.index) ?? GPUShaderStage.COMPUTE) &
          (s.type === 'storage' ? ALL_STAGES & ~GPUShaderStage.VERTEX : ALL_STAGES),
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
      const count = (name: string) => {
        const value = vertex.userAttribs?.find((a) => a.name === name)?.arguments[0];
        return value === undefined ? null : Number(value);
      };
      this.perCell = count('PerCell');
      this.fixedVertices = count('Vertices');
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
    if (this.computePasses.length > 0) {
      const pass = encoder.beginComputePass();
      pass.setBindGroup(0, this.bindGroup);
      for (const { pipeline, iterations } of this.computePasses) {
        pass.setPipeline(pipeline);
        for (let i = 0; i < iterations; i++) pass.dispatchWorkgroups(columns, rows);
      }
      pass.end();
    }
    for (const { from, to } of this.snapshots) {
      encoder.copyBufferToBuffer(from, 0, to, 0, Math.min(from.size, to.size));
    }
  }

  draw(pass: GPURenderPassEncoder, columns: number, rows: number) {
    if (!this.renderPipeline) return;
    // PerCell scales with the field, Vertices is a fixed extra on top; an
    // effect with both draws its per-cell geometry first and the fixed part after.
    const vertices =
      this.perCell === null && this.fixedVertices === null
        ? (columns - 1) * (rows - 1) * 6
        : columns * rows * (this.perCell ?? 0) + (this.fixedVertices ?? 0);
    pass.setPipeline(this.renderPipeline);
    pass.setBindGroup(0, this.bindGroup);
    pass.draw(vertices);
  }
}
