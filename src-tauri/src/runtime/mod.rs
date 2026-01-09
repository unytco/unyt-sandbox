pub mod logs;
pub mod state;

use self::state::{EnvRuntimeStatus, EnvStatusManager};
use std::sync::Arc;
use tauri::{AppHandle, Manager, Runtime};

/// Initializes the modular runtime components
pub fn init(handle: &AppHandle) -> anyhow::Result<()> {
    logs::init(handle.clone())?;
    state::init(handle.clone())?;
    Ok(())
}

#[tauri::command]
pub fn get_runtime_status(state: tauri::State<'_, Arc<EnvStatusManager>>) -> EnvRuntimeStatus {
    state.get_status()
}
