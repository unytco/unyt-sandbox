use tauri::AppHandle;

// this is we are setting it the same as the identifier
pub const IDENTIFIER_DIR: &'static str = "co.unyt.unyt.sandbox";
pub const APP_ID_PREFIX: &'static str = "unyt";
// todo: when we have a way to get the DNA hash we should include this
// const DNA_HASH: &'static str = include_str!("../../workdir/unyt-dna_hashes");

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub _name: String,
    pub _version: String,
    pub identifier: String,
    pub product_name: String,
    pub app_id: String,
    pub network_seed: String,
}

impl AppConfig {
    pub fn new<R: tauri::Runtime>(handle: &AppHandle<R>) -> Self {
        // the version number is semantic versioning,
        // so I want to brek it down and get the first two numbers
        // and use them as the version number
        let version = handle.package_info().version.to_string();
        let version_parts: Vec<&str> = version.split('.').collect();
        let major_version = version_parts[0].to_string();
        let minor_version = version_parts[1].to_string();
        // the reason we use the first two numbers is because we will expect a migration to be implemented if the major or minor version is updated
        // and we will not expect a migration to be implemented if the patch version is updated
        let version = format!("{}.{}", major_version, minor_version);
        Self {
            _name: handle.package_info().name.clone(),
            _version: handle.package_info().version.to_string(),
            identifier: handle.config().identifier.clone(),
            product_name: handle
                .config()
                .product_name
                .clone()
                .unwrap_or_else(|| "Unyt".to_string()),
            app_id: format!("{APP_ID_PREFIX}-{}", version.to_string()),
            // app_id: format!("{APP_ID_PREFIX}-{}", DNA_HASH.trim()),
            network_seed: format!("{}-iroh", handle.config().identifier),
        }
    }
}
