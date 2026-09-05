const display = document.querySelector<HTMLCanvasElement>('#screen')!;
const surface = display.getContext('bitmaprenderer')!;

const report = () => {
  display.width = Math.floor(display.clientWidth * devicePixelRatio);
  display.height = Math.floor(display.clientHeight * devicePixelRatio);
  window.opener?.postMessage({ type: 'projector-size', width: display.width, height: display.height }, '*');
};

window.addEventListener('message', (event) => {
  if (event.source !== window.opener) return;
  if (event.data instanceof ImageBitmap) surface.transferFromImageBitmap(event.data);
});

window.addEventListener('resize', report);
window.addEventListener('beforeunload', () => window.opener?.postMessage({ type: 'projector-closed' }, '*'));

const toggleFullscreen = () => {
  if (document.fullscreenElement) void document.exitFullscreen();
  else void document.documentElement.requestFullscreen();
};
window.addEventListener('click', toggleFullscreen);
window.addEventListener('keydown', (event) => {
  if (event.key === 'f' || event.key === 'F' || event.key === 'Enter') toggleFullscreen();
});

report();
