/// The product name as GitHub renames it in an uploaded asset's name.
fn release_product(name: &str) -> String {
    name.replace([' ', '(', ')', '[', ']', '{', '}'], ".")
        .replace("..", ".")
}

/// Must match the name the release pipeline publishes and signs each asset under.
fn release_asset(
    product: &str,
    version: &str,
    arc_factor: &str,
    target: &str,
    bundle: BundleType,
) -> Option<String> {
    let platform = match (target, bundle) {
        ("linux-x86_64", BundleType::Deb) => "amd64_linux.deb",
        ("linux-x86_64", BundleType::AppImage) => "amd64_linux.AppImage",
        ("darwin-aarch64", BundleType::App) => "aarch64_darwin.app.tar.gz",
        ("darwin-x86_64", BundleType::App) => "x64_darwin.app.tar.gz",
        ("windows-x86_64", BundleType::Msi) => "x64_windows.msi",
        ("windows-x86_64", BundleType::Nsis) => "x64_windows.exe",
        _ => return None,
    };
    Some(format!(
        "unyt_{version}_{product}_{}-arc_{platform}",
        arc(arc_factor)
    ))
}

fn installed_asset<R: Runtime>(app: &AppHandle<R>, version: &str, arc_factor: &str, target: &str, bundle: BundleType) -> Option<String> {
    let product = release_product(&app.package_info().name);
    release_asset(&product, version, arc_factor, target, bundle)
}
