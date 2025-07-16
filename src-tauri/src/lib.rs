mod menu;
use holochain_types::prelude::AppBundle;
use std::path::PathBuf;
use tauri_plugin_holochain::{vec_to_locked, HolochainExt, HolochainPluginConfig, NetworkConfig};
// use tauri_plugin_opener::OpenerExt;
use anyhow::anyhow;
#[cfg(not(mobile))]
use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
// #[cfg(all(desktop))]
// use tauri::tray::{TrayIconBuilder, TrayIconEvent};
use tauri::{AppHandle, Manager, Window};

#[derive(Clone, serde::Serialize)]
struct SplashscreenPayload {
    message: String,
}

#[cfg(not(mobile))]
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
pub mod migration;
mod tauri_config_reader;
use tauri_config_reader::AppConfig;

const APP_ID_FOR_HOLOCHAIN_DIR: &'static str = "domino-sandbox";

pub fn happ_bundle() -> AppBundle {
    let bytes = include_bytes!("../../workdir/domino.happ");
    AppBundle::decode(bytes).expect("Failed to decode domino.happ")
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(
            tauri_plugin_log::Builder::default()
                .level(if tauri::is_dev() {
                    log::LevelFilter::Info
                } else {
                    log::LevelFilter::Warn
                })
                .level_for("tracing::span", log::LevelFilter::Off)
                .level_for("iroh", log::LevelFilter::Warn)
                .level_for("holochain", log::LevelFilter::Warn)
                .level_for("kitsune2", log::LevelFilter::Warn)
                .level_for("kitsune2_gossip", log::LevelFilter::Warn)
                .level_for("holochain_runtime", log::LevelFilter::Warn)
                .level_for("domino", log::LevelFilter::Warn)
                .build(),
        )
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_holochain::init(
            vec_to_locked(vec![]),
            HolochainPluginConfig::new(holochain_dir(), network_config()),
        ))
        .setup(|app| {
            let handle = app.handle().clone();

            let splashscreen_window = tauri::window::Builder::new(
                &handle,
                "splashscreen",
                tauri::webview::Url::App("splashscreen.html".into()),
            )
            .title("Domino - Starting...")
            .inner_size(600.0, 400.0)
            .center()
            .decorations(false)
            .build()?;

            tauri::async_runtime::spawn(async move {
                if let Err(e) = setup_and_launch(handle.clone()).await {
                    handle
                        .emit_all(
                            "splashscreen-error",
                            SplashscreenPayload {
                                message: format!("Failed to launch: {}", e),
                            },
                        )
                        .unwrap();
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

async fn setup_and_launch(handle: AppHandle) -> anyhow::Result<()> {
    setup(handle.clone()).await?;

    let splashscreen_window = handle.get_window("splashscreen").unwrap();

    let mut window_builder = handle
        .holochain()?
        .main_window_builder(
            String::from("main"),
            false,
            Some(AppConfig::new(handle.clone()).app_id),
            None,
        )
        .await?;

    #[cfg(not(mobile))]
    {
        window_builder = window_builder
            .title(String::from(AppConfig::new(handle.clone()).product_name))
            .inner_size(1200.0, 800.0)
            .menu(Menu::with_items(
                &handle,
                &[
                    &Submenu::with_items(
                        &handle,
                        "File",
                        true,
                        &[
                            &MenuItem::with_id(&handle, "open-logs-folder", "Open Logs Folder", true, None::<&str>)?,
                            &PredefinedMenuItem::close_window(&handle, None)?,
                        ],
                    )?,
                    &Submenu::with_items(
                        &handle,
                        "Help",
                        true,
                        &[&MenuItem::with_id(&handle, "about", "About", true, None::<&str>)?,]
                    )?,
                ],
            )?)
            .on_menu_event(move |window, menu_event| match menu_event.id().as_ref() {
                "open-logs-folder" => {
                    let log_folder = window.app_handle().path().app_log_dir().expect("Could not get app log dir");
                    if let Err(err) = tauri_plugin_opener::reveal_item_in_dir(log_folder.clone()) {
                        log::error!("Failed to open log dir at {log_folder:?}: {err:?}");
                    }
                }
                "factory-reset" => {
                    let h = window.app_handle().clone();
                    window.app_handle().dialog()
                        .message("Are you sure you want to perform a factory reset? All your data will be lost.")
                        .title("Factory Reset")
                        .buttons(MessageDialogButtons::OkCancel)
                        .show(move |result| match result {
                            true => {
                                if let Err(err) = std::fs::remove_dir_all(holochain_dir()) {
                                    log::error!("Failed to perform factory reset: {err:?}");
                                } else {
                                    h.restart();
                                }
                            }
                            false => {
                                log::info!("Factory reset cancelled");
                            }
                        });
                }
                "about" => {
                    let h = window.app_handle().clone();
                    tauri::async_runtime::spawn(async move { menu::about_menu(&h).await });
                }
                _ => {}
            });
    }

    window_builder.build()?;

    let main_window = handle.get_window("main").unwrap();
    main_window.show()?;
    splashscreen_window.close()?;

    Ok(())
}

async fn setup(handle: AppHandle) -> anyhow::Result<()> {
    handle
        .emit_all(
            "splashscreen-log",
            SplashscreenPayload {
                message: "Starting Holochain...".into(),
            },
        )
        .unwrap();
    let admin_ws = handle.holochain()?.admin_websocket().await?;
    handle
        .emit_all(
            "splashscreen-log",
            SplashscreenPayload {
                message: "Holochain started. Checking for existing app installation...".into(),
            },
        )
        .unwrap();
    let installed_apps = admin_ws
        .list_apps(None)
        .await
        .map_err(|err| tauri_plugin_holochain::Error::ConductorApiError(err))?;
    let app_is_already_installed = installed_apps
        .iter()
        .find(|app| {
            app.installed_app_id
                .as_str()
                .eq(&AppConfig::new(handle.clone()).app_id)
        })
        .is_some();
    if !app_is_already_installed {
        handle
            .emit_all(
                "splashscreen-log",
                SplashscreenPayload {
                    message: "App not installed. Checking for prior versions to migrate...".into(),
                },
            )
            .unwrap();
        let previous_app = installed_apps
            .iter()
            .filter(|app| {
                app.installed_app_id
                    .as_str()
                    .starts_with(AppConfig::new(handle.clone()).app_id.as_str())
            })
            .min_by_key(|app_info| app_info.installed_at);
        if let Some(previous_app) = previous_app {
            handle
                .emit_all(
                    "splashscreen-log",
                    SplashscreenPayload {
                        message: format!(
                            "Found previous version to migrate: {}",
                            previous_app.installed_app_id
                        )
                        .into(),
                    },
                )
                .unwrap();
            migration::migrate_app(
                &handle.holochain()?.holochain_runtime,
                previous_app.installed_app_id.clone(),
                AppConfig::new(handle.clone()).app_id,
                happ_bundle(),
                None,
                Some(AppConfig::new(handle.clone()).network_seed),
            )
            .await?;
            handle
                .emit_all(
                    "splashscreen-log",
                    SplashscreenPayload {
                        message: "Migration successful.".into(),
                    },
                )
                .unwrap();
            admin_ws
                .disable_app(previous_app.installed_app_id.clone())
                .await
                .map_err(|err| anyhow!("{err:?}"))?;
            handle
                .emit_all(
                    "splashscreen-log",
                    SplashscreenPayload {
                        message: "Disabled previous app version.".into(),
                    },
                )
                .unwrap();
        } else {
            handle
                .emit_all(
                    "splashscreen-log",
                    SplashscreenPayload {
                        message: "No previous versions found. Installing app...".into(),
                    },
                )
                .unwrap();
            handle
                .holochain()?
                .install_app(
                    String::from(AppConfig::new(handle.clone()).app_id),
                    happ_bundle(),
                    None,
                    None,
                    Some(AppConfig::new(handle.clone()).network_seed),
                )
                .await?;
            handle
                .emit_all(
                    "splashscreen-log",
                    SplashscreenPayload {
                        message: "App installed successfully.".into(),
                    },
                )
                .unwrap();
        }
        Ok(())
    } else {
        handle
            .emit_all(
                "splashscreen-log",
                SplashscreenPayload {
                    message: "App already installed. Checking for updates...".into(),
                },
            )
            .unwrap();
        handle
            .holochain()?
            .update_app_if_necessary(
                String::from(AppConfig::new(handle.clone()).app_id),
                happ_bundle(),
            )
            .await?;
        handle
            .emit_all(
                "splashscreen-log",
                SplashscreenPayload {
                    message: "Update check finished. Launching app.".into(),
                },
            )
            .unwrap();
        Ok(())
    }
}

fn network_config() -> NetworkConfig {
    if tauri::is_dev() {
        NetworkConfig::network_type(url2::Url::parse("kitsune-quic://0.0.0.0:55255").unwrap())
    } else {
        NetworkConfig::default()
    }
}

fn holochain_dir() -> PathBuf {
    if tauri::is_dev() {
        if let Ok(path) = std::env::var("DOMINO_HOLOCHAIN_DIR") {
            path.into()
        } else {
            let tmp_dir = tempdir::TempDir::new("domino-holochain")
                .expect("Could not create temporary directory");

            // Convert `tmp_dir` into a `Path`, destroying the `TempDir`
            // without deleting the directory.
            let tmp_path = tmp_dir.into_path();
            tmp_path
        }
    } else {
        app_dirs2::app_root(
            app_dirs2::AppDataType::UserData,
            &app_dirs2::AppInfo {
                name: APP_ID_FOR_HOLOCHAIN_DIR,
                author: std::env!("CARGO_PKG_AUTHORS"),
            },
        )
        .expect("Could not get app root")
        .join("holochain")
    }
}
