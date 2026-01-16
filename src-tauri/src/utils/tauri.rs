use crate::app_config::{AppConfig, APP_ID_PREFIX};
use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};
use crate::utils::holochain::{happ_bundle, migrate_app};
use anyhow::anyhow;
use log::debug;
use std::sync::Arc;
use tauri::{AppHandle, Emitter, Manager, WebviewWindow};
use tauri_plugin_holochain::{
    AppStatusFilter, DnaModifiersOpt, HolochainExt, RoleSettings, RoleSettingsMap,
};
use tracing::info;

pub async fn open_window(handle: AppHandle) -> anyhow::Result<WebviewWindow> {
    debug!("open_window: Creating main window");
    let app_config = AppConfig::new(&handle);
    println!(
        "[unyt_tauri] open_window: App config created with app_id: {}",
        app_config.app_id
    );

    let mut window_builder = handle
        .holochain()?
        .main_window_builder(String::from("main"), true, Some(app_config.app_id), None)
        .await?;
    debug!("open_window: Window builder created");

    #[cfg(not(mobile))]
    {
        debug!("open_window: Configuring desktop window properties");
        window_builder = window_builder
            .title(app_config.product_name)
            .inner_size(1400.0, 1000.0);
        println!(
            "[unyt_tauri] open_window: Desktop window configured with title 'Unyt' and size 1400x1000"
        );
    }

    debug!("open_window: Building window");
    let window = window_builder.build()?;

    // TODO: KEEP?
    window.hide()?; // Ensure it stays hidden until explicitly shown by close_splashscreen

    debug!("open_window: Window built successfully");
    Ok(window)
}

//
// Very simple setup for now:
// - On app start, check whether the app is already installed:
//   - If it's not installed, install it
//   - If it's installed, check if it's necessary to update the coordinators for our hApp,
//     and do so if it is
//
// You can modify this function to suit your needs if they become more complex
pub async fn setup(handle: AppHandle) -> anyhow::Result<()> {
    let state_manager = handle.state::<Arc<EnvStatusManager>>();
    state_manager.update_status(EnvRuntimeStatus::ConductorStarting);

    println!("[unyt_tauri] setup: Starting application setup");
    let admin_ws = handle.holochain()?.admin_websocket().await?;
    println!("[unyt_tauri] setup: Connected to admin websocket");
    state_manager.update_status(EnvRuntimeStatus::AppInstalling);

    let app_config = AppConfig::new(&handle);
    println!(
        "[unyt_tauri] setup: App config created with app_id: {}",
        app_config.app_id
    );

    let installed_apps = admin_ws
        .list_apps(Some(AppStatusFilter::Enabled))
        .await
        .map_err(|err| tauri_plugin_holochain::Error::ConductorApiError(err))?;
    println!(
        "[unyt_tauri] setup: Found {} installed apps",
        installed_apps.len()
    );

    let app_is_already_installed = installed_apps
        .iter()
        .find(|app| app.installed_app_id.as_str().eq(&app_config.app_id))
        .is_some();
    println!(
        "[unyt_tauri] setup: App already installed: {}",
        app_is_already_installed
    );

    if !app_is_already_installed {
        debug!("setup: App not installed, checking for previous versions");
        let previous_app = installed_apps
            .iter()
            .filter(|app| app.installed_app_id.as_str().starts_with(APP_ID_PREFIX))
            .min_by_key(|app_info| app_info.installed_at);

        if let Some(prev_app) = &previous_app {
            println!(
                "[unyt_tauri] setup: Found previous app version: {}",
                prev_app.installed_app_id
            );
        } else {
            debug!("setup: No previous app versions found");
        }

        let mut roles_settings: RoleSettingsMap = RoleSettingsMap::new();
        println!(
            "[unyt_tauri] setup: Creating role settings for alliance with network_seed: {:?}",
            app_config.network_seed
        );
        roles_settings.insert(
            String::from("alliance"),
            RoleSettings::Provisioned {
                membrane_proof: None,
                modifiers: Some(DnaModifiersOpt {
                    network_seed: Some(app_config.network_seed),
                    ..Default::default()
                }),
            },
        );
        info!("setup: Role settings configured");

        if let Some(previous_app) = previous_app {
            println!(
                "[unyt_tauri] setup: Migrating from previous app: {}",
                previous_app.installed_app_id
            );
            migrate_app(
                &handle.holochain()?.holochain_runtime,
                previous_app.installed_app_id.clone(),
                app_config.app_id.clone(),
                happ_bundle(),
                Some(roles_settings),
            )
            .await?;
            info!("setup: App migration completed");

            println!(
                "[unyt_tauri] setup: Disabling previous app: {}",
                previous_app.installed_app_id
            );
            admin_ws
                .disable_app(previous_app.installed_app_id.clone())
                .await
                .map_err(|err| anyhow!("{err:?}"))?;
            debug!("setup: Previous app disabled");
        } else {
            println!(
                "[unyt_tauri] setup: Installing new app: {}",
                app_config.app_id
            );
            handle
                .holochain()?
                .install_app(
                    String::from(app_config.app_id),
                    happ_bundle(),
                    Some(roles_settings),
                    None,
                    None,
                )
                .await?;
            info!("setup: New app installed successfully");
        }
        info!("setup: Fresh installation completed");
    } else {
        info!("setup: App already installed, checking for updates");
        handle
            .holochain()?
            .update_app_if_necessary(String::from(app_config.app_id), happ_bundle())
            .await?;
        info!("setup: App update check completed");
    }
    
    println!("[unyt_tauri] setup: Waiting for app websocket port...");
    
    // Give the conductor a moment to fully initialize listeners
    tokio::time::sleep(std::time::Duration::from_secs(1)).await;

    // IMPORTANT: In a multi-app scenario, we should filter these auths to find the one matching our app_id.
    // Since we currently only have one primary app, taking the first available port is sufficient.
    let port = handle
        .holochain()?
        .holochain_runtime
        .apps_websockets_auths
        .lock()
        .await
        .first()
        .map(|auth| auth.app_websocket_port)
        .ok_or(anyhow!("No app websocket port found"))?;
    
    println!("[unyt_tauri] setup: Emitting backend-ready on port {}", port);
    let _ = handle.emit("backend-ready", port);

    // Set status to Ready - Backend initialization is complete.
    // Handing over to Unyt App to manage peer discovery and global def sync.
    if let Some(status_manager) = handle.try_state::<Arc<EnvStatusManager>>() {
        tracing::info!(target: "unyt::network", "System backend initialization complete. Handing over to Unyt App.");
        status_manager.update_status(EnvRuntimeStatus::Ready);
    }

    crate::utils::holochain::spawn_heartbeat(handle);

    Ok(())
}
