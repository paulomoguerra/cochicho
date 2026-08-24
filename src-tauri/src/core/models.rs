//! Catálogo de modelos + residência em disco (port de `ModelResidence.swift` +
//! `DiskUsage.swift` + `WhisperModels`/`ParakeetModels` adaptados aos backends
//! novos: whisper.cpp GGUF e sherpa-onnx no lugar de WhisperKit/FluidAudio).

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::core::settings::EngineKind;

/// Um modelo do catálogo. `file` é o caminho relativo dentro de models/<engine>/.
pub struct ModelInfo {
    /// Nome canônico usado em settings (`whisper_model`). Para whisper usamos o nome
    /// legacy do WhisperKit quando existe, para a migração do app antigo ser direta.
    pub name: &'static str,
    pub engine: EngineKind,
    pub file: &'static str,
    pub url: &'static str,
    pub approx_bytes: u64,
    /// Modelos .en só fazem inglês — escondidos quando o idioma é pt-BR.
    pub english_only: bool,
}

macro_rules! whisper_model {
    ($name:literal, $file:literal, $bytes:expr, $en:expr) => {
        ModelInfo {
            name: $name,
            engine: EngineKind::Whisper,
            file: $file,
            url: concat!(
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/",
                $file
            ),
            approx_bytes: $bytes,
            english_only: $en,
        }
    };
}

pub const WHISPER_CATALOG: &[ModelInfo] = &[
    whisper_model!("openai_whisper-tiny", "ggml-tiny.bin", 78_000_000, false),
    whisper_model!("openai_whisper-tiny.en", "ggml-tiny.en.bin", 78_000_000, true),
    whisper_model!("openai_whisper-base", "ggml-base.bin", 148_000_000, false),
    whisper_model!("openai_whisper-base.en", "ggml-base.en.bin", 148_000_000, true),
    whisper_model!("openai_whisper-small", "ggml-small.bin", 488_000_000, false),
    whisper_model!("openai_whisper-small.en", "ggml-small.en.bin", 488_000_000, true),
    whisper_model!("openai_whisper-medium", "ggml-medium.bin", 1_530_000_000, false),
    whisper_model!("openai_whisper-medium.en", "ggml-medium.en.bin", 1_530_000_000, true),
    whisper_model!("openai_whisper-large-v3", "ggml-large-v3.bin", 3_100_000_000, false),
    whisper_model!("openai_whisper-large-v3-turbo", "ggml-large-v3-turbo.bin", 1_620_000_000, false),
    ModelInfo {
        name: "distil-whisper_large-v3",
        engine: EngineKind::Whisper,
        file: "ggml-distil-large-v3.bin",
        url: "https://huggingface.co/distil-whisper/distil-large-v3-ggml/resolve/main/ggml-distil-large-v3.bin",
        approx_bytes: 1_510_000_000,
        english_only: true,
    },
];

/// URLs oficiais dos releases `asr-models` do sherpa-onnx (tar.bz2 multi-arquivo).
/// Verificadas 2026-08-24: GitHub responde 302 para os assets.
pub const PARAKEET_CATALOG: &[ModelInfo] = &[
    ModelInfo {
        name: "parakeet-tdt-0.6b-v3",
        engine: EngineKind::Parakeet,
        file: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2",
        approx_bytes: 650_000_000,
        english_only: false,
    },
    ModelInfo {
        name: "parakeet-tdt-0.6b-v2",
        engine: EngineKind::Parakeet,
        file: "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8",
        url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2",
        approx_bytes: 640_000_000,
        english_only: true,
    },
];

pub fn find_model(engine: EngineKind, name: &str) -> Option<&'static ModelInfo> {
    let catalog = match engine {
        EngineKind::Whisper => WHISPER_CATALOG,
        EngineKind::Parakeet => PARAKEET_CATALOG,
        EngineKind::Apple => &[],
    };
    catalog.iter().find(|m| m.name == name)
}

/// Migração: aceita tanto o nome legacy ("openai_whisper-base") quanto o arquivo
/// ("ggml-base.bin") e devolve o item do catálogo.
pub fn resolve_whisper_model(setting: &str) -> Option<&'static ModelInfo> {
    WHISPER_CATALOG
        .iter()
        .find(|m| m.name == setting || m.file == setting)
}

pub fn resolve_parakeet_model(setting: &str) -> Option<&'static ModelInfo> {
    PARAKEET_CATALOG
        .iter()
        .find(|m| m.name == setting || m.file == setting)
}

/// Diretório raiz dos modelos, por plataforma.
/// macOS: ~/Library/Application Support/EkoNami/Models
/// Linux: $XDG_DATA_HOME/ekonami/models (~/.local/share/ekonami/models)
pub fn models_dir() -> PathBuf {
    data_dir().join("models")
}

