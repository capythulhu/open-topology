export type Camera = { yaw: number; pitch: number; zoom: number };

export function createCamera(canvas: HTMLCanvasElement): Camera {
  const camera: Camera = { yaw: 0.6, pitch: 0.9, zoom: 1.6 };
  let dragging = false;
  let lastX = 0;
  let lastY = 0;

  canvas.addEventListener('pointerdown', (e) => {
    dragging = true;
    lastX = e.clientX;
    lastY = e.clientY;
    canvas.setPointerCapture(e.pointerId);
  });

  canvas.addEventListener('pointerup', (e) => {
    dragging = false;
    canvas.releasePointerCapture(e.pointerId);
  });

  canvas.addEventListener('pointermove', (e) => {
    if (!dragging) return;
    camera.yaw += (e.clientX - lastX) * 0.01;
    camera.pitch = Math.max(0.05, Math.min(1.5, camera.pitch + (e.clientY - lastY) * 0.01));
    lastX = e.clientX;
    lastY = e.clientY;
  });

  canvas.addEventListener('wheel', (e) => {
    e.preventDefault();
    camera.zoom = Math.max(0.4, Math.min(6, camera.zoom * (e.deltaY > 0 ? 0.94 : 1.06)));
  }, { passive: false });

  return camera;
}
