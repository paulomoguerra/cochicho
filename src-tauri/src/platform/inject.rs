//! Port de `TextInjector.swift`. Duas estratégias, nesta ordem:
//! 1. Accessibility (`kAXSelectedTextAttribute`) com verificação de movimento do
//!    insertion point — muitos apps (Electron, Chrome) devolvem success e não fazem nada.
//! 2. Pasteboard + ⌘V, restaurando o clipboard depois.
//!    Linux: uinput (inalterado).

use std::sync::{Mutex, RwLock};

use crate::core::settings::TerminalPaste;

#[derive(Debug, thiserror::Error)]
pub enum InjectError {
    #[error("clipboard unavailable: {0}")]
    Clipboard(String),
    #[error("paste simulation unavailable: {0}")]
    Paste(String),
}

pub struct TextInjector {
    clipboard: Mutex<Option<arboard::Clipboard>>,
    terminal_paste: RwLock<TerminalPaste>,
}

impl TextInjector {
    pub fn new(terminal_paste: TerminalPaste) -> Self {
        let clipboard = arboard::Clipboard::new().ok();
        if clipboard.is_none() {
            log::warn!("clipboard unavailable at startup");
        }
        Self {
            clipboard: Mutex::new(clipboard),
            terminal_paste: RwLock::new(terminal_paste),
        }
    }

    pub fn set_terminal_paste(&self, mode: TerminalPaste) {
        *self.terminal_paste.write().unwrap() = mode;
    }

    /// Só copia para o clipboard, sem simular paste (setting "copiar em vez de colar").
    pub fn copy_only(&self, text: &str) -> Result<(), InjectError> {
        let mut guard = self.clipboard.lock().unwrap();
        let clipboard = guard
            .as_mut()
            .ok_or_else(|| InjectError::Clipboard("no clipboard".into()))?;
        clipboard
            .set_text(text)
            .map_err(|e| InjectError::Clipboard(e.to_string()))
    }

    /// Insere `text` no app em foco.
    pub fn insert(&self, text: &str, press_return: bool) -> Result<(), InjectError> {
        if text.is_empty() {
            return Ok(());
        }

        #[cfg(target_os = "macos")]
        {
            match macos_insert_via_ax(text) {
                AxOutcome::Inserted => {
                    log::info!("inserted via AX ({} chars)", text.len());
                    if press_return {
                        std::thread::sleep(std::time::Duration::from_millis(80));
                        let _ = macos_key_plain(0x24);
                    }
                    return Ok(());
                }
                AxOutcome::Unverified(reason) => {
                    log::info!("AX insert not verified ({reason}) — pasting");
                }
            }
        }

        self.insert_via_pasteboard(text, press_return)
    }

    fn insert_via_pasteboard(&self, text: &str, press_return: bool) -> Result<(), InjectError> {
        let mut guard = self.clipboard.lock().unwrap();
        let clipboard = guard
            .as_mut()
            .ok_or_else(|| InjectError::Clipboard("no clipboard".into()))?;

        let previous_text = clipboard.get_text().ok();

        clipboard
            .set_text(text)
            .map_err(|e| InjectError::Clipboard(e.to_string()))?;

        // Legacy: 40ms para o app alvo observar a nova geração do pasteboard.
        std::thread::sleep(std::time::Duration::from_millis(40));
        self.simulate_paste()?;
        log::info!("pasted ({} chars)", text.len());

        if press_return {
            std::thread::sleep(std::time::Duration::from_millis(80));
            self.simulate_return()?;
        }

        // Legacy: 500ms para o alvo ler o pasteboard antes de restaurar.
        std::thread::sleep(std::time::Duration::from_millis(500));
        if let Some(prev) = previous_text {
            let _ = clipboard.set_text(prev);
        }
        Ok(())
    }

    #[cfg(target_os = "linux")]
    fn simulate_paste(&self) -> Result<(), InjectError> {
        use evdev::KeyCode;
        let use_terminal_combo = match *self.terminal_paste.read().unwrap() {
            TerminalPaste::Always => true,
            TerminalPaste::Never => false,
            TerminalPaste::Auto => detect_terminal_focus(),
        };
        if use_terminal_combo {
            linux_combo(&[
                KeyCode::KEY_LEFTCTRL,
                KeyCode::KEY_LEFTSHIFT,
                KeyCode::KEY_V,
            ])
        } else {
            linux_combo(&[KeyCode::KEY_LEFTCTRL, KeyCode::KEY_V])
        }
    }

