//! P-B1：blob 的**读时校验**（只读影子层）。
//!
//! 为什么单独一个模块、而不改 [`crate::world`]：`world_blobs` 是那张
//! 内容寻址的权威表（`sha256` 即主键），写入侧（`world::blob_put`）已经很严
//! ——它核验哈希、拒绝越出私根的路径、同内容第二次写不产生第二行。**缺的
//! 全在读的一侧**：`world::blob_get` 只把 `local_path` 从行里取出来就返回，
//! 既不 `stat` 也不重算 sha256。于是"行在、文件被删或被截断"会让调用方
//! **看起来成功**，一直到渲染那一步才炸。
//!
//! 这正是用户点名要消灭的形状（原话："**文件缺失必须可见**"，以及更早的
//! "绝不出现「状态说已入库而东西不在」"）。本模块把"这份字节到底在不在、
//! 还是不是当初那份"变成一个**显式状态**，而不是一个隐含的成功：
//!
//! * [`BlobState::Present`] —— 文件在，且重算的 sha256 与声明**逐位相等**；
//! * [`BlobState::Missing`] —— 行在，文件不在（或不是普通文件）；
//! * [`BlobState::Corrupt`] —— 文件在，但字节数与/或哈希与声明不符；
//! * [`BlobState::NotLocal`] —— 从来没有本地副本（只有云端），**不是损坏**。
//!
//! **为什么 `NotLocal` 必须与 `Corrupt` 分开**：前者是"去取回来"（网络/按需
//! 下载），后者是"这份数据出问题了"（必须告警、并且**不得**当成可用）。把两者
//! 混成一个 `unavailable` 会让用户看到"文件坏了"而其实是"还没下载"，也会让
//! 真正的损坏藏在一堆正常的按需下载里——这正是 fail-closed 的反面。
//!
//! **只读纪律**：本模块**从不**写文件、**从不**删除、**从不**修改任何表。
//! 它只 `stat`/`read` 磁盘、只 `SELECT` 数据库。因此它可以安全地跑在
//! 生产库上做体检，也可以被 harness 直接调用。
//!
//! 设计出处：`docs/plans/2026-10-02-memory-and-generation-results-in-rust.md`
//! §4.2(1-补) 与 §8 的 **B-2**。

// 为什么整个模块允许 dead_code：这是 P-B1 的**只读影子层** —— 先让"读时校验"
// 以可测试、可断言的形式存在于 Rust 里，再由 harness / 体检命令 / 将来的
// `blob_get` 调用它。此刻生产路径还没有调用方（改 `world.rs` 的读路径归那条线，
// 见上文 F4），所以 `verify_*` 只有测试在用。这与 `memory.rs` 里
// `#![allow(dead_code)]` 的理由同型（那份是"留在 Rust 里的本地记忆，等实现接手"）。
// **新增的死代码请单独处理，不要依赖这条豁免。**
#![allow(dead_code)]

use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::path::Path;

/// 一份 blob 的本地状态。**四态**，`NotLocal` 与 `Corrupt` 不合并（见模块文档）。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BlobState {
    /// 文件在，且重算哈希与声明相等。
    Present,
    /// 行在，本地文件不在了。**可见的失败**，不是"没有这份数据"。
    Missing,
    /// 文件在，但字节数或哈希与声明不符。**必须告警**，绝不当成可用。
    Corrupt,
    /// 从来没有本地副本（只有 `remote_key`）。这不是错误，是"按需取回"。
    NotLocal,
}

impl BlobState {
    pub fn as_str(self) -> &'static str {
        match self {
            BlobState::Present => "present",
            BlobState::Missing => "missing",
            BlobState::Corrupt => "corrupt",
            BlobState::NotLocal => "not_local",
        }
    }

    /// 这份 blob 现在能不能被当成可用字节。
    ///
    /// 只有 `Present` 是。`NotLocal` 也不可用——它需要一次取回，
    /// 而"需要取回"与"可用"是两件事（否则调用方会拿着一个不存在的路径去渲染）。
    pub fn is_usable(self) -> bool {
        matches!(self, BlobState::Present)
    }

    /// 是不是"这份数据出问题了"（需要告警，而不是"去下载"）。
    pub fn is_damage(self) -> bool {
        matches!(self, BlobState::Missing | BlobState::Corrupt)
    }
}

