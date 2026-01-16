mod app_config;
mod consts;
mod runtime;
mod utils;

pub use app_config::{get_version, AppConfig, APP_ID_PREFIX, IDENTIFIER_DIR};
pub use utils::holochain::migrate_app;

use crate::runtime::status::{EnvRuntimeStatus, EnvStatusManager};

use std::sync::Arc;
use tauri::{Listener, Manager};
use tracing::{error, info};

#[cfg(not(mobile))]
mod menu;
// todo:
// #[cfg(mobile)]
// mod push_notifications;

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

    let mut builder = tauri::Builder::default()
        // .plugin(runtime::logs::init_legacy_logger())
        .invoke_handler(tauri::generate_handler![
            runtime::events::get_runtime_status,
            runtime::events::update_runtime_status,
            runtime::events::get_app_port,
            runtime::boot::progenitor::is_authorized_progenitor,
            runtime::boot::progenitor::accept_progenitor_role,
            runtime::events::close_splashscreen,
            runtime::events::show_logs,
            runtime::boot::lair::unlock_lair
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

    // Secure lair keystore with argon2
    builder = builder.plugin(
        tauri_plugin_stronghold::Builder::new(|password| {
            use argon2::{
                password_hash::{PasswordHasher, SaltString},
                Argon2,
            };

            // NB: use the environment variable for the salt (TAURI_LAIR_SALT),
            // the default should be used as testing fallback only...
            let salt_str = std::env::var("TAURI_LAIR_SALT")
                .unwrap_or_else(|_| "u76ByY463Y0vO58yD5S6Vw".to_string());

            let salt = SaltString::from_b64(&salt_str).expect("invalid salt");
            Argon2::default()
                .hash_password(password.as_bytes(), &salt)
                .expect("failed to hash password")
                .hash
                .expect("failed to get hash bytes")
                .as_bytes()
                .to_vec()
        })
        .build(),
    );
    debug!("Enabled argon2-based password hashing for lair keystore");

    builder = builder.plugin(tauri_plugin_holochain::plugin_builder().build());
    info!("Added holochain plugin");

    builder = builder.setup(move |app| {
        runtime::init(app.handle())?;
        debug!("Setting up Tauri application");

        let handle = app.handle().clone();
        tauri::async_runtime::spawn(async move {
            // Initial attempt to unlock lair with no password...
            // If this attempt fails, the UI will eventually call `unlock_lair`` again with a password.
            // Upon success, the `LairReady` status update will trigger the remaining setup.
            if let Err(e) = runtime::boot::lair::unlock_lair(handle.clone(), None).await {
                info!("Lair is locked or awaiting initial password: {}", e);
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
        let setup_triggered = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));

        app.handle()
            .listen("runtime://status-update", move |event| {
                let status: EnvRuntimeStatus = match serde_json::from_str(event.payload()) {
                    Ok(s) => s,
                    Err(_) => return,
                };

                if status == EnvRuntimeStatus::LairReady
                    && !setup_triggered.swap(true, std::sync::atomic::Ordering::SeqCst)
                {
                    info!("Lair is ready, triggering application setup");
                    let tauri_window_handle = handle.clone();
                    tauri::async_runtime::spawn(async move {
                        info!("Starting setup process");
                        if let Err(err) = utils::tauri::setup(tauri_window_handle.clone()).await {
                            println!("[ERROR] Failed to setup: {err:?}");
                            let error_msg = format!("Failed to setup: {err:?}");
                            error!("{error_msg}");

                            let state_manager = tauri_window_handle.state::<Arc<EnvStatusManager>>();
                            state_manager
                                .update_status(EnvRuntimeStatus::AppInstallationError(error_msg));
                            return;
                        }
                        info!("Setup completed successfully");
                    });

                    let unyt_window_handle = handle.clone();
                    tauri::async_runtime::spawn(async move {
                        debug!("Opening unyt app (the main) window");
                        if let Err(err) = utils::tauri::open_window(unyt_window_handle.clone()).await {
                            println!("[ERROR] Failed to open window: {err:?}");
                            let error_msg = format!("Failed to setup: {err:?}");
                            error!("{error_msg}");

                            let state_manager = unyt_window_handle.state::<Arc<EnvStatusManager>>();
                            state_manager.update_status(EnvRuntimeStatus::Error(error_msg));
                        } else {
                            debug!("Main window opened successfully");
                        }
                    });
                }
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
