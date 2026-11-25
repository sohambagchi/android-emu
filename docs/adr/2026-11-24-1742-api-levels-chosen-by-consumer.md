# API levels chosen by the consuming flake, picked at run time

**Status:** accepted

**Context:** Projects need images other than API 35 (screen-scratch needs Android 12). Images must be in the Nix-built SDK before they can boot.
**Decision:** `lib.mkEmu { system; apiLevels; imageType; }` builds an SDK with every listed API level plus the `emu-*` scripts. `EMU_API` picks one at run time (default: the first listed) and the default AVD name follows it (`emu-$EMU_API`). The flake's own packages still build `[ "35" ]` only.
**Alternatives:** One flake output per API level — duplicates the scripts and the SDK per level. Downloading images with `sdkmanager` at run time — breaks the read-only, reproducible SDK.
**Consequences:** Each listed level adds ~1.5 GB. An `EMU_API` outside the list fails fast with the levels that were built.
