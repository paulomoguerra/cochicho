import type { Appearance } from "./ipc";

const KEY = "eko-nami-appearance";

export function readStoredAppearance(): Appearance {
  try {
    const v = localStorage.getItem(KEY);
    if (v === "light" || v === "dark") return v;
  } catch {
    /* private mode */
  }
  return "dark";
}

export function applyAppearance(appearance: Appearance) {
  document.documentElement.dataset.theme = appearance;
  try {
    localStorage.setItem(KEY, appearance);
  } catch {
    /* ignore */
  }
}
