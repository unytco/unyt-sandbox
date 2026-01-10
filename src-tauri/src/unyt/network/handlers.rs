use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use crate::unyt::progenitor::is_progenitor;
use std::sync::Arc;
use tauri::AppHandle;

pub async fn handle_timeout(
    app_handle: &AppHandle,
    status_manager: &Arc<EnvStatusManager>,
    sync_ticks: &mut i32,
) -> anyhow::Result<()> {
    if is_progenitor(app_handle.clone()).await? {
        tracing::info!(target: "unyt::network", "No peers found. Prompting for progenitor role.");
        status_manager.update_status(EnvRuntimeStatus::ProgenitorPrompt);
    } else {
        tracing::warn!(target: "unyt::network", "No peers found and not progenitor. Searching...");
        *sync_ticks = 0;
    }
    Ok(())
}

pub fn handle_conductor_error(err: anyhow::Error, status_manager: &Arc<EnvStatusManager>) {
    let err_msg = format!("{:?}", err);
    if err_msg.contains("Websocket") || err_msg.contains("Closed") {
        tracing::error!(target: "unyt::network", "Terminal conductor error: {}", err_msg);
        status_manager.update_status(EnvRuntimeStatus::Error(format!(
            "Holochain connection lost: {}",
            err_msg
        )));
    }
}
