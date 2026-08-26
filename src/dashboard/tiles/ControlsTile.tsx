import { useEffect, useState } from "react";
import {
  type HotkeyMode,
  type HotkeySpec,
  type HudSize,
  type Language,
  type PermissionsStatus,
  type Settings,
  type TerminalPaste,
  hotkeyCaptureBegin,
  hotkeyCaptureCancel,
  hotkeyRestart,
  permissionsPromptAccessibility,
  permissionsOpenSettings,
  permissionsRequestMicrophone,
  permissionsStatus,
  settingsUpdate,
} from "../../lib/ipc";
import { isRoomy, type TileSize } from "../layout";
import { Card, CardHeader, FlagRow, SegmentPicker } from "../ui";

const MAC_PRESETS: HotkeySpec[] = [
  { key_code: 61, modifier_flag: 0x40, display_name: "R⌥" },
  { key_code: 54, modifier_flag: 0x10, display_name: "R⌘" },
  { key_code: 63, modifier_flag: 0x800000, display_name: "FN" },
];

const LINUX_PRESETS: HotkeySpec[] = [
  { key_code: 97, modifier_flag: 0, display_name: "RCTRL" },
  { key_code: 100, modifier_flag: 0, display_name: "RALT" },
  { key_code: 125, modifier_flag: 0, display_name: "RMENU" },
];

function sameHotkey(a: HotkeySpec, b: HotkeySpec): boolean {
  return a.key_code === b.key_code && a.modifier_flag === b.modifier_flag;
}

const MAC_KEY_CODES: Record<string, number> = {
  KeyA: 0x00, KeyS: 0x01, KeyD: 0x02, KeyF: 0x03, KeyH: 0x04, KeyG: 0x05,
  KeyZ: 0x06, KeyX: 0x07, KeyC: 0x08, KeyV: 0x09, KeyB: 0x0b, KeyQ: 0x0c,
  KeyW: 0x0d, KeyE: 0x0e, KeyR: 0x0f, KeyY: 0x10, KeyT: 0x11, Digit1: 0x12,
  Digit2: 0x13, Digit3: 0x14, Digit4: 0x15, Digit6: 0x16, Digit5: 0x17,
  Digit9: 0x19, Digit7: 0x1a, Digit8: 0x1c, Digit0: 0x1d, KeyO: 0x1f,
  KeyU: 0x20, KeyI: 0x22, KeyP: 0x23, KeyL: 0x25, KeyJ: 0x26, KeyK: 0x28,
  Equal: 0x18, Minus: 0x1b, BracketRight: 0x1e, BracketLeft: 0x21,
  Quote: 0x27, Semicolon: 0x29, Backslash: 0x2a, Comma: 0x2b, Slash: 0x2c,
  KeyN: 0x2d, KeyM: 0x2e, Period: 0x2f, Tab: 0x30, Space: 0x31,
  Backquote: 0x32, Backspace: 0x33, Escape: 0x35, CapsLock: 0x39, Enter: 0x24,
  F1: 0x7a, F2: 0x78, F3: 0x63, F4: 0x76, F5: 0x60, F6: 0x61,
  F7: 0x62, F8: 0x64, F9: 0x65, F10: 0x6d, F11: 0x67, F12: 0x6f,
  F13: 0x69, F14: 0x6b, F15: 0x71, F16: 0x6a, F17: 0x40, F18: 0x4f,
  F19: 0x50, F20: 0x5a, Home: 0x73, PageUp: 0x74, Delete: 0x75,
  End: 0x77, PageDown: 0x79, ArrowLeft: 0x7b, ArrowRight: 0x7c,
  ArrowDown: 0x7d, ArrowUp: 0x7e,
};

