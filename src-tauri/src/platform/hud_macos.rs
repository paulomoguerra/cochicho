//! Tweaks de NSWindow no HUD — port do comportamento de `HUDPanel` (NSPanel
//! non-activating). Não dá para promover o WebviewWindow a NSPanel de verdade a
//! partir do ponteiro cru; aplicamos os equivalentes em NSWindow:
//! - style mask NonactivatingPanel (não vira key)
//! - level statusBar, collectionBehavior canJoinAllSpaces|fullScreenAuxiliary|stationary
//! - hidesOnDeactivate = false
//! Delta vs legacy: não é NSPanel subclass com `canBecomeKey == false` override;
//! NonactivatingPanel + focused(false) no builder cobrem o caso prático.

use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior, NSWindowStyleMask};
use objc2_foundation::MainThreadMarker;
use tauri::{WebviewWindow, Runtime};

/// NSStatusWindowLevel = 25.
const STATUS_BAR_LEVEL: isize = 25;

pub fn apply_nonactivating_panel<R: Runtime>(window: &WebviewWindow<R>) {
    let Ok(ptr) = window.ns_window() else {
        log::warn!("hud: ns_window() indisponível");
        return;
    };

    // MainThreadMarker: AppKit exige main thread; o setup do Tauri já está lá.
    let _mtm = MainThreadMarker::new().expect("hud tweaks must run on main thread");

    unsafe {
        let ns = &*(ptr as *const NSWindow);
        let mut mask = ns.styleMask();
        mask.insert(NSWindowStyleMask::NonactivatingPanel);
        // Borderless já vem do builder; garantir.
        mask.insert(NSWindowStyleMask::Borderless);
        ns.setStyleMask(mask);

        ns.setLevel(STATUS_BAR_LEVEL);
        ns.setCollectionBehavior(
            NSWindowCollectionBehavior::CanJoinAllSpaces
                | NSWindowCollectionBehavior::FullScreenAuxiliary
                | NSWindowCollectionBehavior::Stationary,
        );
        ns.setHidesOnDeactivate(false);
        ns.setOpaque(false);
        // ignoresMouseEvents já via set_ignore_cursor_events no builder.
    }
    log::info!("hud: NSWindow nonactivating + floating aplicados");
}
