//! Port de `HotkeyMonitor.swift`: CGEventTap no nível da sessão.
//!
//! Tap em vez de NSEvent.addGlobalMonitor porque fn / left-right modifiers e o
//! consumo do evento (F-key não digita no app alvo) só existem no tap. Sem
//! Accessibility, `CGEventTap::new` falha — o caller emite `hotkey:unavailable`.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};

use core_foundation::runloop::{kCFRunLoopCommonModes, CFRunLoop};
use core_graphics::event::{
    CGEventFlags, CGEventTap, CGEventTapLocation, CGEventTapOptions, CGEventTapPlacement,
    CGEventType, CallbackResult, EventField,
};

use crate::core::settings::HotkeySpec;

/// kVK_Function — engolir fn quebra atalhos do sistema (fn+setas, emoji).
const KEY_FUNCTION: i64 = 63;

pub struct HotkeyMonitor {
    stop_flag: Option<Arc<AtomicBool>>,
    run_loop: Arc<Mutex<Option<CFRunLoop>>>,
    join: Option<JoinHandle<()>>,
}

#[derive(Debug, thiserror::Error)]
pub enum HotkeyError {
    #[error("CGEventTap falhou — conceda Accessibility ao Eko Nami em Ajustes do Sistema")]
    TapCreateFailed,
}

struct TapState {
    spec: HotkeySpec,
    is_pressed: bool,
    on_press: Arc<dyn Fn() + Send + Sync>,
    on_release: Arc<dyn Fn() + Send + Sync>,
    /// CFMachPortRef como usize — CFMachPort não é Send, mas o ref é só
    /// usado na thread do run loop (callback + re-enable).
    mach_port_ref: usize,
}

impl HotkeyMonitor {
    pub fn new() -> Self {
        Self {
            stop_flag: None,
            run_loop: Arc::new(Mutex::new(None)),
            join: None,
        }
    }

    pub fn start(
        &mut self,
        spec: HotkeySpec,
        on_press: Arc<dyn Fn() + Send + Sync>,
        on_release: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<(), HotkeyError> {
        self.stop();

        let stop_flag = Arc::new(AtomicBool::new(false));
        let run_loop_slot = self.run_loop.clone();
        let stop_flag_thread = stop_flag.clone();
        let state = Arc::new(Mutex::new(TapState {
            spec,
            is_pressed: false,
            on_press,
            on_release,
            mach_port_ref: 0,
        }));

        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), HotkeyError>>();

        let join = thread::Builder::new()
            .name("ekonami-hotkey".into())
            .spawn(move || {
                let events = vec![
                    CGEventType::FlagsChanged,
                    CGEventType::KeyDown,
                    CGEventType::KeyUp,
                ];

                let state_cb = state.clone();
                let tap = match CGEventTap::new(
                    CGEventTapLocation::Session,
                    CGEventTapPlacement::HeadInsertEventTap,
                    CGEventTapOptions::Default,
                    events,
                    move |_proxy, etype, event| {
                        let mut guard = match state_cb.lock() {
                            Ok(g) => g,
                            Err(_) => return CallbackResult::Keep,
                        };

                        // Sistema desabilita taps lentos/interrompidos — rearmar.
                        if matches!(
                            etype,
                            CGEventType::TapDisabledByTimeout | CGEventType::TapDisabledByUserInput
                        ) {
                            let port = guard.mach_port_ref;
                            if port != 0 {
                                unsafe {
                                    CGEventTapEnable(
                                        port as core_foundation::mach_port::CFMachPortRef,
                                        true,
                                    );
                                }
                            }
                            return CallbackResult::Keep;
                        }

                        let key_code =
                            event.get_integer_value_field(EventField::KEYBOARD_EVENT_KEYCODE);
                        let is_repeat = event
                            .get_integer_value_field(EventField::KEYBOARD_EVENT_AUTOREPEAT)
                            != 0;
                        let flags = event.get_flags();

                        let consume = handle_event(&mut guard, etype, key_code, is_repeat, flags);
                        if consume {
                            CallbackResult::Drop
                        } else {
                            CallbackResult::Keep
                        }
                    },
                ) {
                    Ok(t) => t,
                    Err(()) => {
                        let _ = ready_tx.send(Err(HotkeyError::TapCreateFailed));
                        return;
                    }
                };

                // Guarda o port para re-enable no callback (o tap vive nesta thread).
                if let Ok(mut guard) = state.lock() {
                    guard.mach_port_ref = tap.mach_port().as_concrete_TypeRef() as usize;
                }

                let loop_source = tap
                    .mach_port()
                    .create_runloop_source(0)
                    .expect("runloop source");
                let rl = CFRunLoop::get_current();
                rl.add_source(&loop_source, unsafe { kCFRunLoopCommonModes });
                tap.enable();

                {
                    let mut slot = run_loop_slot.lock().unwrap();
                    *slot = Some(rl.clone());
                }
                let _ = ready_tx.send(Ok(()));

                // Roda até stop() chamar CFRunLoopStop.
                while !stop_flag_thread.load(Ordering::SeqCst) {
                    CFRunLoop::run_current();
                    if stop_flag_thread.load(Ordering::SeqCst) {
                        break;
                    }
                }

                {
                    let mut slot = run_loop_slot.lock().unwrap();
                    *slot = None;
                }
                // `tap` drop invalida o mach port.
            })
            .map_err(|_| HotkeyError::TapCreateFailed)?;

        match ready_rx.recv() {
            Ok(Ok(())) => {
                self.stop_flag = Some(stop_flag);
                self.join = Some(join);
                Ok(())
            }
            Ok(Err(e)) => {
                let _ = join.join();
                Err(e)
            }
            Err(_) => {
                let _ = join.join();
                Err(HotkeyError::TapCreateFailed)
            }
        }
    }

