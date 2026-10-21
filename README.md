# Thuis Control

Thuis Control is a native macOS app for controlling LG webOS and Samsung TVs on your local network. Its full window and menu-bar Control Center run in one app.

## What it does

- Controls power, volume, navigation, inputs, and installed apps.
- Discovers and pairs with compatible LG webOS and Samsung TVs locally.
- Stores TV pairing keys in the macOS Keychain.
- Can send Wake-on-LAN packets when a MAC address is configured.
- Supports a rooted LG launcher through a user-provided SSH key kept outside this repository.

## Privacy and security

The repository contains no devices, IP addresses, MAC addresses, accounts, pairing keys, SSH keys, screenshots, backups, or build artifacts.

TV details are entered locally and stored in UserDefaults. Pairing credentials are stored in the macOS Keychain. The app does not use a cloud service, telemetry, or arbitrary network-load exceptions; it requests local-network access only.

Never commit `root-key`, `known_hosts`, built `.app` bundles, pairing tokens, or your own test logs. The included `.gitignore` blocks these common files.

## Requirements

- macOS 14 or later on Apple silicon.
- Xcode Command Line Tools (`xcode-select --install`).
- A TV on the same local network.

## Build and run

```sh
./build.sh
open "Thuis Control.app"
```

Add a TV through the connection/settings screen, then choose **Connect** and approve the pairing request on the TV. Closing the main window keeps the menu-bar Control Center available.

## Rooted LG support

For a rooted LG setup, place your own private key at `~/.local/share/lg-tv/root-key` and its host key entry at `~/.local/share/lg-tv/known_hosts`. These files remain on your Mac. The app uses strict host-key checking and BatchMode SSH; it does not create or copy credentials.

## License

[MIT](LICENSE)
