use crate::runtime::boot::holochain::{holochain_dir, network_config};
use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use secrecy::{ExposeSecret, SecretString};
use std::sync::Arc;
use tauri::{AppHandle, Manager};
use tauri_plugin_holochain::{
    launch_holochain_runtime, vec_to_locked, HolochainPlugin, HolochainPluginConfig,
};
use tracing::debug;
use zeroize::Zeroize;

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

    let passphrase = match &password {
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
            Ok(())
        }
        Err(e) => {
            let err_msg = format!("{:?}", e);
            // Detect Lair password requirements or incorrect password
            if err_msg.contains("LairError")
                || err_msg.contains("passphrase")
                || err_msg.contains("Inaccessible")
            {
                if !is_initial_setup && password.is_some() {
                    // If we provided a password and it's not initial setup, it's likely invalid
                    status_manager.update_status(EnvRuntimeStatus::LairInvalidPassword);
                    Err("Incorrect password".to_string())
                } else {
                    status_manager
                        .update_status(EnvRuntimeStatus::LairAwaitingPassword { is_initial_setup });
                    Err("Password required".to_string())
                }
            } else {
                status_manager.update_status(EnvRuntimeStatus::ConductorError(err_msg.clone()));
                Err(err_msg)
            }
        }
    }
}
