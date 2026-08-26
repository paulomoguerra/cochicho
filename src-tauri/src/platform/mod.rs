//! Backends de plataforma. O core só vê estes traits; cada SO tem seu módulo.
//!
//! | Concern     | macOS                              | Linux                          |
//! |-------------|------------------------------------|--------------------------------|
//! | hotkey      | CGEventTap (session)               | evdev /dev/input               |
//! | injeção     | AX verificado + pasteboard + ⌘V    | clipboard + uinput             |
//! | permissions | Accessibility + mic (TCC)          | —                              |

pub mod inject;

#[cfg(target_os = "linux")]
pub mod hotkey_linux;
#[cfg(target_os = "linux")]
pub use hotkey_linux as hotkey;

#[cfg(target_os = "macos")]
pub mod hotkey_macos;
#[cfg(target_os = "macos")]
pub use hotkey_macos as hotkey;

#[cfg(target_os = "macos")]
pub mod hud_macos;
#[cfg(target_os = "macos")]
pub mod permissions_macos;
