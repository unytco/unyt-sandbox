use crate::app_config::AppConfig;
use serde::{Deserialize, Serialize};
use tauri::AppHandle;
use tauri_plugin_holochain::{AgentPubKey, AppStatusFilter, CellInfo, HolochainExt};

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct AllianceDnaProps {
    pub progenitor_pubkey: Option<AgentPubKey>,
    pub notary_agents: Option<Vec<AgentPubKey>>,
}

#[tauri::command]
pub async fn is_authorized_progenitor(app_handle: AppHandle) -> std::result::Result<bool, String> {
    let holochain = app_handle.holochain().map_err(|e| format!("{:?}", e))?;
    let admin_ws = holochain
        .admin_websocket()
        .await
        .map_err(|e| format!("{:?}", e))?;
    let app_config = AppConfig::new(&app_handle);

    // Get app info to find our pubkey and DNA modifiers
    let apps = admin_ws
        .list_apps(Some(AppStatusFilter::Enabled))
        .await
        .map_err(|e| format!("{:?}", e))?;
    let app = apps
        .iter()
        .find(|a| a.installed_app_id.as_str() == app_config.app_id)
        .ok_or_else(|| "App not found".to_string())?;

    let my_pub_key = app.agent_pub_key.clone();

    // Look for the unyt (alliance) cell to get properties
    if let Some(cells) = app.cell_info.get("alliance") {
        for cell in cells {
            if let CellInfo::Provisioned(provisioned) = cell {
                let props_value = serde_json::to_value(&provisioned.dna_modifiers.properties)
                    .map_err(|e| e.to_string())?;

                let props: AllianceDnaProps = if props_value.is_null() {
                    AllianceDnaProps::default()
                } else {
                    serde_json::from_value(props_value)
                        .map_err(|e| format!("Failed to decode DNA properties: {:?}", e))?
                };

                if let Some(progenitor_key) = props.progenitor_pubkey {
                    let is_match = progenitor_key == my_pub_key;
                    tracing::info!(target: "unyt::progenitor", "Progenitor check: DNA={} Me={} Match={}", progenitor_key, my_pub_key, is_match);
                    return Ok(is_match);
                } else {
                    tracing::info!(target: "unyt::progenitor", "No progenitor_pubkey found in DNA properties. Current agent is the default Progenitor.");
                    return Ok(true);
                }
            }
        }
    }

    Ok(false)
}
