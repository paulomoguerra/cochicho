//! Port de `Permissions.swift` — TCC Accessibility + microfone.
//! Sem Accessibility o CGEventTap e a injeção AX falham em silêncio; a UI consulta
//! `permissions_status` para avisar. Mic passa pelo Swift bridge (AVFoundation async).

use serde::Serialize;

#[derive(Clone, Debug, Serialize)]
pub struct PermissionsStatus {
    pub accessibility: bool,
    pub microphone: MicStatus,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum MicStatus {
    Authorized,
    Denied,
    NotDetermined,
    Restricted,
    Unknown,
}

/// `AXIsProcessTrusted` — true se o processo já tem Accessibility.
pub fn accessibility_trusted() -> bool {
    unsafe { AXIsProcessTrusted() }
}

/// Mostra o diálogo do sistema pedindo Accessibility (se ainda não concedida).
pub fn prompt_accessibility() -> bool {
    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;

    let key = CFString::new("AXTrustedCheckOptionPrompt");
    let value = CFBoolean::true_value();
    let pairs = &[(key.as_CFType(), value.as_CFType())];
    let opts = CFDictionary::from_CFType_pairs(pairs);
    unsafe { AXIsProcessTrustedWithOptions(opts.as_concrete_TypeRef()) }
}

pub fn microphone_status() -> MicStatus {
    match crate::apple_bridge::mic_status() {
        0 => MicStatus::NotDetermined,
        1 => MicStatus::Restricted,
        2 => MicStatus::Denied,
        3 => MicStatus::Authorized,
        _ => MicStatus::Unknown,
    }
}

/// Pede acesso ao microfone (bloqueia até a resposta). Só chamar a partir da UI.
pub fn request_microphone() -> bool {
    match microphone_status() {
        MicStatus::Authorized => true,
        MicStatus::NotDetermined => crate::apple_bridge::mic_request(),
        _ => false,
    }
}

pub fn status() -> PermissionsStatus {
    PermissionsStatus {
        accessibility: accessibility_trusted(),
        microphone: microphone_status(),
    }
}

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(
        options: core_foundation::dictionary::CFDictionaryRef,
    ) -> bool;
}
