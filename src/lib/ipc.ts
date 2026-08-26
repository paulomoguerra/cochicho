import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";

export type DictationState = "idle" | "starting" | "listening" | "finishing" | "failed";

export type EngineKind = "apple" | "parakeet" | "whisper";
export type ParakeetVersion = "v3" | "v2";
export type Appearance = "dark" | "light";
export type Language = "pt-BR" | "en-US";
export type HotkeyMode = "hold" | "toggle";
export type HudSize = "minimal" | "medium" | "large";
export type TerminalPaste = "auto" | "always" | "never";

/** Bate com `Tile` em settings.rs (`rename_all = "lowercase"`). */
export type TileId = "mic" | "engine" | "stats" | "history" | "dictionary" | "controls";
export type TileSize = "small" | "wide" | "tall" | "big";

export interface TileConfig {
  tile: TileId;
  size: TileSize;
}

export interface HotkeySpec {
  key_code: number;
  modifier_flag: number;
  display_name: string;
}

export interface Settings {
  engine: EngineKind | null;
  parakeet_version: ParakeetVersion;
  parakeet_model: string;
  whisper_model: string;
  language: Language;
  hotkey_mode: HotkeyMode;
  hud_size: HudSize;
  hotkey: HotkeySpec;
  show_menu_bar: boolean;
  show_dock: boolean;
  sound_enabled: boolean;
  dictionary_enabled: boolean;
  save_history: boolean;
  copy_to_clipboard: boolean;
  press_return: boolean;
  terminal_paste: TerminalPaste;
  tile_layout: TileConfig[];
  custom_tile_layout: TileConfig[];
  layout_source_is_custom: boolean;
  appearance: Appearance;
}

export interface SettingsPatch {
  engine?: EngineKind | null;
  parakeet_version?: ParakeetVersion;
  parakeet_model?: string;
  whisper_model?: string;
  language?: Language;
  hotkey_mode?: HotkeyMode;
  hud_size?: HudSize;
  hotkey?: HotkeySpec;
  show_menu_bar?: boolean;
  show_dock?: boolean;
  sound_enabled?: boolean;
  dictionary_enabled?: boolean;
  save_history?: boolean;
  copy_to_clipboard?: boolean;
  press_return?: boolean;
  terminal_paste?: TerminalPaste;
  tile_layout?: TileConfig[];
  custom_tile_layout?: TileConfig[];
  layout_source_is_custom?: boolean;
  appearance?: Appearance;
}

export interface StatePayload {
  state: DictationState;
  error: string | null;
  transcript: string;
}

export interface TranscriptPayload {
  text: string;
  is_final: boolean;
}

export interface ModelStatus {
  name: string;
  engine: EngineKind;
  display: string;
  downloaded: boolean;
  bytes_on_disk: number;
  approx_bytes: number;
  english_only: boolean;
  label: string;
  family: string;
  quant: string;
  languages: string;
  speed: number;
  quality: number;
  ram_mb: number;
  blurb: string;
  recommended: boolean;
}

export interface DownloadProgress {
  name: string;
  progress: number;
}

export interface ModelResidenceStatus {
  supported: boolean;
  loaded_engine: EngineKind | null;
  loaded_model: string | null;
}

export type MicrophonePermission = "authorized" | "denied" | "notdetermined" | "restricted" | "unknown";

export interface PermissionsStatus {
  accessibility: boolean;
  microphone: MicrophonePermission;
}

export type EntryKind = "term" | "correction";

export interface DictionaryEntry {
  id: string;
  kind: EntryKind;
  write: string;
  hear: string;
  is_enabled: boolean;
}

export interface AppliedCorrection {
  from: string;
  to: string;
  count: number;
}

export interface HistoryEntry {
  id: string;
  text: string;
  corrected_text: string;
  corrections: AppliedCorrection[];
  engine: string;
  model: string;
  duration_seconds: number;
  word_count: number;
  created_at: string;
}

