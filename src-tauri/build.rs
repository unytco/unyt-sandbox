use std::fs;
use std::path::Path;

fn main() {
    // Read the HOLOCHAIN_ARC_FACTOR environment variable
    let arc_factor = std::env::var("HOLOCHAIN_ARC_FACTOR").unwrap_or_else(|_| "".to_string());

    // App identity: used for multiple app variants (unyt-sandbox, holo-hosting). Fallbacks = current default app.
    let identifier_dir = std::env::var("TAURI_APP_IDENTIFIER")
        .unwrap_or_else(|_| "co.unyt.unyt.sandbox".to_string());
    let app_id_prefix =
        std::env::var("TAURI_APP_ID_PREFIX").unwrap_or_else(|_| "unyt-sandbox".to_string());

    // Escape for use inside Rust string literals (backslash and quote)
    let identifier_dir_esc = escape_rust_str(&identifier_dir);
    let app_id_prefix_esc = escape_rust_str(&app_id_prefix);

    // Extract Holochain version from Cargo.lock
    let holochain_version = extract_holochain_version().unwrap_or_else(|| "unknown".to_string());

    // Generate a Rust file with arc factor, holochain version, and app identity
    let code = format!(
        r#"
pub const HOLOCHAIN_ARC_FACTOR: &str = "{}";
pub const HOLOCHAIN_VERSION: &str = "{}";
pub const IDENTIFIER_DIR: &str = "{}";
pub const APP_ID_PREFIX: &str = "{}";
"#,
        arc_factor, holochain_version, identifier_dir_esc, app_id_prefix_esc
    );

    std::fs::write("src/consts.rs", code).expect("Failed to write generated file");

    println!("cargo:rerun-if-env-changed=HOLOCHAIN_ARC_FACTOR");
    println!("cargo:rerun-if-env-changed=TAURI_APP_IDENTIFIER");
    println!("cargo:rerun-if-env-changed=TAURI_APP_ID_PREFIX");
    println!("cargo:rerun-if-changed=../Cargo.lock");

    tauri_build::build()
}

fn escape_rust_str(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn extract_holochain_version() -> Option<String> {
    // Try to read Cargo.lock from parent directory
    let cargo_lock_path = Path::new("../Cargo.lock");

    let contents = fs::read_to_string(cargo_lock_path).ok()?;

    // Parse Cargo.lock to find holochain version
    // Look for: [[package]]
    //           name = "holochain"
    //           version = "x.y.z"
    let lines: Vec<&str> = contents.lines().collect();

    for i in 0..lines.len() {
        if lines[i].trim() == "[[package]]" {
            // Check next few lines for name = "holochain"
            if i + 1 < lines.len() && lines[i + 1].contains("name = \"holochain\"") {
                // Look for version on next line
                if i + 2 < lines.len() {
                    let version_line = lines[i + 2];
                    if version_line.contains("version = ") {
                        // Extract version between quotes
                        if let Some(start) = version_line.find("\"") {
                            if let Some(end) = version_line[start + 1..].find("\"") {
                                return Some(version_line[start + 1..start + 1 + end].to_string());
                            }
                        }
                    }
                }
            }
        }
    }

    None
}
