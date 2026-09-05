const WIDTH = 208;
const HEIGHT = 156;
const DEPTH_WIDTH = 640;
const DEPTH_HEIGHT = 480;

export type Preview = {
  element: HTMLCanvasElement;
  draw: (frame: Uint8Array<ArrayBuffer>, crop: { x: number; y: number; size: number; aspect: number }) => void;
};

export function createPreview(): Preview {
  const element = document.createElement('canvas');
  element.className = 'preview';
  element.width = WIDTH;
  element.height = HEIGHT;

  const context = element.getContext('2d')!;
  const image = context.createImageData(WIDTH, HEIGHT);

  const draw: Preview['draw'] = (frame, crop) => {
    const samples = new Uint16Array(frame.buffer);

    let near = 65535;
    let far = 0;
    for (let i = 0; i < samples.length; i += 37) {
      const z = samples[i];
      if (z === 0) continue;
      if (z < near) near = z;
      if (z > far) far = z;
    }
    const span = Math.max(far - near, 1);

    for (let y = 0; y < HEIGHT; y++) {
      const sy = ((y * DEPTH_HEIGHT) / HEIGHT) | 0;
      for (let x = 0; x < WIDTH; x++) {
        const z = samples[sy * DEPTH_WIDTH + (((x * DEPTH_WIDTH) / WIDTH) | 0)];
        const at = (y * WIDTH + x) * 4;
        const shade = z === 0 ? 0 : 40 + 215 * (1 - (z - near) / span);
        image.data[at] = shade;
        image.data[at + 1] = shade;
        image.data[at + 2] = shade;
        image.data[at + 3] = 255;
      }
    }
    context.putImageData(image, 0, 0);

    const window = crop.size * DEPTH_HEIGHT;
    const w = (window * crop.aspect * WIDTH) / DEPTH_WIDTH;
    const h = (window * HEIGHT) / DEPTH_HEIGHT;
    context.strokeStyle = '#6aa9ff';
    context.lineWidth = 1;
    context.strokeRect(crop.x * WIDTH - w / 2, crop.y * HEIGHT - h / 2, w, h);
  };

  return { element, draw };
}
