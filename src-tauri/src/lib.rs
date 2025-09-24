mod app_config;
mod utils;
use anyhow::anyhow;
pub use app_config::{AppConfig, APP_ID_PREFIX, IDENTIFIER_DIR};
use std::path::PathBuf;
use tauri::{AppHandle, Listener, WebviewWindow};
use tauri_plugin_holochain::{
    vec_to_locked, AppBundle, AppStatusFilter, DnaModifiersOpt, HolochainExt,
    HolochainPluginConfig, NetworkConfig, RoleSettings, RoleSettingsMap,
};
pub use utils::migrate_app;

#[cfg(not(mobile))]
mod menu;
// todo:
// #[cfg(mobile)]
// mod push_notifications;

pub fn happ_bundle() -> AppBundle {
    println!("[unyt_tauri] Loading happ bundle from workdir/unyt.happ");
    let bytes = include_bytes!("../../workdir/unyt.happ");
    println!(
        "[unyt_tauri] Happ bundle bytes loaded, size: {} bytes",
        bytes.len()
    );
    let bundle = AppBundle::decode(bytes).expect("Failed to decode unyt happ");
    println!("[unyt_tauri] Happ bundle decoded successfully");
    bundle
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    println!("[unyt_tauri] Starting Tauri application");
    std::env::set_var("WASM_LOG", "debug");
    println!("[unyt_tauri] Set WASM_LOG environment variable to debug");

    println!("[unyt_tauri] Building Tauri application with plugins");
    let mut builder = tauri::Builder::default().plugin(
        tauri_plugin_log::Builder::default()
            .level(log::LevelFilter::Warn)
            .level_for("tracing::span", log::LevelFilter::Off)
            .level_for("iroh", log::LevelFilter::Warn)
            .level_for("holochain", log::LevelFilter::Warn)
            .level_for("kitsune2", log::LevelFilter::Warn)
            .level_for("kitsune2_gossip", log::LevelFilter::Warn)
            .level_for("kitsune2_transport_iroh", log::LevelFilter::Info)
            .level_for("holochain_runtime", log::LevelFilter::Info)
            .level_for("unyt", log::LevelFilter::Debug)
            .build(),
    );
    println!("[unyt_tauri] Added logging plugin");

    builder = builder
        // .plugin(tauri_plugin_deep_link::init())
        .plugin(tauri_plugin_notification::init());
    println!("[unyt_tauri] Added notification plugin");

    builder = builder.plugin(tauri_plugin_process::init());
    println!("[unyt_tauri] Added process plugin");

    builder = builder.plugin(tauri_plugin_dialog::init());
    println!("[unyt_tauri] Added dialog plugin");

    let holochain_dir = holochain_dir();
    let network_config = network_config();
    println!("[unyt_tauri] Holochain directory: {:?}", holochain_dir);
    println!(
        "[unyt_tauri] Network config bootstrap URL: {:?}",
        network_config.bootstrap_url
    );

    builder = builder.plugin(tauri_plugin_holochain::async_init(
        vec_to_locked(vec![]),
        HolochainPluginConfig::new(holochain_dir, network_config).enable_mdns_discovery(),
    ));
    println!("[unyt_tauri] Added holochain plugin with MDNS discovery enabled");

    builder = builder.setup(move |app| {
        println!("[unyt_tauri] Setting up Tauri application");
        #[cfg(mobile)]
        {
            println!("[unyt_tauri] Mobile platform detected, adding mobile-specific plugins");
            app.handle().plugin(tauri_plugin_barcode_scanner::init())?;
            println!("[unyt_tauri] Added barcode scanner plugin");
            app.handle()
                .plugin(tauri_plugin_safe_area_insets_css::init())?;
            println!("[unyt_tauri] Added safe area insets CSS plugin");
        }
        #[cfg(not(mobile))]
        {
            println!("[unyt_tauri] Desktop platform detected, adding desktop-specific plugins");
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
            println!("[unyt_tauri] Added updater plugin");
        }
        let handle = app.handle().clone();
        println!("[unyt_tauri] Setting up holochain setup-completed event listener");

        app.handle()
            .listen("holochain://setup-completed", move |_event| {
                println!("[unyt_tauri] Received holochain://setup-completed event");
                let handle2 = handle.clone();
                tauri::async_runtime::spawn(async move {
                    println!("[unyt_tauri] Starting setup process");
                    if let Err(err) = setup(handle2.clone()).await {
                        println!("[ERROR] Failed to setup: {err:?}");
                        log::error!("Failed to setup: {err:?}");
                        return;
                    }
                    println!("[unyt_tauri] Setup completed successfully");

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
                    println!("[unyt_tauri] Opening main window");
                    if let Err(err) = open_window(handle.clone()).await {
                        println!("[ERROR] Failed to open window: {err:?}");
                        log::error!("Failed to setup: {err:?}");
                    } else {
                        println!("[unyt_tauri] Main window opened successfully");
                    }
                });
            });

        println!("[unyt_tauri] Tauri application setup completed");
        Ok(())
    });

    #[cfg(not(mobile))]
    {
        println!("[unyt_tauri] Adding desktop menu");
        builder = builder.menu(|handle| menu::build_menu(handle));
        println!("[unyt_tauri] Desktop menu added");
    }

    println!("[unyt_tauri] Starting Tauri application run loop");
    builder
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
    println!("[unyt_tauri] Tauri application has exited");
}

