//! Offline world-authority tooling.
//!
//! `gmgn-taskd world-import` / `gmgn-taskd world-dump` open the *same* private
//! root and database as the daemon, but take the daemon's exclusive `taskd.lock`
//! first: they refuse to run while `gmgn-taskd` is running, so there is never a
//! second writer. This is the one-command path used by the migration evidence
//! (`docs/plans/2026-10-02-rust-world-authority-and-mcp.md`): import the exported
//! `state.json` bundle once, then dump the authoritative snapshot to compare
//! field by field.

use crate::{files, store, world};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

fn flag(args: &[String], name: &str) -> Option<String> {
    let mut index = 0;
    while index < args.len() {
        if args[index] == name {
            return args.get(index + 1).cloned();
        }
        index += 1;
    }
    None
}

fn required(args: &[String], name: &str) -> Result<String, String> {
    flag(args, name).ok_or_else(|| format!("missing {name}"))
}

fn absolute(raw: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(raw);
    if !path.is_absolute() {
        return Err(format!("{raw} must be an absolute path"));
    }
    Ok(path)
}

/// Open the private root with the daemon's exclusive lock held. The lock is
/// returned so it lives as long as the command: dropping it releases the root.
fn open_root(root: &Path) -> Result<(store::Database, std::fs::File), String> {
    files::directory(root).map_err(str::to_owned)?;
    let lock = files::open_private(&root.join("taskd.lock")).map_err(str::to_owned)?;
    fs2::FileExt::try_lock_exclusive(&lock)
        .map_err(|_| "already_running: gmgn-taskd holds the private root".to_owned())?;
    let database = store::Database::open(root.to_path_buf(), None).map_err(str::to_owned)?;
    Ok((database, lock))
}

fn runtime() -> Result<tokio::runtime::Runtime, String> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|_| "runtime_unavailable".to_owned())
}

/// `world-import --root <dir> --bundle <worlds.json> [--producer import]`
///
/// The bundle is the canonical payload produced by
/// `tools/world-migration/world_state_migration.py canonicalize`. The import is
/// idempotent by content: running it twice leaves one record set.
pub fn world_import(args: &[String]) -> Result<i32, String> {
    let root = absolute(&required(args, "--root")?)?;
    let bundle = absolute(&required(args, "--bundle")?)?;
    let producer = flag(args, "--producer").unwrap_or_else(|| "import".to_owned());
    let out = flag(args, "--out");
    let payload: Value = serde_json::from_slice(
        &std::fs::read(&bundle).map_err(|error| format!("bundle unreadable: {error}"))?,
    )
    .map_err(|error| format!("bundle is not JSON: {error}"))?;
    let worlds = payload
        .get("worlds")
        .and_then(Value::as_array)
        .ok_or_else(|| "bundle has no worlds[]".to_owned())?
        .clone();
    let bundle_digest = payload
        .get("bundleSha256")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();

    let (database, _lock) = open_root(&root)?;
    let runtime = runtime()?;
    let mut results = Vec::new();
    for entry in worlds {
        let world_id = entry
            .get("worldID")
            .and_then(Value::as_str)
            .ok_or_else(|| "world entry has no worldID".to_owned())?
            .to_owned();
        let request = world::ImportRequest {
            world_id: world_id.clone(),
            request_id: format!("migration:{}", bundle_digest),
            producer: Some(producer.clone()),
            package_id: entry
                .get("packageID")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned(),
            package_version: entry
                .get("packageVersion")
                .and_then(Value::as_str)
                .unwrap_or("unknown")
                .to_owned(),
            state_sha256: entry
                .get("stateSha256")
                .and_then(Value::as_str)
                .ok_or_else(|| "world entry has no stateSha256".to_owned())?
                .to_owned(),
            state_json: entry
                .get("stateJson")
                .and_then(Value::as_str)
                .ok_or_else(|| "world entry has no stateJson".to_owned())?
                .to_owned(),
        };
        let result = runtime.block_on(database.call(move |store| {
            let transaction = store
                .connection
                .transaction()
                .map_err(|_| "storage_unavailable")?;
            let result = world::import(&transaction, &request)?;
            transaction.commit().map_err(|_| "storage_unavailable")?;
            store.changed.send_modify(|value| *value = value.wrapping_add(1));
            Ok(result)
        }))
        .map_err(str::to_owned)?;
        let mut entry = result;
        entry["worldID"] = json!(world_id);
        results.push(entry);
    }
    let report = json!({
        "tool": "gmgn-taskd world-import",
        "root": root.to_string_lossy(),
        "bundle": bundle.to_string_lossy(),
        "bundleSha256": bundle_digest,
        "worlds": results,
    });
    write_report(&report, out.as_deref())?;
    Ok(0)
}

