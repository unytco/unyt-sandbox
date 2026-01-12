use serde::Serialize;
use std::io;
use tauri::{AppHandle, Emitter};
use tracing::Subscriber;
use tracing_subscriber::layer::Context;
use tracing_subscriber::Layer;

#[derive(Clone, Serialize)]
pub struct TauriLogPayload {
    pub message: String,
    pub level: String,
    pub target: String,
}

/// Custom tracing layer that emits logs as Tauri events
struct TauriLogLayer {
    app_handle: AppHandle,
}

impl<S> Layer<S> for TauriLogLayer
where
    S: Subscriber,
{
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let level = event.metadata().level().to_string();
        let target = event.metadata().target().to_string();

        // Extraction of the message
        let log_info = format!("[{}] {}: {:?}", level, target, event);

        let _ = self.app_handle.emit(
            "runtime://env-log",
            TauriLogPayload {
                message: log_info,
                level,
                target,
            },
        );
    }
}

/// Initialize the log bridge
pub fn init(app_handle: AppHandle) -> anyhow::Result<()> {
    use tracing_subscriber::prelude::*;

    let tauri_layer = TauriLogLayer {
        app_handle: app_handle.clone(),
    };

    // Show filtered Holochain/Kitsune logs
    let holochain_log = std::env::var("HOLOCHAIN_LOG").unwrap_or_else(|_| "info".to_string());
    let kitsune_log = std::env::var("KITSUNE_LOG").unwrap_or_else(|_| "info".to_string());
    let unyt_log = std::env::var("UNYT_LOG").unwrap_or_else(|_| "debug".to_string());
    let lair_log = std::env::var("LAIR_LOG").unwrap_or_else(|_| "info".to_string());

    let filter_str = format!(
        "holochain={},kitsune2={},unyt={},lair={}",
        holochain_log, kitsune_log, unyt_log, lair_log
    );

    let filter = tracing_subscriber::EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new(filter_str));

    tracing_subscriber::registry()
        .with(filter)
        .with(tauri_layer)
        .with(tracing_subscriber::fmt::layer().with_writer(io::stdout))
        .init();

    Ok(())
}
