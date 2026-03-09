mod app_config;
mod consts;
mod joining;
mod runtime;
mod utils;

pub use app_config::{get_version, AppConfig, KEYCHAIN_SALT_USER};
pub use consts::{APP_ID_PREFIX, IDENTIFIER_DIR};
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
    tracing::debug!(target: "unyt", "Starting Tauri application");
    // check for UNYT_WASM_LOG and set it to debug if it is not set
    if let Ok(wasm_log) = std::env::var("UNYT_WASM_LOG") {
        std::env::set_var("WASM_LOG", wasm_log);
    } else {
        std::env::set_var("WASM_LOG", "debug");
    }
    tracing::debug!(target: "unyt", "Building Tauri application with plugins");

    let mut builder = tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![
            runtime::events::get_runtime_status,
            runtime::events::update_runtime_status,
            runtime::events::get_app_port,
            runtime::boot::progenitor::is_authorized_progenitor,
            runtime::events::close_splashscreen,
            runtime::events::show_logs,
            runtime::boot::lair::unlock_lair,
            joining::generate_agent_key,
            joining::get_joining_config,
            joining::install_with_proofs,
            joining::complete_joining_setup,
            joining::reset_joining_state,
            joining::list_app_cells,
        ]);

    tracing::debug!(target: "unyt", "Added logging plugin and runtime commands");

    builder = builder
        // .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_notification::init());
    tracing::debug!(target: "unyt", "Added notification plugin");

    builder = builder.plugin(tauri_plugin_process::init());
    tracing::debug!(target: "unyt", "Added process plugin");

    builder = builder.plugin(tauri_plugin_dialog::init());
    tracing::debug!(target: "unyt", "Added dialog plugin");

    builder = builder.plugin(tauri_plugin_http::init());
    tracing::debug!(target: "unyt", "Added HTTP plugin");

    builder = builder.plugin(tauri_plugin_shell::init());
    tracing::debug!(target: "unyt", "Added shell plugin");

    builder = builder.on_window_event(|window, event| {
        if let tauri::WindowEvent::CloseRequested { .. } = event {
            if window.label() == "main" {
                tracing::info!(target: "unyt", "Main window closed, exiting application");
                window.app_handle().exit(0);
            }
        }
    });

    // Secure lair keystore with argon2
    builder = builder.plugin(
        tauri_plugin_stronghold::Builder::new(|password| {
            use argon2::{
                password_hash::{PasswordHasher, SaltString},
                Argon2,
            };
            use keyring::Entry;
            use rand::rngs::OsRng;

            // OS-Level Secret Management (Keychain/Secret Service)
            // We store a unique salt per-installation in the OS Keychain.
            // This ensures that even if the app data folder is stolen, the salt
            // required to crack the password remains in the OS-protected store.
            let service = IDENTIFIER_DIR;
            let username = KEYCHAIN_SALT_USER;

            let salt_str = (|| {
                let entry = Entry::new(service, username).ok()?;
                if let Ok(s) = entry.get_password() {
                    return Some(s);
                }

                // If not in keychain, prioritize the environment variable (for testing/CI)
                // then fallback to generating a new random salt.
                let s = std::env::var("TAURI_LAIR_SALT").ok().unwrap_or_else(|| {
                    tracing::info!(target: "unyt", "Generating new unique salt for Lair keystore");
                    SaltString::generate(&mut OsRng).to_string()
                });

                // Try to save the salt to the keychain for future use
                if let Err(e) = entry.set_password(&s) {
                    tracing::warn!(target: "unyt", "Failed to persist salt to OS Keychain: {}", e);
                }
                Some(s)
            })()
            .unwrap_or_else(|| {
                // Fallback for environments without a Keychain or Env Var (e.g. headless Linux servers)
                // TODO: Disucss options for this final fallback case...
                tracing::warn!(target: "unyt", "Keychain unavailable, using default fallback salt");
                "u76ByY463Y0vO58yD5S6Vw".to_string()
            });

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
    tracing::debug!(target: "unyt", "Enabled native-backed argon2 password hashing for lair keystore");

    builder = builder.plugin(tauri_plugin_holochain::plugin_builder().build());
    info!("Added holochain plugin");

    builder = builder.setup(move |app| {
        // Initialize logs and status
        runtime::init(app.handle())?;
        joining::init(app.handle());
        tracing::debug!(target: "unyt", "Tauri setup initialized");

        let handle = app.handle().clone();

        #[cfg(mobile)]
        {
            tracing::debug!(target: "unyt", "Mobile platform detected, adding mobile-specific plugins");
            app.handle().plugin(tauri_plugin_barcode_scanner::init())?;
            tracing::debug!(target: "unyt", "Added barcode scanner plugin");
            app.handle()
                .plugin(tauri_plugin_safe_area_insets_css::init())?;
            tracing::debug!(target: "unyt", "Added safe area insets CSS plugin");
        }

        #[cfg(not(mobile))]
        {
            tracing::debug!(target: "unyt", "Desktop platform detected, adding desktop-specific plugins");

            let agent_id = std::env::var("AGENT_ID").unwrap_or_else(|_| "".into());
            if agent_id.is_empty() {
                app.handle()
                    .plugin(tauri_plugin_single_instance::init(move |app, _argv, _cwd| {
                        info!("Second instance detected, focusing main window");
                        if let Some(main) = app.get_webview_window("main") {
                            let _ = main.set_focus();
                        } else if let Some(splash) = app.get_webview_window("splashscreen") {
                            let _ = splash.set_focus();
                        }
                    }))?;
            } else {
                tracing::debug!(target: "unyt", "AGENT_ID set, skipping single_instance plugin to allow multiple instances");
            }

            app.handle()
                .plugin(tauri_plugin_updater::Builder::new().build())?;
            tracing::debug!(target: "unyt", "Added updater plugin");
        }

        // Track if setup has been triggered (to prevent multiple setup attempts)
        let setup_triggered = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));

        let setup_triggered_clone = setup_triggered.clone();
        let handle_clone = handle.clone();
        app.handle()
            .listen("runtime://status-update", move |event| {
                let status: EnvRuntimeStatus = match serde_json::from_str(event.payload()) {
                    Ok(s) => s,
                    Err(_) => return,
                };

                tracing::debug!(target: "unyt", "Received runtime status update: {:?}", status);

                // Only trigger setup if Lair is ready and we haven't already done so
                if status == EnvRuntimeStatus::LairReady
                    && !setup_triggered_clone.swap(true, std::sync::atomic::Ordering::SeqCst)
                {
                    info!("Lair is ready, triggering application setup (first time)");
                    let window_handle = handle_clone.clone();
                    tauri::async_runtime::spawn(async move {
                        info!("Starting setup process");
                        if let Err(err) = utils::tauri::setup(window_handle.clone()).await {
                            println!("[ERROR] Failed to setup: {err:?}");
                            let error_msg = format!("Failed to setup: {err:?}");
                            error!("{error_msg}");

                            let state_manager = window_handle.state::<Arc<EnvStatusManager>>();
                            state_manager
                                .update_status(EnvRuntimeStatus::AppInstallationError(error_msg));
                            return;
                        }
                        info!("Setup completed successfully");

                        // Check if setup returned because joining or network setup is required.
                        // In that case we still need to open the window so the
                        // frontend can show the joining wizard or network dashboard,
                        // but we skip treating it as fully "ready".
                        let state_manager = window_handle.state::<Arc<EnvStatusManager>>();
                        let is_joining = matches!(
                            state_manager.get_status(),
                            EnvRuntimeStatus::JoiningRequired { .. }
                                | EnvRuntimeStatus::NetworkSetupRequired { .. }
                        );

                        // Open window ONLY after setup (installation/update) is successful
                        tracing::debug!(target: "unyt", "Opening unyt app (the main) window");
                        if let Err(err) = utils::tauri::open_window(window_handle.clone()).await {
                            println!("[ERROR] Failed to open window: {err:?}");
                            let error_msg = format!("Failed to open main window: {err:?}");
                            error!("{error_msg}");

                            let state_manager = window_handle.state::<Arc<EnvStatusManager>>();
                            state_manager.update_status(EnvRuntimeStatus::Error(error_msg));
                        } else {
                            tracing::debug!(target: "unyt", "Main window opened successfully");
                            if is_joining {
                                info!("Window opened for joining/network-setup flow — closing splashscreen");
                                if let Some(splashscreen) = window_handle.get_webview_window("splashscreen") {
                                    let _ = splashscreen.close();
                                }
                            }
                        }
                    });
                }
            });

        // Now that listener is registered, trigger initial unlock attempt
        let handle_for_unlock = handle.clone();
        tauri::async_runtime::spawn(async move {
            // Initial attempt to unlock lair with no password...
            // If this attempt fails, the UI will eventually call `unlock_lair` again with a password.
            // Upon success, the `LairReady` status update will trigger the remaining setup.
            if let Err(e) = runtime::boot::lair::unlock_lair(handle_for_unlock.clone(), None).await {
                info!("Lair is locked or awaiting initial password: {}", e);
            }
        });

        // Proactive check: If we are already in LairReady state, trigger setup..
        let state_manager = handle.state::<Arc<EnvStatusManager>>();
        if state_manager.get_status() == EnvRuntimeStatus::LairReady 
            && !setup_triggered.swap(true, std::sync::atomic::Ordering::SeqCst) 
        {
            info!("Proactive check: Lair is already ready, triggering application setup");
            let window_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(err) = utils::tauri::setup(window_handle.clone()).await {
                    println!("[ERROR] Failed to setup: {err:?}");
                }
            });
        }

        tracing::debug!(target: "unyt", "Tauri application setup completed");
        Ok(())
    });

    #[cfg(not(mobile))]
    {
        tracing::debug!(target: "unyt", "Adding desktop menu");
        builder = builder.menu(|handle| menu::build_menu(handle));
        tracing::debug!(target: "unyt", "Desktop menu added");
    }

    tracing::debug!(target: "unyt", "Starting Tauri application run loop");
    builder
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|_app_handle, event| {
            if let tauri::RunEvent::ExitRequested { .. } = event {
                std::process::exit(0);
            }
        });
}
