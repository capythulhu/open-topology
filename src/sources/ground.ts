export type Ground = { a: number; b: number; c: number; spread: number };

export type Reading = { spread: number; coverage: number };

export type Crop = { x: number; y: number; size: number };

const WIDTH = 640;
const HEIGHT = 480;

// Anything this far from the surface is background — a wall, or the floor beyond
// the box — not something standing on it, and must not set the vertical scale.
const BACKGROUND_MM = 1000;

// The range never closes below this. Measured temporal noise on a static scene
// is 5mm median and 17mm at the 97th percentile, so a range anywhere near that
// hands the whole palette to noise the moment the surface is genuinely flat.
const QUIETEST_MM = 80;

function solve(points: Float64Array, count: number): Ground | null {
  let sxx = 0, sxy = 0, syy = 0, sx = 0, sy = 0, sz = 0, sxz = 0, syz = 0;
  for (let i = 0; i < count * 3; i += 3) {
    const x = points[i], y = points[i + 1], z = points[i + 2];
    sxx += x * x; sxy += x * y; syy += y * y;
    sx += x; sy += y; sz += z;
    sxz += x * z; syz += y * z;
  }
  const det =
    sxx * (syy * count - sy * sy) - sxy * (sxy * count - sy * sx) + sx * (sxy * sy - syy * sx);
  if (Math.abs(det) < 1e-6) return null;
  return {
    a: (sxz * (syy * count - sy * sy) - sxy * (syz * count - sy * sz) + sx * (syz * sy - syy * sz)) / det,
    b: (sxx * (syz * count - sy * sz) - sxz * (sxy * count - sy * sx) + sx * (sxy * sz - syz * sx)) / det,
    c: (sxx * (syy * sz - syz * sy) - sxy * (sxy * sz - syz * sx) + sxz * (sxy * sy - syy * sx)) / det,
    spread: 0,
  };
}

function medianAbs(values: Float64Array, count: number): number {
  const sorted = Array.from(values.subarray(0, count), Math.abs).sort((p, q) => p - q);
  return sorted[count >> 1] || 1;
}

/**
 * Fits the plane that best explains the frame and measures how far the surface
 * departs from it. Height is then read against that plane rather than against
 * the camera, so a tilted sensor cancels out instead of spending the whole
 * palette on its own tilt.
 */
export function fitGround(samples: Uint16Array, crop: Crop): { ground: Ground | null; coverage: number } {
  const cx = crop.x * WIDTH;
  const cy = crop.y * HEIGHT;
  const half = (crop.size * HEIGHT) / 2;

  const points = new Float64Array(((2 * half) / 3 + 1) ** 2 * 3);
  let count = 0;
  let looked = 0;

  for (let y = Math.max(0, cy - half) | 0; y < Math.min(HEIGHT, cy + half); y += 3) {
    for (let x = Math.max(0, cx - half) | 0; x < Math.min(WIDTH, cx + half); x += 3) {
      const z = samples[y * WIDTH + x];
      looked++;
      if (z === 0) continue;
      points[count * 3] = x;
      points[count * 3 + 1] = y;
      points[count * 3 + 2] = z;
      count++;
    }
  }

  const coverage = looked > 0 ? count / looked : 0;
  if (count < 300) return { ground: null, coverage };

  const deviations = new Float64Array(count);
  const measure = (fit: Ground) => {
    for (let i = 0, r = 0; r < count; i += 3, r++) {
      deviations[r] = points[i + 2] - (fit.a * points[i] + fit.b * points[i + 1] + fit.c);
    }
  };

  let plane = solve(points, count);
  if (!plane) return { ground: null, coverage };

  // One least-squares pass is dragged well off the surface by background, so
  // refit against whatever is still near the plane it just found.
  const inliers = new Float64Array(points.length);
  for (let pass = 0; pass < 3; pass++) {
    measure(plane);
    const limit = medianAbs(deviations, count) * 3;
    let kept = 0;
    for (let i = 0, r = 0; r < count; i += 3, r++) {
      if (Math.abs(deviations[r]) >= limit) continue;
      inliers[kept * 3] = points[i];
      inliers[kept * 3 + 1] = points[i + 1];
      inliers[kept * 3 + 2] = points[i + 2];
      kept++;
    }
    if (kept < 300) break;
    const refit = solve(inliers, kept);
    if (!refit) break;
    plane = refit;
  }

  measure(plane);
  const onSurface = Array.from(deviations.subarray(0, count), Math.abs)
    .filter((d) => d < BACKGROUND_MM)
    .sort((p, q) => p - q);
  if (onSurface.length < 100) return { ground: null, coverage };

  plane.spread = Math.max(onSurface[Math.floor(onSurface.length * 0.97)], QUIETEST_MM);
  return { ground: plane, coverage };
}

/**
 * How far the frame departs from a captured reference. Same vertical scale as the
 * plane fit, but the baseline is per pixel, so lens distortion and fixed-pattern
 * depth error cancel along with the tilt.
 */
export function spreadAgainst(samples: Uint16Array, reference: Uint16Array, crop: Crop): Reading {
  const cx = crop.x * WIDTH;
  const cy = crop.y * HEIGHT;
  const half = (crop.size * HEIGHT) / 2;

  const deviations: number[] = [];
  let looked = 0;
  let seen = 0;

  for (let y = Math.max(0, cy - half) | 0; y < Math.min(HEIGHT, cy + half); y += 3) {
    for (let x = Math.max(0, cx - half) | 0; x < Math.min(WIDTH, cx + half); x += 3) {
      const i = y * WIDTH + x;
      looked++;
      if (samples[i] === 0) continue;
      seen++;
      if (reference[i] === 0) continue;
      const deviation = Math.abs(reference[i] - samples[i]);
      if (deviation < BACKGROUND_MM) deviations.push(deviation);
    }
  }

  const coverage = looked > 0 ? seen / looked : 0;
  if (deviations.length < 100) return { spread: 0, coverage };

  deviations.sort((p, q) => p - q);
  return { spread: Math.max(deviations[Math.floor(deviations.length * 0.97)], QUIETEST_MM), coverage };
}
