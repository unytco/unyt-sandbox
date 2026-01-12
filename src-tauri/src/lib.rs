mod app_config;
mod holochain_consts;
mod runtime;
mod utils;
use anyhow::anyhow;
pub use app_config::{get_version, AppConfig, APP_ID_PREFIX, IDENTIFIER_DIR};
use std::sync::Arc;
use tauri::{AppHandle, Listener, Manager, WebviewWindow};
use tauri_plugin_holochain::{
    AppBundle, AppStatusFilter, DnaModifiersOpt, HolochainExt, RoleSettings, RoleSettingsMap,
};
pub use utils::migrate_app;

#[cfg(not(mobile))]
mod menu;
// todo:
// #[cfg(mobile)]
// mod push_notifications;

macro_rules! debug {
    ($($arg:tt)*) => {
        println!("[unyt]: {}", format!($($arg)*));
    };
}

pub fn happ_bundle() -> AppBundle {
    debug!("Loading happ bundle from workdir/unyt.happ");
    let bytes = include_bytes!("../../unyt/workdir/unyt.happ");
    debug!("Happ bundle bytes loaded, size: {} bytes", bytes.len());
    let bundle = AppBundle::unpack(&bytes[..]).expect("Failed to decode unyt happ");
    debug!("Happ bundle decoded successfully");
    bundle
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    debug!("Starting Tauri application");
    // check for UNYT_WASM_LOG and set it to debug if it is not set
    if let Ok(wasm_log) = std::env::var("UNYT_WASM_LOG") {
        std::env::set_var("WASM_LOG", wasm_log);
    } else {
        std::env::set_var("WASM_LOG", "debug");
    }
    debug!("Building Tauri application with plugins");

    let mut builder = tauri::Builder::default().invoke_handler(tauri::generate_handler![
        runtime::get_runtime_status,
        runtime::update_runtime_status,
        runtime::boot::is_authorized_progenitor,
        runtime::boot::accept_progenitor_role,
        runtime::close_splashscreen,
        runtime::show_logs,
        runtime::boot::unlock_lair
    ]);
    debug!("Added logging plugin and runtime commands");

    builder = builder
        // .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_notification::init());
    debug!("Added notification plugin");

    builder = builder.plugin(tauri_plugin_process::init());
    debug!("Added process plugin");

    builder = builder.plugin(tauri_plugin_dialog::init());
    debug!("Added dialog plugin");

    builder = builder.plugin(tauri_plugin_http::init());
    debug!("Added HTTP plugin");

    builder = builder.plugin(tauri_plugin_holochain::plugin_builder().build());
    debug!("Added holochain plugin (manual launch mode)");

    builder = builder.setup(move |app| {
        runtime::init(app.handle())?;
        debug!("Setting up Tauri application");

        let handle = app.handle().clone();
        tauri::async_runtime::spawn(async move {
            // Initial attempt to unlock lair with no password...
            // If this attempt fails, the UI will eventually call `unlock_lair`` again with a password.
            // Upon success, the `holochain://setup-completed`` listener below will trigger the remaining setup.
            if let Err(e) = runtime::boot::unlock_lair(handle.clone(), None).await {
                debug!("Lair is locked or awaiting initial password: {}", e);
            }
        });

        #[cfg(mobile)]
        {
            debug!("Mobile platform detected, adding mobile-specific plugins");
            app.handle().plugin(tauri_plugin_barcode_scanner::init())?;
            debug!("Added barcode scanner plugin");
            app.handle()
                .plugin(tauri_plugin_safe_area_insets_css::init())?;
            debug!("Added safe area insets CSS plugin");
        }
        #[cfg(not(mobile))]
        {
            debug!("Desktop platform detected, adding desktop-specific plugins");
            // let h = app.handle();
            // app.handle()
            //     .plugin(tauri_plugin_single_instance::init(move |app, argv, cwd| {
            //         // h.emit(
            //         //     "single-instance",
            //         //     Payload { args: argv, cwd },
            //         // )
            //         // .unwrap();
            //     }))?;

            app.handle()
                .plugin(tauri_plugin_updater::Builder::new().build())?;
            debug!("Added updater plugin");
        }
        let handle = app.handle().clone();
        debug!("Setting up holochain setup-completed event listener");

        app.handle()
            .listen("holochain://setup-completed", move |_event| {
                debug!("Received holochain://setup-completed event");
                let handle2 = handle.clone();
                tauri::async_runtime::spawn(async move {
                    debug!("Starting setup process");
                    if let Err(err) = setup(handle2.clone()).await {
                        let error_msg = format!("Failed to setup: {err:?}");
                        println!("[ERROR] {error_msg}");
                        log::error!("{error_msg}");

                        let state_manager = handle2.state::<Arc<EnvStatusManager>>();
                        state_manager.update_status(EnvRuntimeStatus::Error(error_msg));
                        return;
                    }
                    debug!("Setup completed successfully");

                    // todo
                    // #[cfg(mobile)]
                    // if let Err(err) =
                    //     push_notifications::setup_push_notifications(handle2.clone())
                    // {
                    //     log::error!("Failed to setup push notifications: {err:?}");
                    // }
                });
                let handle = handle.clone();
                tauri::async_runtime::spawn(async move {
                    debug!("Opening main window");
                    if let Err(err) = open_window(handle.clone()).await {
                        let error_msg = format!("Failed to open window: {err:?}");
                        println!("[ERROR] {error_msg}");
                        log::error!("{error_msg}");

                        let state_manager = handle.state::<Arc<EnvStatusManager>>();
                        state_manager.update_status(EnvRuntimeStatus::Error(error_msg));
                    } else {
                        debug!("Main window opened successfully");
                    }
                });
            });

        debug!("Tauri application setup completed");
        Ok(())
    });

    #[cfg(not(mobile))]
    {
        debug!("Adding desktop menu");
        builder = builder.menu(|handle| menu::build_menu(handle));
        debug!("Desktop menu added");
    }

    debug!("Starting Tauri application run loop");
    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
    debug!("Tauri application has exited");
}