/// 一次校验的完整结果。**带证据**，让界面/日志能说出**为什么**不可用。
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct BlobVerification {
    pub sha256: String,
    pub state: BlobState,
    /// 行里声明的字节数。
    pub declared_bytes: i64,
    /// 实际读到的字节数（读不到则 `None`）。
    pub actual_bytes: Option<u64>,
    /// 实际重算的 sha256（只在文件可读时有值）。
    pub actual_sha256: Option<String>,
    /// 行里的本地路径（原样回显，供调用方/界面定位）。
    pub local_path: Option<String>,
    /// 云端 object key（有 ⇒ `NotLocal` 时可以说"可从未上云/已上云取回"）。
    pub remote_key: Option<String>,
    /// 可读的原因。**四态都有**，因为"为什么是 present"同样是证据。
    pub reason: String,
    /// 建议的下一步（给界面用；不是自动动作）。
    pub remedy: &'static str,
}

/// 校验**一份** blob。
///
/// * `root` 给定时，`local_path` 必须落在 `root` 里；越界**不**降级成 `Missing`，
///   而是 `Corrupt` + `blob_outside_private_root` —— 一份指向私根之外的 blob 行
///   是**描述坏了**，不是"文件暂时不在"。
/// * 行不存在 ⇒ `Ok(None)`（"没有这条记录"与"记录坏了"是两件事）。
pub fn verify_blob(
    connection: &Connection,
    root: Option<&Path>,
    sha256: &str,
) -> Result<Option<BlobVerification>> {
    let wanted = sha256.trim().to_ascii_lowercase();
    let row: Option<(i64, String, Option<String>, Option<String>)> = connection
        .query_row(
            "SELECT bytes, mime, local_path, remote_key FROM world_blobs WHERE sha256=?1",
            params![wanted],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let Some((declared_bytes, _mime, local_path, remote_key)) = row else {
        return Ok(None);
    };

    Ok(Some(verify_row(
        &wanted,
        declared_bytes,
        local_path,
        remote_key,
        root,
    )))
}

/// 校验**全部** blob。给体检/对账用（只读）。
///
/// 返回按 `sha256` 升序；`include_present=false` 时只返回非 `Present` 的那些
/// ——那就是"今天有问题的字节"的清单。
pub fn verify_all(
    connection: &Connection,
    root: Option<&Path>,
    include_present: bool,
) -> Result<Vec<BlobVerification>> {
    let mut statement = connection
        .prepare("SELECT sha256, bytes, local_path, remote_key FROM world_blobs ORDER BY sha256")
        .map_err(|_| "storage_unavailable")?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, Option<String>>(3)?,
            ))
        })
        .map_err(|_| "storage_unavailable")?;

    let mut out = Vec::new();
    for row in rows {
        let (sha256, declared_bytes, local_path, remote_key) =
            row.map_err(|_| "storage_unavailable")?;
        let verification = verify_row(&sha256, declared_bytes, local_path, remote_key, root);
        if include_present || verification.state != BlobState::Present {
            out.push(verification);
        }
    }
    Ok(out)
}

/// 汇总：给"文件缺失必须可见"一个可断言的数字。
///
/// `damaged` 只数 `Missing` + `Corrupt`（**故意排除 `NotLocal`**：那是按需下载，
/// 不是损坏）。这两个数字混起来会让"确实坏了"被稀释。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
pub struct BlobAudit {
    pub total: usize,
    pub present: usize,
    /// `Missing + Corrupt`。
    pub damaged: usize,
    /// 只有云端副本（待取回），**不算损坏**。
    pub not_local: usize,
}

impl BlobAudit {
    pub fn from(verifications: &[BlobVerification]) -> Self {
        let mut audit = BlobAudit {
            total: verifications.len(),
            present: 0,
            damaged: 0,
            not_local: 0,
        };
        for item in verifications {
            match item.state {
                BlobState::Present => audit.present += 1,
                BlobState::NotLocal => audit.not_local += 1,
                BlobState::Missing | BlobState::Corrupt => audit.damaged += 1,
            }
        }
        audit
    }

    /// 体检是否干净：**没有损坏**。
    ///
    /// 注意 `NotLocal` 不影响干净性——"还没下载"不是数据问题。
    pub fn is_clean(&self) -> bool {
        self.damaged == 0
    }
}

