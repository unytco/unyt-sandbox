use crate::{app_config::AppConfig, generated_arc_factor::HOLOCHAIN_VERSION, network_config};
use anyhow::anyhow;
use holochain_client::{AppInfo, CellInfo};
use tauri::{AppHandle, Manager};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
use tauri_plugin_holochain::HolochainExt;

pub async fn about_menu<R: tauri::Runtime>(h: &AppHandle<R>) {
    let app_version = h.package_info().version.to_string();
    let product_name = AppConfig::new(h).product_name.clone();

    // Build clean sections - Essential info first, technical details last
    let mut sections = Vec::new();

    // 1. VERSION INFORMATION (Most important - always first)
    sections.push(format!(
        "━━━ VERSION INFORMATION ━━━\n\n{} Version: v{}\nHolochain Version: {}",
        product_name, app_version, HOLOCHAIN_VERSION
    ));

    // 2. APP INFORMATION (Important for users)
    if let Ok(app_info) = get_app_info(h.clone()).await {
        sections.push(format_app_info(app_info));
    }

    // 3. NETWORK CONFIGURATION (Technical - for debugging)
    let network_config = network_config();
    let mut network_info = String::from("━━━ NETWORK CONFIGURATION ━━━\n");

    // Bootstrap URL
    network_info.push_str(&format!(
        "\nBootstrap URL: {}",
        network_config.bootstrap_url
    ));

    // Signal URL
    network_info.push_str(&format!(
        "\nSignal URL: {}",
        network_config.signal_url.to_string()
    ));

    // Target Arc Factor
    network_info.push_str(&format!(
        "\nTarget Arc Factor: {}",
        if network_config.target_arc_factor == 0 {
            "0 (Zero Arc Mode)".to_string()
        } else {
            format!("{}", network_config.target_arc_factor)
        }
    ));

    // Base64 Auth Material
    if let Some(auth) = &network_config.base64_auth_material {
        let auth_display = if auth.len() > 20 {
            format!("{}...{}", &auth[..10], &auth[auth.len() - 10..])
        } else {
            auth.clone()
        };
        network_info.push_str(&format!("\nAuth Material: {}", auth_display));
    } else {
        network_info.push_str("\nAuth Material: None");
    }

    // WebRTC Configuration
    if let Some(webrtc) = &network_config.webrtc_config {
        network_info.push_str("\n\nWebRTC Config:");
        network_info.push_str(&format!(
            "\n{}",
            serde_json::to_string_pretty(webrtc).unwrap_or_default()
        ));
    } else {
        network_info.push_str("\n\nWebRTC Config: None");
    }

    // Report Configuration
    network_info.push_str(&format!(
        "\n\nReport Config:\n{}",
        serde_json::to_string_pretty(&network_config.report)
            .unwrap_or_else(|_| "Unable to serialize".to_string())
    ));

    // Advanced Configuration
    if let Some(advanced) = &network_config.advanced {
        network_info.push_str("\n\nAdvanced Config:");
        network_info.push_str(&format!(
            "\n{}",
            serde_json::to_string_pretty(advanced).unwrap_or_default()
        ));
    } else {
        network_info.push_str("\n\nAdvanced Config: None");
    }

    sections.push(network_info);

    // 4. NETWORK BACKEND STATS (Very technical - always last)
    if let Ok(backend) = get_network_dump(h.clone()).await {
        if !backend.is_empty() {
            sections.push(format!("━━━ NETWORK BACKEND STATS ━━━\n\n{}", backend));
        }
    }

    let about_message = sections.join("\n\n");
    let clipboard_message = format!(
        "{}\n\n(Click 'Copy' to copy this information to clipboard)",
        about_message
    );

    let message_for_clipboard = about_message.clone();
    let handle = h.clone();

    h.dialog()
        .message(clipboard_message)
        .title(format!("About {}", product_name))
        .buttons(MessageDialogButtons::OkCancelCustom(
            "Copy".to_string(),
            "Close".to_string(),
        ))
        .show(move |result| {
            if result {
                // User clicked "Copy" button
                if let Some(window) = handle.get_webview_window("main") {
                    let msg = message_for_clipboard.clone();
                    let js_code = format!(
                        "navigator.clipboard.writeText({}).then(() => console.log('Copied to clipboard'), (err) => console.error('Failed to copy:', err))",
                        serde_json::to_string(&msg).unwrap_or_default()
                    );
                    if let Err(e) = window.eval(&js_code) {
                        log::error!("Failed to copy to clipboard: {:?}", e);
                    }
                }
            }
        })
}

fn format_app_info(app_info: Option<AppInfo>) -> String {
    match app_info {
        Some(info) => {
            let mut output = String::from("━━━ APPLICATION INFORMATION ━━━\n");

            // Status and App ID (most important first)
            output.push_str(&format!("\nStatus: {:?}", info.status));
            output.push_str(&format!("\nApp ID: {}", info.installed_app_id));

            // Agent Public Key
            let agent_key = format!("{:?}", info.agent_pub_key);
            let short_agent_key = if agent_key.len() > 50 {
                format!(
                    "{}...{}",
                    &agent_key[..24],
                    &agent_key[agent_key.len() - 24..]
                )
            } else {
                agent_key
            };
            output.push_str(&format!("\nAgent: {}", short_agent_key));

            // DNA Information from alliance cell
            if let Some(cells) = info.cell_info.get("alliance") {
                if let Some(cell) = cells.iter().find_map(|c| match c {
                    CellInfo::Provisioned(c) => Some(c),
                    _ => None,
                }) {
                    let dna_hash = cell.cell_id.dna_hash().to_string();
                    let short_dna = if dna_hash.len() > 50 {
                        format!("{}...{}", &dna_hash[..24], &dna_hash[dna_hash.len() - 24..])
                    } else {
                        dna_hash
                    };
                    output.push_str(&format!("\nDNA Hash: {}", short_dna));
                    output.push_str(&format!(
                        "\nNetwork Seed: {}",
                        cell.dna_modifiers.network_seed
                    ));
                }
            }

            output
        }
        None => String::from("━━━ APPLICATION INFORMATION ━━━\n\nApp not installed or not running"),
    }
}

async fn get_app_info<R: tauri::Runtime>(handle: AppHandle<R>) -> anyhow::Result<Option<AppInfo>> {
    let holochain_client = handle.holochain()?;
    let admin_ws = holochain_client.admin_websocket().await?;

    let installed_apps = admin_ws
        .list_apps(None)
        .await
        .map_err(|err| anyhow!("Failed to list apps: {:?}", err))?;

    let app_config = AppConfig::new(&handle);
    let expected_app_info = installed_apps
        .into_iter()
        .find(|app| app.installed_app_id.as_str() == app_config.app_id);

    Ok(expected_app_info)
}

async fn get_network_dump<R: tauri::Runtime>(handle: AppHandle<R>) -> anyhow::Result<String> {
    let holochain_client = handle.holochain()?;
    let admin_ws = holochain_client.admin_websocket().await?;

    let data = admin_ws
        .dump_network_stats()
        .await
        .map_err(|err| anyhow!("Failed to dump network stats: {:?}", err))?;

    Ok(serde_json::to_string_pretty(&data).unwrap_or_else(|_| "Unable to serialize network stats".to_string()))
}
