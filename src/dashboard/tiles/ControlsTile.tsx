import { useEffect, useState } from "react";
import {
  type HotkeyMode,
  type HotkeySpec,
  type HudSize,
  type Language,
  type Settings,
  type TerminalPaste,
  settingsUpdate,
} from "../../lib/ipc";
import { isRoomy, type TileSize } from "../layout";
import { Card, CardHeader, FlagRow, SegmentPicker } from "../ui";

const MAC_PRESETS: HotkeySpec[] = [
  { key_code: 61, modifier_flag: 0x40, display_name: "R⌥" },
  { key_code: 54, modifier_flag: 0x10, display_name: "R⌘" },
  { key_code: 63, modifier_flag: 0x80, display_name: "FN" },
];

const LINUX_PRESETS: HotkeySpec[] = [
  { key_code: 97, modifier_flag: 0, display_name: "RCTRL" },
  { key_code: 100, modifier_flag: 0, display_name: "RALT" },
  { key_code: 125, modifier_flag: 0, display_name: "RMENU" },
];

function sameHotkey(a: HotkeySpec, b: HotkeySpec): boolean {
  return a.key_code === b.key_code && a.modifier_flag === b.modifier_flag;
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

  useEffect(() => {
    if (!recording) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      // Captura local (dashboard em foco) — a hotkey global continua no backend.
      const spec: HotkeySpec = {
        key_code: e.keyCode,
        modifier_flag: 0,
        display_name: e.key.length === 1 ? e.key.toUpperCase() : e.code.replace(/^Key/, ""),
      };
      void settingsUpdate({ hotkey: spec });
      setRecording(false);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [recording]);

  const patch = (partial: Partial<Settings>) => {
    void settingsUpdate(partial);
  };

  const setMenuBar = (on: boolean) => {
    if (!on && !settings.show_dock) {
      patch({ show_menu_bar: false, show_dock: true });
    } else {
      patch({ show_menu_bar: on });
    }
  };

  const setDock = (on: boolean) => {
    if (!on && !settings.show_menu_bar) {
      patch({ show_dock: false, show_menu_bar: true });
    } else {
      patch({ show_dock: on });
    }
  };

  return (
    <Card>
      <CardHeader number="06" title="CONTROLES" />
      <div className="card-body" style={{ gap: roomy ? 8 : 12 }}>
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
                onClick={() => patch({ hotkey: p })}
              >
                {p.display_name}
              </button>
            ))}
            <button
              type="button"
              className={`seg-btn${recording ? " on" : ""}`}
              onClick={() => setRecording((v) => !v)}
            >
              {recording ? "APERTE…" : "OUTRA…"}
            </button>
          </div>
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
            <FlagRow label="ÍCONE NA MENUBAR" on={settings.show_menu_bar} onChange={setMenuBar} />
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
