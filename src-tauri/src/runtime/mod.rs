pub mod logs;
pub mod status;
pub mod boot;

use self::status::EnvStatusManager;
use std::sync::Arc;
use tauri::{AppHandle, Manager};

/// Initialize logs and status to be used during runtime
pub fn init(handle: &AppHandle) -> anyhow::Result<()> {
    logs::init(handle.clone())?;
    status::init(handle.clone())?;
    Ok(())
}

#[tauri::command]
pub fn update_runtime_status(status_manager: tauri::State<'_, Arc<EnvStatusManager>>, status: self::status::EnvRuntimeStatus) {
    status_manager.update_status(status);
}

#[tauri::command]
pub fn get_runtime_status(status_manager: tauri::State<'_, Arc<EnvStatusManager>>) -> self::status::EnvRuntimeStatus {
    status_manager.get_status()
}

#[tauri::command]
pub fn close_splashscreen(app_handle: AppHandle) {
    tracing::info!(target: "unyt::runtime", "Closing splashscreen and showing main window");
    if let Some(splashscreen) = app_handle.get_webview_window("splashscreen") {
        let _ = splashscreen.close();
    } else {
        tracing::warn!(target: "unyt::runtime", "Splashscreen window not found during close attempt");
    }
    if let Some(main) = app_handle.get_webview_window("main") {
        let _ = main.show();
        let _ = main.set_focus();
    } else {
        tracing::warn!(target: "unyt::runtime", "Main window not found during splashscreen close attempt");
    }
}

#[tauri::command]
pub fn show_logs(app_handle: AppHandle) {
    println!("[unyt_tauri] show_logs command received");
    tracing::info!(target: "unyt::runtime", "Showing logs window");
    
    if let Some(logs) = app_handle.get_webview_window("logs") {
        let _ = logs.show();
        let _ = logs.set_focus();
    } else {
        println!("[unyt_tauri] Logs window not found, recreating...");
        let res = tauri::WebviewWindowBuilder::new(
            &app_handle,
            "logs",
            tauri::WebviewUrl::App("/logs.html".into())
        )
        .title("Unyt System Logs")
        .inner_size(800.0, 600.0)
        .visible(false) // Start hidden, then show
        .build();
        
        match res {
            Ok(logs) => {
                let _ = logs.show();
                let _ = logs.set_focus();
            },
            Err(e) => {
                tracing::error!(target: "unyt::runtime", "Failed to recreate logs window: {}", e);
            }
        }
    }
}