async fn open_window(handle: AppHandle) -> anyhow::Result<WebviewWindow> {
    debug!("open_window: Creating main window");
    let app_config = app_config::AppConfig::new(&handle);
    println!(
        "[unyt_tauri] open_window: App config created with app_id: {}",
        app_config.app_id
    );

    let mut window_builder = handle
        .holochain()?
        .main_window_builder(String::from("main"), false, Some(app_config.app_id), None)
        .await?;
    debug!("open_window: Window builder created");

    #[cfg(not(mobile))]
    {
        debug!("open_window: Configuring desktop window properties");
        window_builder = window_builder
            .title(app_config.product_name)
            .inner_size(1400.0, 1000.0)
            .transparent(false);
        println!(
            "[unyt_tauri] open_window: Desktop window configured with title 'Unyt' and size 1400x1000"
        );
    }

    debug!("open_window: Building window");
    let window = window_builder.build()?;
    window.hide()?; // Ensure it stays hidden until explicitly shown by close_splashscreen
    debug!("open_window: Window built successfully and hidden");
    Ok(window)
}

// Very simple setup for now:
// - On app start, check whether the app is already installed:
//   - If it's not installed, install it
//   - If it's installed, check if it's necessary to update the coordinators for our hApp,
//     and do so if it is
//
use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};

async fn setup(handle: AppHandle) -> anyhow::Result<()> {
    let state_manager = handle.state::<Arc<EnvStatusManager>>();
    state_manager.update_status(EnvRuntimeStatus::ConductorStarting);

    debug!("setup: Starting application setup");
    let admin_ws = handle.holochain()?.admin_websocket().await?;
    state_manager.update_status(EnvRuntimeStatus::AppInstalling);
    debug!("setup: Connected to admin websocket");

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
        debug!("setup: Role settings configured");

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
            debug!("setup: App migration completed");

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
            debug!("setup: New app installed successfully");
        }
        debug!("setup: Fresh installation completed");
    } else {
        debug!("setup: App already installed, checking for updates");
        handle
            .holochain()?
            .update_app_if_necessary(String::from(app_config.app_id), happ_bundle())
            .await?;
        debug!("setup: App update check completed");
    }

    // Set status to Ready - Backend initialization is complete.
    // Handing over to Unyt App to manage peer discovery and global def sync.
    if let Some(status_manager) = handle.try_state::<Arc<runtime::status::EnvStatusManager>>() {
        tracing::info!(target: "unyt::network", "System backend initialization complete. Handing over to Unyt App.");
        status_manager.update_status(runtime::status::EnvRuntimeStatus::Ready);
    }

    Ok(())
}
