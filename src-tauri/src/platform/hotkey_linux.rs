//! Hotkey global no Linux via evdev: lê /dev/input/event* diretamente, então funciona
//! igual em Wayland, X11 e TTY. Requer o usuário no grupo `input` (o wizard de
//! primeiro run orienta: `sudo usermod -aG input $USER` + relogin).
//!
//! Diferença do macOS: não dá para "consumir" só a tecla do hotkey sem fazer grab do
//! teclado inteiro (o que bloquearia a digitação). Então o evento também chega ao app
//! em foco — por isso os presets são teclas inertes (RCTRL, RALT, F9).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use evdev::{EventSummary, KeyCode};

use crate::core::settings::HotkeySpec;

pub struct HotkeyMonitor {
    running: Arc<AtomicBool>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

#[derive(Debug, thiserror::Error)]
pub enum HotkeyError {
    #[error("nenhum dispositivo de entrada acessível expõe essa tecla (grupo `input` configurado?)")]
    NoDevices,
}

impl HotkeyMonitor {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
            tasks: Vec::new(),
        }
    }

    /// Começa a observar a tecla do spec em todos os dispositivos que a expõem.
    pub fn start(
        &mut self,
        spec: HotkeySpec,
        on_press: Arc<dyn Fn() + Send + Sync>,
        on_release: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<(), HotkeyError> {
        self.stop();
        self.running.store(true, Ordering::SeqCst);

        let target = KeyCode(spec.key_code as u16);
        let mut started = 0;

        for (path, device) in evdev::enumerate() {
            let supported = device
                .supported_keys()
                .map(|keys| keys.contains(target))
                .unwrap_or(false);
            if !supported {
                continue;
            }

            let Ok(stream) = device.into_event_stream() else {
                continue;
            };

            let on_press = on_press.clone();
            let on_release = on_release.clone();
            let running = self.running.clone();

            self.tasks.push(tokio::spawn(async move {
                let mut stream = stream;
                loop {
                    if !running.load(Ordering::SeqCst) {
                        break;
                    }
                    match stream.next_event().await {
                        Ok(event) => {
                            if let EventSummary::Key(_, code, value) = event.destructure() {
                                if code != target {
                                    continue;
                                }
                                match value {
                                    1 => on_press(),
                                    0 => on_release(),
                                    // 2 = autorepeat — o Swift ignorava isRepeat também.
                                    _ => {}
                                }
                            }
                        }
                        Err(e) => {
                            log::warn!("evdev error on {:?}: {e}", path);
                            break;
                        }
                    }
                }
            }));
            started += 1;
        }

        if started == 0 {
            self.stop();
            return Err(HotkeyError::NoDevices);
        }
        log::info!(
            "hotkey monitor: watching {started} input devices for {:?}",
            spec.display_name
        );
        Ok(())
    }

    pub fn stop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        for task in self.tasks.drain(..) {
            task.abort();
        }
    }
}

impl Drop for HotkeyMonitor {
    fn drop(&mut self) {
        self.stop();
    }
}