/// `world-dump --root <dir> [--out <file>]`
///
/// Dumps every authoritative world snapshot, including the materialized
/// `state.json`-shaped document. This is exactly what
/// `world_state_migration.py compare` consumes.
pub fn world_dump(args: &[String]) -> Result<i32, String> {
    let root = absolute(&required(args, "--root")?)?;
    let out = flag(args, "--out");
    let (database, _lock) = open_root(&root)?;
    let runtime = runtime()?;
    let dump = runtime
        .block_on(database.call(|store| {
            let mut statement = store
                .connection
                .prepare(
                    "SELECT world_id FROM world_records WHERE domain=?1 ORDER BY world_id",
                )
                .map_err(|_| "storage_unavailable")?;
            let world_ids = statement
                .query_map([world::WORLD_DOMAIN], |row| row.get::<_, String>(0))
                .map_err(|_| "storage_unavailable")?
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| "storage_unavailable")?;
            drop(statement);
            let mut worlds = Vec::new();
            for world_id in world_ids {
                let snapshot = world::snapshot(
                    &store.connection,
                    &world::SnapshotRequest {
                        world_id: world_id.clone(),
                        include_state: Some(true),
                    },
                )?;
                let mut record = snapshot["record"].clone();
                let (facts, last_seq) = world::read_facts(
                    &store.connection,
                    &world::FactsRequest {
                        world_id: world_id.clone(),
                        after: Some(0),
                        limit: Some(world::MAX_READ_LIMIT),
                    },
                )?;
                let imports: Option<(String, String, String, i64)> = store
                    .connection
                    .query_row(
                        "SELECT package_id, package_version, source_hash, imported_at_ms
                         FROM world_imports WHERE world_id=?1",
                        [&world_id],
                        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                    )
                    .ok();
                record["worldID"] = json!(world_id);
                record["factCount"] = json!(facts.len());
                record["lastFactSeq"] = json!(last_seq);
                record["factKinds"] = json!(facts
                    .iter()
                    .map(|fact| fact["kind"].clone())
                    .collect::<Vec<_>>());
                if let Some((package_id, package_version, source_hash, imported_at)) = imports {
                    record["import"] = json!({
                        "packageID": package_id,
                        "packageVersion": package_version,
                        "sourceSha256": source_hash,
                        "importedAtMs": imported_at,
                    });
                }
                worlds.push(record);
            }
            Ok(json!(worlds))
        }))
        .map_err(str::to_owned)?;
    let report = json!({
        "tool": "gmgn-taskd world-dump",
        "root": root.to_string_lossy(),
        "worlds": dump,
    });
    write_report(&report, out.as_deref())?;
    Ok(0)
}

fn write_report(report: &Value, out: Option<&str>) -> Result<(), String> {
    let text = serde_json::to_string_pretty(report).map_err(|_| "report_unserializable")?;
    match out {
        Some(path) => std::fs::write(path, text).map_err(|error| format!("cannot write {path}: {error}")),
        None => {
            println!("{text}");
            Ok(())
        }
    }
}
