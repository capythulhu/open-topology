import { slider } from './panel';
import { angleOf, WARP_DEFAULT, type WarpState } from './warp';

const CORNERS = ['nw', 'ne', 'sw', 'se'] as const;
const NUDGE = 0.005;
const FIT = 0.98;

export function renderStage(state: WarpState, aspect: number, fieldAspect: number, onChange: () => void): HTMLElement {
  const wide = fieldAspect > aspect;
  const footprint = { w: wide ? FIT : (FIT * fieldAspect) / aspect, h: wide ? (FIT * aspect) / fieldAspect : FIT };

  const stage = document.createElement('div');
  stage.className = 'stage';
  stage.style.aspectRatio = String(aspect);
  stage.tabIndex = 0;

  const screen = document.createElement('div');
  screen.className = 'screen';
  stage.append(screen);

  const frame = document.createElement('div');
  frame.className = 'frame';
  frame.style.width = `${footprint.w * 100}%`;
  frame.style.height = `${footprint.h * 100}%`;
  frame.style.left = `${(1 - footprint.w) * 50}%`;
  frame.style.top = `${(1 - footprint.h) * 50}%`;
  const mark = document.createElement('span');
  mark.className = 'mark';
  mark.textContent = 'top';
  frame.append(mark);
  for (const corner of CORNERS) {
    const handle = document.createElement('i');
    handle.className = `handle ${corner}`;
    frame.append(handle);
  }
  screen.append(frame);

  const place = () => {
    const mx = state.mirrorX ? -1 : 1;
    const my = state.mirrorY ? -1 : 1;
    frame.style.transform =
      `translate(${(state.x / footprint.w) * 100}%, ${(state.y / footprint.h) * 100}%) rotate(${angleOf(state)}deg) ` +
      `scale(${state.scaleX * mx}, ${state.scaleY * my})`;
    mark.style.transform = `scale(${mx}, ${my})`;
  };
  place();

  const local = (event: PointerEvent) => {
    const box = screen.getBoundingClientRect();
    const dx = event.clientX - (box.left + box.width / 2) - state.x * box.width;
    const dy = event.clientY - (box.top + box.height / 2) - state.y * box.height;
    const radians = (-angleOf(state) * Math.PI) / 180;
    return {
      x: (Math.cos(radians) * dx - Math.sin(radians) * dy) / box.width,
      y: (Math.sin(radians) * dx + Math.cos(radians) * dy) / box.height,
    };
  };

  stage.addEventListener('pointerdown', (event) => {
    const box = screen.getBoundingClientRect();
    const target = event.target as HTMLElement;
    const corner = target.classList.contains('handle');
    const start = { x: event.clientX, y: event.clientY, sx: state.x, sy: state.y };
    stage.setPointerCapture(event.pointerId);
    stage.focus();
    event.preventDefault();

    const move = (event: PointerEvent) => {
      if (corner) {
        const p = local(event);
        state.scaleX = Math.max(0.05, (Math.abs(p.x) * 2) / footprint.w);
        state.scaleY = Math.max(0.05, (Math.abs(p.y) * 2) / footprint.h);
      } else {
        state.x = start.sx + (event.clientX - start.x) / box.width;
        state.y = start.sy + (event.clientY - start.y) / box.height;
      }
      place();
      onChange();
    };
    const stop = () => {
      stage.removeEventListener('pointermove', move);
      stage.removeEventListener('pointerup', stop);
    };
    stage.addEventListener('pointermove', move);
    stage.addEventListener('pointerup', stop);
  });

  stage.addEventListener('keydown', (event) => {
    const step = event.shiftKey ? NUDGE * 4 : NUDGE;
    if (event.key === 'ArrowLeft') state.x -= step;
    else if (event.key === 'ArrowRight') state.x += step;
    else if (event.key === 'ArrowUp') state.y -= step;
    else if (event.key === 'ArrowDown') state.y += step;
    else return;
    event.preventDefault();
    place();
    onChange();
  });

  const tools = document.createElement('div');
  tools.className = 'tools';
  const tool = (label: string, title: string, act: () => void) => {
    const button = document.createElement('button');
    button.textContent = label;
    button.title = title;
    button.addEventListener('click', () => {
      act();
      place();
      onChange();
    });
    tools.append(button);
  };
  tool('↔', 'mirror horizontally', () => (state.mirrorX = !state.mirrorX));
  tool('↕', 'mirror vertically', () => (state.mirrorY = !state.mirrorY));
  tool('↻', 'rotate a quarter turn', () => (state.quarter = (state.quarter + 1) % 4));
  tool('⟲', 'reset', () => Object.assign(state, WARP_DEFAULT));

  const sliders = document.createElement('div');
  sliders.className = 'sliders';
  const control = (name: keyof WarpState, lo: number, hi: number) =>
    sliders.append(
      slider({ name, offset: 0, value: Number(state[name]), lo, hi }, (_, value) => {
        (state[name] as number) = value;
        place();
        onChange();
      }),
    );
  control('tilt', -15, 15);
  control('height', 0, 4000);
  control('offsetX', -2000, 2000);
  control('offsetY', -2000, 2000);

  const hint = document.createElement('p');
  hint.className = 'hint';
  hint.textContent = 'drag to move, drag a corner to stretch, arrow keys to nudge';

  const wrap = document.createElement('div');
  wrap.append(stage, tools, sliders, hint);
  return wrap;
}
