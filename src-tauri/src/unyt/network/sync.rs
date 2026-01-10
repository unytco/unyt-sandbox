use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use tauri_plugin_holochain::*;
use serde_json::Value;
use std::sync::Arc;

pub const TOTAL_UNYT_SYNC_STEPS: u8 = 3;

pub async fn handle_network_sync(
    app_ws: AppWebsocket,
    status_manager: Arc<EnvStatusManager>,
    peer_count: usize,
) {
    // 1. Determine current sync state
    let (step, message) = determine_sync_step(&app_ws, peer_count).await;

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

async fn determine_sync_step(app_ws: &AppWebsocket, peer_count: usize) -> (u8, String) {
    // Milestone 1: Global Settings (ZF, Credit Limits)
    if !get_global_definition(app_ws).await {
        return (0, format!("Connected to {peer_count} peers. Awaiting validation..."));
    }
    // Milestone 2: System Templates
    let template_id = match get_code_templates(app_ws).await {
        Some(id) => id,
        None => return (1, "Global settings found. Syncing templates...".to_string()),
    };
    // Milestone 3: Active Ledger Agreements
    if get_smart_agreements(app_ws, template_id).await {
        (3, "Network synchronization complete.".to_string())
    } else {
        (2, "System templates synced. Finalizing agreements...".to_string())
    }
}

async fn get_global_definition(app_ws: &AppWebsocket) -> bool {
    let result: std::result::Result<Value, anyhow::Error> = app_ws
        .call_zome(
            ZomeCallTarget::RoleName("alliance".into()),
            "transactor".into(),
            "get_current_global_definition".into(),
            ExternIO::encode(()).unwrap(),
        )
        .await
        .map_err(|e| anyhow::anyhow!("Zome call failed: {:?}", e))
        .and_then(|io| {
            io.decode()
                .map_err(|e| anyhow::anyhow!("Decode failed: {:?}", e))
        });

    match result {
        Ok(val) => !val.is_null(),
        Err(_) => false,
    }
}

async fn get_code_templates(app_ws: &AppWebsocket) -> Option<Value> {
    let result: std::result::Result<Value, anyhow::Error> = app_ws
        .call_zome(
            ZomeCallTarget::RoleName("alliance".into()),
            "transactor".into(),
            "get_code_templates_lib".into(),
            ExternIO::encode(()).unwrap(),
        )
        .await
        .map_err(|e| anyhow::anyhow!("Zome call failed: {:?}", e))
        .and_then(|io| {
            io.decode()
                .map_err(|e| anyhow::anyhow!("Decode failed: {:?}", e))
        });

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
    let result: std::result::Result<Value, anyhow::Error> = app_ws
        .call_zome(
            ZomeCallTarget::RoleName("alliance".into()),
            "transactor".into(),
            "get_smart_agreements_for_code_template".into(),
            ExternIO::encode(template_id).unwrap(),
        )
        .await
        .map_err(|e| anyhow::anyhow!("Zome call failed: {:?}", e))
        .and_then(|io| {
            io.decode()
                .map_err(|e| anyhow::anyhow!("Decode failed: {:?}", e))
        });

    if let Ok(Value::Array(agreements)) = result {
        !agreements.is_empty()
    } else {
        false
    }
}
