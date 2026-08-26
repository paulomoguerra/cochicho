//! FFI para a dylib `AppleSpeechBridge` (SpeechAnalyzer é API só-Swift).
//! ABI v2: availability + mic + sessão streaming com callback de chunks.

use std::ffi::{c_char, c_void, CStr, CString};
use std::os::raw::c_float;

/// kind no callback: 0 partial, 1 final, 2 error, 3 ended.
pub type ChunkCallback =
    unsafe extern "C" fn(user_data: *mut c_void, text: *const c_char, kind: i32);

extern "C" {
    fn ekonami_asb_speech_available() -> i32;
    fn ekonami_asb_bridge_version() -> i32;
    fn ekonami_asb_mic_status() -> i32;
    fn ekonami_asb_mic_request() -> i32;
    fn ekonami_asb_session_start(
        locale: *const c_char,
        bias_csv: *const c_char,
        callback: ChunkCallback,
        user_data: *mut c_void,
    ) -> i32;
    fn ekonami_asb_session_feed(session: i32, samples: *const c_float, count: i32) -> i32;
    fn ekonami_asb_session_finish(session: i32) -> i32;
    fn ekonami_asb_session_cancel(session: i32) -> i32;
    fn ekonami_asb_warm_load(locale: *const c_char) -> i32;
    fn ekonami_asb_warm_unload() -> i32;
    fn ekonami_asb_menubar_icon_png(active: i32, length: *mut usize) -> *const u8;
    fn ekonami_asb_hotkey_capture(
        key_code: *mut i64,
        modifier_flag: *mut u64,
        display_name: *mut c_char,
        display_capacity: i32,
    ) -> i32;
    fn ekonami_asb_hotkey_capture_cancel();
}

pub fn speech_available() -> bool {
    unsafe { ekonami_asb_speech_available() == 1 }
}

pub fn bridge_version() -> i32 {
    unsafe { ekonami_asb_bridge_version() }
}

pub fn mic_status() -> i32 {
    unsafe { ekonami_asb_mic_status() }
}

pub fn mic_request() -> bool {
    unsafe { ekonami_asb_mic_request() == 1 }
}

/// Starts an Apple Speech streaming session.
///
/// # Safety
///
/// `callback` must remain callable for the whole lifetime of the native
/// session. `user_data` must point to valid callback state for every callback
/// invocation, and that state must remain alive until the native session has
/// finished or been cancelled.
pub unsafe fn session_start(
    locale: &str,
    bias_csv: &str,
    callback: ChunkCallback,
    user_data: *mut c_void,
) -> Result<i32, String> {
    let locale = CString::new(locale).map_err(|e| e.to_string())?;
    let bias = CString::new(bias_csv).map_err(|e| e.to_string())?;
    let id =
        unsafe { ekonami_asb_session_start(locale.as_ptr(), bias.as_ptr(), callback, user_data) };
    if id > 0 {
        Ok(id)
    } else {
        Err(format!("apple speech session_start failed ({id})"))
    }
}

pub fn session_feed(session: i32, samples: &[f32]) -> Result<(), String> {
    if samples.is_empty() {
        return Ok(());
    }
    let rc = unsafe { ekonami_asb_session_feed(session, samples.as_ptr(), samples.len() as i32) };
    if rc == 0 {
        Ok(())
    } else {
        Err(format!("apple speech feed failed ({rc})"))
    }
}

pub fn session_finish(session: i32) -> Result<(), String> {
    let rc = unsafe { ekonami_asb_session_finish(session) };
    if rc == 0 {
        Ok(())
    } else {
        Err(format!("apple speech finish failed ({rc})"))
    }
}

pub fn session_cancel(session: i32) {
    unsafe {
        let _ = ekonami_asb_session_cancel(session);
    }
}

pub fn warm_load(locale: &str) -> Result<(), String> {
    let locale = CString::new(locale).map_err(|e| e.to_string())?;
    let rc = unsafe { ekonami_asb_warm_load(locale.as_ptr()) };
    if rc == 0 {
        Ok(())
    } else {
        Err(format!("apple speech warm load failed ({rc})"))
    }
}

pub fn warm_unload() {
    unsafe {
        let _ = ekonami_asb_warm_unload();
    }
}

pub fn menubar_icon_png(active: bool) -> Option<Vec<u8>> {
    let mut length = 0usize;
    let ptr = unsafe { ekonami_asb_menubar_icon_png(active as i32, &mut length) };
    if ptr.is_null() || length == 0 {
        return None;
    }
    Some(unsafe { std::slice::from_raw_parts(ptr, length) }.to_vec())
}

pub fn capture_hotkey() -> Result<(i64, u64, String), String> {
    let mut key_code = -1i64;
    let mut modifier_flag = 0u64;
    let mut display_name = [0 as c_char; 64];
    let rc = unsafe {
        ekonami_asb_hotkey_capture(
            &mut key_code,
            &mut modifier_flag,
            display_name.as_mut_ptr(),
            display_name.len() as i32,
        )
    };
    if rc != 0 {
        return Err("captura cancelada".into());
    }
    let display = unsafe { CStr::from_ptr(display_name.as_ptr()) }
        .to_string_lossy()
        .into_owned();
    Ok((key_code, modifier_flag, display))
}

pub fn cancel_hotkey_capture() {
    unsafe { ekonami_asb_hotkey_capture_cancel() }
}

/// Copies a UTF-8-ish C string received from the native callback.
///
/// # Safety
///
/// `ptr` must be null or point to a valid, readable, NUL-terminated C string
/// that remains alive for the duration of this call.
pub unsafe fn text_from_callback(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    CStr::from_ptr(ptr).to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bridge_links_and_answers() {
        let version = bridge_version();
        assert_eq!(version, 4, "unexpected bridge ABI version");
        let _ = speech_available();
        let _ = mic_status(); // 0..3 ou unknown — não pode trapear
    }
}
