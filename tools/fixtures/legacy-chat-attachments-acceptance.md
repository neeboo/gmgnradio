# Legacy native attachment consumers — actual private authority acceptance

Worktree: `/Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio`.
Root-verified daemon: `target/debug/gmgn-taskd`, central schema27 build 22429 (root reports build exit 0).
Evidence logs: `/private/tmp/gmgn-legacy-attachments.sJPDDj/`.

All runs used `tools/test-rust-chat-attachments-daemon.py --run --daemon /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio/target/debug/gmgn-taskd`. The shared driver creates a canonical private root with private SQLite/endpoint/random port/token, reads the actual schema and authority rows, and kills/waits its exact process group in `finally`. Tokens are never printed.

| Consumer arguments | Exit | Real SQLite verification | Exact daemon recovery | Log |
| --- | --- | --- | --- | --- |
| `--consumer-source tools/test-resident-image-attachments.swift --consumer-source tools/fixtures/PrivateAttachmentWindow.swift` | 0 | 2 owners / 3 durable submission bindings | PID 44738, TERM exit -15, PID and group gone | `resident-evidence.log` |
| `--consumer-source tools/test-unity-chat-images.swift --consumer-source tools/fixtures/PrivateAttachmentWindow.swift` | 0 | 1 owner / 1 durable submission binding | PID 44865, TERM exit -15, PID and group gone | `images-evidence.log` |
| `--consumer-source tools/test-unity-chat-image-drop.swift --consumer-source tools/fixtures/PrivateAttachmentWindow.swift` | 0 | 2 owners / 1 durable submission binding | PID 44342, TERM exit -15, PID and group gone | `drop.log` |
| `--consumer-script tools/test-stage-resident-chat.swift` | 0 | 10 owners / 15 durable submission bindings; **197 original assertions / 0 failures** | PID 44801, TERM exit -15, PID and group gone | `stage-final.log` |

The three native executable consumers compiled in Swift 6. Stage also type-checks extracted real SwiftUI source and compiles/runs its original harness in its existing language mode; it emits a production `WishMachineTaskPresentationStore` default-argument actor-isolation warning, so this is **not** a Swift 6 Stage pass. Settings dependencies are explicitly wired to the same private RPC rather than default application endpoints.

Retained assertions cover image-only submission, paste classification, valid native PNG pixels and private 0600 copies, four-image admission, over-limit restoration of genuinely issued refs, unknown/unowned restoration rejection, generation fencing, mixed/nonimage drops, reentrant preparation, cancellation, asynchronous removal/close, original image retention, submitted image retention, and late restoration of Stage/Live Cam drafts without duplicating or overwriting newer text.

First resident/images attempts failed because fixture child directory URLs omitted `isDirectory: true`, making the production exact parent-directory URL comparison reject the reply. The fixtures now supply actual directory facts, with no production validator weakening. Full original assertions were rerun successfully; failure logs `resident.log` and `images.log` remain. Stage initially failed compilation after another worker added the real product settings dependency; the fixture now includes that production client and explicitly injects private settings RPC. No assertions were removed.

`test-unity-chat-image-picker.swift` and `test-unity-chat-image-drop-appkit.swift` were **compile-only** (both exit 0), logs `picker-compile.log` and `appkit-drop-compile.log`. Their temporary window/sheet cases were not executed during the user's meeting. No formal App, provider, audio, credentials, or user database was accessed.

Post-run `ps -p 44342,44738,44801,44865 -o pid=,args=` returned no rows. Shared driver checks each exact PID and process group after wait; fixture roots were removed by their owning temporary-directory contexts.
