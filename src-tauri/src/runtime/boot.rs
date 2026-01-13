use crate::app_config::{get_version, AppConfig, IDENTIFIER_DIR};
use crate::holochain_consts;
use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use log::debug;
use serde::{Deserialize, Serialize};
use secrecy::{ExposeSecret, SecretString};
use zeroize::Zeroize;
use std::path::PathBuf;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_holochain::{
    launch_holochain_runtime, vec_to_locked, AgentPubKey, AppStatusFilter, CellInfo, HolochainExt,
    HolochainPlugin, HolochainPluginConfig, NetworkConfig, ReportConfig,
};

#[derive(Debug, Default, Serialize, Deserialize, Clone)]
pub struct AllianceDnaProps {
    pub progenitor_pubkey: Option<AgentPubKey>,
}

// This function determines the holochain directory path based on the development mode and the app version
// Returns the path to the holochain directory
// (Relocated from mod.rs to boot.rs to avoid circular dependencies)
pub fn holochain_dir() -> PathBuf {
    debug!("holochain_dir: Determining holochain directory path");
    let use_persistent_dev = std::env::var("UNYT_PERSISTENT_DEV").is_ok();

    if tauri::is_dev() && cfg!(not(mobile)) && !use_persistent_dev {
        println!(
            "[unyt_tauri] holochain_dir: Development mode on desktop, creating temporary directory"
        );
        let tmp_dir =
            tempdir::TempDir::new(IDENTIFIER_DIR).expect("Could not create temporary directory");
        println!(
            "[unyt_tauri] holochain_dir: Temporary directory created: {:?}",
            tmp_dir.path()
        );

        // Convert `tmp_dir` into a `Path` (this destroys the `TempDir` without deleting the directory)
        let tmp_path = tmp_dir.into_path();
        println!(
            "[unyt_tauri] holochain_dir: Using temporary path: {:?}",
            tmp_path
        );
        tmp_path
    } else {
        debug!("holochain_dir: Production mode, using app data directory for persisted storage");
        let version = get_version();
        debug!("holochain_dir: App version: {}", version);

        let app_root = app_dirs2::app_root(
            app_dirs2::AppDataType::UserData,
            &app_dirs2::AppInfo {
                name: IDENTIFIER_DIR,
                author: std::env!("CARGO_PKG_AUTHORS"),
            },
        )
        .expect("Could not get app root");
        debug!("holochain_dir: App root: {:?}", app_root);

        let holochain_path = app_root.join(version).join("holochain");
        println!(
            "[unyt_tauri] holochain_dir: Final holochain path: {:?}",
            holochain_path
        );
        holochain_path
    }
}

// This function creates the network configuration for the holochain runtime
// Returns the network configuration
// (Relocated from mod.rs to boot.rs to avoid circular dependencies)
pub fn network_config() -> NetworkConfig {
    debug!("network_config: Creating network configuration");
    let mut network_config = NetworkConfig::default();

    network_config.bootstrap_url = url2::Url2::parse("https://dev-test-bootstrap2.holochain.org/");
    println!(
        "[unyt_tauri] network_config: Bootstrap URL set to: {:?}",
        network_config.bootstrap_url
    );

    network_config.webrtc_config = Some(serde_json::json!({
        "iceServers": [
            { "urls": ["stun:stun.cloudflare.com:3478", "stun:stun.l.google.com:19302"]}
        ]
    }));

    // enable reporting
    network_config.report = ReportConfig::JsonLines {
        days_retained: 30,
        fetched_op_interval_s: 60,
    };

    // network_config.advanced = Some(serde_json::json!({
    //     "tx5Transport": {
    //         "timeoutS": 30, // defaults to 60
    //     }
    // }));

    // Configure arc factor: only set to 0 for zero arc mode, otherwise use Holochain default
    println!(
        "[unyt_tauri] network_config: HOLOCHAIN_ARC_FACTOR: {:?}",
        holochain_consts::HOLOCHAIN_ARC_FACTOR
    );
    match holochain_consts::HOLOCHAIN_ARC_FACTOR {
        "0" => {
            debug!("network_config: Zero arc mode enabled (HOLOCHAIN_ARC_FACTOR=0)");
            network_config.target_arc_factor = 0;
        }
        "" => {
            println!(
                "[unyt_tauri] network_config: HOLOCHAIN_ARC_FACTOR='' - using Holochain default arc factor"
            );
            // Don't set target_arc_factor, let Holochain use its default
        }
        val => {
            if let Ok(arc_factor) = val.parse::<u32>() {
                println!(
                    "[unyt_tauri] network_config: HOLOCHAIN_ARC_FACTOR='{}' - using custom arc factor",
                    arc_factor
                );
                network_config.target_arc_factor = arc_factor;
            } else {
                println!(
                    "[unyt_tauri] network_config: HOLOCHAIN_ARC_FACTOR='{}' - using Holochain default arc factor",
                    val
                );
            }
        }
    }

    network_config
}

