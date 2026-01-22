
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

### Lair Keystore Salt
The application uses a unique cryptographic salt for hashing the Lair keystore password. By default, this salt is generated on first launch and stored securely in the **OS Keychain** (macOS Keychain, Windows Credential Manager, or Linux Secret Service).

To override this behavior or provide a specific salt (e.g., for automated testing or recovery):

```bash
TAURI_LAIR_SALT=your-base64-salt yarn network:tauri
```
*Note: Overriding the salt on an existing installation will prevent the app from unlocking the keystore unless the password is also updated to match the new derivation.*
