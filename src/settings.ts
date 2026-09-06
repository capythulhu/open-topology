import type { WarpState } from './warp';

export type Settings = {
  field?: string;
  effect?: string;
  params?: Record<string, Record<string, number>>;
  view?: { heightScale: number; spin: number };
  projector?: WarpState;
  placement?: Placement;
};

export type Placement = { left: number; top: number; width: number; height: number };

const KEY = 'open-topology.settings';

export async function loadSettings(): Promise<Settings> {
  try {
    const response = await fetch('/settings');
    if (response.ok) return (await response.json()) as Settings;
  } catch {}
  try {
    return JSON.parse(localStorage.getItem(KEY) ?? '{}') as Settings;
  } catch {
    return {};
  }
}

let pending: ReturnType<typeof setTimeout> | null = null;

export function saveSettings(settings: Settings) {
  if (pending) clearTimeout(pending);
  pending = setTimeout(() => {
    pending = null;
    const body = JSON.stringify(settings, null, 2);
    try {
      localStorage.setItem(KEY, body);
    } catch {}
    void fetch('/settings', { method: 'PUT', headers: { 'content-type': 'application/json' }, body }).catch(() => {});
  }, 300);
}
