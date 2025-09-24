# Arc Configuration

This document explains how to configure the Holochain arc factor for the Unyt application.

## Environment Variable

The application supports configuring the arc factor through the `HOLOCHAIN_ARC_FACTOR` environment variable.

### Usage

The configuration is simplified to support two modes:

- `HOLOCHAIN_ARC_FACTOR=0` - Zero arc mode (holds no DHT data, suitable for mobile/light clients)
- **Not set or any other value** - Uses Holochain's default arc factor (suitable for desktop/server nodes)

### Default Behavior

If `HOLOCHAIN_ARC_FACTOR` is not set, the application uses platform-based defaults:

- **Mobile platforms**: Automatically sets arc factor to `0` (zero arc)
- **Desktop platforms**: Uses Holochain's default arc factor (typically full participation)

### Examples

```bash
# Run with zero arc (light client mode)
HOLOCHAIN_ARC_FACTOR=0 ./unyt-tauri

# Run with Holochain default arc (full node mode)
./unyt-tauri
# or
HOLOCHAIN_ARC_FACTOR=anything ./unyt-tauri
```

## Release Builds

The GitHub Actions release workflow creates different arc versions based on the platform:

### Desktop Platforms (Windows, macOS, Linux)

- `unyt-*-default-arc.*` - Default arc versions (uses Holochain default)
- `unyt-*-zero-arc.*` - Zero arc versions (arc factor 0)

### Android Platform

- `unyt.*` - Zero arc only (arc factor 0, no suffix needed)

This allows users to choose the appropriate version based on their needs:

- Choose **default arc** for desktop installations that can contribute to the network
- Choose **zero arc** for mobile or resource-constrained environments
- **Android builds are always zero arc** since mobile devices should typically be light clients

## Technical Details

The arc factor determines what fraction of the DHT space a node is responsible for:

- `0` = No responsibility for DHT data (pure consumer)
- **Holochain default** = Automatic determination based on network conditions and node capabilities

This setting affects:

- Storage requirements
- Network bandwidth usage
- DHT resilience contribution
- Sync performance

## Artifact Naming

Release artifacts are automatically named using the Tauri product name configuration:

### Desktop Platforms

- **Default arc**: `Unyt.exe`, `Unyt.deb`, `Unyt.dmg` (standard names)
- **Zero arc**: `Unyt-zero-arc.exe`, `Unyt-zero-arc.deb`, `Unyt-zero-arc.dmg`

### Android Platform

- **Zero arc only**: `Unyt.apk`, `Unyt.aab` (standard names, always zero arc)

This is achieved by dynamically setting the `TAURI_PRODUCT_NAME_SUFFIX` environment variable during the build process, which Tauri uses to generate the final product names. Android builds use an empty suffix since they're always zero arc by default.
