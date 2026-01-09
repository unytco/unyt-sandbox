use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use holochain_client::AgentInfoRequest;
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tauri_plugin_holochain::HolochainExt;

pub fn start_monitoring(app_handle: AppHandle) {
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;

            let state_manager = match app_handle.try_state::<Arc<EnvStatusManager>>() {
                Some(s) => s,
                None => continue,
            };

            // Only monitor networking if we are in a state that expects it
            let current_status = state_manager.get_status();
            match current_status {
                EnvRuntimeStatus::Networking { .. } | EnvRuntimeStatus::Syncing { .. } => {
                    if let Ok(holochain) = app_handle.holochain() {
                        if let Ok(mut admin_ws) = holochain.admin_websocket().await {
                            // Get peer info
                            if let Ok(agent_info) = admin_ws
                                .agent_info(AgentInfoRequest { cell_id: None })
                                .await
                            {
                                let peer_count = agent_info.len();

                                // Update status with peer count if we are in Networking state
                                if let EnvRuntimeStatus::Networking { .. } = current_status {
                                    state_manager
                                        .update_status(EnvRuntimeStatus::Networking { peer_count });
                                }

                                // If we have peers, we might want to check for validation receipts
                                if peer_count > 0 {
                                    // Transition to Syncing state if we were in Networking
                                    if let EnvRuntimeStatus::Networking { .. } = current_status {
                                        state_manager.update_status(EnvRuntimeStatus::Syncing {
                                            progress: 0.1,
                                            message: format!(
                                                "Connected to {peer_count} peer/s. Awaiting validation...",
                                            ),
                                        });
                                    }
                                }
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    });
}
