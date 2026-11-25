{
  description = "Headless Android emulator + SDK tooling, reusable across projects";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # The emulator binaries are only published for these hosts.
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f system);

      # Default device. The AVD name and console port can be overridden per
      # invocation with EMU_NAME / EMU_PORT (see emu-up); the API level and image
      # type are fixed here because the system image is part of the Nix build.
      apiLevel = "35";
      imageType = "google_apis";

      mkPkgs = system: import nixpkgs {
        inherit system;
        config = {
          android_sdk.accept_license = true;
          allowUnfree = true;
        };
      };

      abiFor = system: if system == "aarch64-darwin" then "arm64-v8a" else "x86_64";

      mkSdk = system:
        let pkgs = mkPkgs system;
        in (pkgs.androidenv.composeAndroidPackages {
          platformVersions = [ apiLevel ];
          buildToolsVersions = [ "35.0.0" ];
          includeEmulator = true;
          includeSystemImages = true;
          systemImageTypes = [ imageType ];
          abiVersions = [ (abiFor system) ];
          includeNDK = false;
        }).androidsdk;

      mkEmu = system:
        let
          pkgs = mkPkgs system;
          sdk = mkSdk system;
          sdkRoot = "${sdk}/libexec/android-sdk";
          # Shared prelude. ANDROID_SERIAL pins every adb call in the scripts to this
          # emulator, so they keep working when a physical device is also attached.
          env = ''
            export ANDROID_HOME="${sdkRoot}"
            export ANDROID_SDK_ROOT="${sdkRoot}"
            export ANDROID_AVD_HOME="''${ANDROID_AVD_HOME:-$HOME/.android/avd}"
            EMU_NAME="''${EMU_NAME:-emu-${apiLevel}}"
            EMU_PORT="''${EMU_PORT:-5554}"
            export ANDROID_SERIAL="emulator-$EMU_PORT"
            STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/android-emu"
            mkdir -p "$ANDROID_AVD_HOME" "$STATE_DIR"
          '';
          deps = [ sdk pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.procps ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.util-linux; # setsid
          mk = name: text: pkgs.writeShellApplication {
            inherit name text;
            runtimeInputs = deps;
          };
        in {
          emu-up = mk "emu-up" ''
            ${env}
            # Usage: emu-up [--window]   (headless by default)
            window_args=(-no-window)
            if [[ "''${1:-}" == "--window" ]]; then window_args=(); fi

            if [[ ! -f "$ANDROID_AVD_HOME/$EMU_NAME.ini" ]]; then
              echo "Creating AVD $EMU_NAME"
              echo no | avdmanager create avd -n "$EMU_NAME" \
                -k "system-images;android-${apiLevel};${imageType};${abiFor system}" \
                -d pixel_7 >/dev/null
              # Override avdmanager's defaults in place (the emulator takes the last
              # duplicate key, but keeping one copy keeps config.ini readable).
              cfg="$ANDROID_AVD_HOME/$EMU_NAME.avd/config.ini"
              set_cfg() { sed -i "/^$1=/d" "$cfg"; echo "$1=$2" >> "$cfg"; }
              set_cfg hw.keyboard yes
              set_cfg hw.ramSize 3072
              set_cfg disk.dataPartition.size 6G
              set_cfg hw.gpu.enabled yes
              set_cfg hw.gpu.mode swiftshader_indirect
            fi

            if adb get-state >/dev/null 2>&1; then
              running="$(adb emu avd name 2>/dev/null | head -n1 | tr -d '\r')"
              if [[ "$running" == "$EMU_NAME" ]]; then
                echo "$EMU_NAME is already running as $ANDROID_SERIAL"; exit 0
              fi
              echo "$ANDROID_SERIAL is taken by AVD '$running'; pick another even EMU_PORT (5556, 5558, ...)" >&2
              exit 1
            fi

            log="$STATE_DIR/$EMU_NAME.log"
            echo "Starting $EMU_NAME as $ANDROID_SERIAL (log: $log)"
            # -no-snapshot: always cold boot (about 25s) and never write a snapshot,
            # so every run starts from the same clean state.
            launcher=(nohup)
            if command -v setsid >/dev/null; then launcher=(setsid nohup); fi
            "''${launcher[@]}" emulator -avd "$EMU_NAME" -port "$EMU_PORT" "''${window_args[@]}" \
              -no-audio -no-boot-anim -no-metrics -no-snapshot -gpu swiftshader_indirect \
              >"$log" 2>&1 < /dev/null &
            pid=$!

            echo -n "Waiting for boot"
            limit="''${EMU_BOOT_TIMEOUT:-300}"
            SECONDS=0
            while (( SECONDS < limit )); do
              if ! kill -0 "$pid" 2>/dev/null; then
                echo " emulator exited. Last log lines:" >&2; tail -n 20 "$log" >&2; exit 1
              fi
              if [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
                echo " ready after ''${SECONDS}s ($ANDROID_SERIAL)"; exit 0
              fi
              echo -n "."; sleep 2
            done
            echo " timed out after ''${limit}s; see $log" >&2; exit 1
          '';

          emu-down = mk "emu-down" ''
            ${env}
            # Matches the qemu process emu-up started for this AVD and port.
            pattern="-avd $EMU_NAME -port $EMU_PORT( |$)"
            adb emu kill >/dev/null 2>&1 || true
            for _ in $(seq 1 30); do
              if ! adb get-state >/dev/null 2>&1 && ! pgrep -f -- "$pattern" >/dev/null; then
                echo "$EMU_NAME stopped"; exit 0
              fi
              sleep 1
            done
            echo "$EMU_NAME did not exit after 'adb emu kill'; sending SIGTERM" >&2
            pkill -f -- "$pattern" || true
          '';

          emu-shot = mk "emu-shot" ''
            ${env}
            # Usage: emu-shot [out.png]
            out="''${1:-$STATE_DIR/shot-$(date +%Y%m%d-%H%M%S).png}"
            mkdir -p "$(dirname "$out")"
            if ! adb exec-out screencap -p > "$out" || [[ ! -s "$out" ]]; then
              rm -f "$out"; echo "screencap failed on $ANDROID_SERIAL" >&2; exit 1
            fi
            echo "$out"
          '';
          inherit sdk;
        };
    in {
      packages = forAll mkEmu;

      devShells = forAll (system:
        let
          pkgs = mkPkgs system;
          emu = mkEmu system;
          sdkRoot = "${emu.sdk}/libexec/android-sdk";
        in {
          default = pkgs.mkShell {
            packages = builtins.attrValues emu;
            ANDROID_HOME = sdkRoot;
            ANDROID_SDK_ROOT = sdkRoot;
          };
        });
    };
}