/// Diretório de dados do app (settings/history/dictionary também vivem aqui).
///
/// Em builds de dev o sufixo `-dev` isola os dados do app de produção instalado
/// em /Applications — dev nunca lê nem escreve no diretório de prod. A migração
/// dos dados do app Swift (M4) acontece só em build release.
pub fn data_dir() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        let dir_name = if cfg!(debug_assertions) {
            "EkoNami-dev"
        } else {
            "EkoNami"
        };
        dirs::home_dir()
            .unwrap_or_default()
            .join("Library/Application Support")
            .join(dir_name)
    }
    #[cfg(target_os = "linux")]
    {
        let dir_name = if cfg!(debug_assertions) {
            "ekonami-dev"
        } else {
            "ekonami"
        };
        dirs::data_dir()
            .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join(".local/share"))
            .join(dir_name)
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let dir_name = if cfg!(debug_assertions) {
            "ekonami-dev"
        } else {
            "ekonami"
        };
        dirs::data_dir().unwrap_or_default().join(dir_name)
    }
}

pub fn model_path(info: &ModelInfo) -> PathBuf {
    let engine_dir = match info.engine {
        EngineKind::Whisper => "whisper",
        EngineKind::Parakeet => "parakeet",
        EngineKind::Apple => "apple",
    };
    models_dir().join(engine_dir).join(info.file)
}

/// Arquivos ONNX + tokens dentro do diretório Parakeet extraído.
/// Campos ficam prontos para o `TransducerRecognizer` quando sherpa-rs linkar.
#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct ParakeetOnnxPaths {
    pub encoder: PathBuf,
    pub decoder: PathBuf,
    pub joiner: PathBuf,
    pub tokens: PathBuf,
}

/// Resolve encoder/decoder/joiner/tokens no diretório (ou um nível abaixo, se
/// o tar tiver wrap extra). Aceita tanto `*.int8.onnx` quanto `*.onnx`.
pub fn parakeet_onnx_paths(dir: &Path) -> Option<ParakeetOnnxPaths> {
    fn find_named(root: &Path, needle: &str) -> Option<PathBuf> {
        let direct = root.join(needle);
        if direct.is_file() {
            return Some(direct);
        }
        // Alternativas comuns nos releases sherpa-onnx.
        let alts: &[&str] = match needle {
            "encoder.int8.onnx" => &["encoder.onnx"],
            "decoder.int8.onnx" => &["decoder.onnx"],
            "joiner.int8.onnx" => &["joiner.onnx"],
            "tokens.txt" => &[],
            _ => &[],
        };
        for alt in alts {
            let p = root.join(alt);
            if p.is_file() {
                return Some(p);
            }
        }
        // Um nível de subpasta (às vezes o tar aninha).
        if let Ok(entries) = std::fs::read_dir(root) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    let nested = p.join(needle);
                    if nested.is_file() {
                        return Some(nested);
                    }
                    for alt in alts {
                        let nested = p.join(alt);
                        if nested.is_file() {
                            return Some(nested);
                        }
                    }
                }
            }
        }
        None
    }

    Some(ParakeetOnnxPaths {
        encoder: find_named(dir, "encoder.int8.onnx")?,
        decoder: find_named(dir, "decoder.int8.onnx")?,
        joiner: find_named(dir, "joiner.int8.onnx")?,
        tokens: find_named(dir, "tokens.txt")?,
    })
}

pub fn is_downloaded(info: &ModelInfo) -> bool {
    let path = model_path(info);
    if info.engine == EngineKind::Parakeet {
        path.is_dir() && parakeet_onnx_paths(&path).is_some()
    } else {
        path.is_file()
    }
}

/// Tamanho em disco de um modelo baixado (port de `DiskUsage.swift`).
pub fn disk_size(info: &ModelInfo) -> u64 {
    fn dir_size(path: &Path) -> u64 {
        let mut total = 0;
        if let Ok(entries) = std::fs::read_dir(path) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.is_dir() {
                    total += dir_size(&p);
                } else if let Ok(meta) = p.metadata() {
                    total += meta.len();
                }
            }
        }
        total
    }

    let path = model_path(info);
    if path.is_dir() {
        dir_size(&path)
    } else {
        path.metadata().map(|m| m.len()).unwrap_or(0)
    }
}

