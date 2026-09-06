window.opener?.postMessage({ type: 'projector-ready' }, '*');
window.addEventListener('beforeunload', () => window.opener?.postMessage({ type: 'projector-closed' }, '*'));

const toggleFullscreen = () => {
  if (document.fullscreenElement) void document.exitFullscreen();
  else void document.documentElement.requestFullscreen();
};
window.addEventListener('click', toggleFullscreen);
window.addEventListener('keydown', (event) => {
  if (event.key === 'f' || event.key === 'F' || event.key === 'Enter') toggleFullscreen();
});
