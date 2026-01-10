use crate::app_config::AppConfig;
use tauri::AppHandle;
use tauri_plugin_holochain::*;
use serde::{Deserialize, Serialize};

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct AllianceDnaProps {
    pub progenitor_pubkey: Option<AgentPubKey>,
}

/// Checks if the local agent is the progenitor of the DNA
pub async fn is_progenitor(app_handle: AppHandle) -> anyhow::Result<bool> {
    let holochain = app_handle.holochain()?;
    let admin_ws = holochain.admin_websocket().await?;
    let app_config = AppConfig::new(&app_handle);

    // Get app info to find our pub key and DNA modifiers
    let apps = admin_ws.list_apps(Some(AppStatusFilter::Enabled)).await?;
    let app = apps
        .iter()
        .find(|a| a.installed_app_id.as_str() == app_config.app_id)
        .ok_or_else(|| anyhow::anyhow!("App not found"))?;

    let my_pub_key = app.agent_pub_key.clone();

    // Look for the unyt (alliance) cell to get properties
    if let Some(cells) = app.cell_info.get("alliance") {
        for cell in cells {
            if let CellInfo::Provisioned(provisioned) = cell {
                // Use the holochain_serialized_bytes::decode function if we can bring it in,
                // or use the fact that SerializedBytes implements Serialize/Deserialize.
                // Since we are in a Tauri context and traits are acting up, we'll use a robust 
                // conversion through Value as a fallback if decode is still missing.
                let props: AllianceDnaProps = serde_json::from_value(serde_json::to_value(&provisioned.dna_modifiers.properties)?)
                    .map_err(|e| anyhow::anyhow!("Failed to decode DNA properties: {:?}", e))?;
                
                if let Some(progenitor_key) = props.progenitor_pubkey {
                    return Ok(progenitor_key == my_pub_key);
                }
            }
        }
    }

    // TEMPORARY: Default to true if no progenitor is set (dev mode)
    Ok(true)
}
