# Rust music cache private acceptance

Command: `python3 tools/test-rust-music-cache-daemon.py --daemon /Users/ghostcorn/.codex/worktrees/rust-full-migration/gmgnradio/target/debug/gmgn-taskd`

Actual execution handle: 90344. Exit code: 0.

Readable log: `/tmp/gmgn-music-cache-f5a495ec-e1db-413f-80c3-93e2abab78f9.log`.

The fixture compiles the production `RustMusicCacheClient`, `StreamingMusicCache`, provider HTTP leaf and actual Taskd HTTP transport. The provider leaf returns private byte facts without contacting a provider or audio device; every cache transition executes against the real schema32 daemon and SQLite database.

Observed download count: 3 (first Netease file, replacement of a deliberately corrupted ready file, separate QQ identity). Cache hits and a changed M4A address for the same ready track do not download again. Real file hashes are independently checked by Rust: an incorrect hash is rejected, a matching duplicate completion remains ready, and an HTML file with a correct hash plus forged `audioValid: true` does not publish.

After an actual daemon restart, claimed actions remain unknown. Neither a new request ID nor another claim authorizes a download; a foreign host session cannot read the action. Final SQL readback: `ready=3`, `unknown=2`. SQL dump contains no signed source URL, provider host or Cookie value.

Cleanup executes for both owned daemons, asserting process exit and absent owned process group. The canonical temporary root is removed. The fixture does not print numeric daemon PIDs; its process-group cleanup assertions are part of the successful run.

The first private run exposed Foundation standardization changing a canonical `/private/var` directory to `/var`. Production path checks now use POSIX `realpath`, exact direct-child paths and `lstat` regular-file checks. Rust's canonical path and byte validation rules were not relaxed.

Scope: cache authority and file facts only. This is not audio-device playback, provider login, or formal application acceptance.
