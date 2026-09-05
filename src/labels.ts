import { MAX_LABELS } from './program';

export type Placed = {
  cell: [number, number];
  height: number;
  value: number;
  unit: number;
  line: number;
  tag: number;
};

const STRIDE = 32;
const UNITS = ['', 'mm', 'cm²', 'mL', 'mm/s', '°', '', '%'];
const DECIMALS = [2, 0, 0, 0, 0, 0, 0, 0];
const TAGS = ['', 'L', 'W', 'H', 'r', 'impact'];

export const LABELS_BYTES = MAX_LABELS * STRIDE;

export function parseLabels(bytes: ArrayBuffer): Placed[] {
  const floats = new Float32Array(bytes);
  const uints = new Uint32Array(bytes);
  const out: Placed[] = [];
  for (let i = 0; i < MAX_LABELS; i++) {
    const at = i * (STRIDE / 4);
    if (uints[at + 6] === 0) continue;
    out.push({
      cell: [floats[at], floats[at + 1]],
      height: floats[at + 2],
      value: floats[at + 3],
      unit: uints[at + 4],
      line: uints[at + 5],
      tag: uints[at + 7],
    });
  }
  return out;
}

export function createStabilizer() {
  type Tracked = Placed & { missing: number };
  let tracked: Tracked[] = [];

  return (incoming: Placed[]): Placed[] => {
    const claimed = new Set<number>();
    const next: Tracked[] = [];

    for (const label of incoming) {
      let best = -1;
      let nearest = 40;
      tracked.forEach((t, i) => {
        if (claimed.has(i) || t.unit !== label.unit || t.tag !== label.tag || t.line !== label.line) return;
        const d = Math.hypot(t.cell[0] - label.cell[0], t.cell[1] - label.cell[1]);
        if (d < nearest) {
          nearest = d;
          best = i;
        }
      });

      if (best < 0) {
        next.push({ ...label, cell: [label.cell[0], label.cell[1]], missing: 0 });
        continue;
      }
      const t = tracked[best];
      claimed.add(best);
      t.cell = [t.cell[0] + (label.cell[0] - t.cell[0]) * 0.2, t.cell[1] + (label.cell[1] - t.cell[1]) * 0.2];
      t.height += (label.height - t.height) * 0.2;
      t.value += (label.value - t.value) * 0.12;
      t.missing = 0;
      next.push(t);
    }

    tracked.forEach((t, i) => {
      if (claimed.has(i) || ++t.missing >= 20) return;
      const twin = next.some(
        (n) => n.missing === 0 && n.unit === t.unit && n.tag === t.tag && n.line === t.line &&
          Math.hypot(n.cell[0] - t.cell[0], n.cell[1] - t.cell[1]) < 40,
      );
      if (!twin) next.push(t);
    });
    tracked = next;
    return tracked;
  };
}

export function drawLabels(
  context: CanvasRenderingContext2D,
  labels: Placed[],
  project: (cell: [number, number], height: number) => { x: number; y: number },
) {
  const { canvas } = context;
  context.clearRect(0, 0, canvas.width, canvas.height);
  if (labels.length === 0) return;

  const scale = devicePixelRatio;
  const lineHeight = 15;
  context.font = `${12 * scale}px ui-monospace, SFMono-Regular, Menlo, monospace`;
  context.textBaseline = 'middle';
  context.lineJoin = 'round';

  type Block = { anchor: { x: number; y: number }; x: number; y: number; w: number; h: number; lines: { text: string; line: number }[] };
  const blocks: Block[] = [];
  for (const label of labels) {
    const text = `${TAGS[label.tag] ?? ''} ${label.value.toFixed(DECIMALS[label.unit] ?? 1)} ${UNITS[label.unit] ?? ''}`.trim();
    let block = blocks.find((b) => b.anchor.x === label.cell[0] && b.anchor.y === label.cell[1]);
    if (!block) {
      const at = project(label.cell, label.height);
      block = { anchor: { x: label.cell[0], y: label.cell[1] }, x: at.x + 10, y: at.y - 10, w: 0, h: 0, lines: [] };
      (block as Block & { dot: { x: number; y: number } }).dot = at;
      blocks.push(block);
    }
    block.lines.push({ text, line: label.line });
    block.w = Math.max(block.w, context.measureText(text).width / scale);
    block.h = Math.max(block.h, (label.line + 1) * lineHeight);
  }

  const placed: Block[] = [];
  for (const block of blocks) {
    for (let guard = 0; guard < 16; guard++) {
      const hit = placed.find(
        (p) => block.x < p.x + p.w + 8 && block.x + block.w + 8 > p.x && block.y < p.y + p.h && block.y + block.h > p.y - lineHeight,
      );
      if (!hit) break;
      block.y = hit.y + hit.h + 4;
    }
    placed.push(block);
  }

  for (const block of placed) {
    const dot = (block as Block & { dot: { x: number; y: number } }).dot;
    context.fillStyle = '#ffffff';
    context.beginPath();
    context.arc(dot.x * scale, dot.y * scale, 2.5 * scale, 0, Math.PI * 2);
    context.fill();

    if (block.y - (dot.y - 10) > lineHeight) {
      context.strokeStyle = 'rgba(255, 255, 255, 0.5)';
      context.lineWidth = 1 * scale;
      context.beginPath();
      context.moveTo(dot.x * scale, dot.y * scale);
      context.lineTo((block.x - 4) * scale, block.y * scale);
      context.stroke();
    }

    for (const { text, line } of block.lines) {
      const x = block.x * scale;
      const y = (block.y + line * lineHeight) * scale;
      context.lineWidth = 3 * scale;
      context.strokeStyle = 'rgba(8, 9, 12, 0.85)';
      context.strokeText(text, x, y);
      context.fillStyle = '#e8eaee';
      context.fillText(text, x, y);
    }
  }
}
