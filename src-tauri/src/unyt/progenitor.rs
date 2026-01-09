use crate::app_config::AppConfig;
use holochain_client::{AppStatusFilter, CellInfo};
use tauri::AppHandle;
use tauri_plugin_holochain::HolochainExt;
use serde::{Deserialize, Serialize};
use holochain_client::AgentPubKey;

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct AllianceDnaProps {
    pub progenitor_pubkey: Option<AgentPubKey>,
}

/// Checks if the local agent is the progenitor of the DNA
pub async fn is_progenitor(app_handle: AppHandle) -> anyhow::Result<bool> {
    let holochain = app_handle.holochain()?;
    let mut admin_ws = holochain.admin_websocket().await?;
    let app_config = AppConfig::new(&app_handle);

    // Get app info to find our pub key and DNA modifiers
    let apps = admin_ws.list_apps(Some(AppStatusFilter::Enabled)).await?;
    let app = apps
        .iter()
        .find(|a| a.installed_app_id.as_str() == app_config.app_id)
        .ok_or_else(|| anyhow::anyhow!("App not found"))?;

    let my_pub_key = app.agent_pub_key.clone();

    // Look for the alliance cell to get properties
    if let Some(cells) = app.cell_info.get("alliance") {
        for cell in cells {
            if let CellInfo::Provisioned(provisioned) = cell {
                let props: AllianceDnaProps = provisioned.dna_modifiers.properties.clone().decode()
                    .map_err(|e| anyhow::anyhow!("Failed to decode DNA properties: {:?}", e))?;
                
                if let Some(progenitor_key) = props.progenitor_pubkey {
                    return Ok(progenitor_key == my_pub_key);
                }
            }
        }
    }

    // Default to true if no progenitor is set (dev mode)
    Ok(true)
}