    #[cfg(target_os = "linux")]
    fn simulate_return(&self) -> Result<(), InjectError> {
        linux_combo(&[evdev::KeyCode::KEY_ENTER])
    }

    #[cfg(target_os = "macos")]
    fn simulate_paste(&self) -> Result<(), InjectError> {
        macos_key_with_command(0x09) // kVK_ANSI_V
    }

    #[cfg(target_os = "macos")]
    fn simulate_return(&self) -> Result<(), InjectError> {
        macos_key_plain(0x24) // kVK_Return
    }
}

// ---------------------------------------------------------------------------
// Linux: uinput (via o suporte embutido do crate evdev)

#[cfg(target_os = "linux")]
fn linux_combo(keys: &[evdev::KeyCode]) -> Result<(), InjectError> {
    use evdev::uinput::VirtualDevice;
    use evdev::{AttributeSet, InputEvent, KeyCode, KeyEvent};

    let mut set = AttributeSet::<KeyCode>::new();
    for key in keys {
        set.insert(*key);
    }

    let mut device = VirtualDevice::builder()
        .map_err(|e| InjectError::Paste(format!("uinput open: {e}")))?
        .name("ekonami-inject")
        .with_keys(&set)
        .map_err(|e| InjectError::Paste(format!("uinput keys: {e}")))?
        .build()
        .map_err(|e| {
            InjectError::Paste(format!(
                "uinput create: {e} (falta a regra udev para /dev/uinput — rode o setup)"
            ))
        })?;

    std::thread::sleep(std::time::Duration::from_millis(50));

    let event = |key: KeyCode, value: i32| InputEvent::from(KeyEvent::new(key, value));
    let emit = |device: &mut VirtualDevice, events: &[InputEvent]| -> Result<(), InjectError> {
        device
            .emit(events)
            .map_err(|e| InjectError::Paste(e.to_string()))
    };

    let (last, modifiers) = keys.split_last().expect("combo vazio");
    for &modifier in modifiers {
        emit(&mut device, &[event(modifier, 1)])?;
    }
    emit(&mut device, &[event(*last, 1)])?;
    std::thread::sleep(std::time::Duration::from_millis(30));
    emit(&mut device, &[event(*last, 0)])?;
    for &modifier in modifiers.iter().rev() {
        emit(&mut device, &[event(modifier, 0)])?;
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn detect_terminal_focus() -> bool {
    if std::env::var_os("WAYLAND_DISPLAY").is_some() && std::env::var_os("DISPLAY").is_none() {
        return false;
    }
    let Ok(output) = std::process::Command::new("xprop")
        .args(["-root", "_NET_ACTIVE_WINDOW"])
        .output()
    else {
        return false;
    };
    let stdout = String::from_utf8_lossy(&output.stdout);
    let Some(id) = stdout.split('#').nth(1).map(|s| s.trim().to_string()) else {
        return false;
    };
    let Ok(class_out) = std::process::Command::new("xprop")
        .args(["-id", &id, "WM_CLASS"])
        .output()
    else {
        return false;
    };
    let class = String::from_utf8_lossy(&class_out.stdout).to_lowercase();
    const TERMINALS: &[&str] = &[
        "alacritty",
        "kitty",
        "foot",
        "wezterm",
        "gnome-terminal",
        "konsole",
        "xterm",
        "urxvt",
        "st",
        "terminator",
        "tilix",
        "ghostty",
        "rio",
    ];
    TERMINALS.iter().any(|t| class.contains(t))
}

// ---------------------------------------------------------------------------
// macOS: AX verificado + CGEvent ⌘V

#[cfg(target_os = "macos")]
enum AxOutcome {
    Inserted,
    Unverified(String),
}

#[cfg(target_os = "macos")]
fn macos_insert_via_ax(text: &str) -> AxOutcome {
    use core_foundation::base::{CFTypeRef, TCFType};
    use core_foundation::string::CFString;

    unsafe {
        let system = AXUIElementCreateSystemWide();
        let mut focused: CFTypeRef = std::ptr::null();
        let focused_attr = CFString::new("AXFocusedUIElement");
        if AXUIElementCopyAttributeValue(system, focused_attr.as_concrete_TypeRef(), &mut focused)
            != 0
            || focused.is_null()
        {
            return AxOutcome::Unverified("no focused element".into());
        }
        let element = focused as AXUIElementRef;

        let selected_attr = CFString::new("AXSelectedText");
        let mut settable: u8 = 0;
        if AXUIElementIsAttributeSettable(
            element,
            selected_attr.as_concrete_TypeRef(),
            &mut settable,
        ) != 0
            || settable == 0
        {
            return AxOutcome::Unverified("selected text not settable".into());
        }

        let Some(before) = ax_selected_range(element) else {
            return AxOutcome::Unverified("no readable selection range".into());
        };

        let value = CFString::new(text);
        if AXUIElementSetAttributeValue(
            element,
            selected_attr.as_concrete_TypeRef(),
            value.as_CFTypeRef(),
        ) != 0
        {
            return AxOutcome::Unverified("set attribute failed".into());
        }

        let Some(after) = ax_selected_range(element) else {
            return AxOutcome::Unverified("selection range unreadable after write".into());
        };

        // Só movimento prova inserção — comprimento exato falha com autocorrect/newlines.
        if after.location == before.location && after.length == before.length {
            return AxOutcome::Unverified(format!("selection unmoved at {}", before.location));
        }

        AxOutcome::Inserted
    }
}

#[cfg(target_os = "macos")]
#[derive(Clone, Copy)]
struct CfRange {
    location: i64,
    length: i64,
}

#[cfg(target_os = "macos")]
fn ax_selected_range(element: AXUIElementRef) -> Option<CfRange> {
    use core_foundation::base::{CFTypeRef, TCFType};
    use core_foundation::string::CFString;

    unsafe {
        let attr = CFString::new("AXSelectedTextRange");
        let mut value: CFTypeRef = std::ptr::null();
        if AXUIElementCopyAttributeValue(element, attr.as_concrete_TypeRef(), &mut value) != 0
            || value.is_null()
        {
            return None;
        }
        // AXValue type for CFRange = 4 (kAXValueCFRangeType)
        if AXValueGetType(value as AXValueRef) != 4 {
            return None;
        }
        let mut range = CfRange {
            location: 0,
            length: 0,
        };
        if !AXValueGetValue(value as AXValueRef, 4, &mut range as *mut _ as *mut _) {
            return None;
        }
        Some(range)
    }
}

#[cfg(target_os = "macos")]
fn macos_key_with_command(key_code: u16) -> Result<(), InjectError> {
    macos_post_key(key_code, true)
}

#[cfg(target_os = "macos")]
fn macos_key_plain(key_code: u16) -> Result<(), InjectError> {
    macos_post_key(key_code, false)
}

#[cfg(target_os = "macos")]
fn macos_post_key(key_code: u16, with_command: bool) -> Result<(), InjectError> {
    use objc2_core_graphics::{
        CGEvent, CGEventFlags, CGEventSource, CGEventSourceStateID, CGEventTapLocation,
    };

    // privateState no legacy — HIDSystemState é o equivalente acessível aqui.
    let source = CGEventSource::new(CGEventSourceStateID::Private)
        .or_else(|| CGEventSource::new(CGEventSourceStateID::HIDSystemState))
        .ok_or_else(|| InjectError::Paste("no event source".into()))?;

    let flags = if with_command {
        CGEventFlags::MaskCommand
    } else {
        CGEventFlags::empty()
    };

    for key_down in [true, false] {
        let event = CGEvent::new_keyboard_event(Some(&source), key_code, key_down)
            .ok_or_else(|| InjectError::Paste("no key event".into()))?;
        // Flags explícitas — o usuário pode ainda estar segurando o hotkey.
        CGEvent::set_flags(Some(&event), flags);
        CGEvent::post(CGEventTapLocation::HIDEventTap, Some(&event));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
type AXUIElementRef = *mut std::ffi::c_void;
#[cfg(target_os = "macos")]
type AXValueRef = *mut std::ffi::c_void;
#[cfg(target_os = "macos")]
type AXError = i32;

#[cfg(target_os = "macos")]
#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(
        element: AXUIElementRef,
        attribute: core_foundation::string::CFStringRef,
        value: *mut core_foundation::base::CFTypeRef,
    ) -> AXError;
    fn AXUIElementIsAttributeSettable(
        element: AXUIElementRef,
        attribute: core_foundation::string::CFStringRef,
        settable: *mut u8,
    ) -> AXError;
    fn AXUIElementSetAttributeValue(
        element: AXUIElementRef,
        attribute: core_foundation::string::CFStringRef,
        value: core_foundation::base::CFTypeRef,
    ) -> AXError;
    fn AXValueGetType(value: AXValueRef) -> u32;
    fn AXValueGetValue(value: AXValueRef, the_type: u32, value_ptr: *mut std::ffi::c_void) -> bool;
}
