# Headless emulator flake

- `nix develop` gives adb, emulator, avdmanager and the API 35 `google_apis` SDK (x86_64-linux, aarch64-darwin).
- `emu-up` creates the AVD on first run, cold-boots it headless (or `--window`) and waits for boot; `emu-down` stops it; `emu-shot` saves a screenshot.
- `EMU_NAME`, `EMU_PORT` and `EMU_BOOT_TIMEOUT` configure the scripts; `ANDROID_SERIAL` pins them to their own emulator.
- `packages.<system>.sdk` and the scripts are reusable from other flakes.
- README and [DEV_GUIDE](../../DEV_GUIDE.md) cover usage, app development and kernel development; paths point at `~/dev/android-emu`.
- Rationale: see ADRs [2026-11-23-2019-system-image-fixed-in-flake](../adr/2026-11-23-2019-system-image-fixed-in-flake.md), [2026-11-23-2019-cold-boot-every-start](../adr/2026-11-23-2019-cold-boot-every-start.md), [2026-11-23-2019-software-gpu-rendering](../adr/2026-11-23-2019-software-gpu-rendering.md)
