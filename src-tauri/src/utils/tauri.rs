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
        .main_window_builder(String::from("main"), true, Some(app_config.app_id.clone()), None)
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
    let holochain = handle.holochain()?;
    let admin_ws = holochain.admin_websocket().await?;
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
        // .map_err(|err| tauri_plugin_holochain::Error::ConductorApiError(err))?;
        .map_err(|err| anyhow!("{err:?}"))?;
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
        }

        let mut roles_settings: RoleSettingsMap = RoleSettingsMap::new();
        roles_settings.insert(
            String::from("alliance"),
            RoleSettings::Provisioned {
                membrane_proof: None,
                modifiers: Some(DnaModifiersOpt {
                    network_seed: Some(app_config.network_seed.clone()),
                    ..Default::default()
                }),
            },
        );

        if let Some(previous_app) = previous_app {
            println!(
                "[unyt_tauri] setup: Migrating from previous app: {}",
                previous_app.installed_app_id
            );
            migrate_app(
                &holochain.holochain_runtime,
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
            holochain
                .install_app(
                    app_config.app_id.clone(),
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
        holochain
            .update_app_if_necessary(app_config.app_id.clone(), happ_bundle())
            .await?;
        info!("setup: App update check completed");
    }

    // Now that the app is installed/updated, we MUST ensure it's enabled and authorized.
    // We use the plugin's `app_websocket` method which handles:
    // 1. Finding or creating an app interface.
    // 2. Ensuring the app is enabled.
    // 3. Authenticating (generating/storing the token).
    // This will populate the plugin's internal `apps_websockets_auths` state.
    println!("[unyt_tauri] setup: Ensuring app websocket is ready for app_id: {}...", app_config.app_id);
    let app_ws = holochain.app_websocket(app_config.app_id.clone()).await
        .map_err(|err| anyhow!("Failed to get app websocket: {:?}", err))?;
    
    // We can get the port directly from the app_ws.
    // In holochain_client 0.5+, we might need to use get_port() if it exists or similar.
    // If not, we can now safely look it up in the plugin's auths because app_websocket() just populated it.
    let port = {
        let auths = holochain.holochain_runtime.apps_websockets_auths.lock().await;
        auths.iter()
            .find(|auth| auth.app_id.eq(&app_config.app_id))
            .map(|auth| auth.app_websocket_port)
            .ok_or_else(|| anyhow!("App websocket was created but no port found in auths list. This should not happen."))?
    };

    println!("[unyt_tauri] setup: Successfully authorized app on port {} for app_id {}", port, app_config.app_id);
    
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

