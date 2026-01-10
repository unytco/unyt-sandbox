pub mod logs;
pub mod status;

use self::status::{EnvRuntimeStatus, EnvStatusManager};
use std::sync::Arc;
use tauri::AppHandle;

/// Initializes the modular runtime components
pub fn init(handle: &AppHandle) -> anyhow::Result<()> {
    logs::init(handle.clone())?;
    status::init(handle.clone())?;
    Ok(())
}

#[tauri::command]
pub fn get_runtime_status(status_manager: tauri::State<'_, Arc<EnvStatusManager>>) -> EnvRuntimeStatus {
    status_manager.get_status()
}

#[tauri::command]
pub fn accept_progenitor_role(status_manager: tauri::State<'_, Arc<EnvStatusManager>>) {
    tracing::info!(target: "unyt::network", "User accepted progenitor role.");
    status_manager.update_status(EnvRuntimeStatus::Ready);
}
