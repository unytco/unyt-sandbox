use crate::app_config::AppConfig;
use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use crate::utils::holochain::{
    // dna_hash_for_app_bundle_role,
    happ_bundle,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_holochain::{
    AgentPubKey, AppStatusFilter, DnaModifiersOpt, HolochainExt, RoleSettings, RoleSettingsMap,
    YamlProperties,
};
use tokio::sync::Mutex;
use tracing::{error, info, warn};

/// Persistent state shared across the joining flow.
pub struct JoiningState {
    pub agent_key: Option<AgentPubKey>,
}

impl JoiningState {
    pub fn new() -> Self {
        Self { agent_key: None }
    }
}

pub type SharedJoiningState = Arc<Mutex<JoiningState>>;

pub fn init(app_handle: &AppHandle) {
    app_handle.manage(Arc::new(Mutex::new(JoiningState::new())));
}

// ---------------------------------------------------------------------------
// Tauri Commands
// ---------------------------------------------------------------------------

#[derive(Serialize)]
pub struct GenerateAgentKeyResult {
    pub agent_key: String,
}

/// Generate a new agent keypair via the conductor's Lair keystore.
/// Returns the base64-encoded `AgentPubKey` to the frontend.
#[tauri::command]
pub async fn generate_agent_key(app_handle: AppHandle) -> Result<GenerateAgentKeyResult, String> {
    let holochain = app_handle.holochain().map_err(|e| format!("{e:?}"))?;
    let admin_ws = holochain
        .admin_websocket()
        .await
        .map_err(|e| format!("{e:?}"))?;

    let agent_pub_key = admin_ws
        .generate_agent_pub_key()
        .await
        .map_err(|e| format!("Failed to generate agent key: {e:?}"))?;

    let b64 = format!("{}", agent_pub_key);

    let joining_state = app_handle.state::<SharedJoiningState>();
    {
        let mut state = joining_state.lock().await;
        state.agent_key = Some(agent_pub_key);
    }

    info!("[joining] Generated agent key: {}…", &b64[..20]);
    Ok(GenerateAgentKeyResult { agent_key: b64 })
}

/// Return the joining service URL so the frontend knows where to send HTTP
/// requests. Returns `null` when no joining service is configured.
#[tauri::command]
pub fn get_joining_config(app_handle: AppHandle) -> Option<JoiningConfig> {
    let app_config = AppConfig::new(&app_handle);
    app_config.joining_service_url.map(|url| JoiningConfig {
        url,
        app_id: app_config.app_id,
    })
}

#[derive(Serialize)]
pub struct JoiningConfig {
    pub url: String,
    pub app_id: String,
}

/// Input from the frontend after the joining flow completes.
#[derive(Deserialize)]
pub struct InstallWithProofsInput {
    /// Base64-encoded membrane proofs keyed by DnaHash (base64).
    pub membrane_proofs: HashMap<String, String>,
    /// Optional network seed from the joining service `/provision` response.
    pub network_seed: Option<String>,
    /// Optional DNA properties from the joining service `/provision` response.
    /// When present and containing `joining_server_signer`, these are forwarded
    /// to the DNA modifiers during installation.
    pub properties: Option<serde_json::Value>,
}

/// Install the hApp using the previously-generated agent key and the
/// membrane proofs received from the joining service.
#[tauri::command]
pub async fn install_with_proofs(
    app_handle: AppHandle,
    input: InstallWithProofsInput,
) -> Result<(), String> {
    let state_manager = app_handle.state::<Arc<EnvStatusManager>>();
    state_manager.update_status(EnvRuntimeStatus::AppInstalling);

    let joining_state = app_handle.state::<SharedJoiningState>();
    let agent_pub_key = {
        let state = joining_state.lock().await;
        state
            .agent_key
            .clone()
            .ok_or_else(|| "No agent key generated yet".to_string())?
    };

    let agent_key_b64 = format!("{}", agent_pub_key);

    let result = do_install(&app_handle, input, agent_pub_key).await;

    if let Err(ref err_msg) = result {
        error!("[joining] Installation failed: {}", err_msg);
        let app_config = AppConfig::new(&app_handle);
        let joining_service_url = app_config.joining_service_url.unwrap_or_default();
        info!(
            "[joining] Reverting status to NetworkSetupRequired for agent {}…",
            &agent_key_b64[..20]
        );
        state_manager.update_status(EnvRuntimeStatus::NetworkSetupRequired {
            agent_key: agent_key_b64,
            joining_service_url,
        });
    }

    result
}

async fn do_install(
    app_handle: &AppHandle,
    input: InstallWithProofsInput,
    agent_pub_key: AgentPubKey,
) -> Result<(), String> {
    let app_config = AppConfig::new(app_handle);
    let bundle = happ_bundle();

    info!(
        "[joining] Starting install for app_id={}, agent={}…",
        app_config.app_id,
        &format!("{}", agent_pub_key)[..20]
    );
    info!(
        "[joining] Received {} membrane proof key(s): {:?}",
        input.membrane_proofs.len(),
        input.membrane_proofs.keys().collect::<Vec<_>>()
    );
    for (hash, proof) in &input.membrane_proofs {
        info!(
            "[joining]   proof for {}: {} bytes (base64 len={})",
            hash,
            proof.len() * 3 / 4,
            proof.len()
        );
    }

    let network_seed = input
        .network_seed
        .unwrap_or_else(|| app_config.network_seed.clone());
    info!("[joining] Using network_seed: {}", network_seed);

    info!("[joining] Properties payload: {:?}", input.properties);
    let yaml_properties: Option<YamlProperties> = input.properties.and_then(|props| {
        if props.get("joining_server_signer").is_some() {
            let yaml_val = serde_yaml::to_value(&props).ok()?;
            info!("[joining] Forwarding joining_server_signer from provision properties");
            Some(YamlProperties::new(yaml_val))
        } else if let Ok(signer) = std::env::var("JOINING_SERVER_SIGNER") {
            // check for env variable joining_server_signer
            let mut new_props = props.clone();
            new_props["joining_server_signer"] = Value::String(signer);
            let yaml_val = serde_yaml::to_value(&props).ok()?;
            info!("[joining] Forwarding joining_server_signer from environment variable");
            Some(YamlProperties::new(yaml_val))
        } else {
            warn!("[joining] Properties present but no joining_server_signer found");
            None
        }
    });

    let mut roles_settings: RoleSettingsMap = RoleSettingsMap::new();

    for role in bundle.manifest().app_roles() {
        // let hash_modifiers: DnaModifiersOpt = DnaModifiersOpt {
        //     network_seed: Some(network_seed.clone()),
        //     ..Default::default()
        // };
        // let dna_hash = dna_hash_for_app_bundle_role(&bundle, &role.name, Some(hash_modifiers))
        //     .await
        //     .map_err(|e| format!("Failed to compute DNA hash for role {}: {e:?}", role.name))?;
        // let hash_b64 = dna_hash.as_ref().map(|h| format!("{}", h));
        // info!(
        //     "[joining] Role '{}' -> DnaHash: {}",
        //     role.name,
        //     hash_b64.as_deref().unwrap_or("None")
        // );
        // WARNING: This is a hack to be able to install without knowing the DNA hash
        let proof = input.membrane_proofs.get(&role.name);

        if proof.is_some() {
            info!("[joining]   Membrane proof FOUND for role '{}'", role.name);
        } else {
            warn!("[joining]   No membrane proof for role '{}'", role.name);
        }

        let membrane_proof = match proof {
            Some(b64_proof) => {
                use base64::Engine;
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(&b64_proof)
                    .map_err(|e| format!("Invalid base64 membrane proof: {e}"))?;
                info!(
                    "[joining]   Decoded membrane proof for '{}': {} bytes",
                    role.name,
                    bytes.len()
                );
                Some(Arc::new(tauri_plugin_holochain::SerializedBytes::from(
                    tauri_plugin_holochain::UnsafeBytes::from(bytes),
                )))
            }
            None => None,
        };

        roles_settings.insert(
            role.name.clone(),
            RoleSettings::Provisioned {
                membrane_proof,
                modifiers: Some(DnaModifiersOpt::<YamlProperties> {
                    network_seed: Some(network_seed.clone()),
                    properties: yaml_properties.clone(),
                }),
            },
        );
    }

    info!("[joining] Calling install_app for '{}'…", app_config.app_id);
    let holochain = app_handle.holochain().map_err(|e| format!("{e:?}"))?;
    if let Err(e) = holochain
        .install_app(
            app_config.app_id.clone(),
            bundle,
            Some(roles_settings),
            Some(agent_pub_key),
            None,
        )
        .await
    {
        let err_str = format!("{e:?}");
        if err_str.contains("AppAlreadyInstalled") {
            info!("[joining] App already installed, skipping install");
            return Ok(());
        }
        return Err(format!("Failed to install app: {e:?}"));
    }

    info!(
        "[joining] App installed successfully: {}",
        app_config.app_id
    );
    Ok(())
}

/// Reset the joining state so a fresh retry can be attempted.
/// Generates a new agent key and re-emits `JoiningRequired` so the frontend
/// can restart the KYC flow from scratch.
#[tauri::command]
pub async fn reset_joining_state(app_handle: AppHandle) -> Result<GenerateAgentKeyResult, String> {
    let joining_state = app_handle.state::<SharedJoiningState>();
    {
        let mut state = joining_state.lock().await;
        state.agent_key = None;
    }

    let result = generate_agent_key(app_handle.clone()).await?;

    let app_config = AppConfig::new(&app_handle);
    let state_manager = app_handle.state::<Arc<EnvStatusManager>>();
    state_manager.update_status(EnvRuntimeStatus::JoiningRequired {
        agent_key: result.agent_key.clone(),
        joining_service_url: app_config.joining_service_url.unwrap_or_default(),
    });

    info!(
        "[joining] State reset, new agent key: {}…",
        &result.agent_key[..20]
    );
    Ok(result)
}

/// Serializable cell entry for the frontend dashboard.
/// Hashes are encoded as base64 strings (same format the JS client uses via `Display`).
#[derive(Serialize)]
pub struct AppCellEntry {
    pub cell_type: String,
    pub dna_hash: String,
    pub agent_pub_key: String,
    pub name: String,
    pub network_seed: String,
    pub clone_id: Option<String>,
    pub enabled: bool,
    pub properties: Option<String>,
}

/// Response from list_app_cells containing the cells under the "alliance" role.
#[derive(Serialize)]
pub struct ListAppCellsResponse {
    pub installed: bool,
    pub cells: Vec<AppCellEntry>,
}

/// Return the installed app's cell info via the admin websocket.
/// The frontend uses this to reliably list all provisioned and cloned cells
/// (networks) even when the AppWebsocket connection isn't fully established yet.
#[tauri::command]
pub async fn list_app_cells(app_handle: AppHandle) -> Result<ListAppCellsResponse, String> {
    let holochain = app_handle.holochain().map_err(|e| format!("{e:?}"))?;
    let admin_ws = holochain
        .admin_websocket()
        .await
        .map_err(|e| format!("{e:?}"))?;
    let app_config = AppConfig::new(&app_handle);

    let apps = admin_ws
        .list_apps(Some(AppStatusFilter::Enabled))
        .await
        .map_err(|e| format!("{e:?}"))?;

    let app_info = match apps
        .into_iter()
        .find(|a| a.installed_app_id == app_config.app_id)
    {
        Some(info) => info,
        None => {
            return Ok(ListAppCellsResponse {
                installed: false,
                cells: vec![],
            });
        }
    };

    let role_cells = app_info.cell_info.get("alliance");
    let mut entries = Vec::new();

    if let Some(cells) = role_cells {
        for cell in cells {
            match cell {
                tauri_plugin_holochain::CellInfo::Provisioned(p) => {
                    entries.push(AppCellEntry {
                        cell_type: "provisioned".into(),
                        dna_hash: format!("{}", p.cell_id.dna_hash()),
                        agent_pub_key: format!("{}", p.cell_id.agent_pubkey()),
                        name: p.name.clone(),
                        network_seed: p.dna_modifiers.network_seed.clone(),
                        clone_id: None,
                        enabled: true,
                        properties: serde_json::to_string(&p.dna_modifiers.properties).ok(),
                    });
                }
                tauri_plugin_holochain::CellInfo::Cloned(c) => {
                    entries.push(AppCellEntry {
                        cell_type: "cloned".into(),
                        dna_hash: format!("{}", c.cell_id.dna_hash()),
                        agent_pub_key: format!("{}", c.cell_id.agent_pubkey()),
                        name: c.name.clone(),
                        network_seed: c.dna_modifiers.network_seed.clone(),
                        clone_id: Some(format!("{}", c.clone_id)),
                        enabled: c.enabled,
                        properties: serde_json::to_string(&c.dna_modifiers.properties).ok(),
                    });
                }
                _ => {}
            }
        }
    }

    Ok(ListAppCellsResponse {
        installed: true,
        cells: entries,
    })
}

/// Finalize setup after the app has been installed via the joining flow.
/// This mirrors the tail end of `utils::tauri::setup()`: ensures the app
/// websocket is ready and emits `backend-ready`.
#[tauri::command]
pub async fn complete_joining_setup(app_handle: AppHandle) -> Result<(), String> {
    let state_manager = app_handle.state::<Arc<EnvStatusManager>>();
    let app_config = AppConfig::new(&app_handle);
    let holochain = app_handle.holochain().map_err(|e| format!("{e:?}"))?;

    state_manager.update_status(EnvRuntimeStatus::Syncing {
        step: 3,
        total_steps: 8,
        message: String::from("Authorizing lair connection..."),
    });

    let _app_ws = holochain
        .app_websocket(app_config.app_id.clone())
        .await
        .map_err(|e| format!("Failed to get app websocket: {e:?}"))?;

    let port = {
        let auths = holochain
            .holochain_runtime
            .apps_websockets_auths
            .lock()
            .await;
        auths
            .iter()
            .find(|auth| auth.app_id.eq(&app_config.app_id))
            .map(|auth| auth.app_websocket_port)
            .ok_or_else(|| "App websocket port not found after install".to_string())?
    };

    info!(
        "[joining] App authorized on port {} for {}",
        port, app_config.app_id
    );

    state_manager.update_status(EnvRuntimeStatus::Syncing {
        step: 3,
        total_steps: 8,
        message: String::from("Finalizing system initialization..."),
    });

    let _ = app_handle.emit("backend-ready", port);
    state_manager.update_status(EnvRuntimeStatus::Ready);

    crate::utils::holochain::spawn_heartbeat(app_handle);

    Ok(())
}
