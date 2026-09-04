import { MAX_LABELS } from './program';

export type Placed = {
  cell: [number, number];
  height: number;
  value: number;
  unit: number;
  line: number;
};

// Mirrors lib/labels.slang: 32 bytes, float2 cell, float height, float value,
// then unit, line, shown, reserved as uints.
const STRIDE = 32;
const UNITS = ['', 'mm', 'cm²', 'mL', 'mm/s', '°', ''];
const DECIMALS = [2, 0, 0, 0, 0, 0, 0];

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
    });
  }
  return out;
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
  context.font = `${12 * scale}px ui-monospace, SFMono-Regular, Menlo, monospace`;
  context.textBaseline = 'middle';
  context.lineJoin = 'round';

  for (const label of labels) {
    const at = project(label.cell, label.height);
    const x = (at.x + 10) * scale;
    const y = (at.y - 10 + label.line * 15) * scale;
    const text = `${label.value.toFixed(DECIMALS[label.unit] ?? 1)} ${UNITS[label.unit] ?? ''}`.trim();

    if (label.line === 0) {
      context.fillStyle = '#ffffff';
      context.beginPath();
      context.arc(at.x * scale, at.y * scale, 2.5 * scale, 0, Math.PI * 2);
      context.fill();
    }

    // Dark halo so the text reads over any effect.
    context.lineWidth = 3 * scale;
    context.strokeStyle = 'rgba(8, 9, 12, 0.85)';
    context.strokeText(text, x, y);
    context.fillStyle = '#e8eaee';
    context.fillText(text, x, y);
  }
}