async fn open_window(handle: AppHandle) -> anyhow::Result<WebviewWindow> {
    println!("[unyt_tauri] open_window: Creating main window");
    let app_config = app_config::AppConfig::new(&handle);
    println!(
        "[unyt_tauri] open_window: App config created with app_id: {}",
        app_config.app_id
    );

    let mut window_builder = handle
        .holochain()?
        .main_window_builder(String::from("main"), true, Some(app_config.app_id), None)
        .await?;
    println!("[unyt_tauri] open_window: Window builder created");

    #[cfg(not(mobile))]
    {
        println!("[unyt_tauri] open_window: Configuring desktop window properties");
        window_builder = window_builder
            .title(String::from("Unyt"))
            .inner_size(1400.0, 1000.0);
        println!(
            "[unyt_tauri] open_window: Desktop window configured with title 'Unyt' and size 1400x1000"
        );
    }

    println!("[unyt_tauri] open_window: Building window");
    let window = window_builder.build()?;
    println!("[unyt_tauri] open_window: Window built successfully");
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
    println!("[unyt_tauri] setup: Starting application setup");
    let admin_ws = handle.holochain()?.admin_websocket().await?;
    println!("[unyt_tauri] setup: Connected to admin websocket");

    let app_config = AppConfig::new(&handle);
    println!(
        "[unyt_tauri] setup: App config created with app_id: {}",
        app_config.app_id
    );

    let installed_apps = admin_ws
        .list_apps(Some(AppStatusFilter::Running))
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
        println!("[unyt_tauri] setup: App not installed, checking for previous versions");
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
            println!("[unyt_tauri] setup: No previous app versions found");
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
        println!("[unyt_tauri] setup: Role settings configured");

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
            println!("[unyt_tauri] setup: App migration completed");

            println!(
                "[unyt_tauri] setup: Disabling previous app: {}",
                previous_app.installed_app_id
            );
            admin_ws
                .disable_app(previous_app.installed_app_id.clone())
                .await
                .map_err(|err| anyhow!("{err:?}"))?;
            println!("[unyt_tauri] setup: Previous app disabled");
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
            println!("[unyt_tauri] setup: New app installed successfully");
        }

        println!("[unyt_tauri] setup: Fresh installation completed");
        Ok(())
    } else {
        println!("[unyt_tauri] setup: App already installed, checking for updates");
        handle
            .holochain()?
            .update_app_if_necessary(String::from(app_config.app_id), happ_bundle())
            .await?;
        println!("[unyt_tauri] setup: App update check completed");

        Ok(())
    }
}

fn network_config() -> NetworkConfig {
    println!("[unyt_tauri] network_config: Creating network configuration");
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

    // Configure arc factor: only set to 0 for zero arc mode, otherwise use Holochain default
    match std::env::var("HOLOCHAIN_ARC_FACTOR") {
        Ok(val) if val == "0" => {
            println!("[unyt_tauri] network_config: Zero arc mode enabled (HOLOCHAIN_ARC_FACTOR=0)");
            network_config.target_arc_factor = 0;
        }
        Ok(val) => {
            println!(
                "[unyt_tauri] network_config: HOLOCHAIN_ARC_FACTOR='{}' - using Holochain default arc factor",
                val
            );
            // Don't set target_arc_factor, let Holochain use its default
        }
        Err(_) => {
            // Default behavior based on platform
            if cfg!(mobile) {
                println!(
                    "[unyt_tauri] network_config: Mobile platform detected, setting target_arc_factor to 0"
                );
                network_config.target_arc_factor = 0;
            } else {
                println!(
                    "[unyt_tauri] network_config: Desktop platform detected, using Holochain default arc factor"
                );
                // Don't set target_arc_factor, let Holochain use its default
            }
        }
    }

    println!("[unyt_tauri] network_config: Network configuration created successfully");
    network_config
}

fn holochain_dir() -> PathBuf {
    println!("[unyt_tauri] holochain_dir: Determining holochain directory path");
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
        println!("[unyt_tauri] holochain_dir: Production mode or mobile, using app data directory");
        let version = get_version();
        println!("[unyt_tauri] holochain_dir: App version: {}", version);

        let app_root = app_dirs2::app_root(
            app_dirs2::AppDataType::UserData,
            &app_dirs2::AppInfo {
                name: IDENTIFIER_DIR,
                author: std::env!("CARGO_PKG_AUTHORS"),
            },
        )
        .expect("Could not get app root");
        println!("[unyt_tauri] holochain_dir: App root: {:?}", app_root);

        let holochain_path = app_root.join(version).join("holochain");
        println!(
            "[unyt_tauri] holochain_dir: Final holochain path: {:?}",
            holochain_path
        );
        holochain_path
    }
}

fn get_version() -> String {
    let semver = std::env!("CARGO_PKG_VERSION");
    println!("[unyt_tauri] get_version: Raw semver: {}", semver);

    if semver.starts_with("0.0.") {
        println!(
            "[unyt_tauri] get_version: Version starts with 0.0., returning full version: {}",
            semver
        );
        return semver.to_string();
    }

    if semver.starts_with("0.") {
        let v: Vec<&str> = semver.split(".").collect();
        let version = format!("{}.{}", v[0], v[1]);
        println!(
            "[unyt_tauri] get_version: Version starts with 0., returning major.minor: {}",
            version
        );
        return version;
    }
    let v: Vec<&str> = semver.split(".").collect();
    let version = format!("{}", v[0]);
    println!(
        "[unyt_tauri] get_version: Returning major version only: {}",
        version
    );
    return version;
}
