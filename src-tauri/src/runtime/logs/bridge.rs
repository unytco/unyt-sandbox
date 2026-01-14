use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tracing::Subscriber;
use tracing_log::LogTracer;
use tracing_subscriber::layer::Context;
use tracing_subscriber::Layer;

#[derive(Clone, Serialize)]
pub struct TauriLogPayload {
    pub message: String,
    pub level: String,
    pub target: String,
}

/// Custom tracing layer that emits logs as Tauri events
struct TauriLogBridge {
    app_handle: AppHandle,
}

impl<S> Layer<S> for TauriLogBridge
where
    S: Subscriber,
{
    fn on_event(&self, event: &tracing::Event<'_>, _ctx: Context<'_, S>) {
        let level = event.metadata().level().to_string();
        let target = event.metadata().target().to_string();

        let mut message = String::new();
        struct MessageVisitor<'a>(&'a mut String);
        impl<'a> tracing::field::Visit for MessageVisitor<'a> {
            fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
                if field.name() == "message" {
                    use std::fmt::Write;
                    let _ = write!(self.0, "{:?}", value);
                }
            }
        }
        event.record(&mut MessageVisitor(&mut message));

        // If no message field was found, fall back to the whole event debug string
        if message.is_empty() {
            message = format!("{:?}", event);
        }

        // Clean up quotes from Debug formatting if present
        if message.starts_with('"') && message.ends_with('"') {
            message = message[1..message.len() - 1].to_string();
        }

        let _ = self.app_handle.emit(
            "runtime://env-log",
            TauriLogPayload {
                message,
                level,
                target,
            },
        );
    }
}

/// Initialize the log bridge
pub fn init(app_handle: AppHandle) -> anyhow::Result<()> {
    use tracing_subscriber::prelude::*;
    use tracing_subscriber::{fmt, EnvFilter};

    // Bridge standard log crate to tracing
    // We use .ok() because another logger (like tauri-plugin-log) might have already initialized the log bridge
    let _ = LogTracer::init();

    // Build the Unified Filter (Legacy Logic)
    let mut filter = EnvFilter::builder()
        .with_default_directive(tracing::Level::WARN.into())
        .from_env_lossy();

    // 1. Restore Legacy UNYT_LOG_LEVEL
    if let Ok(level) = std::env::var("UNYT_LOG_LEVEL") {
        if let Ok(directive) = level.parse::<tracing_subscriber::filter::Directive>() {
            filter = filter.add_directive(directive);
        }
    }

    // 2. Restore Legacy UNYT_SPECIFIC_LOG (e.g., "unyt=debug,holochain=info")
    if let Ok(specific_logs) = std::env::var("UNYT_SPECIFIC_LOG") {
        for entry in specific_logs.split(',') {
            if let Ok(directive) = entry.trim().parse() {
                filter = filter.add_directive(directive);
            }
        }
    }

    // 3. Keep current active status-based defaults if legacy vars aren't fully covering it
    if std::env::var("UNYT_LOG_LEVEL").is_err() && std::env::var("UNYT_SPECIFIC_LOG").is_err() {
        let holochain_log = std::env::var("HOLOCHAIN_LOG").unwrap_or_else(|_| "info".to_string());
        let kitsune_log = std::env::var("KITSUNE_LOG").unwrap_or_else(|_| "info".to_string());
        let unyt_log = std::env::var("UNYT_LOG").unwrap_or_else(|_| "debug".to_string());
        let lair_log = std::env::var("LAIR_LOG").unwrap_or_else(|_| "info".to_string());

        let filter_str = format!(
            "holochain={},kitsune2={},unyt={},lair={}",
            holochain_log, kitsune_log, unyt_log, lair_log
        );
        if let Ok(directive) = filter_str.parse() {
            filter = filter.add_directive(directive);
        }
    }

    // UI Output Layer (The new approach)
    let tauri_log_bridge = TauriLogBridge {
        app_handle: app_handle.clone(),
    };

    // Terminal Output Layer (The old approach's visibility)
    let terminal_layer = fmt::layer()
        .with_target(true)
        .with_thread_ids(false)
        .with_level(true);

    // Combine everything into a single Registry
    tracing_subscriber::registry()
        .with(filter) // Logic: What to show
        .with(tauri_log_bridge) // Sink 1: Show in UI
        .with(terminal_layer) // Sink 2: Show in Terminal
        .init();

    Ok(())
}
