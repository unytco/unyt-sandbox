
## Development and Testing

For developers working on the codebase, the following environment variables can be used to customize the runtime behavior:

### Persistent Development Mode
By default, development builds on desktop use a temporary directory for Holochain data which is deleted when the app closes. To use the standard app data directory and persist your state across restarts:

```bash
UNYT_PERSISTENT_DEV=true yarn network:tauri
```

### Bypass Lair Password
To skip the Lair keystore password prompt during development (uses an empty password):

```bash
UNYT_BYPASS_PASSWORD=true yarn network:tauri
```
