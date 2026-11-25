# API level picked at run time

- `lib.mkEmu { system; apiLevels = [ ... ]; }` builds an SDK with several system images; `EMU_API` chooses which one `emu-up` creates and boots.
- Default AVD name is `emu-$EMU_API`; the flake's own packages and dev shell are unchanged (API 35 only, same SDK store path).
- Rationale: see ADR [2026-11-24-1742-api-levels-chosen-by-consumer](../adr/2026-11-24-1742-api-levels-chosen-by-consumer.md)
