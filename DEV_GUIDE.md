# Developer guide

Practical notes for app and kernel work on top of this flake on a NixOS x86_64 host with KVM.
Commands assume the dev shell (`nix develop ~/dev/android-emu`) unless stated otherwise.

Anything marked **(unverified)** was not tested on this host; the list at the end collects them.
Everything else was checked against the tools shipped in the flake (emulator 37.3.9,
platform-tools 37.0.1, cmdline-tools 23.0, build-tools 35.0.0, system image
`android-35;google_apis;x86_64` r9).

## Reference: what the flake gives you

| Item | Value |
| --- | --- |
| SDK root | `$ANDROID_HOME` = `<sdk>/libexec/android-sdk` (read-only Nix store path) |
| Tools on `PATH` | `adb emulator avdmanager sdkmanager apkanalyzer lint d8 r8 fastboot ...` (from `<sdk>/bin`) |
| Not on `PATH` | build-tools binaries (`aapt2`, `apksigner`, `zipalign`): use `$ANDROID_HOME/build-tools/35.0.0/` |
| Not included | JDK, Gradle, NDK |
| Installed packages | `platforms;android-35`, `build-tools;35.0.0`, `emulator` 37.3.9, `platform-tools` 37.0.1, `cmdline-tools;23.0`, `cmake;4.1.2`, `system-images;android-35;google_apis;x86_64` |
| AVDs | `~/.android/avd/<name>.avd` (default `emu-35`, Pixel 7 profile) |
| Logs, screenshots | `~/.local/state/android-emu/` (`$EMU_NAME.log`, `shot-*.png`) |
| Script settings | `EMU_NAME` (default `emu-35`), `EMU_PORT` (default `5554`, serial `emulator-$EMU_PORT`), `EMU_BOOT_TIMEOUT` (default 300 s) |
| Default launch flags (emu-up) | `-port $EMU_PORT -no-window -no-audio -no-boot-anim -no-metrics -no-snapshot -gpu swiftshader_indirect` |
| AVD overrides (emu-up, on creation) | `hw.keyboard=yes`, `hw.ramSize=3072`, `disk.dataPartition.size=6G`, `hw.gpu.enabled=yes`, `hw.gpu.mode=swiftshader_indirect`; 4 vCPUs from the Pixel 7 profile |
| Guest | Android 15, `userdebug`, `ro.debuggable=1`, `su` at `/system/xbin/su`, ABIs `x86_64,arm64-v8a` (ARM translation) |
| Guest kernel | `6.6.50-android15-8-g8adecb593e9b-ab12525588` (GKI, built with Kleaf) |

