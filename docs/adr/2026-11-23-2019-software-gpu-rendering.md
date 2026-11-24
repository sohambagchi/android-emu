# Software GPU rendering

**Status:** accepted

**Context:** The emulator must run headless and on hosts without a usable GPU.
**Decision:** Render with SwiftShader (`-gpu swiftshader_indirect`, `hw.gpu.mode=swiftshader_indirect`).
**Alternatives:** host GPU passthrough — needs a display and matching host drivers.
**Consequences:** 3D and animations are slow and don't represent real hardware.
