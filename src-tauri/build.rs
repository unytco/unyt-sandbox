use std::fs;
use std::path::Path;

fn main() {
    // Read the HOLOCHAIN_ARC_FACTOR environment variable
    let arc_factor = std::env::var("HOLOCHAIN_ARC_FACTOR").unwrap_or_else(|_| "".to_string());

    // Extract Holochain version from Cargo.lock
    let holochain_version = extract_holochain_version().unwrap_or_else(|| "unknown".to_string());

    // Generate a Rust file with the arc factor value and holochain version
    let code = format!(
        r#"
        pub const HOLOCHAIN_ARC_FACTOR: &str = "{}";
        pub const HOLOCHAIN_VERSION: &str = "{}";
        "#,
        arc_factor, holochain_version
    );

    // Write to a generated file
    std::fs::write("src/consts.rs", code).expect("Failed to write generated file");

    // Tell Cargo to rerun this build script if files change
    println!("cargo:rerun-if-env-changed=HOLOCHAIN_ARC_FACTOR");
    println!("cargo:rerun-if-changed=../Cargo.lock");

    // This is essential for Tauri to work properly
    tauri_build::build()
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
