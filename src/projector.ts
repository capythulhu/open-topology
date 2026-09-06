window.opener?.postMessage({ type: 'projector-ready' }, '*');

let placed = '';
setInterval(() => {
  if (document.fullscreenElement) return;
  const placement = { left: window.screenX, top: window.screenY, width: window.outerWidth, height: window.outerHeight };
  const key = JSON.stringify(placement);
  if (key === placed) return;
  placed = key;
  window.opener?.postMessage({ type: 'projector-placed', ...placement }, '*');
}, 1000);
window.addEventListener('beforeunload', () => window.opener?.postMessage({ type: 'projector-closed' }, '*'));

const toggleFullscreen = () => {
  if (document.fullscreenElement) void document.exitFullscreen();
  else void document.documentElement.requestFullscreen();
};
window.addEventListener('click', toggleFullscreen);
window.addEventListener('keydown', (event) => {
  if (event.key === 'f' || event.key === 'F' || event.key === 'Enter') toggleFullscreen();
});
