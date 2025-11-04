use tauri::menu::{Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::{AppHandle, Manager, Runtime};
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons};
mod about;

use crate::holochain_dir;

pub fn build_menu<R: Runtime>(app_handle: &AppHandle<R>) -> tauri::Result<Menu<R>> {
    app_handle.on_menu_event(|app_handle, menu_event| match menu_event.id().as_ref() {
        "open-logs-folder" => {
            let log_folder = app_handle
                .path()
                .app_log_dir()
                .expect("Could not get app log dir");
            if let Err(err) = opener::reveal(log_folder.clone()) {
                log::error!("Failed to open log dir at {log_folder:?}: {err:?}");
            }
        }
        "reload" => {
            if let Some(window) = app_handle.get_webview_window("main") {
                if let Err(err) = window.eval("window.location.reload()") {
                    log::error!("Failed to reload window: {err:?}");
                }
            }
        }
        "restart" => {
            app_handle.restart();
        }
        "quit" => {
            app_handle.exit(0);
        }
        "factory-reset" => {
            let h = app_handle.clone();
            app_handle
                .dialog()
                .message(
                    "Are you sure you want to perform a factory reset? All your data will be lost.",
                )
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
                    false => {}
                });
        }
        "about" => {
            let h = app_handle.clone();
            tauri::async_runtime::spawn(async move { about::about_menu(&h).await });
        }
        _ => {}
    });

    Menu::with_items(
        app_handle,
        &[
            &Submenu::with_items(
                app_handle,
                "File",
                true,
                &[&MenuItem::with_id(
                    app_handle,
                    "quit",
                    "Quit",
                    true,
                    Some("CmdOrCtrl+Q"),
                )?],
            )?,
            &Submenu::with_items(
                app_handle,
                "Edit",
                true,
                &[
                    &PredefinedMenuItem::undo(app_handle, None)?,
                    &PredefinedMenuItem::redo(app_handle, None)?,
                    &PredefinedMenuItem::separator(app_handle)?,
                    &PredefinedMenuItem::cut(app_handle, None)?,
                    &PredefinedMenuItem::copy(app_handle, None)?,
                    &PredefinedMenuItem::paste(app_handle, None)?,
                    &PredefinedMenuItem::separator(app_handle)?,
                    &PredefinedMenuItem::select_all(app_handle, None)?,
                ],
            )?,
            &Submenu::with_items(
                app_handle,
                "View",
                true,
                &[&MenuItem::with_id(
                    app_handle,
                    "reload",
                    "Reload",
                    true,
                    Some("CmdOrCtrl+R"),
                )?],
            )?,
            &Submenu::with_items(
                app_handle,
                "Advanced",
                true,
                &[
                    &MenuItem::with_id(
                        app_handle,
                        "restart",
                        "Restart Application",
                        true,
                        None::<&str>,
                    )?,
                    &MenuItem::with_id(
                        app_handle,
                        "open-logs-folder",
                        "Open Logs Folder",
                        true,
                        None::<&str>,
                    )?,
                    &PredefinedMenuItem::separator(app_handle)?,
                    &MenuItem::with_id(
                        app_handle,
                        "factory-reset",
                        "Factory Reset",
                        true,
                        None::<&str>,
                    )?,
                ],
            )?,
            &Submenu::with_items(
                app_handle,
                "Help",
                true,
                &[&MenuItem::with_id(
                    app_handle,
                    "about",
                    "About",
                    true,
                    None::<&str>,
                )?],
            )?,
        ],
    )
}
