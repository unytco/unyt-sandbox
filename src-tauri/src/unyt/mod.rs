pub mod network;
pub mod progenitor;

use tauri::AppHandle;

pub fn init(handle: &AppHandle) -> anyhow::Result<()> {
    network::start_monitoring(handle.clone());
    Ok(())
}
