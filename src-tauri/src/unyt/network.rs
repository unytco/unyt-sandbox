use crate::app_config::AppConfig;
use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use crate::unyt::progenitor::is_progenitor;
use holochain_client::{AgentInfoRequest, AppWebsocket, ExternIO, ZomeCallTarget};
use serde_json::Value;
use std::sync::Arc;
use std::time::Duration;
use tauri::{AppHandle, Manager};
use tauri_plugin_holochain::HolochainExt;

const TIMEOUT_DURATION_SEC: u64 = 2;
const MAX_SYNC_ATTEMPTS: i32 = 15;
const TOTAL_UNYT_SYNC_STEPS: u8 = 3;

pub fn start_monitoring(app_handle: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let mut sync_ticks: i32 = 0;
        let app_config = AppConfig::new(&app_handle);

        loop {
            tokio::time::sleep(Duration::from_secs(TIMEOUT_DURATION_SEC)).await;

            let status_manager = match app_handle.try_state::<Arc<EnvStatusManager>>() {
                Some(s) => s,
                None => continue,
            };

            let current_status = status_manager.get_status();
            match current_status {
                EnvRuntimeStatus::Networking { .. } | EnvRuntimeStatus::Syncing { .. } => {
                    if let Ok(holochain) = app_handle.holochain() {
                        if let Ok(mut admin_ws) = holochain.admin_websocket().await {
                            if let Ok(agent_info) = admin_ws
                                .agent_info(AgentInfoRequest { cell_id: None })
                                .await
                            {
                                let agent_count = agent_info.len();
                                // Subtract 1 to exclude the current agent from the peer count
                                let peer_count = agent_count.saturating_sub(1);

                                if let EnvRuntimeStatus::Networking { .. } = current_status {
                                    status_manager
                                        .update_status(EnvRuntimeStatus::Networking { peer_count });
                                }

                                if peer_count > 0 {
                                    if let Ok(app_ws) =
                                        holochain.app_websocket(app_config.app_id.clone()).await
                                    {
                                        sync_logic(app_ws, status_manager, peer_count).await;
                                    }
                                } else {
                                    sync_ticks += 1;
                                    if sync_ticks > MAX_SYNC_ATTEMPTS {
                                        if let Ok(true) = is_progenitor(app_handle.clone()).await {
                                            tracing::info!(target: "unyt::network", "No peers found after timeout. Prompting for progenitor role.");
                                            status_manager
                                                .update_status(EnvRuntimeStatus::ProgenitorPrompt);
                                        } else {
                                            tracing::warn!(target: "unyt::network", "No peers found and not progenitor. Continuing to search...");
                                            sync_ticks = 0;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                EnvRuntimeStatus::Ready | EnvRuntimeStatus::Error(_) => {
                    tracing::info!(target: "unyt::network", "Initialization terminal state reached. Exiting monitoring loop.");
                    break;
                }
                _ => {}
            }
        }
    });
}

async fn sync_logic(
    app_ws: AppWebsocket,
    status_manager: Arc<EnvStatusManager>,
    peer_count: usize,
) {
    // 1. Determine current sync state
    let (step, message) = if get_global_definition(&app_ws).await {
        if let Some(template_id) = get_code_templates(&app_ws).await {
            if get_smart_agreements(&app_ws, template_id).await {
                (TOTAL_UNYT_SYNC_STEPS, "Network synchronization complete.")
            } else {
                (TOTAL_UNYT_SYNC_STEPS - 1, "System templates synced. Finalizing agreements...")
            }
        } else {
            (TOTAL_UNYT_SYNC_STEPS - 2, "Global settings found. Syncing templates...")
        }
    } else {
        (TOTAL_UNYT_SYNC_STEPS - 3, format!("Connected to {peer_count} peers. Awaiting validation..."))
    };

    // 2. Update status if it has changed (to prevent log spam)
    let previous_status = status_manager.get_status();
    let new_status = if step == TOTAL_UNYT_SYNC_STEPS {
        EnvRuntimeStatus::Ready
    } else {
        EnvRuntimeStatus::Syncing {
            step,
            total_steps: TOTAL_UNYT_SYNC_STEPS,
            message: format!("({peer_count} peers) {message}"),
        }
    };

    if previous_status != new_status {
        tracing::info!(target: "unyt::network", "Sync Milestone {step}/{TOTAL_UNYT_SYNC_STEPS}: {message}");
        status_manager.update_status(new_status);
    }
}

async fn get_global_definition(app_ws: &AppWebsocket) -> bool {
    let result: Result<Value, _> = app_ws
        .call_zome(
            ZomeCallTarget::RoleName("alliance".into()),
            "transactor".into(),
            "get_current_global_definition".into(),
            ExternIO::encode(()).unwrap(),
        )
        .await
        .and_then(|io| io.decode().map_err(|e| e.into()));

    match result {
        Ok(val) => !val.is_null(),
        Err(_) => false,
    }
}

async fn get_code_templates(app_ws: &AppWebsocket) -> Option<Value> {
    let result: Result<Value, _> = app_ws
        .call_zome(
            ZomeCallTarget::RoleName("alliance".into()),
            "transactor".into(),
            "get_code_templates_lib".into(),
            ExternIO::encode(()).unwrap(),
        )
        .await
        .and_then(|io| io.decode().map_err(|e| e.into()));

    if let Ok(Value::Array(templates)) = result {
        templates
            .iter()
            .find(|t| t["title"].as_str() == Some("__system_credit_limit_computation"))
            .map(|t| t["id"].clone())
    } else {
        None
    }
}

async fn get_smart_agreements(app_ws: &AppWebsocket, template_id: Value) -> bool {
    let result: Result<Value, _> = app_ws
        .call_zome(
            ZomeCallTarget::RoleName("alliance".into()),
            "transactor".into(),
            "get_smart_agreements_for_code_template".into(),
            ExternIO::encode(template_id).unwrap(),
        )
        .await
        .and_then(|io| io.decode().map_err(|e| e.into()));

    if let Ok(Value::Array(agreements)) = result {
        !agreements.is_empty()
    } else {
        false
    }
}
