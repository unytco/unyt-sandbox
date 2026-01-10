mod handlers;
mod sync;

use crate::app_config::AppConfig;
use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tauri_plugin_holochain::HolochainExt;

const TIMEOUT_DURATION_SEC: u64 = 2;
pub const MAX_SYNC_ATTEMPTS: i32 = 15;

/// Start the monitoring of the network and peers
pub fn start_monitoring(app_handle: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut sync_ticks: i32 = 0;
        let app_config = AppConfig::new(&app_handle);

        loop {
            // Wait for next tick
            tokio::time::sleep(Duration::from_secs(TIMEOUT_DURATION_SEC)).await;

            let status_manager = match app_handle.try_state::<Arc<EnvStatusManager>>() {
                Some(s) => s,
                None => continue,
            };

            let current_status = status_manager.get_status();
            match current_status {
                EnvRuntimeStatus::Networking { .. }
                | EnvRuntimeStatus::Syncing { .. }
                | EnvRuntimeStatus::ProgenitorPrompt => {
                    if let Err(e) = monitor_network_and_peers(
                        &app_handle,
                        &app_config,
                        &status_manager,
                        &mut sync_ticks,
                    )
                    .await
                    {
                        handlers::handle_conductor_error(e, &status_manager);
                    }
                }
                EnvRuntimeStatus::Ready | EnvRuntimeStatus::Error(_) => {
                    tracing::info!(target: "unyt::network", "Initialization terminal state reached. Exiting network sync and monitoring loop.");
                    break;
                }
                _ => {}
            }
        }
    });
}

/// Monitor the network to manage syncing with peers and initializing the app
async fn monitor_network_and_peers(
    app_handle: &AppHandle,
    app_config: &AppConfig,
    status_manager: &Arc<EnvStatusManager>,
    sync_ticks: &mut i32,
) -> anyhow::Result<()> {
    let holochain = app_handle.holochain()?;
    let admin_ws = holochain.admin_websocket().await?;

    let agent_info = admin_ws
        .agent_info(None)
        .await
        .map_err(|e| anyhow::anyhow!("Conductor connection failed: {:?}", e))?;

    // Subtract 1 to exclude the current agent from the peer count
    let peer_count = agent_info.len().saturating_sub(1);
    let current_status = status_manager.get_status();

    if peer_count > 0 {
        // Path A: Peers discovered - proceed to peer sync
        let app_ws = holochain.app_websocket(app_config.app_id.clone()).await?;
        sync::handle_network_sync(app_ws, status_manager.clone(), peer_count).await;
    } else {
        // Path B: No peers found - update counter and handle progenitor timeout
        if let EnvRuntimeStatus::Networking { .. } = current_status {
            status_manager.update_status(EnvRuntimeStatus::Networking { peer_count });
        }

        if current_status != EnvRuntimeStatus::ProgenitorPrompt {
            *sync_ticks += 1;
            if *sync_ticks > MAX_SYNC_ATTEMPTS {
                handlers::handle_timeout(app_handle, status_manager, sync_ticks).await?;
            }
        }
    }

    Ok(())
}
