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
use tauri::{AppHandle, Manager, WebviewWindow, WebviewWindowBuilder};

#[cfg(not(mobile))]
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
mod tauri_config_reader;
mod utils;
use tauri_config_reader::AppConfig;

const APP_ID_FOR_HOLOCHAIN_DIR: &'static str = "domino-sandbox";

// const DNA_HASH: &'static str = "domino-dna_hashes";
// const DNA_HASH: &'static str = include_str!("../../workdir/dash-chat-dna_hashes");

pub fn happ_bundle() -> AppBundle {
    let bytes = include_bytes!("../../workdir/domino.happ");
    AppBundle::decode(bytes).expect(&"Failed to decode domino.happ")
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // std::env::set_var("WASM_LOG", "debug");
    // Get the config from the generated context

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
            vec_to_locked(vec![]), // TODO: path to add password on startup
            HolochainPluginConfig::new(holochain_dir(), network_config())
        ))
        .setup(|app| {
            let handle = app.handle().clone();
            
            // Create and show splash screen
            let splash_window = match create_splash_window(&handle) {
                Ok(window) => {
                    log::info!("Splash screen created successfully");
                    if let Err(e) = window.show() {
                        log::error!("Failed to show splash screen: {:?}", e);
                    }
                    Some(window)
                }
                Err(e) => {
                    log::error!("Failed to create splash screen: {:?}", e);
                    None
                }
            };
            
            let result: anyhow::Result<()> = tauri::async_runtime::block_on(async move {
                setup(handle.clone()).await?;

                // After set up we can be sure our app is installed and up to date, so we can just open it
                let mut window_builder = app.holochain()?
                .main_window_builder(String::from("main"), false, Some(AppConfig::new(handle.clone()).app_id), None)
                .await?;
               #[cfg(not(mobile))]
                {
                    window_builder = window_builder
                        .title(String::from(AppConfig::new(handle.clone()).product_name))
                        .inner_size(1200.0, 800.0)
                        .menu(
                            Menu::with_items(
                                &handle,
                                &[
                                    &Submenu::with_items(
                                        &handle,
                                        "File",
                                        true,
                                        &[
                                            &MenuItem::with_id(
                                               & handle,
                                                "open-logs-folder",
                                                "Open Logs Folder",
                                                true,
                                                None::<&str>,
                                            )?,
                                            // &MenuItem::with_id(
                                            //    & handle,
                                            //     "factory-reset",
                                            //     "Factory Reset",
                                            //     true,
                                            //     None::<&str>,
                                            // )?,
                                            &PredefinedMenuItem::close_window(&handle, None)?,
                                        ],
                                    )?,
                                    &Submenu::with_items(
                                        &handle,
                                        "Help",
                                        true,
                                        &[&MenuItem::with_id(
                                            &handle,
                                            "about",
                                            "About",
                                            true,
                                            None::<&str>,
                                        )?],
                                    )?,
                                ],
                            )?
                        )
                        .on_menu_event(move |window, menu_event| match menu_event.id().as_ref() {
                            "open-logs-folder" => {
                                let log_folder = window.app_handle()
                                    .path()
                                    .app_log_dir()
                                    .expect("Could not get app log dir");
                                if let Err(err) = tauri_plugin_opener::reveal_item_in_dir(log_folder.clone()) {
                                    log::error!("Failed to open log dir at {log_folder:?}: {err:?}");
                                }
                            }
                            "factory-reset" => {
                                let h = window.app_handle().clone();
                                window.app_handle()
                                        .dialog()
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
                                tauri::async_runtime::spawn(async move {
                                    menu::about_menu(&h).await
                                });
                            }
                            _ => {}
                        });
                }

                let main_window = window_builder.build()?;

                // Show main window first
                main_window.show()?;
                log::info!("Main window created and shown successfully");
                
                // Close splash screen after a brief delay to ensure smooth transition
                let handle_clone = handle.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(tokio::time::Duration::from_millis(1500)).await;
                    if let Some(splash_window) = handle_clone.get_webview_window("splash") {
                        log::info!("Closing splash screen");
                        let _ = splash_window.close();
                    }
                });

                // // Setup system tray
                // #[cfg(all(desktop))]
                // setup_tray(&handle)?;

                Ok(())
            });

            result?;

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

