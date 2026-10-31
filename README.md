# G-Helper (fork with iGPU control in Ultimate Mode)

This is a fork of [G-Helper](https://github.com/seerge/g-helper) by seerge, the lightweight control tool for ASUS laptops. It follows the original project closely and adds one feature. For everything else (features, supported models, FAQ, troubleshooting) see the **[original README](https://github.com/seerge/g-helper#readme)**.

## What this fork adds

### Disable iGPU in Ultimate Mode

An optional setting under **Extra → Other**, off by default.

- **Switching to Ultimate**: after the MUX switch is accepted, the integrated GPU is disabled in Device Manager, then the laptop restarts. The screen can go dark for a moment before the restart.
- **Switching back to Standard/Eco**: the integrated GPU is re-enabled first. If that fails, the switch is cancelled, because outside Ultimate the built-in display runs from the integrated GPU.
- **Turning the setting on while already in Ultimate** disables the integrated GPU straight away. Turning it off re-enables it.
- On startup the setting is re-applied to match the current mode. The MUX recovery hotkey (hold Ctrl+Shift+Alt+M4) also re-enables the integrated GPU before restarting.

Requirements and limits:

- G-Helper has to run as administrator. "Run on Startup" already does this.
- Works with an Intel integrated GPU, or an AMD one paired with an NVIDIA dGPU. On all-AMD laptops the setting is hidden, because the two GPUs can't be told apart reliably.

> [!WARNING]
> While the integrated GPU is disabled, only change the GPU mode from G-Helper. If the MUX is switched elsewhere (BIOS, Armoury Crate, or a BIOS update resetting it), the built-in screen stays blank after boot until G-Helper starts and re-enables the integrated GPU.

## Install

1. Download `GHelper.exe` from [Releases](https://github.com/wqin0/g-helper/releases).
2. Close G-Helper and replace your existing `GHelper.exe` with it.

The built-in updater in these builds checks this fork's releases. Builds are not code-signed, unlike the official ones.

## How builds are made

- Every 3 hours a GitHub Actions workflow checks the original repository and merges new commits.
- Each upstream release is rebuilt with this fork's changes, usually within 3 hours.
- Versions are the upstream version plus a fork build number (`0.291.1`, `0.291.2`, ...).
- Merge conflicts and build breaks are handed to an AI coding agent ([OpenCode](https://opencode.ai)).
- A release is only published if the build passes and the fork's changes are confirmed still present. Otherwise syncing pauses and an issue is opened.

## License

GPL-3.0, same as the original project. See [LICENSE](LICENSE).
