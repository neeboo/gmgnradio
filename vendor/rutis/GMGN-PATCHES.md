# GMGN embedding patches

Upstream: https://github.com/arcships/rutis
Revision: 330ff51b65c0178ab205abb377f6d9dbcd7225fd
License: MIT (LICENSE retained; upstream headers retained).

Only the rutis and rutis-agent crates are vendored. Node, Python, the CLI and
rutis-dsh are not included. The reduced workspace manifest preserves upstream
package metadata and shared dependency versions.

Changes will be recorded here with their regression tests. No changes are made
to global Cargo caches or the Applications production bundle.

1. Make the six TUI dependencies optional, gate TuiPlugin/module and the two
   TUI examples behind the tui feature. Upstream-compatible defaults retain
   tui; GMGN disables defaults. The model/tool driver remains upstream code.

2. Race LanguageModel::do_stream initialization against the turn cancellation
   token, using a biased tokio select. Cancelling while HTTP/SSE establishment
   is pending returns AgentError::Stopped and drops the pending future. This
   does not imply reversal of external side effects.

3. Require at least one StreamPart::Finish before accepting stream EOF.
   EOF without Finish returns AgentError::Llm("stream_ended_without_finish")
   before assistant history is written or collected tool calls are executed.
   Existing stream errors and explicit cancellation retain their original
   error outcomes. No new retry behavior is introduced.

Baseline: the exact unpatched Git revision passed three wrapper tests and
two negative controls demonstrating (2) and (3). The baseline boundary binary
was rerun with exit 0; log /tmp/gmgn-rutis-upstream-boundaries-baseline.log.
Patched regressions live in services/gmgn-agent-runtime/tests/upstream_boundaries.rs:
pending establishment cancellation, incomplete text EOF rejection, and no tool
execution after incomplete EOF. Tests use ScriptedLlm and local in-memory
fixtures only, with no model network calls or production data.

Patched verification: cargo +1.95.0 test -p gmgn-agent-runtime --locked --offline
-j 1 passed all three wrapper tests and three regression tests (exit 0).
Log: /tmp/gmgn-rutis-runtime-patched-tests.log.

4. Add ToolExecutionContext (the full model ToolCall plus CancellationToken)
   and ToolDef::new_contextual. Existing new/from_function_tool constructors
   and their argument-only runners remain available. ToolRegistry dispatches
   contextual runners when present, rejects already-cancelled calls, gives
   cancellation priority, and rechecks cancellation before returning success.
   Repository search found no ToolDef struct-literal construction; this adds
   a public field, so downstream struct literals outside this repository would
   need that field. Constructor APIs retain source compatibility.

GMGN contextual seam verification: 10 runtime tests passed with exit 0 via
cargo +1.95.0 test -p gmgn-agent-runtime --locked --offline -j 1.
Log: /tmp/gmgn-rutis-host-context-final-tests.log. Host mocks cover trusted
world/scope/session/run identity, strict receipt call-ID matching, stale session,
unknown/error/panic outcomes, receipt after cancellation, token propagation,
duplicate host run rejection, and rejection of legacy tools in GMGN wrappers.
