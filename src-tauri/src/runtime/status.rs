use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter, Manager};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "status", content = "data")]
pub enum EnvRuntimeStatus {
    Starting,
    LairAwaitingPassword {
        is_initial_setup: bool,
    },
    LairInvalidPassword,
    LairReady,
    ConductorStarting,
    ConductorError(String),
    ConductorCrashed,
    AppInstalling,
    AppInstallationError(String),
    Syncing {
        step: u8,
        total_steps: u8,
        message: String,
    },
    Ready,
    Error(String),
}

pub struct EnvStatusManager {
    status: Mutex<EnvRuntimeStatus>,
    app_handle: AppHandle,
}

impl EnvStatusManager {
    pub fn new(app_handle: AppHandle) -> Self {
        Self {
            status: Mutex::new(EnvRuntimeStatus::Starting),
            app_handle,
        }
    }

    pub fn update_status(&self, new_status: EnvRuntimeStatus) {
        let mut status = self.status.lock().unwrap_or_else(|poisoned| {
            tracing::error!(target: "unyt::runtime", "Status Mutex was poisoned! Attempting to recover...");
            poisoned.into_inner()
        });
        if *status != new_status {
            tracing::info!(target: "unyt::runtime", "Status update: {:?} -> {:?}", *status, new_status);
            *status = new_status.clone();
            let _ = self.app_handle.emit("runtime://status-update", new_status);
        }
    }

    pub fn get_status(&self) -> EnvRuntimeStatus {
        self.status.lock().unwrap_or_else(|poisoned| {
            tracing::error!(target: "unyt::runtime", "Status Mutex was poisoned! Attempting to recover...");
            poisoned.into_inner()
        }).clone()
    }
}

pub fn init(app_handle: AppHandle) -> anyhow::Result<()> {
    app_handle.manage(Arc::new(EnvStatusManager::new(app_handle.clone())));
    Ok(())
}