export interface HistoryTotals {
  total_words: number;
  total_seconds: number;
  entry_count: number;
}

type ListenPromise = Promise<UnlistenFn>;

export const dictationToggle = () => invoke("dictation_toggle");
export const dictationState = () => invoke<StatePayload>("dictation_state");
export const platformInfo = () => invoke<string>("platform_info");
export const onboardingNeeded = () => invoke<boolean>("onboarding_needed");
export const permissionsStatus = () => invoke<PermissionsStatus>("permissions_status");
export const permissionsPromptAccessibility = () =>
  invoke<boolean>("permissions_prompt_accessibility");
export const permissionsRequestMicrophone = () =>
  invoke<boolean>("permissions_request_microphone");
export const permissionsOpenSettings = (kind: "microphone" | "accessibility") =>
  invoke<boolean>("permissions_open_settings", { kind });

export const settingsGet = () => invoke<Settings>("settings_get");
export const hotkeyStatus = () => invoke<string | null>("hotkey_status");
export const hotkeyCaptureBegin = () => invoke<HotkeySpec>("hotkey_capture_begin");
export const hotkeyCaptureCancel = () => invoke("hotkey_capture_cancel");
export const hotkeyRestart = () => invoke("hotkey_restart");
export const settingsUpdate = (patch: SettingsPatch) =>
  invoke<Settings>("settings_update", { patch });

export const modelCatalog = () => invoke<ModelStatus[]>("model_catalog");
export const modelResidence = () => invoke<ModelResidenceStatus>("model_residence");
export const modelLoadSelected = () =>
  invoke<ModelResidenceStatus>("model_load_selected");
export const modelUnload = () => invoke<ModelResidenceStatus>("model_unload");
export const modelDownload = (engine: EngineKind, name: string) =>
  invoke("model_download", { engine, name });
export const modelDelete = (engine: EngineKind, name: string) =>
  invoke("model_delete", { engine, name });

export const dictionaryList = () => invoke<DictionaryEntry[]>("dictionary_list");
export const dictionaryAdd = (entry: DictionaryEntry) =>
  invoke("dictionary_add", { entry });
export const dictionaryUpdate = (entry: DictionaryEntry) =>
  invoke("dictionary_update", { entry });
export const dictionaryRemove = (id: string) => invoke("dictionary_remove", { id });
export const dictionaryToggle = (id: string) => invoke("dictionary_toggle", { id });
export const dictionaryRestoreDefaults = () => invoke("dictionary_restore_defaults");

export const historyList = () => invoke<HistoryEntry[]>("history_list");
export const historyTotals = () => invoke<HistoryTotals>("history_totals");
export const historyClear = () => invoke("history_clear");

export const onDictationState = (cb: (p: StatePayload) => void): ListenPromise =>
  listen<StatePayload>("dictation:state", (e) => cb(e.payload));

export const onTranscript = (cb: (p: TranscriptPayload) => void): ListenPromise =>
  listen<TranscriptPayload>("dictation:transcript", (e) => cb(e.payload));

export const onAudioLevel = (cb: (level: number) => void): ListenPromise =>
  listen<number>("audio:level", (e) => cb(e.payload));

export const onHotkeyUnavailable = (cb: (msg: string) => void): ListenPromise =>
  listen<string>("hotkey:unavailable", (e) => cb(e.payload));

export const onHotkeyAvailable = (cb: () => void): ListenPromise =>
  listen("hotkey:available", cb);

export const onModelProgress = (cb: (p: DownloadProgress) => void): ListenPromise =>
  listen<DownloadProgress>("model:progress", (e) => cb(e.payload));

export const onSettingsChanged = (cb: (s: Settings) => void): ListenPromise =>
  listen<Settings>("settings:changed", (e) => cb(e.payload));

export const onDictionaryChanged = (cb: () => void): ListenPromise =>
  listen("dictionary:changed", () => cb());

export const onHistoryChanged = (cb: () => void): ListenPromise =>
  listen("history:changed", () => cb());
