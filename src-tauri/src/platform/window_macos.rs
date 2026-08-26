use objc2_app_kit::NSWindow;
use objc2_foundation::MainThreadMarker;
use tauri::{Runtime, WebviewWindow};

pub fn disable_state_restoration<R: Runtime>(window: &WebviewWindow<R>) {
    let Ok(ptr) = window.ns_window() else {
        log::warn!("window: ns_window() indisponível");
        return;
    };

    let _mtm = MainThreadMarker::new().expect("window policy must run on main thread");

    unsafe {
        let ns = &*(ptr as *const NSWindow);
        ns.setRestorable(false);
    }
}
