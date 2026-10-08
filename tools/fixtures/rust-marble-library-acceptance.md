# Marble Library actual private acceptance

- Driver: `tools/test-marble-library-daemon.py` with production Library, raw HTTP client/cache, typed Rust client, and extracted unchanged production HTTP authority transport.
- Real schema30 daemon: `target/debug/gmgn-taskd`; build owned by root (77613 exit0).
- First actual run 31487 exited 1 at the original preparation assertion. It exposed Library requiring an `action` absent from command/read; source also used wrong activation op. Raw failure log: `/tmp/gmgn-marble-library-ed99370d-e50d-4ebf-aeed-2ad9aa00ae38.log`.
- Fixed production pending-task claim/complete identity verification and `activate_preset`; removed retired typed provider methods. Swift6 actual source typecheck exit0; diffcheck exit0.
- Actual rerun 67735 exited 0. Raw tool output/log: `/tmp/gmgn-marble-library-b1fda2c4-e1a1-47cd-a122-f1d58455e77f.log`.

Verified original assertions: refresh yields two account plus five public worlds; SQL-backed select and existing-preset activation; dropped successful receipt response recovers through identical receipt without redoing HTTP; actual provider connection loss retains unknown and blocks a new paid request; duplicate receipt idempotence; native key echo response never forwarded; restart recovers a persisted claimed action as unknown and does not execute it.

Read-only SQLite checks: schema version >=30, selected `catalog-dj`, three actual action rows with two persisted receipts; no fixture key in persisted receipts. Local provider counts: list=1, generate=1, asset=2, echo=1. All private daemon PID/process groups reaped with double-stop checks and temporary directory cleanup. No external provider, production app/database, audio or production credentials accessed.

Expanded actual run 89955 exited 0 using the central debug86725 binary containing the not-due journal fix. Raw tool log: `/tmp/gmgn-marble-library-e8d1996e-46a7-4b69-8381-923439b27492.log`. All earlier assertions reran unchanged. The production Library performed paid POST once, waited according to Rust waitMS, received a pending operation GET followed by a done GET, retrieved the exact response world ID (display name deliberately differs), and delivered a real native preparation failure without a fabricated manifest. SQL retained operation `operation-exact` and failed status with zero preset package bindings. Explicit resume performed operation/world/preparation-failure actions on that same operation without another paid POST.

Expanded read-only counts: eleven actual action rows, ten receipts; provider list=1, generate=2 (one connection-loss case plus one new generation), operation=3, world=2, asset=2, echo=1. Restart, unknown, and resume added no paid generation. Owned daemon PID/PG double-stop and temporary cleanup passed again. Production source stayed frozen throughout this expansion.

Boundary: cache bytes in this fixture only exercise the native copy leaf. Rust-controlled due polling and native preparation failure are covered. Real SPZ/GLB successful package construction/manifest registration is covered by the separate pipeline fixture, not this fixture.

## Dead provider rules retirement

Removed Swift Generate/Operation/list/world provider DTOs, provider decoder/default/order policy, public catalog data array, unused error cases and native UI generation-authoring fields. Native identity/assets/direct projection types and the display classification constant remain.

The original six `MarbleWorldClientTests` now execute real private Rust commands/claimed action bodies and provider fact receipts before native projection. Their image/text preset, progress42/error, asset ordering/semantics, preview and public HTTPS assertions remain. Standalone `--client-tests` uses the actual Swift Testing source, production transport/client/projection; only UI and unused fallback lifecycle are stubs. Actual log `/tmp/gmgn-marble-library-6364c71b-1885-4886-a048-729736e17b42.log`: 6/6 passed; read-only SQLite seven owners/seven action rows/six claims/four receipts/one queued next poll; no provider HTTP request.

Deleting the generic `MarbleWorld.Decodable` revealed its implicit use in `MarbleLivingCabinDocument`. That published local asset format now has a strict nested raw metadata codec and direct native mapper; it binds the manifest's explicit 500k resource and requires actual scale/offset, without provider quality/default rules. `tools/test-marble-cabin-integration.swift` passed with original assertions plus the actual bundled `marble.json` identity/semantic measurements and rejection of a missing fixed500k resource. No provider compatibility DTO was restored.

Combined actual run 25019 exited0 after these deletions: cabin integration passed, then the full Library rawHTTP/generation/resume/unknown/restart driver passed. Raw Library log `/tmp/gmgn-marble-library-8287ab9d-ee75-405b-9dc9-6988da6fa142.log`, same eleven actions/ten receipts/provider counts and double PID/PG cleanup as above.
