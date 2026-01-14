// Original logging pattern.

pub mod bridge;
pub use bridge::init;

use tauri::plugin::TauriPlugin;
use tauri::Runtime;

/**
 * Custom debug macro
 * This macro uses tracing::debug under the hood, ensuring that logs
 * appear in both the terminal and the UI System Logs window.
 */
#[macro_export]
macro_rules! debug {
    ($($arg:tt)*) => {
        // We use the 'unyt' target to maintain the prefix logic in the unified system
        tracing::debug!(target: "unyt", $($arg)*);
    };
}

pub fn parse_log_level(level: &str) -> Option<log::LevelFilter> {
    match level.to_lowercase().as_str() {
        "off" => Some(log::LevelFilter::Off),
        "error" => Some(log::LevelFilter::Error),
        "warn" => Some(log::LevelFilter::Warn),
        "info" => Some(log::LevelFilter::Info),
        "debug" => Some(log::LevelFilter::Debug),
        "trace" => Some(log::LevelFilter::Trace),
        _ => None,
    }
}

pub fn init_legacy_logger<R: Runtime>() -> TauriPlugin<R> {
    let mut log_builder = tauri_plugin_log::Builder::default();

    // Set general log level (default: Warn)
    let general_level = std::env::var("UNYT_LOG_LEVEL")
        .ok()
        .and_then(|level| parse_log_level(&level))
        .unwrap_or(log::LevelFilter::Warn);

    log_builder = log_builder.level(general_level);

    // Default module-specific log levels
    log_builder = log_builder
        .level_for("tracing::span", log::LevelFilter::Off)
        .level_for("iroh", log::LevelFilter::Warn)
        .level_for("holochain", log::LevelFilter::Info)
        .level_for("kitsune2", log::LevelFilter::Info)
        .level_for("kitsune2_gossip", log::LevelFilter::Info)
        .level_for("kitsune2_api", log::LevelFilter::Debug)
        .level_for("holochain_runtime", log::LevelFilter::Info)
        .level_for("unyt", log::LevelFilter::Debug);

    // Override with specific log levels from environment variable
    if let Ok(specific_logs) = std::env::var("UNYT_SPECIFIC_LOG") {
        let log_configs: Vec<(String, log::LevelFilter)> = specific_logs
            .split(',')
            .filter_map(|entry| {
                let entry = entry.trim();
                entry.split_once('=').and_then(|(module, level_str)| {
                    let module = module.trim().to_string();
                    let level_str = level_str.trim();
                    parse_log_level(level_str).map(|level| (module, level))
                })
            })
            .collect();

        for (module, level) in log_configs {
            log_builder = log_builder.level_for(module, level);
        }
    }

    log_builder.build()
}