const MAC_MODIFIERS: Record<string, HotkeySpec> = {
  ControlLeft: { key_code: 59, modifier_flag: 0x01, display_name: "L⌃" },
  ShiftLeft: { key_code: 56, modifier_flag: 0x02, display_name: "L⇧" },
  ShiftRight: { key_code: 60, modifier_flag: 0x04, display_name: "R⇧" },
  MetaLeft: { key_code: 55, modifier_flag: 0x08, display_name: "L⌘" },
  MetaRight: { key_code: 54, modifier_flag: 0x10, display_name: "R⌘" },
  AltLeft: { key_code: 58, modifier_flag: 0x20, display_name: "L⌥" },
  AltRight: { key_code: 61, modifier_flag: 0x40, display_name: "R⌥" },
  ControlRight: { key_code: 62, modifier_flag: 0x2000, display_name: "R⌃" },
  Fn: { key_code: 63, modifier_flag: 0x800000, display_name: "FN" },
};

const LINUX_KEY_CODES: Record<string, number> = {
  Escape: 1, Digit1: 2, Digit2: 3, Digit3: 4, Digit4: 5, Digit5: 6,
  Digit6: 7, Digit7: 8, Digit8: 9, Digit9: 10, Digit0: 11, KeyQ: 16,
  KeyW: 17, KeyE: 18, KeyR: 19, KeyT: 20, KeyY: 21, KeyU: 22, KeyI: 23,
  KeyO: 24, KeyP: 25, KeyA: 30, KeyS: 31, KeyD: 32, KeyF: 33, KeyG: 34,
  KeyH: 35, KeyJ: 36, KeyK: 37, KeyL: 38, KeyZ: 44, KeyX: 45, KeyC: 46,
  KeyV: 47, KeyB: 48, KeyN: 49, KeyM: 50, Space: 57, CapsLock: 58,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66,
  F9: 67, F10: 68, F11: 87, F12: 88,
};

export function hotkeyFromKeyboardEvent(e: KeyboardEvent, isMac: boolean): HotkeySpec | null {
  if (isMac && MAC_MODIFIERS[e.code]) return MAC_MODIFIERS[e.code]!;
  if (!isMac && e.code === "ControlRight") return LINUX_PRESETS[0]!;
  if (!isMac && e.code === "AltRight") return LINUX_PRESETS[1]!;

  const keyCode = (isMac ? MAC_KEY_CODES : LINUX_KEY_CODES)[e.code];
  if (keyCode === undefined) return null;
  const labels: Record<string, string> = {
    Space: "SPACE", Escape: "ESC", Enter: "RETURN", Backspace: "DELETE",
    Delete: "FWD DEL", Tab: "TAB", ArrowLeft: "←", ArrowRight: "→",
    ArrowUp: "↑", ArrowDown: "↓", PageUp: "PGUP", PageDown: "PGDN",
  };
  const display = e.code.startsWith("Key")
    ? e.code.slice(3)
    : e.code.startsWith("Digit")
      ? e.code.slice(5)
      : labels[e.code] ?? e.code.toUpperCase();
  return { key_code: keyCode, modifier_flag: 0, display_name: display };
}

