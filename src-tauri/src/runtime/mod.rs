pub mod boot;
pub mod events;
pub mod logs;
pub mod status;

pub use status::{EnvRuntimeStatus, EnvStatusManager};

use tauri::AppHandle;

/// Initialize logs and status to be used during runtime
pub fn init(handle: &AppHandle) -> anyhow::Result<()> {
    logs::init(handle.clone())?;
    status::init(handle.clone())?;
    Ok(())
}
