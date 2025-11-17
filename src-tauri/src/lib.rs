mod app_config;
mod generated_arc_factor;
mod utils;
use anyhow::anyhow;
pub use app_config::{get_version, AppConfig, APP_ID_PREFIX, IDENTIFIER_DIR};
use std::path::PathBuf;
use tauri::{AppHandle, Listener, WebviewWindow};
use tauri_plugin_holochain::{
    vec_to_locked, AppBundle, AppStatusFilter, DnaModifiersOpt, HolochainExt,
    HolochainPluginConfig, NetworkConfig, ReportConfig, RoleSettings, RoleSettingsMap,
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
    let bytes = include_bytes!("../../workdir/unyt.happ");
    debug!("Happ bundle bytes loaded, size: {} bytes", bytes.len());
    let bundle = AppBundle::unpack(&bytes[..]).expect("Failed to decode unyt happ");
    debug!("Happ bundle decoded successfully");
    bundle
}

fn parse_log_level(level: &str) -> Option<log::LevelFilter> {
    match level.to_lowercase().as_str() {
        "off" => Some(log::LevelFilter::Off),
        "error" => Some(log::LevelFilter::Error),
        "warn" => Some(log::LevelFilter::Warn),
        "info" => Some(log::LevelFilter::Info),
        "debug" => Some(log::LevelFilter::Debug),
        "trace" => Some(log::LevelFilter::Trace),
        _ => None,
    }
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

    // Setup logging with environment variable support
    let mut log_builder = tauri_plugin_log::Builder::default();

    // Set general log level (default: Warn)
    let general_level = std::env::var("UNYT_LOG_LEVEL")
        .ok()
        .and_then(|level| parse_log_level(&level))
        .unwrap_or(log::LevelFilter::Warn);
    log_builder = log_builder.level(general_level);
    debug!("General log level set to: {:?}", general_level);

    // Default module-specific log levels
    log_builder = log_builder
        .level_for("tracing::span", log::LevelFilter::Off)
        .level_for("iroh", log::LevelFilter::Warn)
        .level_for("holochain", log::LevelFilter::Info)
        .level_for("kitsune2", log::LevelFilter::Info)
        .level_for("kitsune2_gossip", log::LevelFilter::Info)
        .level_for("kitsune2_api", log::LevelFilter::Debug)
        .level_for("holochain_runtime", log::LevelFilter::Info)
        .level_for("unyt", log::LevelFilter::Debug);

    // Override with specific log levels from environment variable
    if let Ok(specific_logs) = std::env::var("UNYT_SPECIFIC_LOG") {
        debug!("Applying specific log levels: {}", specific_logs);

        // Parse and collect module-level pairs first
        let log_configs: Vec<(String, log::LevelFilter)> = specific_logs
            .split(',')
            .filter_map(|entry| {
                let entry = entry.trim();
                entry.split_once('=').and_then(|(module, level_str)| {
                    let module = module.trim().to_string();
                    let level_str = level_str.trim();
                    parse_log_level(level_str).map(|level| (module, level))
                })
            })
            .collect();

        // Apply the collected configurations
        for (module, level) in log_configs {
            debug!("Set log level for '{}' to {:?}", module, level);
            log_builder = log_builder.level_for(module, level);
        }
    }

    let mut builder = tauri::Builder::default().plugin(log_builder.build());
    debug!("Added logging plugin");

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

    let holochain_dir = holochain_dir();
    let network_config = network_config();
    debug!("Holochain directory: {:?}", holochain_dir);
    println!(
        "[unyt_tauri] Network config bootstrap URL: {:?}",
        network_config.bootstrap_url
    );

    builder = builder.plugin(tauri_plugin_holochain::async_init(
        vec_to_locked(vec![]),
        HolochainPluginConfig::new(holochain_dir, network_config),
    ));
    debug!("Added holochain plugin with MDNS discovery enabled");

    builder = builder.setup(move |app| {
        debug!("Setting up Tauri application");
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
                        println!("[ERROR] Failed to setup: {err:?}");
                        log::error!("Failed to setup: {err:?}");
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
                        println!("[ERROR] Failed to open window: {err:?}");
                        log::error!("Failed to setup: {err:?}");
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
    debug!("open_window: Window built successfully");
    Ok(window)
}

// Very simple setup for now:
// - On app start, check whether the app is already installed:
//   - If it's not installed, install it
//   - If it's installed, check if it's necessary to update the coordinators for our hApp,
//     and do so if it is
//
// You can modify this function to suit your needs if they become more complex
async fn setup(handle: AppHandle) -> anyhow::Result<()> {
    debug!("setup: Starting application setup");
    let admin_ws = handle.holochain()?.admin_websocket().await?;
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
        Ok(())
    } else {
        debug!("setup: App already installed, checking for updates");
        handle
            .holochain()?
            .update_app_if_necessary(String::from(app_config.app_id), happ_bundle())
            .await?;
        debug!("setup: App update check completed");

        Ok(())
    }
}

fn network_config() -> NetworkConfig {
    debug!("network_config: Creating network configuration");
    let mut network_config = NetworkConfig::default();

    // Don't use the bootstrap service on tauri dev mode
    // if tauri::is_dev() {
    //     network_config.bootstrap_url = url2::Url2::parse("http://0.0.0.0:8888");
    // } else {
    //     network_config.bootstrap_url =
    //         url2::Url2::parse("https://bootstrap.kitsune-v0-1.kitsune.darksoil-studio.garnix.me");
    // }
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
        generated_arc_factor::HOLOCHAIN_ARC_FACTOR
    );
    match generated_arc_factor::HOLOCHAIN_ARC_FACTOR {
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
            println!(
                "[unyt_tauri] network_config: HOLOCHAIN_ARC_FACTOR='{}' - using Holochain default arc factor",
                val
            );
            // Don't set target_arc_factor, let Holochain use its default
        }
    }

    debug!("network_config: Network configuration created successfully");
    network_config
}

fn holochain_dir() -> PathBuf {
    debug!("holochain_dir: Determining holochain directory path");
    if tauri::is_dev() && cfg!(not(mobile)) {
        println!(
            "[unyt_tauri] holochain_dir: Development mode on desktop, creating temporary directory"
        );
        let tmp_dir =
            tempdir::TempDir::new(IDENTIFIER_DIR).expect("Could not create temporary directory");
        println!(
            "[unyt_tauri] holochain_dir: Temporary directory created: {:?}",
            tmp_dir.path()
        );

        // Convert `tmp_dir` into a `Path`, destroying the `TempDir`
        // without deleting the directory.
        let tmp_path = tmp_dir.into_path();
        println!(
            "[unyt_tauri] holochain_dir: Using temporary path: {:?}",
            tmp_path
        );
        tmp_path
    } else {
        debug!("holochain_dir: Production mode or mobile, using app data directory");
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