`sdkmanager --list` works against the store SDK (it needs network for the remote list) and is
useful for discovering package names, but it cannot install anything there. Add packages by
editing `flake.nix` (see [Other API levels and image types](#other-api-levels-and-image-types)).

## 1. Android app development

### Dev shell

```sh
nix develop ~/dev/android-emu
emu-up                 # create emu-35 on first run, cold-boot headless as emulator-5554, wait for boot
adb devices
emu-down
```

The scripts export `ANDROID_SERIAL=emulator-$EMU_PORT` internally, so every `adb` call they make
targets their own emulator. Any `ANDROID_SERIAL` you set is overridden inside the scripts; use
`EMU_PORT` to pick the serial. Your own `adb` calls are not pinned: the bare `adb ...` examples
below assume `export ANDROID_SERIAL=emulator-5554` (see
[Targeting the emulator](#targeting-the-emulator-when-other-devices-are-attached)).

Single scripts without entering the shell: `nix run ~/dev/android-emu#emu-up`.

### Using the flake from another project

Pull the SDK and scripts into the project's own shell and add a JDK (AGP 8.x needs JDK 17).
This snippet was evaluated and `nix develop` on it gives `java`, `adb`, the `emu-*` scripts and
the variables below.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Pick one:
    android-emu.url = "git+file:///home/soham/dev/android-emu";
    # android-emu.url = "path:/home/soham/dev/android-emu";
    # android-emu.url = "github:<owner>/android-emu";
  };

  outputs = { self, nixpkgs, android-emu }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      emu = android-emu.packages.${system};
      sdkRoot = "${emu.sdk}/libexec/android-sdk";
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ emu.sdk emu.emu-up emu.emu-down emu.emu-shot pkgs.jdk17 ];
        ANDROID_HOME = sdkRoot;
        ANDROID_SDK_ROOT = sdkRoot;
        # Use the Nix-patched aapt2 instead of the one AGP downloads from Maven.
        GRADLE_OPTS = "-Dorg.gradle.project.android.aapt2FromMavenOverride=${sdkRoot}/build-tools/35.0.0/aapt2";
      };
    };
}
```

Notes:

- `git+file:` only sees files tracked by git, and Nix will not write a lock entry for it until
  the repo has a commit. `path:` copies the whole directory and locks it by hash.
- Do not add `android-emu.inputs.nixpkgs.follows = "nixpkgs"` unless you want it: a different
  nixpkgs revision means a different SDK store path and a fresh multi-GB download, and AVDs
  created from one SDK will resolve their image against whichever `ANDROID_SDK_ROOT` is set.

### Building and installing APKs

```sh
./gradlew assembleDebug
adb -s emulator-5554 install -r app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell am start -n com.example.app/.MainActivity
./gradlew installDebug          # installs on every connected device; see ANDROID_SERIAL below
```

NixOS gotchas:

- **aapt2 from Maven.** AGP downloads its own `aapt2` jar from Google Maven; the binary inside is
  linked for a generic FHS system. The usual fix is to point AGP at the SDK copy, which nixpkgs
  has patched (`$ANDROID_HOME/build-tools/35.0.0/aapt2 version` runs here):
  `-Pandroid.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/35.0.0/aapt2`, or the `GRADLE_OPTS` line
  above, or the same key in `~/.gradle/gradle.properties`. This host has `nix-ld` enabled
  (`/lib64/ld-linux-x86-64.so.2` → nix-ld), so the downloaded aapt2 *may* work as-is; the
  override is still the reproducible choice. **(unverified: no Gradle project built here)**
- **Read-only SDK.** AGP tries to install missing components (a build-tools version it prefers, a
  different `compileSdk` platform, NDK) into `ANDROID_HOME` and fails because the store is
  read-only. Keep `compileSdk = 35` and `buildToolsVersion = "35.0.0"`, or add what AGP wants to
  `flake.nix`. **(unverified: exact AGP error text and defaults)**

### Targeting the emulator when other devices are attached

`adb` without `-s` fails with `adb: more than one device/emulator` as soon as a USB phone is also
attached (verified: a phone is plugged into this host). The `emu-*` scripts
are unaffected because they pin their own serial. For your own commands, set the serial once
per shell:

```sh
export ANDROID_SERIAL=emulator-5554   # default for every adb command in this shell
adb -s <serial> shell ...              # per-command override (-s beats ANDROID_SERIAL)
adb -e shell ...                       # -e picks the only emulator (verified)
```

Gradle's `connected*`/`install*` tasks target all devices by default; AGP is documented to honour
`ANDROID_SERIAL` for this **(unverified)**.

### Logcat

```sh
adb logcat -c                                   # clear buffers
adb logcat -v color,time                        # colour + timestamps (default format: threadtime)
adb logcat MyTag:D ActivityManager:I '*:S'      # tag filters; '*:S' silences the rest
adb logcat -s MyTag                             # same as 'MyTag:V *:S'
adb logcat --pid="$(adb shell pidof -s com.example.app)"
adb logcat -b crash                             # crash buffer only (also: main, system, events, all)
adb logcat -d > app.log                         # dump and exit
adb logcat -T 100                               # last 100 lines, then follow
```

`ANDROID_LOG_TAGS` sets the default filter spec.

### Networking and port forwarding

- Guest addresses: `eth0` 10.0.2.15, `wlan0` 10.0.2.16 (verified).
- From the guest, `10.0.2.2` is the host's loopback, so a dev server on host `localhost:8080`
  is `http://10.0.2.2:8080` in the app.
