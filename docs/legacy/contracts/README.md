# Legacy contracts (moved 2026-09-27)

These two JSON Schema files were written for the 2026-07-28 initial design
(`docs/plans/2026-07-28-gmgn-radio-implementation.md`) when the product was an
AI radio. They are kept here for historical reference only.

**Nothing in this repository validates against them, and they have diverged
from what ships.**

Evidence at the time of the move:

- No source file references `dj-event.schema.json` or `dj-tools.schema.json`.
  A repository-wide search over `*.swift`, `*.rs`, `*.py`, `*.mjs` and the
  `Makefile` returns no match; the only mentions were in `docs/`.
- There is no JSON Schema validator dependency in `Cargo.toml` or in the Swift
  packages.
- Fields the event schema requires do not appear in the implementation:
  `occurred_at`, `correlation_id`, `user_speech_started`, `privacy_disabled`
  have zero matches in first-party source.
- The tool schema enumerates 10 tool names. The shipped dispatcher
  (`apps/macos/Sources/GMGNRadio/Agent/DJAgentToolDispatcher.swift`) defines 18,
  and the two lists intersect on exactly one name: `search_music`.

They were moved out of the repository root so that an unenforced, drifted
schema is not mistaken for a live contract. If a typed boundary between the
client, `gmgn-taskd` and the agent backends is wanted later, that boundary
should be generated from, and tested against, the code that actually runs.
