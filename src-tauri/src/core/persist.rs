//! Port de `DiskPersister.swift`: grava o JSON de um store fora da thread chamadora.
//!
//! Cada save chega como snapshot por valor; um mutex serializa as escritas. Saves
//! carregam versão monotônica — snapshot velho que chega atrasado é descartado em vez
//! de sobrescrever dados mais novos. Escrita atômica (tmp + rename).

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

use serde::Serialize;
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct DiskPersister {
    inner: Arc<Inner>,
}

struct Inner {
    path: PathBuf,
    last_written: AtomicU64,
    /// Serializa check-de-versão + escrita, como o actor fazia no Swift.
    write_lock: Mutex<()>,
}

impl DiskPersister {
    pub fn new(path: PathBuf) -> Self {
        Self {
            inner: Arc::new(Inner {
                path,
                last_written: AtomicU64::new(0),
                write_lock: Mutex::new(()),
            }),
        }
    }

    pub fn save<T: Serialize + Send + 'static>(&self, snapshot: T, version: u64) {
        let inner = self.inner.clone();

        // Fora de um runtime Tokio (testes unitários, shutdown), grava inline.
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            Self::write_sync(&inner, &snapshot, version);
            return;
        };
        runtime.spawn(async move {
            let _guard = inner.write_lock.lock().await;
            if version <= inner.last_written.load(Ordering::SeqCst) {
                return;
            }
            let Ok(data) = serde_json::to_vec_pretty(&snapshot) else {
                return;
            };
            inner.last_written.store(version, Ordering::SeqCst);

            let tmp = inner.path.with_extension("tmp");
            if tokio::fs::write(&tmp, &data).await.is_ok() {
                let _ = tokio::fs::rename(&tmp, &inner.path).await;
            }
        });
    }

    fn write_sync<T: Serialize>(inner: &Inner, snapshot: &T, version: u64) {
        if version <= inner.last_written.load(Ordering::SeqCst) {
            return;
        }
        let Ok(data) = serde_json::to_vec_pretty(snapshot) else {
            return;
        };
        inner.last_written.store(version, Ordering::SeqCst);
        let tmp = inner.path.with_extension("tmp");
        if std::fs::write(&tmp, &data).is_ok() {
            let _ = std::fs::rename(&tmp, &inner.path);
        }
    }
}