- Port forwarding (`tcp:0` picks a free port):

```sh
adb forward tcp:9000 tcp:9000          # host:9000 -> device:9000 (e.g. a debug server in the app)
adb reverse tcp:8080 tcp:8080          # device:8080 -> host:8080 (lets the app use localhost:8080)
adb forward --list; adb reverse --list
adb forward --remove-all; adb reverse --remove-all
```

`adb reverse` is preferable to `10.0.2.2` when the same build also runs on a physical device.

### Screenshots and screen recording

```sh
emu-shot                         # -> ~/.local/state/android-emu/shot-YYYYmmdd-HHMMSS.png
emu-shot out.png
adb exec-out screencap -p > out.png       # what emu-shot does

adb shell screenrecord --time-limit 30 --bit-rate 8M /sdcard/rec.mp4   # Ctrl-C to stop early
adb pull /sdcard/rec.mp4 && adb shell rm /sdcard/rec.mp4
```

`screenrecord` defaults to a 180 s limit (`--time-limit 0` removes it). Recording works with the
software (SwiftShader) GPU **(unverified: no recording made)**.

### Instrumented tests

```sh
./gradlew connectedAndroidTest                      # build, install app + test APK, run, report
# reports: app/build/reports/androidTests/connected/

adb shell pm list instrumentation                   # find the runner component
adb shell am instrument -w com.example.app.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -e class com.example.FooTest#bar \
  com.example.app.test/androidx.test.runner.AndroidJUnitRunner
adb shell am instrument -w -r --no-window-animation ...   # raw output, no animations
```

`am instrument` flags above were checked against the guest's `am help`; the Gradle tasks and
runner names are the AGP/AndroidX defaults **(unverified: no project here)**. For CI-style runs
the `aosp_atd` / `google_atd` (Automated Test Device) images are leaner; see below.

### Other API levels and image types

The SDK is built by `pkgs.androidenv.composeAndroidPackages` in `flake.nix`. It deploys the
cross product of `platformVersions` × `systemImageTypes` × `abiVersions` that exists in nixpkgs'
`androidenv/repo.json`. To add images, extend the lists in `mkSdk`:

```nix
(pkgs.androidenv.composeAndroidPackages {
  platformVersions = [ "34" "35" "36" ];
  buildToolsVersions = [ "35.0.0" ];
  includeEmulator = true;
  includeSystemImages = true;
  systemImageTypes = [ "google_apis" "google_apis_playstore" "google_atd" ];
  abiVersions = [ "x86_64" ];
  includeNDK = false;
  # includeCmake = false;          # defaults to true on x86_64; cmake 4.1.2 is in the SDK today
  # extraLicenses = [ "android-sdk-preview-license" ];  # for preview images
}).androidsdk
```

x86_64 image types in the pinned `repo.json`:

| API | Types |
| --- | --- |
| 34 | `default google_apis google_apis_playstore aosp_atd google_atd android-wear` |
| 35 | the above plus `google_apis_ps16k google_apis_playstore_ps16k` |
| 36 | the above plus `android-tv android-wear-signed` |
| 36.1 | `google_apis google_apis_playstore google_apis_ps16k google_apis_playstore_ps16k android-wear-signed` |

`sdkmanager --list` shows more (tablet, desktop, XR, TV variants); those are not all in `repo.json`.
Each image is roughly a 1.6 GB download and 3.5 GB unpacked (API 35 `google_apis` x86_64).