// Very simple setup for now:
// - On app start, check whether the app is already installed:
//   - If it's not installed, install it
//   - If it's installed, check if it's necessary to update the coordinators for our hApp,
//     and do so if it is
//
// You can modify this function to suit your needs if they become more complex
async fn setup(handle: AppHandle) -> anyhow::Result<()> {
    let admin_ws = handle.holochain()?.admin_websocket().await?;
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
        let previous_app = installed_apps
            .iter()
            .filter(|app| {
                app.installed_app_id
                    .as_str()
                    .starts_with(AppConfig::new(handle.clone()).app_id.as_str())
            })
            .min_by_key(|app_info| app_info.installed_at);

        if let Some(previous_app) = previous_app {
            utils::migrate_app(
                &handle.holochain()?.holochain_runtime,
                previous_app.installed_app_id.clone(),
                AppConfig::new(handle.clone()).app_id,
                happ_bundle(),
                None,
                Some(AppConfig::new(handle.clone()).network_seed),
            )
            .await?;

            admin_ws
                .disable_app(previous_app.installed_app_id.clone())
                .await
                .map_err(|err| anyhow!("{err:?}"))?;
        } else {
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
        }

        Ok(())
    } else {
        handle
            .holochain()?
            .update_app_if_necessary(
                String::from(AppConfig::new(handle.clone()).app_id),
                happ_bundle(),
            )
            .await?;

        Ok(())
    }
}

// #[cfg(all(desktop))]
// fn setup_tray(app: &AppHandle) -> tauri::Result<()> {
//     let tray_menu = Menu::with_items(
//         app,
//         &[
//             &MenuItem::with_id(app, "show", "Show", true, None::<&str>)?,
//             &MenuItem::with_id(app, "hide", "Hide", true, None::<&str>)?,
//             &PredefinedMenuItem::separator(app)?,
//             &MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?,
//         ],
//     )?;

//     let _tray = TrayIconBuilder::new()
//         .icon(app.default_window_icon().unwrap().clone())
//         .menu(&tray_menu)
//         .menu_on_left_click(false)
//         .tooltip("Domino")
//         .on_menu_event(move |app, event| match event.id().as_ref() {
//             "show" => {
//                 if let Some(window) = app.get_webview_window("main") {
//                     let _ = window.show();
//                     let _ = window.set_focus();
//                 }
//             }
//             "hide" => {
//                 if let Some(window) = app.get_webview_window("main") {
//                     let _ = window.hide();
//                 }
//             }
//             "quit" => {
//                 app.exit(0);
//             }
//             _ => {}
//         })
//         .on_tray_icon_event(|tray, event| match event {
//             TrayIconEvent::Click {
//                 button: tauri::tray::MouseButton::Left,
//                 button_state: tauri::tray::MouseButtonState::Up,
//                 ..
//             } => {
//                 let app = tray.app_handle();
//                 if let Some(window) = app.get_webview_window("main") {
//                     let _ = if window.is_visible().unwrap_or(false) {
//                         window.hide()
//                     } else {
//                         window.show();
//                         window.set_focus()
//                     };
//                 }
//             }
//             _ => {}
//         })
//         .build(app)?;

//     Ok(())
// }

fn network_config() -> NetworkConfig {
    let mut network_config = NetworkConfig::default();

    // Don't use the bootstrap service on tauri dev mode
    if tauri::is_dev() {
        network_config.bootstrap_url = url2::Url2::parse("http://0.0.0.0:8888");
    } else {
        network_config.bootstrap_url =
            url2::Url2::parse("https://dev-test-bootstrap2.holochain.org/");
    }

    // Don't hold any slice of the DHT in mobile
    if cfg!(mobile) {
        network_config.target_arc_factor = 0;
    }

    network_config
}

fn holochain_dir() -> PathBuf {
    if tauri::is_dev() {
        #[cfg(target_os = "android")]
        {
            app_dirs2::app_root(
                app_dirs2::AppDataType::UserCache,
                &app_dirs2::AppInfo {
                    name: "domino",
                    author: std::env!("CARGO_PKG_AUTHORS"),
                },
            )
            .expect("Could not get the UserCache directory")
        }
        #[cfg(not(target_os = "android"))]
        {
            let tmp_dir = tempdir::TempDir::new(APP_ID_FOR_HOLOCHAIN_DIR)
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

fn create_splash_window(handle: &AppHandle) -> tauri::Result<WebviewWindow> {
    // Try to create splash window with custom HTML file
    let splash_result = WebviewWindowBuilder::new(handle, "splash", tauri::WebviewUrl::App("splash.html".into()))
        .title("Domino")
        .inner_size(400.0, 300.0)
        .resizable(false)
        .decorations(false)
        .center()
        .always_on_top(true)
        .build();
    
    match splash_result {
        Ok(window) => {
            log::info!("Splash screen with custom HTML created successfully");
            Ok(window)
        }
        Err(e) => {
            log::warn!("Failed to create splash with custom HTML: {:?}, creating simple splash", e);
            // Fallback: create a simple splash with inline content
            WebviewWindowBuilder::new(handle, "splash", tauri::WebviewUrl::App("about:blank".into()))
                .title("Domino - Loading...")
                .inner_size(400.0, 300.0)
                .resizable(false)
                .decorations(false)
                .center()
                .always_on_top(true)
                .build()
        }
    }
}
