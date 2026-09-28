# VoiceMem selective Rust port — provenance and notices

Scope: the durable world/resident memory layer implemented in
`services/gmgn-taskd/src/memory.rs` and exercised by
`services/gmgn-taskd/tests/local_memory_process.py`.

## VoiceMem (semantic reference)

- Reference repository: https://github.com/xzf-thu/VoiceMem
- Reference commit: `a450911fc8cbb44c46d810aace2f3288bad287e4`
- License: Apache-2.0.

This port takes **semantic concepts only** — no upstream source text is copied.
The specific semantics and the porting deviations are frozen in
`docs/plans/2026-09-08-voicemem-rust-contract.md` §9. Ported semantics map to
these upstream paths (inspected at the pinned commit):

- `web/session_context.py` — `SessionBuffer`: turns remain usable (pending)
  until a durable memory commit confirms them, then are cleared
  (commit-after-durability); interrupted-reply marker and per-session/space
  isolation.
- `voicemem/leftbrain/extract_facts_openai.py` — additive fact extraction with
  junk filtering; one-off requests and assistant self-statements are not
  memories; attribute-conflict corrections keep a replacement interface.
- `voicemem/leftbrain/memory_repository.py` and `memory_repository_v2.py` —
  bounded fact consolidation and `update_memory` correction.
- `voicemem/orchestrator.py` (`Ingest`/`_finish_ingest`) and
  `voicemem/rightbrain/brain.py` (`RightBrain.write`) +
  `experience_repository.py` — grounded relationship/experience notes.
- `voicemem/leftbrain/merged_extraction.py` — transient single-occurrence mood
  must not be promoted to a stable personality trait.

Selective-port deviations (this implementation, not a full VoiceMem port):
two-section single versioned snapshot replaces left-brain mem0/Qdrant plus
right-brain graph storage; snapshot-style whole-section consolidation with an
explicit `removed` list replaces a pure additive append stream; no audio /
voiceprint / scene / multi-speaker handling; no real user database access or
model-weight downloads; vector storage is sqlite-vec (below) instead of
mem0/Qdrant. The external compaction/embedding service layer of the original
port was removed from this daemon: the semantic snapshot tables and the
vector-generation ledger stay in place, but nothing writes vectors any more
and no provider is called.

## sqlite-vec

- Crate: `sqlite-vec`, pinned `=0.1.9` (crates.io maximum stable; alphas
  rejected). https://github.com/asg017/sqlite-vec
- License: MIT/Apache-2.0 (dual). Vendored `sqlite-vec.c` is compiled
  statically with `SQLITE_CORE` and registered process-wide via
  `sqlite3_auto_extension` before any SQLite connection opens.
- Redistribution notices for sqlite-vec and its vendored sources are
  reproduced in the crate (`LICENSE`) and apply as delivered by crates.io.

## Project license

The surrounding gmgn-taskd code remains under the repository's existing
LICENSE (see `LICENSE` at the repository root); this directory adds no
separate license and derives no copyrighted text from VoiceMem.