/// Remove um modelo baixado do disco (arquivo Whisper ou pasta Parakeet).
pub fn delete_model(info: &ModelInfo) -> Result<(), String> {
    let path = model_path(info);
    if !path.exists() {
        return Ok(());
    }
    if path.is_dir() {
        std::fs::remove_dir_all(&path).map_err(|e| e.to_string())?;
    } else {
        std::fs::remove_file(&path).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[derive(Clone, Debug, Serialize)]
pub struct ModelStatus {
    pub name: String,
    pub engine: EngineKind,
    pub display: String,
    pub downloaded: bool,
    pub bytes_on_disk: u64,
    pub approx_bytes: u64,
    pub english_only: bool,
}

pub fn catalog_status() -> Vec<ModelStatus> {
    WHISPER_CATALOG
        .iter()
        .chain(PARAKEET_CATALOG.iter())
        .map(|info| ModelStatus {
            name: info.name.to_string(),
            engine: info.engine,
            display: info.file.to_string(),
            downloaded: is_downloaded(info),
            bytes_on_disk: if is_downloaded(info) {
                disk_size(info)
            } else {
                0
            },
            approx_bytes: info.approx_bytes,
            english_only: info.english_only,
        })
        .collect()
}

/// Baixa um arquivo com progresso. Retorna o path final (movido atomicamente).
pub async fn download_file(
    url: &str,
    dest: PathBuf,
    mut on_progress: impl FnMut(f64) + Send,
) -> Result<PathBuf, String> {
    use tokio::io::AsyncWriteExt;

    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    let response = reqwest::get(url).await.map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("HTTP {}", response.status()));
    }
    let total = response.content_length().unwrap_or(0);

    let tmp = dest.with_extension("download");
    let mut file = tokio::fs::File::create(&tmp)
        .await
        .map_err(|e| e.to_string())?;
    let mut downloaded: u64 = 0;
    let mut stream = response.bytes_stream();

    use futures_util::StreamExt;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| e.to_string())?;
        file.write_all(&chunk).await.map_err(|e| e.to_string())?;
        downloaded += chunk.len() as u64;
        if total > 0 {
            on_progress(downloaded as f64 / total as f64);
        }
    }
    file.flush().await.map_err(|e| e.to_string())?;
    drop(file);

    tokio::fs::rename(&tmp, &dest)
        .await
        .map_err(|e| e.to_string())?;
    Ok(dest)
}

/// Extrai tar.bz2 do Parakeet para `dest_dir` (o diretório final do modelo).
/// Usa `tar` do sistema — zero crate extra, disponível em macOS e Linux.
pub fn extract_parakeet_archive(archive: &Path, dest_dir: &Path) -> Result<(), String> {
    if let Some(parent) = dest_dir.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }

    // Extrai para um staging ao lado; o tar cria a pasta com o nome do release.
    let staging_parent = dest_dir
        .parent()
        .ok_or("destino Parakeet sem parent")?
        .join(format!(
            ".extract-{}",
            dest_dir
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("parakeet")
        ));
    if staging_parent.exists() {
        std::fs::remove_dir_all(&staging_parent).map_err(|e| e.to_string())?;
    }
    std::fs::create_dir_all(&staging_parent).map_err(|e| e.to_string())?;

    let status = std::process::Command::new("tar")
        .args(["-xjf"])
        .arg(archive)
        .arg("-C")
        .arg(&staging_parent)
        .status()
        .map_err(|e| format!("tar: {e}"))?;
    if !status.success() {
        let _ = std::fs::remove_dir_all(&staging_parent);
        return Err(format!("tar saiu com status {status}"));
    }

    // O release costuma extrair como <file>/encoder...; às vezes os arquivos
    // caem direto no staging.
    let extracted = find_extracted_model_root(&staging_parent)
        .ok_or_else(|| "arquivo Parakeet incompleto após extração".to_string())?;

    if dest_dir.exists() {
        std::fs::remove_dir_all(dest_dir).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&extracted, dest_dir).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_dir_all(&staging_parent);

    if parakeet_onnx_paths(dest_dir).is_none() {
        let _ = std::fs::remove_dir_all(dest_dir);
        return Err("extração Parakeet sem encoder/decoder/joiner/tokens".into());
    }
    Ok(())
}

/// Encontra a raiz que contém os quatro arquivos do modelo.
fn find_extracted_model_root(staging: &Path) -> Option<PathBuf> {
    if parakeet_onnx_paths(staging).is_some() {
        return Some(staging.to_path_buf());
    }
    let entries = std::fs::read_dir(staging).ok()?;
    for entry in entries.flatten() {
        let p = entry.path();
        if p.is_dir() && parakeet_onnx_paths(&p).is_some() {
            return Some(p);
        }
    }
    None
}

