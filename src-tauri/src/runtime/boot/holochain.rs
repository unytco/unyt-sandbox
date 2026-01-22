use crate::app_config::{get_version, IDENTIFIER_DIR};
use crate::consts;
use std::path::PathBuf;
use std::sync::OnceLock;
use tauri_plugin_holochain::{NetworkConfig, ReportConfig};

static IDENTIFIER: OnceLock<String> = OnceLock::new();

// This function determines the holochain directory path based on the development mode and the app version
// Returns the path to the holochain directory
// (Relocated from mod.rs to boot.rs to avoid circular dependencies)
pub fn holochain_dir() -> PathBuf {
    tracing::debug!(target: "unyt", "holochain_dir: Determining holochain directory path");
    let use_persistent_dev = std::env::var("UNYT_PERSISTENT_DEV").is_ok();

    let identifier: &'static str = IDENTIFIER.get_or_init(|| {
        let agent_id = std::env::var("AGENT_ID").unwrap_or_else(|_| "".into());
        if agent_id.is_empty() {
            IDENTIFIER_DIR.to_string()
        } else {
            format!("{}-{}", IDENTIFIER_DIR, agent_id)
        }
    }).as_str();

    let agent_id = std::env::var("AGENT_ID").unwrap_or_else(|_| "".into());

    if tauri::is_dev() && cfg!(not(mobile)) && !use_persistent_dev {
        println!(
            "[unyt_tauri] holochain_dir: Development mode on desktop, creating temporary directory for agent {}",
            agent_id
        );
        let tmp_dir =
            tempdir::TempDir::new(identifier).expect("Could not create temporary directory");
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
        tracing::debug!(target: "unyt", "holochain_dir: Production mode or mobile, using app data directory");
        let version = get_version();
        tracing::debug!(target: "unyt", "holochain_dir: App version: {}", version);

        let app_root = app_dirs2::app_root(
            app_dirs2::AppDataType::UserData,
            &app_dirs2::AppInfo {
                name: identifier,
                author: std::env!("CARGO_PKG_AUTHORS"),
            },
        )
        .expect("Could not get app root");
        tracing::debug!(target: "unyt", "holochain_dir: App root: {:?}", app_root);

        let holochain_path = app_root.join(version).join("holochain");
        println!(
            "[unyt_tauri] holochain_dir: Final holochain path: {:?}",
            holochain_path
        );
        holochain_path
    }
}

// This function creates the network configuration for the holochain runtime
// Returns the network configuration
pub fn network_config() -> NetworkConfig {
    tracing::debug!(target: "unyt", "network_config: Creating network configuration");
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
        consts::HOLOCHAIN_ARC_FACTOR
    );
    match consts::HOLOCHAIN_ARC_FACTOR {
        "0" => {
            tracing::debug!(target: "unyt", "network_config: Zero arc mode enabled (HOLOCHAIN_ARC_FACTOR=0)");
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

    tracing::debug!(target: "unyt", "network_config: Network configuration created successfully");
    network_config
}
