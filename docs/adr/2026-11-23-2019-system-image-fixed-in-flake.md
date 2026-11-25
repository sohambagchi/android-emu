# System image fixed in the flake

**Status:** superseded by [2026-11-24-1742-api-levels-chosen-by-consumer](2026-11-24-1742-api-levels-chosen-by-consumer.md)

**Context:** The SDK and system image are built by Nix, so the device can't be chosen freely at run time.
**Decision:** API level (35), image type (`google_apis`) and ABI are set in `flake.nix`. Only the AVD name (`EMU_NAME`) and console port (`EMU_PORT`) vary per invocation.
**Alternatives:** download images at run time with `sdkmanager` — breaks the read-only, reproducible SDK.
**Consequences:** another API level or image type means editing `flake.nix` and rebuilding the SDK.