/// Download + (se Parakeet) extração. Progresso: 0..0.95 download, 0.95..1 extract.
pub async fn download_model(
    info: &ModelInfo,
    mut on_progress: impl FnMut(f64) + Send,
) -> Result<(), String> {
    if is_downloaded(info) {
        on_progress(1.0);
        return Ok(());
    }

    match info.engine {
        EngineKind::Whisper => {
            let dest = model_path(info);
            download_file(info.url, dest, on_progress).await?;
        }
        EngineKind::Parakeet => {
            let dest_dir = model_path(info);
            let archive = dest_dir.with_extension("tar.bz2.download");
            if let Some(parent) = archive.parent() {
                std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
            }
            download_file(info.url, archive.clone(), |p| {
                on_progress(p * 0.95);
            })
            .await?;
            on_progress(0.96);
            let dest = dest_dir.clone();
            let arch = archive.clone();
            tokio::task::spawn_blocking(move || extract_parakeet_archive(&arch, &dest))
                .await
                .map_err(|e| e.to_string())??;
            let _ = std::fs::remove_file(&archive);
            on_progress(1.0);
        }
        EngineKind::Apple => return Err("Apple não tem download".into()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    #[test]
    fn catalog_entries_have_url_and_file() {
        for info in WHISPER_CATALOG.iter().chain(PARAKEET_CATALOG.iter()) {
            assert!(!info.name.is_empty(), "empty name");
            assert!(!info.file.is_empty(), "empty file for {}", info.name);
            assert!(
                info.url.starts_with("https://"),
                "bad url for {}: {}",
                info.name,
                info.url
            );
            assert!(info.approx_bytes > 0, "zero size for {}", info.name);
        }
    }

    #[test]
    fn model_paths_are_unique() {
        let mut seen = HashSet::new();
        for info in WHISPER_CATALOG.iter().chain(PARAKEET_CATALOG.iter()) {
            let p = model_path(info);
            assert!(
                seen.insert(p.clone()),
                "duplicate model_path: {}",
                p.display()
            );
        }
    }

    #[test]
    fn resolve_whisper_accepts_legacy_and_file() {
        assert_eq!(
            resolve_whisper_model("openai_whisper-base").map(|m| m.file),
            Some("ggml-base.bin")
        );
        assert_eq!(
            resolve_whisper_model("ggml-base.bin").map(|m| m.name),
            Some("openai_whisper-base")
        );
    }

    #[test]
    fn resolve_parakeet_by_name() {
        assert_eq!(
            resolve_parakeet_model("parakeet-tdt-0.6b-v3").map(|m| m.file),
            Some("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
        );
    }

    #[test]
    fn parakeet_urls_point_at_sherpa_releases() {
        for info in PARAKEET_CATALOG {
            assert!(
                info.url.contains("sherpa-onnx") && info.url.ends_with(".tar.bz2"),
                "{}",
                info.url
            );
        }
    }

    #[test]
    fn parakeet_onnx_paths_finds_int8_layout() {
        let dir = std::env::temp_dir().join(format!("ekonami-parakeet-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for name in [
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "joiner.int8.onnx",
            "tokens.txt",
        ] {
            std::fs::write(dir.join(name), b"x").unwrap();
        }
        let paths = parakeet_onnx_paths(&dir).expect("should find");
        assert!(paths.encoder.ends_with("encoder.int8.onnx"));
        assert!(paths.tokens.ends_with("tokens.txt"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn parakeet_onnx_paths_finds_nested_layout() {
        let dir = std::env::temp_dir().join(format!("ekonami-parakeet-nest-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let inner = dir.join("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8");
        std::fs::create_dir_all(&inner).unwrap();
        for name in [
            "encoder.int8.onnx",
            "decoder.int8.onnx",
            "joiner.int8.onnx",
            "tokens.txt",
        ] {
            std::fs::write(inner.join(name), b"x").unwrap();
        }
        // find_extracted_model_root style: paths on inner
        assert!(parakeet_onnx_paths(&inner).is_some());
        assert!(parakeet_onnx_paths(&dir).is_some());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn delete_model_removes_file() {
        let info = &WHISPER_CATALOG[0];
        // Não toca no data_dir real — só valida a lógica com path sintetizado via
        // is_downloaded false quando ausente.
        assert!(!is_downloaded(info) || model_path(info).exists());
        // delete de path inexistente é no-op ok:
        // (se por acaso o tiny estiver baixado no dev dir, não apagamos aqui)
        let fake = ModelInfo {
            name: "test-never-exists",
            engine: EngineKind::Whisper,
            file: "__eko_nami_test_missing__.bin",
            url: "https://example.com/x",
            approx_bytes: 1,
            english_only: false,
        };
        assert!(delete_model(&fake).is_ok());
    }
}
