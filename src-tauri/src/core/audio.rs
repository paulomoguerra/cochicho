//! Port de `AudioCapture.swift` com cpal: captura o mic default, mixa para mono,
//! reamostra para 16 kHz (formato que as engines esperam) e reporta nível RMS.
//! A curva de nível replica o mapeamento do Swift: dB = 20·log10(rms), piso −60 dB.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use rubato::{Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction};

pub const ENGINE_SAMPLE_RATE: u32 = 16_000;

#[derive(Clone, Copy, Debug)]
pub struct AudioFormat {
    pub channels: u16,
    pub sample_rate: u32,
}

#[derive(Debug, thiserror::Error)]
pub enum AudioError {
    #[error("no input device")]
    NoDevice,
    #[error("audio stream failed: {0}")]
    Stream(String),
}

pub struct AudioCapture {
    stream: Option<cpal::Stream>,
}

impl Default for AudioCapture {
    fn default() -> Self {
        Self::new()
    }
}

impl AudioCapture {
    pub fn new() -> Self {
        Self { stream: None }
    }

    /// Abre o dispositivo de entrada default e começa a entregar chunks f32 mono a
    /// 16 kHz para `on_samples`, e nível 0..1 para `on_level`. Os callbacks rodam na
    /// thread de áudio — mantenha-os baratos (o controller encaminha via canal).
    pub fn start<F, G>(&mut self, on_samples: F, on_level: G) -> Result<AudioFormat, AudioError>
    where
        F: Fn(&[f32]) + Send + 'static,
        G: Fn(f32) + Send + 'static,
    {
        let host = cpal::default_host();
        let device = host.default_input_device().ok_or(AudioError::NoDevice)?;
        let supported = device
            .default_input_config()
            .map_err(|e| AudioError::Stream(e.to_string()))?;

        let source_rate = supported.sample_rate();
        let channels = supported.channels();
        let format = AudioFormat {
            channels,
            sample_rate: source_rate,
        };

        // Reamostrador sinc de qualidade alta, blocos fixos de entrada.
        const INPUT_BLOCK: usize = 4096;
        let ratio = ENGINE_SAMPLE_RATE as f64 / source_rate as f64;
        let params = SincInterpolationParameters {
            sinc_len: 256,
            f_cutoff: 0.95,
            interpolation: SincInterpolationType::Linear,
            oversampling_factor: 256,
            window: WindowFunction::BlackmanHarris2,
        };
        let resampler = SincFixedIn::<f32>::new(ratio, 2.0, params, INPUT_BLOCK, 1)
            .map_err(|e| AudioError::Stream(e.to_string()))?;

        let state = std::sync::Arc::new(std::sync::Mutex::new(CaptureState {
            resampler,
            pending: Vec::with_capacity(INPUT_BLOCK * 2),
            channels: channels as usize,
        }));

        let needs_resample = (source_rate as i32 - ENGINE_SAMPLE_RATE as i32).abs() > 1;

        let stream = device
            .build_input_stream(
                supported.config(),
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    // Mono mixdown.
                    let mut state = state.lock().unwrap();
                    let ch = state.channels.max(1);
                    let mono: Vec<f32> = if ch == 1 {
                        data.to_vec()
                    } else {
                        data.chunks(ch)
                            .map(|frame| frame.iter().sum::<f32>() / ch as f32)
                            .collect()
                    };

                    if !mono.is_empty() {
                        let rms = (mono.iter().map(|s| s * s).sum::<f32>() / mono.len() as f32).sqrt();
                        let db = 20.0 * rms.max(1e-6).log10();
                        on_level(((db + 60.0) / 60.0).clamp(0.0, 1.0));
                    }

                    if needs_resample {
                        state.pending.extend_from_slice(&mono);
                        while state.pending.len() >= INPUT_BLOCK {
                            let block: Vec<f32> = state.pending.drain(..INPUT_BLOCK).collect();
                            if let Ok(out) = state.resampler.process(&[block], None) {
                                if let Some(chunk) = out.into_iter().next() {
                                    on_samples(&chunk);
                                }
                            }
                        }
                    } else {
                        on_samples(&mono);
                    }
                },
                |err| log::error!("audio stream error: {err}"),
                None,
            )
            .map_err(|e| AudioError::Stream(e.to_string()))?;

        stream.play().map_err(|e| AudioError::Stream(e.to_string()))?;
        self.stream = Some(stream);
        Ok(format)
    }

    /// Para imediatamente — samples em voo são descartados.
    pub fn stop(&mut self) {
        self.stream = None;
    }
}

struct CaptureState {
    resampler: SincFixedIn<f32>,
    pending: Vec<f32>,
    channels: usize,
}
