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

pub fn session_start(
    locale: &str,
    bias_csv: &str,
    callback: ChunkCallback,
    user_data: *mut c_void,
) -> Result<i32, String> {
    let locale = CString::new(locale).map_err(|e| e.to_string())?;
    let bias = CString::new(bias_csv).map_err(|e| e.to_string())?;
    let id = unsafe {
        ekonami_asb_session_start(locale.as_ptr(), bias.as_ptr(), callback, user_data)
    };
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
    let rc = unsafe {
        ekonami_asb_session_feed(session, samples.as_ptr(), samples.len() as i32)
    };
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

/// Copia o CStr do callback (válido só durante a chamada).
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
        assert_eq!(version, 2, "unexpected bridge ABI version");
        let available = speech_available();
        assert!(available || !available, "call must return without trapping");
        let _ = mic_status(); // 0..3 ou unknown — não pode trapear
    }
}