#[tauri::command]
pub async fn unlock_lair(
    app_handle: AppHandle,
    password: Option<SecretString>,
) -> std::result::Result<(), String> {
    let status_manager = app_handle.state::<Arc<EnvStatusManager>>();

    let holochain_dir = holochain_dir();
    let is_initial_setup = !holochain_dir.exists() || !holochain_dir.join("keystore").exists();

    // Trigger password prompt ONLY on initial setup if no password/bypass is provided.
    // Otherwise, fall through to attempt unlock (initial empty-pass attempt happens on subsequent runs).
    if is_initial_setup && password.is_none() && std::env::var("UNYT_BYPASS_PASSWORD").is_err() {
        debug!("unlock_lair: Initial setup detected, triggering password prompt. Note: Use UNYT_BYPASS_PASSWORD to skip.");
        status_manager.update_status(EnvRuntimeStatus::LairAwaitingPassword { is_initial_setup });
        return Err("Password required (initial setup)".to_string());
    }

    let passphrase = match password {
        Some(p) => {
            let mut bytes = p.expose_secret().as_bytes().to_vec();
            let locked = vec_to_locked(bytes.clone());
            bytes.zeroize();
            locked
        }
        None => vec_to_locked(vec![]),
    };

    let network_config = network_config();
    let config = HolochainPluginConfig::new(holochain_dir, network_config).enable_mdns_discovery();
    tracing::info!(target: "unyt::runtime", "Added holochain plugin with MDNS discovery enabled");

    match launch_holochain_runtime(passphrase, config).await {
        Ok(holochain_runtime) => {
            let p = HolochainPlugin {
                app_handle: app_handle.clone(),
                holochain_runtime,
            };
            app_handle.manage(p);
            status_manager.update_status(EnvRuntimeStatus::LairReady);
            let _ = app_handle.emit("holochain://setup-completed", ());
            Ok(())
        }
        Err(e) => {
            let err_msg = format!("{:?}", e);
            // Detect Lair password requirements or incorrect password
            if err_msg.contains("LairError")
                || err_msg.contains("passphrase")
                || err_msg.contains("Inaccessible")
            {
                status_manager.update_status(EnvRuntimeStatus::LairAwaitingPassword {
                    is_initial_setup,
                });
                Err("Password required or incorrect".to_string())
            } else {
                status_manager.update_status(EnvRuntimeStatus::Error(err_msg.clone()));
                Err(err_msg)
            }
        }
    }
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
                let props: AllianceDnaProps = serde_json::from_value(
                    serde_json::to_value(&provisioned.dna_modifiers.properties)
                        .map_err(|e| e.to_string())?,
                )
                .map_err(|e| format!("Failed to decode DNA properties: {:?}", e))?;

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

#[tauri::command]
pub fn accept_progenitor_role(status_manager: tauri::State<'_, Arc<EnvStatusManager>>) {
    tracing::info!(target: "unyt::runtime", "User accepted progenitor role.");
    status_manager.update_status(EnvRuntimeStatus::Ready);
}