export function ControlsTile({
  size,
  settings,
  isMac,
  isLinux,
  hotkeyWarning,
}: {
  size: TileSize;
  settings: Settings;
  isMac: boolean;
  isLinux: boolean;
  hotkeyWarning: string | null;
}) {
  const roomy = isRoomy(size);
  const presets = isMac ? MAC_PRESETS : LINUX_PRESETS;
  const [recording, setRecording] = useState(false);
  const [captureError, setCaptureError] = useState<string | null>(null);
  const [permissions, setPermissions] = useState<PermissionsStatus | null>(null);

  useEffect(() => {
    if (!isMac) return;
    const refresh = () => {
      permissionsStatus()
        .then((next) => {
          setPermissions(next);
          if (next.accessibility && hotkeyWarning) {
            void hotkeyRestart().catch(() => {});
          }
        })
        .catch(() => {});
    };
    refresh();
    const timer = window.setInterval(refresh, 2000);
    return () => window.clearInterval(timer);
  }, [isMac, hotkeyWarning]);

  useEffect(() => {
    if (!recording || isMac) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      const isIsolatedModifier = isMac && !!MAC_MODIFIERS[e.code];
      if (!isIsolatedModifier && (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey)) {
        setCaptureError("USE UMA TECLA SÓ");
        return;
      }
      const spec = hotkeyFromKeyboardEvent(e, isMac);
      if (!spec) {
        setCaptureError("TECLA NÃO SUPORTADA");
        return;
      }
      void settingsUpdate({ hotkey: spec })
        .then(() => {
          setCaptureError(null);
          setRecording(false);
        })
        .catch(() => {
          setCaptureError("NÃO FOI POSSÍVEL SALVAR");
          void hotkeyCaptureCancel();
        });
    };
    const onBlur = () => {
      setRecording(false);
      void hotkeyCaptureCancel();
    };
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("keydown", onKey, true);
      window.removeEventListener("blur", onBlur);
      void hotkeyCaptureCancel();
    };
  }, [recording, isMac]);

  useEffect(() => {
    if (!recording || !isMac) return;
    const onBlur = () => {
      setRecording(false);
      void hotkeyCaptureCancel();
    };
    window.addEventListener("blur", onBlur);
    return () => window.removeEventListener("blur", onBlur);
  }, [recording, isMac]);

  const patch = (partial: Partial<Settings>) => {
    void settingsUpdate(partial);
  };

  const setDock = (on: boolean) => {
    patch({ show_dock: on });
  };

  return (
    <Card>
      <CardHeader number="06" title="CONTROLES" />
      <div className="card-body controls-scroll" style={{ gap: roomy ? 8 : 12 }}>
        <div>
          <div style={{ display: "flex", justifyContent: "space-between", marginBottom: 8 }}>
            <span className="muted">TECLA DE ATIVAÇÃO</span>
            <span style={{ fontSize: 11, fontWeight: 600, color: "var(--accent)" }}>
              {settings.hotkey.display_name}
            </span>
          </div>
          <div className="seg">
            {presets.map((p) => (
              <button
                key={p.display_name}
                type="button"
                className={`seg-btn${sameHotkey(settings.hotkey, p) ? " on" : ""}`}
                onClick={() => {
                  setRecording(false);
                  setCaptureError(null);
                  void settingsUpdate({ hotkey: p });
                }}
              >
                {p.display_name}
              </button>
            ))}
            <button
              type="button"
              className={`seg-btn${recording ? " on" : ""}`}
              onClick={() => {
                if (recording) {
                  setRecording(false);
                  setCaptureError(null);
                  void hotkeyCaptureCancel();
                } else {
                  setCaptureError(null);
                  setRecording(true);
                  if (isMac) {
                    void hotkeyCaptureBegin()
                      .then((spec) => settingsUpdate({ hotkey: spec }))
                      .then(() => {
                        setCaptureError(null);
                        setRecording(false);
                      })
                      .catch((reason) => {
                        if (String(reason) !== "captura cancelada") {
                          setCaptureError("NÃO FOI POSSÍVEL CAPTURAR");
                        }
                        setRecording(false);
                        void hotkeyCaptureCancel();
                      });
                  }
                }
              }}
            >
              {recording ? "APERTE…" : "OUTRA…"}
            </button>
          </div>
          {captureError && <p className="capture-error">{captureError}</p>}
        </div>

        <div>
          <span className="muted">MODO</span>
          <div style={{ marginTop: 8 }}>
            <SegmentPicker<HotkeyMode>
              options={[
                { value: "hold", label: "SEGURAR" },
                { value: "toggle", label: "ALTERNAR" },
              ]}
              value={settings.hotkey_mode}
              onChange={(hotkey_mode) => patch({ hotkey_mode })}
            />
          </div>
        </div>

        {size !== "small" && (
          <div>
            <span className="muted">IDIOMA</span>
            <div style={{ marginTop: 8 }}>
              <SegmentPicker<Language>
                options={[
                  { value: "pt-BR", label: "PT-BR" },
                  { value: "en-US", label: "EN-US" },
                ]}
                value={settings.language}
                onChange={(language) => patch({ language })}
              />
            </div>
          </div>
        )}

        {size !== "small" && (
          <div>
            <span className="muted">TAMANHO DO HUD</span>
            <div style={{ marginTop: 8 }}>
              <SegmentPicker<HudSize>
                options={[
                  { value: "minimal", label: "MÍN" },
                  { value: "medium", label: "MÉD" },
                  { value: "large", label: "GRD" },
                ]}
                value={settings.hud_size}
                onChange={(hud_size) => patch({ hud_size })}
              />
            </div>
          </div>
        )}

        {roomy && (
          <>
            <hr className="divider" />
            <div className="persistent-setting">
              <span>ÍCONE NA MENUBAR</span>
              <span>SEMPRE ON</span>
            </div>
            {isMac && (
              <div className="permission-stack">
                <button
                  type="button"
                  className={`permission-action${permissions?.microphone === "authorized" ? " granted" : ""}`}
                  disabled={permissions?.microphone === "authorized"}
                  onClick={async () => {
                    const granted = await permissionsRequestMicrophone().catch(() => false);
                    let next = await permissionsStatus().catch(() => null);
                    if (!granted && next?.microphone !== "authorized") {
                      await new Promise((resolve) => window.setTimeout(resolve, 500));
                      next = await permissionsStatus().catch(() => next);
                    }
                    if (next?.microphone !== "authorized") {
                      await permissionsOpenSettings("microphone").catch(() => false);
                    }
                    if (next) setPermissions(next);
                  }}
                >
                  <span>MICROFONE</span>
                  <span>{permissions?.microphone === "authorized" ? "AUTORIZADO" : "LIBERAR"}</span>
                </button>
                <button
                  type="button"
                  className={`permission-action${permissions?.accessibility && !hotkeyWarning ? " granted" : ""}`}
                  disabled={permissions?.accessibility && !hotkeyWarning}
                  onClick={async () => {
                    await permissionsPromptAccessibility().catch(() => false);
                    await permissionsOpenSettings("accessibility").catch(() => false);
                    const next = await permissionsStatus().catch(() => null);
                    if (next) {
                      setPermissions(next);
                      if (next.accessibility) void hotkeyRestart().catch(() => {});
                    }
                  }}
                >
                  <span>ACESSIBILIDADE</span>
                  <span>
                    {hotkeyWarning
                      ? "CORRIGIR"
                      : permissions?.accessibility
                        ? "AUTORIZADA"
                        : "LIBERAR"}
                  </span>
                </button>
              </div>
            )}
            <FlagRow label="ÍCONE NO DOCK" on={settings.show_dock} onChange={setDock} />
            <FlagRow
              label="SONS"
              on={settings.sound_enabled}
              onChange={(sound_enabled) => patch({ sound_enabled })}
            />
            <hr className="divider" />
            <span className="muted">COMPORTAMENTO</span>
            <FlagRow
              label="CORRIGIR COM DICIONÁRIO"
              on={settings.dictionary_enabled}
              onChange={(dictionary_enabled) => patch({ dictionary_enabled })}
            />
            <FlagRow
              label="SALVAR NO HISTÓRICO"
              on={settings.save_history}
              onChange={(save_history) => patch({ save_history })}
            />
            <FlagRow
              label="COPIAR TEXTO"
              on={settings.copy_to_clipboard}
              onChange={(copy_to_clipboard) => patch({ copy_to_clipboard })}
            />
            <FlagRow
              label="ENTER AO INSERIR"
              on={settings.press_return}
              onChange={(press_return) => patch({ press_return })}
            />
            {isLinux && (
              <div style={{ marginTop: 4 }}>
                <span className="muted">COLAR EM TERMINAL</span>
                <div style={{ marginTop: 8 }}>
                  <SegmentPicker<TerminalPaste>
                    options={[
                      { value: "auto", label: "AUTO" },
                      { value: "always", label: "CTRL+SHIFT+V" },
                      { value: "never", label: "CTRL+V" },
                    ]}
                    value={settings.terminal_paste}
                    onChange={(terminal_paste) => patch({ terminal_paste })}
                  />
                </div>
              </div>
            )}
          </>
        )}

        {hotkeyWarning && (
          <p style={{ margin: 0, fontSize: 10, color: "var(--accent)" }}>{hotkeyWarning}</p>
        )}
      </div>
    </Card>
  );
}
