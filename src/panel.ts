import type { Param } from './program';

export type Group = {
  title: string;
  params: Param[];
  onChange: (name: string, value: number) => void;
};

export type Panel = {
  fields: string[];
  field: string;
  onField: (name: string) => void;
  sources: string[];
  source: string;
  onSource: (name: string) => void;
  effects: string[];
  effect: string;
  onEffect: (name: string) => void;
  groups: Group[];
  actions: { label: string; onClick: () => void }[];
  notice: string;
};

function slider(param: Param, onChange: (name: string, value: number) => void): HTMLElement {
  const row = document.createElement('label');
  row.className = 'row';

  const name = document.createElement('span');
  name.textContent = param.name;

  const readout = document.createElement('output');
  const show = (value: number) => (readout.textContent = value.toFixed(Math.abs(value) >= 100 ? 0 : 2));
  show(param.value);

  const input = document.createElement('input');
  input.type = 'range';
  input.min = String(param.lo);
  input.max = String(param.hi);
  input.step = String((param.hi - param.lo) / 200);
  input.value = String(param.value);
  input.addEventListener('input', () => {
    const value = Number(input.value);
    show(value);
    onChange(param.name, value);
  });

  const head = document.createElement('div');
  head.className = 'head';
  head.append(name, readout);
  row.append(head, input);
  return row;
}

function picker(label: string, options: string[], active: string, onPick: (name: string) => void): HTMLElement {
  const wrap = document.createElement('label');
  wrap.className = 'pick';

  const caption = document.createElement('span');
  caption.textContent = label;

  const select = document.createElement('select');
  for (const option of options) {
    const item = document.createElement('option');
    item.value = option;
    item.textContent = option;
    item.selected = option === active;
    select.append(item);
  }
  select.addEventListener('change', () => onPick(select.value));

  wrap.append(caption, select);
  return wrap;
}

export function renderPanel(root: HTMLElement, panel: Panel) {
  root.replaceChildren();

  const title = document.createElement('h1');
  title.textContent = 'OpenTopology';
  root.append(title);

  root.append(picker('field', panel.fields, panel.field, panel.onField));
  root.append(picker('source', panel.sources, panel.source, panel.onSource));
  root.append(picker('effect', panel.effects, panel.effect, panel.onEffect));

  if (panel.notice) {
    const notice = document.createElement('p');
    notice.className = 'notice';
    notice.textContent = panel.notice;
    root.append(notice);
  }

  for (const action of panel.actions) {
    const button = document.createElement('button');
    button.textContent = action.label;
    button.addEventListener('click', action.onClick);
    root.append(button);
  }

  for (const group of panel.groups) {
    if (group.params.length === 0) continue;
    const heading = document.createElement('h2');
    heading.textContent = group.title;
    root.append(heading, ...group.params.map((param) => slider(param, group.onChange)));
  }
}