`emu-up` always creates AVDs from the flake's single `apiLevel`/`imageType`. It never overwrites an
existing AVD, though, because it only creates one when `~/.android/avd/$EMU_NAME.ini` is missing. So
create other images by hand, and `emu-up` will boot them by name:

```sh
echo no | avdmanager create avd -n play-35 \
  -k "system-images;android-35;google_apis_playstore;x86_64" -d pixel_7
EMU_NAME=play-35 EMU_PORT=5556 emu-up
avdmanager list avd -c
avdmanager list device -c            # device profile ids for -d
```

An AVD you create by hand does not get emu-up's `config.ini` overrides (keyboard, 3 GB RAM, 6 GB data,
SwiftShader); edit them in yourself if you want them.

Image types:

- `default`: plain AOSP, no Google Play services.
- `google_apis`: Play services, no Play Store, `userdebug`, so `adb root` and `su` work (this
  flake's default).
- `google_apis_playstore`: Play Store, `user` build, so no `adb root`, no `-writable-system`
  remount, no `su`. Avoid it for system or kernel work.
- `*_ps16k`: 16 KB page-size kernels, for checking native library alignment.
- `aosp_atd`, `google_atd`: trimmed images for automated tests.

Licensing: `android_sdk.accept_license = true` accepts `android-sdk-license` only, which covers
the API 35 images including Play Store (per `repo.json`). Preview, TV and XR images use other
licenses and need `extraLicenses`. Google images and Play services are unfree and only licensed
for development and testing, so don't redistribute them, e.g. from a public binary cache.

### How the scripts behave

- **emu-up** exits 0 at once if `emulator-$EMU_PORT` is already running `$EMU_NAME`. Otherwise it
  polls `sys.boot_completed` for up to `EMU_BOOT_TIMEOUT` seconds (300 by default). If the
  emulator process exits first, it fails at once and prints the last 20 log lines.
- **emu-down** runs `adb emu kill` on its serial and waits up to 30 s. Then it sends SIGTERM via
  `pkill -f -- "-avd $EMU_NAME -port $EMU_PORT( |$)"`. That pattern only matches emulators
  started with `-avd` immediately followed by `-port` (as emu-up does), so for one you started
  by hand, pass a matching `EMU_NAME`/`EMU_PORT` or use `adb -s emulator-N emu kill`.
- **emu-shot** captures from its serial and deletes the output file and exits 1 if capture
  fails or the file is empty (verified, including with a USB phone attached).
- `-port N`: console port. N must be even and in 5554–5584; N+1 is the adb port and the serial is
  `emulator-N` (`-help-port`).

## 2. Android kernel development

### Stock kernel and modules

All of this is in `$ANDROID_HOME/system-images/android-35/google_apis/x86_64/` (read-only):

| File | Contents |
| --- | --- |
| `kernel-ranchu` | x86 bzImage, `6.6.50-android15-8-g8adecb593e9b-ab12525588` |
| `ramdisk.img` | lz4 (legacy) concatenated cpio: generic ramdisk + first-stage modules in `lib/modules/` (`virtio_blk virtio_console virtio_dma_buf virtio_pci virtio_pci_legacy_dev virtio_pci_modern_dev virtio-rng vmw_vsock_virtio_transport` + `modules.{load,dep,alias,softdep}`) |
| `vendor.img`, `system.img` | dynamic partitions; at runtime `/vendor/lib/modules` has 45 goldfish/virtio vendor modules and `/system_dlkm/lib/modules` has 93 GKI modules |
| `kernel_cmdline.txt` | `8250.nr_uarts=1 clocksource=pit` (merged into the cmdline) |
| `advancedFeatures.ini`, `VerifiedBootParams.textproto` | emulator feature flags, vbmeta digest |

Inspect the ramdisk:

```sh
img=$ANDROID_HOME/system-images/android-35/google_apis/x86_64
nix shell nixpkgs#lz4 -c lz4 -dc $img/ramdisk.img > /tmp/ramdisk.cpio
grep -aoE 'lib/modules/[A-Za-z0-9_.-]+' /tmp/ramdisk.cpio | sort -u
```

The running guest's command line (read with `adb shell su 0 cat /proc/cmdline`) contains
`bootconfig`. `androidboot.*` values go through bootconfig, not the cmdline.
The emulator writes the resolved kernel and ramdisk paths to `~/.android/avd/<name>.avd/hardware-qemu.ini`
(`kernel.path`, `disk.ramdisk.path`). `-help-kernel` still talks about `kernel-qemu`; for this image the file is
`kernel-ranchu`.

### Booting a custom kernel

`emu-up` can't pass extra emulator flags, so run `emulator` directly from the dev shell, using
the same flags as emu-up plus your own. Keep `-avd` and `-port` first and in that order so that
`EMU_NAME=... EMU_PORT=... emu-down` can still find the process.

Option A is the default AVD (stop it first; the kernel flags apply to that boot only):

```sh
emu-down
emulator -avd emu-35 -port 5554 -no-window -no-audio -no-boot-anim -no-metrics -no-snapshot \
  -gpu swiftshader_indirect -show-kernel \
  -kernel ~/src/android-kernel/out/dist/bzImage \
  -ramdisk ~/src/android-kernel/out/ramdisk-custom.img
```

Option B is a dedicated AVD, separate from the stock one. Use it when you also change `config.ini`
(e.g. `kernel.parameters`):

```sh
EMU_NAME=kdev EMU_PORT=5556 emu-up && EMU_NAME=kdev EMU_PORT=5556 emu-down   # create with emu-up's defaults
emulator -avd kdev -port 5556 -no-window -no-audio -no-boot-anim -no-metrics -no-snapshot \
  -gpu swiftshader_indirect -show-kernel -kernel ~/src/android-kernel/out/dist/bzImage
export ANDROID_SERIAL=emulator-5556
```

Both stay in the foreground with kernel messages on the terminal. Stop them with Ctrl-C or
`adb -s emulator-N emu kill`.

- `-kernel <file>`, `-ramdisk <file>`, `-show-kernel` (kernel messages on the terminal),
  `-no-snapshot` (full boot, no save) are listed by `emulator -help` (verified). The custom
  kernel and ramdisk flags were not tried on this host.
- `kernel.path` in the AVD's `config.ini` is the persistent equivalent of `-kernel` (the key is
  defined in the emulator's `hardware-properties.ini`).
- `-shell` gives a root console on the terminal that works without adbd; Ctrl-C kills the
  emulator.
- `-selinux permissive|disabled` and `-prop name=value` / `-append-userspace-opt key=value` set
  SELinux mode and boot properties.
- To change files in the system image directory (vendor image, `kernel_cmdline.txt`), copy it
  somewhere writable (`cp -r --no-preserve=mode $img ~/kdev-sysimg`) and pass `-sysdir ~/kdev-sysimg`
  **(unverified: precedence over the AVD's `image.sysdir.1`)**.

### Extra kernel command-line arguments

There is no dedicated emulator option for kernel arguments in `-help`/`-help-all`. Options:

1. **AVD config (recommended).** `hardware-properties.ini` defines `kernel.parameters`
   ("kernel boot parameters string"). Add it to the AVD's `config.ini`. When a key appears twice,
   the last occurrence wins (verified in `hardware-qemu.ini` on an AVD with duplicate keys):
   ```sh
   echo 'kernel.parameters=nokaslr loglevel=8' >> ~/.android/avd/kdev.avd/config.ini
   ```
   It is expected to be appended to the generated cmdline **(unverified)**. Check with
   `adb shell su 0 cat /proc/cmdline`.
2. **`-qemu -append "..."`.** The bundled QEMU accepts `-append` ("use 'cmdline' as kernel command
   line"), but the emulator already passes its own generated `-append`, so a second one will
   probably *replace* it and drop the emulator's arguments **(unverified)**. Avoid it.
3. Userspace properties don't need the cmdline: use `-prop` or `-append-userspace-opt`.

`-qemu` must be the last emulator option; everything after it goes to QEMU.

### Building an emulator-compatible kernel (unverified)

None of this was run on this host. API 35 uses the android15-6.6 GKI, and the virtual-device
(goldfish/ranchu) modules live in `common-modules/virtual-device`.

```sh
mkdir -p ~/src/android-kernel && cd ~/src/android-kernel
repo init -u https://android.googlesource.com/kernel/manifest -b common-android15-6.6
repo sync -c -j12

# Kleaf (Bazel), the supported path for 6.x kernels:
tools/bazel run //common-modules/virtual-device:virtual_device_x86_64_dist -- --destdir=out/dist
# out/dist: bzImage, vmlinux (with symbols), System.map, *.ko, initramfs.img, ...
```

- Legacy `build/build.sh` is deprecated and, for android14+ branches, largely removed:
  `BUILD_CONFIG=common-modules/virtual-device/build.config.virtual_device.x86_64 build/build.sh`.
  Use it only on old branches.
- The checkout and build take tens of GB. Kleaf uses hermetic prebuilt clang and tools that are
  dynamically linked for FHS distros; on NixOS they need `nix-ld` (enabled on this host) or a
  `buildFHSEnv` shell.
- To match the stock kernel exactly, use the build ID in the version string (`ab12525588`). Its
  artifacts, including `vmlinux`, should be on ci.android.com.

### Kernel/module ABI and replacing modules (unverified)

- Vendor modules (`/vendor/lib/modules`) and GKI modules (`/system_dlkm`) are built against a
  specific kernel. A custom kernel from the same branch keeps the KMI and can usually load the
  stock vendor modules. A kernel from another branch or config usually can't, and the guest then
  fails to bring up virtio block, input, GPU or networking devices.
- The robust approach is to build kernel and modules together and replace them all: the
  first-stage modules in the ramdisk (`-ramdisk`), the vendor modules (writable vendor below,
  or a rebuilt `vendor.img` via `-sysdir`), and `system_dlkm`.
- Rebuilding the ramdisk: the stock `ramdisk.img` is generic ramdisk + vendor ramdisk
  concatenated. Keep the generic part and append a cpio of your `lib/modules/` (the Kleaf dist
  `initramfs.img` plays the vendor-ramdisk role).

### Loading modules, root, writable system

`google_apis` is `userdebug`, so root is available. Play Store images are `user` builds where
none of this works.

```sh
emulator -avd kdev -port 5556 -no-window -no-audio -no-metrics -no-snapshot \
  -gpu swiftshader_indirect -writable-system &          # system/vendor become writable after remount
export ANDROID_SERIAL=emulator-5556
adb root                     # restart adbd as root
adb remount                  # may ask for a reboot first; then: adb reboot; adb root; adb remount
adb push mymod.ko /vendor/lib/modules/        # or /data/local/tmp for one-off tests
adb shell insmod /data/local/tmp/mymod.ko
adb shell lsmod; adb shell dmesg | tail
adb shell rmmod mymod
```

- `-writable-system` makes a temporary, large copy of the system image that is deleted when
  the emulator exits (per `-help-writable-system`). Start with it on every boot where you need
  the changes.
- Without `adb root`, `adb shell su 0 <cmd>` works on google_apis (`/system/xbin/su` exists;
  used read-only here).
- Out-of-tree modules must match the running kernel's `vermagic` and modversions. Build them
  against the same tree and config as the kernel, which for the stock kernel means the
  `ab12525588` build.
- The adb steps above (root, remount, insmod) were not run here, so as not to disturb the
  running emulator **(unverified)**.

### Debugging with gdb (QEMU gdbstub)

The bundled QEMU has the gdbstub. Its help strings include `-s` ("shorthand for -gdb tcp::1234"),
`-S` ("freeze CPU at startup") and `-gdb dev`.

```sh
echo 'kernel.parameters=nokaslr' >> ~/.android/avd/kdev.avd/config.ini

emulator -avd kdev -port 5556 -no-window -no-audio -no-metrics -no-snapshot \
  -gpu swiftshader_indirect -show-kernel -kernel out/dist/bzImage -qemu -s -S

# other terminal
gdb out/dist/vmlinux \
  -ex 'target remote :1234' \
  -ex 'hbreak start_kernel' \
  -ex 'continue'
```

Caveats **(unverified on this host)**:

- With KVM, prefer hardware breakpoints (`hbreak`; x86 has 4). Software breakpoints go through
  KVM guest-debug and are less reliable, particularly before the kernel maps its text or when
  set early with `-S`.
- KASLR moves the kernel, so boot with `nokaslr` or relocate symbols. Kleaf's `vmlinux` matches
  only the kernel built in the same run.
- While the guest is stopped, adb disconnects and watchdogs (RCU stall, hung task) may complain
  after resuming. Don't use emu-up's boot-wait with `-S`.
- `-wait-for-debugger` pauses the *emulator process* for a host debugger. It is not the guest
  gdbstub.

### What is practical on this host

- **Works well:** headless boots under KVM, custom `bzImage` from the same GKI branch, module
  loading on `google_apis` images, gdbstub with `hbreak` and `-show-kernel` console logs.
- **No window by default:** emu-up passes `-no-window`. `emu-up --window` or dropping
  `-no-window` opens a Qt window on the Wayland session. Otherwise use screenshots,
  `screenrecord`, or `scrcpy` (not in the flake: `nix shell nixpkgs#scrcpy`).
- **GPU is software:** `-gpu swiftshader_indirect` (it doesn't appear in `-help-gpu` but is
  accepted and resolves to `hw.gpu.mode = swiftshader` in `hardware-qemu.ini`). Graphics drivers
  and GPU-heavy apps are slow and don't represent real hardware.
- **No TCG fallback:** software CPU emulation is unsupported (`-accel off` errors unless
  `ANDROID_I_WANT_MY_TCG=yes`). Without `/dev/kvm` nothing boots.
- **ABI coupling:** the image's vendor and `system_dlkm` modules tie you to the android15-6.6
  KMI. Kernels from other branches need their own modules or a matching image. Upstream
  mainline kernels won't boot Android userspace without the Android patches and goldfish
  drivers.
- **No arm64 guests:** an arm64 guest needs TCG, so on this host use the x86_64 images.
  Apps with only arm64 native code still run through the image's ARM translation
  (`ro.product.cpu.abilist` = `x86_64,arm64-v8a`).
- **Snapshots:** emu-up passes `-no-snapshot`, so every start is a cold boot (about 20–25 s
  here) and no snapshot is written. Keep `-no-snapshot` in manual kernel runs so you never
  resume a snapshot taken under another kernel.
## Not verified locally

- Gradle/AGP builds, the `aapt2FromMavenOverride` fix and AGP's behaviour on a read-only SDK.
- Gradle honouring `ANDROID_SERIAL`; `connectedAndroidTest` report paths and runner names.
- `screenrecord` output under SwiftShader.
- Booting with `-kernel`/`-ramdisk`, `-sysdir` precedence, and whether `kernel.parameters`
  appends to or replaces the cmdline. `-qemu -append` replacing the emulator's cmdline.
- All kernel build steps (repo/Kleaf/legacy build.sh, outputs, disk usage, ci.android.com
  artifacts) and module ABI and ramdisk replacement.
- `adb root` / `adb remount` / `-writable-system` / `insmod` flow (not run, so the shared
  emulator wasn't disturbed).
- gdbstub session behaviour under KVM (`-s -S`, breakpoints, KASLR).