    pub fn stop(&mut self) {
        if let Some(flag) = self.stop_flag.take() {
            flag.store(true, Ordering::SeqCst);
        }
        if let Some(rl) = self.run_loop.lock().unwrap().take() {
            rl.stop();
        }
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}

impl Drop for HotkeyMonitor {
    fn drop(&mut self) {
        self.stop();
    }
}

fn handle_event(
    state: &mut TapState,
    etype: CGEventType,
    key_code: i64,
    is_repeat: bool,
    flags: CGEventFlags,
) -> bool {
    let spec = &state.spec;
    let is_modifier = spec.modifier_flag != 0;
    let should_consume = spec.key_code != KEY_FUNCTION;

    if is_modifier {
        if !matches!(etype, CGEventType::FlagsChanged) || key_code != spec.key_code {
            return false;
        }
        // NX_DEVICE* bits (left/right) — mask raw, não as constantes públicas union.
        let now_pressed = (flags.bits() & spec.modifier_flag) != 0;
        if now_pressed == state.is_pressed {
            return false;
        }
        state.is_pressed = now_pressed;
        fire(state, now_pressed);
        return should_consume;
    }

    if key_code != spec.key_code {
        return false;
    }
    if !matches!(etype, CGEventType::KeyDown | CGEventType::KeyUp) {
        return false;
    }
    if is_repeat {
        return should_consume;
    }

    let now_pressed = matches!(etype, CGEventType::KeyDown);
    if now_pressed == state.is_pressed {
        return should_consume;
    }
    state.is_pressed = now_pressed;
    fire(state, now_pressed);
    should_consume
}

fn fire(state: &TapState, pressed: bool) {
    if pressed {
        (state.on_press)();
    } else {
        (state.on_release)();
    }
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGEventTapEnable(tap: core_foundation::mach_port::CFMachPortRef, enable: bool);
}

use core_foundation::base::TCFType;

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn test_state(spec: HotkeySpec) -> (TapState, Arc<AtomicUsize>, Arc<AtomicUsize>) {
        let presses = Arc::new(AtomicUsize::new(0));
        let releases = Arc::new(AtomicUsize::new(0));
        let press_count = presses.clone();
        let release_count = releases.clone();
        (
            TapState {
                spec,
                is_pressed: false,
                on_press: Arc::new(move || {
                    press_count.fetch_add(1, Ordering::SeqCst);
                }),
                on_release: Arc::new(move || {
                    release_count.fetch_add(1, Ordering::SeqCst);
                }),
                mach_port_ref: 0,
            },
            presses,
            releases,
        )
    }

    #[test]
    fn right_option_fires_once_for_press_and_release() {
        let (mut state, presses, releases) = test_state(HotkeySpec {
            key_code: 61,
            modifier_flag: 0x40,
            display_name: "R⌥".into(),
        });
        // Os bits NX_DEVICE* não fazem parte das flags públicas, mas chegam crus do CGEvent.
        let pressed_flags = CGEventFlags::from_bits_retain(0x40);

        assert!(handle_event(
            &mut state,
            CGEventType::FlagsChanged,
            61,
            false,
            pressed_flags,
        ));
        assert!(!handle_event(
            &mut state,
            CGEventType::FlagsChanged,
            61,
            false,
            pressed_flags,
        ));
        assert!(handle_event(
            &mut state,
            CGEventType::FlagsChanged,
            61,
            false,
            CGEventFlags::empty(),
        ));
        assert_eq!(presses.load(Ordering::SeqCst), 1);
        assert_eq!(releases.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn regular_key_ignores_repeat_and_tracks_key_up() {
        let (mut state, presses, releases) = test_state(HotkeySpec {
            key_code: 109,
            modifier_flag: 0,
            display_name: "F10".into(),
        });

        assert!(handle_event(
            &mut state,
            CGEventType::KeyDown,
            109,
            false,
            CGEventFlags::empty(),
        ));
        assert!(handle_event(
            &mut state,
            CGEventType::KeyDown,
            109,
            true,
            CGEventFlags::empty(),
        ));
        assert!(handle_event(
            &mut state,
            CGEventType::KeyUp,
            109,
            false,
            CGEventFlags::empty(),
        ));
        assert_eq!(presses.load(Ordering::SeqCst), 1);
        assert_eq!(releases.load(Ordering::SeqCst), 1);
    }
}
