const display = document.querySelector<HTMLCanvasElement>('#screen')!;
const canvas = display.transferControlToOffscreen();

const size = () => ({
  width: Math.floor(display.clientWidth * devicePixelRatio),
  height: Math.floor(display.clientHeight * devicePixelRatio),
});

window.opener?.postMessage({ type: 'projector-canvas', canvas, ...size() }, '*', [canvas]);
window.addEventListener('resize', () => window.opener?.postMessage({ type: 'projector-size', ...size() }, '*'));
window.addEventListener('beforeunload', () => window.opener?.postMessage({ type: 'projector-closed' }, '*'));

const toggleFullscreen = () => {
  if (document.fullscreenElement) void document.exitFullscreen();
  else void document.documentElement.requestFullscreen();
};
window.addEventListener('click', toggleFullscreen);
window.addEventListener('keydown', (event) => {
  if (event.key === 'f' || event.key === 'F' || event.key === 'Enter') toggleFullscreen();
});