fn verify_row(
    sha256: &str,
    declared_bytes: i64,
    local_path: Option<String>,
    remote_key: Option<String>,
    root: Option<&Path>,
) -> BlobVerification {
    let base = |state: BlobState, actual_bytes, actual_sha256, reason: String, remedy| {
        BlobVerification {
            sha256: sha256.to_owned(),
            state,
            declared_bytes,
            actual_bytes,
            actual_sha256,
            local_path: local_path.clone(),
            remote_key: remote_key.clone(),
            reason,
            remedy,
        }
    };

    // `local_path` 是 `TEXT`（可空）。空串与 NULL 都当"没有本地副本"，
    // 因为一个空路径永远不可能是"文件暂时不在"。
    let Some(path_text) = local_path.as_deref().filter(|text| !text.is_empty()) else {
        return base(
            BlobState::NotLocal,
            None,
            None,
            if remote_key.is_some() {
                "没有本地副本；云端有 object key，可按需取回".to_owned()
            } else {
                "没有本地副本，也没有云端 key".to_owned()
            },
            "hydrate",
        );
    };

    let path = Path::new(path_text);

    // 私根约束：越界是**描述坏了**，不是"文件不在"（见函数文档）。
    //
    // 必须比**规范化后**的路径：macOS 上 `temp_dir()` 给的 `/var/...` 实际是
    // `/private/var/...`，而 `blob_put` 存的就是 `canonicalize` 的结果。拿未规范化
    // 的前缀去比会把每一份正常 blob 都判成越界 —— 这个分支会**静默误报**，
    // 所以它自己也要被测试覆盖（见 `present_when_bytes_match_the_declared_hash`）。
    if let Some(root) = root {
        if !is_within(root, path) {
            return base(
                BlobState::Corrupt,
                None,
                None,
                format!("本地路径越出私根：{path_text}"),
                "blob_outside_private_root",
            );
        }
    }

    // 只信 `symlink_metadata`：符号链接**不算**这个 blob 的字节
    // （跟随链接会让一份指向别处的 blob 看起来通过）。
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(_) => {
            return base(
                BlobState::Missing,
                None,
                None,
                format!("声明可用但本地文件不存在：{path_text}"),
                "blob_missing",
            );
        }
    };
    if !metadata.is_file() {
        return base(
            BlobState::Missing,
            None,
            None,
            format!("本地路径不是普通文件（目录/链接/设备）：{path_text}"),
            "blob_missing",
        );
    }

    let actual_bytes = metadata.len();
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(_) => {
            return base(
                BlobState::Missing,
                Some(actual_bytes),
                None,
                format!("本地文件存在但读不出来：{path_text}"),
                "blob_missing",
            );
        }
    };
    let actual_sha256 = digest(&bytes);

    // 先比字节数：它能给出比"哈希不对"更省事、更好懂的原因。
    if declared_bytes >= 0 && actual_bytes != declared_bytes as u64 {
        return base(
            BlobState::Corrupt,
            Some(actual_bytes),
            Some(actual_sha256),
            format!("字节数不符：磁盘 {actual_bytes} != 声明 {declared_bytes}"),
            "blob_corrupt",
        );
    }
    if actual_sha256 != sha256 {
        return base(
            BlobState::Corrupt,
            Some(actual_bytes),
            Some(actual_sha256.clone()),
            format!("哈希不符：磁盘 {actual_sha256} != 声明 {sha256}"),
            "blob_corrupt",
        );
    }
    base(
        BlobState::Present,
        Some(actual_bytes),
        Some(actual_sha256),
        "字节在且哈希逐位相等".to_owned(),
        "none",
    )
}

