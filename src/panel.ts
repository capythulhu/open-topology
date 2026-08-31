import type { Param } from './program';

export type Group = {
  title: string;
  params: Param[];
  onChange: (name: string, value: number) => void;
};

function slider(param: Param, onChange: (name: string, value: number) => void): HTMLElement {
  const row = document.createElement('label');
  row.className = 'row';

  const name = document.createElement('span');
  name.textContent = param.name;

  const readout = document.createElement('output');
  readout.textContent = param.value.toFixed(2);

  const input = document.createElement('input');
  input.type = 'range';
  input.min = String(param.lo);
  input.max = String(param.hi);
  input.step = String((param.hi - param.lo) / 200);
  input.value = String(param.value);
  input.addEventListener('input', () => {
    const value = Number(input.value);
    readout.textContent = value.toFixed(2);
    onChange(param.name, value);
  });

  const head = document.createElement('div');
  head.className = 'head';
  head.append(name, readout);
  row.append(head, input);
  return row;
}

export function renderPanel(
  root: HTMLElement,
  effects: string[],
  active: string,
  onSelect: (name: string) => void,
  groups: Group[],
) {
  root.replaceChildren();

  const title = document.createElement('h1');
  title.textContent = 'OpenTopology';

  const picker = document.createElement('select');
  for (const name of effects) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    option.selected = name === active;
    picker.append(option);
  }
  picker.addEventListener('change', () => onSelect(picker.value));
  root.append(title, picker);

  for (const group of groups) {
    if (group.params.length === 0) continue;
    const heading = document.createElement('h2');
    heading.textContent = group.title;
    root.append(heading, ...group.params.map((p) => slider(p, group.onChange)));
  }
}
