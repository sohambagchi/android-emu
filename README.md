# android-emu

A headless Android emulator and SDK tooling, packaged as a Nix flake that any project can
reuse. The default device is API 35 with Google APIs, on x86_64 (Linux, KVM) or arm64
(Apple Silicon).

## Use

```sh
nix develop ~/dev/android-emu   # adds adb, emulator, avdmanager and the emu-* scripts
emu-up            # create the AVD on first run, cold-boot it headless, wait until ready (~20-25s)
emu-up --window   # same, with a visible window
emu-shot [file]   # save a screenshot and print its path
emu-down          # stop the emulator
```

You can also run a single script without entering the shell:
`nix run ~/dev/android-emu#emu-up`.

From another flake, add this repo as an input and include
`android-emu.packages.${system}.sdk` (or the `emu-*` scripts) in that project's dev shell.
For other Android versions, use `android-emu.lib.mkEmu { inherit system; apiLevels = [ "35" "31" ]; }`,
which returns `sdk`, `emu-up`, `emu-down` and `emu-shot` built with those images.

Settings (environment variables):
- `EMU_API` picks the system image's API level, from those the SDK was built with. The default
  is the first one (35 for this flake's own packages).
- `EMU_NAME` picks the AVD name. The default is `emu-$EMU_API`.
- `EMU_PORT` picks the console port, which sets the adb serial to `emulator-$EMU_PORT`.
  The default is 5554.
- `EMU_BOOT_TIMEOUT` is how many seconds `emu-up` waits for boot. The default is 300.
- AVDs are stored in `~/.android/avd`.
- Logs and screenshots go to `~/.local/state/android-emu/`.

Behaviour:
- The scripts pin adb to `emulator-$EMU_PORT` through `ANDROID_SERIAL`, so they still work
  when a phone is also plugged in. Your own `adb` calls are not pinned. If more than one
  device is attached, pass `-s emulator-5554` or export `ANDROID_SERIAL=emulator-5554`.
- Every start is a cold boot (`-no-snapshot`), so no state is saved between runs except
  what lives on the data partition.
- Rendering uses software GPU (`swiftshader_indirect`), so it works headless and needs no
  host GPU. Expect slow 3D and animations.
- `emu-up` exits early if this AVD is already running. It fails with the log tail if the
  emulator process dies during boot.

The flake sets `android_sdk.accept_license = true`, which accepts the Android SDK license.

Further reading: [DEV_GUIDE.md](DEV_GUIDE.md) covers app development (Gradle, logcat, tests,
more AVDs and images) and kernel development (custom kernels, modules, gdb).