fn digest(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

/// `path` 是否落在 `root` 里，**两侧都规范化后再比**。
///
/// 为什么要自己写：`Path::starts_with` 是纯字面的，而 macOS 的 `/var` 与
/// `/private/var` 是同一个地方的两个名字（`temp_dir()` 给前者，`canonicalize`
/// 给后者）。文件**不存在**时 `canonicalize` 会失败，所以对路径本身做
/// "规范化父目录 + 接上文件名"，让"缺失的 blob"也走同一条判断 —— 否则
/// "文件不在"会被误报成"路径越界"，两个完全不同的结论就串了。
fn is_within(root: &Path, path: &Path) -> bool {
    let Some(root) = canonicalish(root) else {
        return false;
    };
    let Some(path) = canonicalish(path) else {
        return false;
    };
    path.starts_with(&root)
}

/// 规范化一个可能**不存在**的路径：能直接规范化就直接；否则规范化它最深一个
/// 存在的祖先，再把剩下的部分接回去。
fn canonicalish(path: &Path) -> Option<std::path::PathBuf> {
    if let Ok(resolved) = std::fs::canonicalize(path) {
        return Some(resolved);
    }
    let mut missing: Vec<std::ffi::OsString> = Vec::new();
    let mut cursor = path;
    loop {
        let parent = cursor.parent()?;
        if let Some(name) = cursor.file_name() {
            missing.push(name.to_os_string());
        }
        if let Ok(resolved) = std::fs::canonicalize(parent) {
            let mut out = resolved;
            for name in missing.iter().rev() {
                out.push(name);
            }
            return Some(out);
        }
        cursor = parent;
    }
}

// ---------------------------------------------------------------------------
// 事实：让"缺失"进入那条统一事件流（形状与主设计 §4.3 / 本文 §7 一致）
// ---------------------------------------------------------------------------

/// 这次校验该发一条什么事实。
///
/// * `Present` ⇒ `None`：**进了就沉默**。每读一次都写一条 `blob.available`
///   会把日志刷爆，而"它在"不是新闻。
/// * `Missing` / `Corrupt` ⇒ `blob.missing`：这是新闻，而且必须可见。
/// * `NotLocal` ⇒ `blob.notLocal`：也是新闻（用户在等下载），但**不是损坏**。
///
/// `epoch` 是"第几次体检"（调用方给，例如按天/按进程启动一次）——
/// 幂等键里带上它，同一次体检里同一条 blob 只发一条事实（§4.3 的幂等纪律）。
pub fn fact_for(verification: &BlobVerification, epoch: i64) -> Option<(String, String, serde_json::Value)> {
    let kind = match verification.state {
        BlobState::Present => return None,
        BlobState::Missing => "blob.missing",
        BlobState::Corrupt => "blob.missing",
        BlobState::NotLocal => "blob.notLocal",
    };
    let id = format!("blob:{}:{}:{}", verification.sha256, verification.state.as_str(), epoch);
    let payload = serde_json::json!({
        "sha256": verification.sha256,
        "state": verification.state.as_str(),
        "declaredBytes": verification.declared_bytes,
        "actualBytes": verification.actual_bytes,
        "actualSHA256": verification.actual_sha256,
        "localPath": verification.local_path,
        "remoteKey": verification.remote_key,
        "reason": verification.reason,
        "remedy": verification.remedy,
    });
    Some((id, kind.to_owned(), payload))
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::world;

    fn setup() -> Connection {
        let connection = Connection::open_in_memory().unwrap();
        world::schema(&connection).unwrap();
        connection
    }

    /// 造一份真文件并登记成 blob，返回 (sha256, 路径)。
    fn publish(root: &Path, name: &str, bytes: &[u8]) -> (String, std::path::PathBuf) {
        let path = root.join(name);
        std::fs::write(&path, bytes).unwrap();
        let sha256 = digest(bytes);
        (sha256, path)
    }

    fn temp_root(tag: &str) -> std::path::PathBuf {
        let root = std::env::temp_dir().join(format!(
            "gmgn-blob-verify-{tag}-{}",
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    fn put(connection: &Connection, root: &Path, sha256: &str, path: &Path, mime: &str) {
        world::blob_put(
            connection,
            root,
            &world::BlobPutRequest {
                sha256: sha256.to_owned(),
                mime: mime.to_owned(),
                local_path: path.to_string_lossy().into_owned(),
                remote_key: None,
            },
        )
        .unwrap();
    }

    #[test]
    fn present_when_bytes_match_the_declared_hash() {
        let connection = setup();
        let root = temp_root("present");
        let bytes = b"glTF\x02\x00\x00\x00 model";
        let (sha256, path) = publish(&root, "model.glb", bytes);
        put(&connection, &root, &sha256, &path, "model/gltf-binary");

        let found = verify_blob(&connection, Some(&root), &sha256).unwrap().unwrap();
        assert_eq!(found.state, BlobState::Present);
        assert_eq!(found.actual_sha256.as_deref(), Some(sha256.as_str()));
        assert_eq!(found.actual_bytes, Some(bytes.len() as u64));
        assert!(found.state.is_usable());
        assert!(!found.state.is_damage());
        // 「在」不是新闻：不发事实。
        assert!(fact_for(&found, 1).is_none());
    }

    /// **B-2 的核心**：行在、文件被删 ⇒ 必须是 `Missing`，绝不静默成功。
    #[test]
    fn missing_when_the_row_survives_but_the_file_is_gone() {
        let connection = setup();
        let root = temp_root("missing");
        let bytes = b"glTF\x02\x00\x00\x00 model";
        let (sha256, path) = publish(&root, "model.glb", bytes);
        put(&connection, &root, &sha256, &path, "model/gltf-binary");
        // 行不动，只删文件（这正是真机上"状态说已入库而东西不在"的形状）
        std::fs::remove_file(&path).unwrap();

        let found = verify_blob(&connection, Some(&root), &sha256).unwrap().unwrap();
        assert_eq!(found.state, BlobState::Missing);
        assert!(!found.state.is_usable(), "缺失的 blob 绝不能被当成可用");
        assert!(found.state.is_damage(), "缺失是损坏类，不是按需下载类");
        assert_eq!(found.remedy, "blob_missing");
        assert_eq!(found.declared_bytes, bytes.len() as i64);
        assert_eq!(found.actual_bytes, None);

        // 必须发一条可见事实（幂等键带 epoch）
        let (id, kind, payload) = fact_for(&found, 7).expect("missing 必须发事实");
        assert_eq!(kind, "blob.missing");
        assert_eq!(id, format!("blob:{sha256}:missing:7"));
        assert_eq!(payload["state"], "missing");
        // 同一次体检里重放同一 sha256 ⇒ 同一条 id（幂等，不产生第二条）
        assert_eq!(fact_for(&found, 7).unwrap().0, id);
        // 下一次体检是新事实
        assert_ne!(fact_for(&found, 8).unwrap().0, id);
    }

    #[test]
    fn corrupt_when_the_bytes_were_truncated() {
        let connection = setup();
        let root = temp_root("truncated");
        let bytes = b"glTF\x02\x00\x00\x00 model with a tail";
        let (sha256, path) = publish(&root, "model.glb", bytes);
        put(&connection, &root, &sha256, &path, "model/gltf-binary");
        // 截断：字节数先不符（比"哈希不对"更好懂的原因）
        std::fs::write(&path, &bytes[..8]).unwrap();

        let found = verify_blob(&connection, Some(&root), &sha256).unwrap().unwrap();
        assert_eq!(found.state, BlobState::Corrupt);
        assert!(!found.state.is_usable());
        assert!(found.reason.contains("字节数不符"), "原因要能读：{}", found.reason);
        assert_eq!(found.remedy, "blob_corrupt");
        assert!(fact_for(&found, 1).is_some());
    }

    /// 同字节数但内容不同 ⇒ 走哈希那一条分支（覆盖两条 Corrupt 路径）。
    #[test]
    fn corrupt_when_the_bytes_differ_but_the_size_matches() {
        let connection = setup();
        let root = temp_root("samesize");
        let bytes = b"AAAAAAAA";
        let (sha256, path) = publish(&root, "model.glb", bytes);
        put(&connection, &root, &sha256, &path, "model/gltf-binary");
        std::fs::write(&path, b"BBBBBBBB").unwrap();

        let found = verify_blob(&connection, Some(&root), &sha256).unwrap().unwrap();
        assert_eq!(found.state, BlobState::Corrupt);
        assert!(found.reason.contains("哈希不符"), "原因要能读：{}", found.reason);
    }

    /// `NotLocal` 与 `Corrupt` **必须分开**：前者是"去下载"，后者是"数据坏了"。
    #[test]
    fn not_local_is_distinct_from_damage() {
        let connection = setup();
        let root = temp_root("notlocal");
        // 只登记一个云端 key，没有本地路径
        connection
            .execute(
                "INSERT INTO world_blobs(sha256,bytes,mime,local_path,remote_key,created_at_ms)
                 VALUES(?1,?2,?3,NULL,?4,?5)",
                params!["a".repeat(64), 1234i64, "model/gltf-binary", "cloud/model.glb", 1i64],
            )
            .unwrap();

        let found = verify_blob(&connection, Some(&root), &"a".repeat(64)).unwrap().unwrap();
        assert_eq!(found.state, BlobState::NotLocal);
        assert!(!found.state.is_usable(), "待取回 ≠ 可用（调用方不能拿它去渲染）");
        assert!(!found.state.is_damage(), "待取回不是损坏");
        assert_eq!(found.remedy, "hydrate");
        let (_, kind, _) = fact_for(&found, 1).unwrap();
        assert_eq!(kind, "blob.notLocal", "待取回与损坏是两条不同的事实");
    }

    /// 一份指向私根之外的 blob 行是**描述坏了**，不是"文件暂时不在"。
    #[test]
    fn outside_the_private_root_is_corrupt_not_missing() {
        let connection = setup();
        let root = temp_root("inside");
        let outside = temp_root("outside");
        let bytes = b"glTF\x02\x00\x00\x00 outside";
        let (sha256, path) = publish(&outside, "model.glb", bytes);
        // 绕过 blob_put 的越界检查，直接种一行（模拟外部/旧版写入的行）
        connection
            .execute(
                "INSERT INTO world_blobs(sha256,bytes,mime,local_path,remote_key,created_at_ms)
                 VALUES(?1,?2,?3,?4,NULL,?5)",
                params![
                    sha256,
                    bytes.len() as i64,
                    "model/gltf-binary",
                    path.to_string_lossy(),
                    1i64
                ],
            )
            .unwrap();

        let found = verify_blob(&connection, Some(&root), &sha256).unwrap().unwrap();
        assert_eq!(found.state, BlobState::Corrupt);
        assert_eq!(found.remedy, "blob_outside_private_root");
        // 不给 root 时不判越界（只要文件在且哈希对就是 Present）——
        // 这让这个函数在"只想知道字节还在不在"的调用点上仍然可用。
        let lax = verify_blob(&connection, None, &sha256).unwrap().unwrap();
        assert_eq!(lax.state, BlobState::Present);
    }

    #[test]
    fn absent_row_is_none_not_a_failure() {
        let connection = setup();
        let root = temp_root("norow");
        assert!(verify_blob(&connection, Some(&root), &"b".repeat(64)).unwrap().is_none());
    }

    /// 体检汇总：`damaged` **不含** `NotLocal`（否则"确实坏了"会被稀释）。
    #[test]
    fn audit_separates_damage_from_pending_hydration() {
        let connection = setup();
        let root = temp_root("audit");
        let good_bytes = b"good";
        let (good_sha, good_path) = publish(&root, "good.glb", good_bytes);
        put(&connection, &root, &good_sha, &good_path, "model/gltf-binary");

        let gone_bytes = b"gone";
        let (gone_sha, gone_path) = publish(&root, "gone.glb", gone_bytes);
        put(&connection, &root, &gone_sha, &gone_path, "model/gltf-binary");
        std::fs::remove_file(&gone_path).unwrap();

        connection
            .execute(
                "INSERT INTO world_blobs(sha256,bytes,mime,local_path,remote_key,created_at_ms)
                 VALUES(?1,?2,?3,NULL,?4,?5)",
                params!["c".repeat(64), 9i64, "model/gltf-binary", "cloud/x.glb", 1i64],
            )
            .unwrap();

        let all = verify_all(&connection, Some(&root), true).unwrap();
        assert_eq!(all.len(), 3);
        let audit = BlobAudit::from(&all);
        assert_eq!(audit.present, 1);
        assert_eq!(audit.damaged, 1, "只有 missing 算损坏");
        assert_eq!(audit.not_local, 1, "not_local 单列，不进 damaged");
        assert!(!audit.is_clean());

        // 只要非 Present 的那些
        let problems = verify_all(&connection, Some(&root), false).unwrap();
        assert_eq!(problems.len(), 2);
        assert!(problems.iter().all(|item| item.state != BlobState::Present));
    }

    /// 校验是**只读**的：跑一遍不许改动库里任何一个字节、不许动磁盘文件。
    #[test]
    fn verification_never_writes() {
        let connection = setup();
        let root = temp_root("readonly");
        let bytes = b"glTF\x02\x00\x00\x00 immutable";
        let (sha256, path) = publish(&root, "model.glb", bytes);
        put(&connection, &root, &sha256, &path, "model/gltf-binary");

        let before_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM world_blobs", [], |row| row.get(0))
            .unwrap();
        let before_bytes = std::fs::read(&path).unwrap();
        let before_meta = std::fs::symlink_metadata(&path).unwrap();

        let _ = verify_all(&connection, Some(&root), true).unwrap();
        let _ = verify_blob(&connection, Some(&root), &sha256).unwrap();
        let _ = verify_blob(&connection, Some(&root), &"d".repeat(64)).unwrap();

        let after_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM world_blobs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(before_rows, after_rows, "校验不得增删行");
        assert_eq!(std::fs::read(&path).unwrap(), before_bytes, "校验不得改字节");
        assert_eq!(
            std::fs::symlink_metadata(&path).unwrap().len(),
            before_meta.len(),
            "校验不得改文件"
        );
    }
}
