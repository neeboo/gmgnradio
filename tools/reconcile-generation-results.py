#!/usr/bin/env python3
"""P-B1 S0：生成结果的四方对账（**只读**）。

背景与判据见 docs/plans/2026-10-02-memory-and-generation-results-in-rust.md §6.2「S0」。
这个脚本回答 S0 的唯一问题：

    一件产物今天在**几处**出现、路径是否一致、sha256 是否一致、文件是否存在？

它把主设计 §2.4「同一事实存多份」从散文变成**逐件的机械对账**，并把两个已知
真缺陷变成**会自动 FAIL 的检查项**：

  * **B-1 缺陷抓手**：「状态声明的入库 ⇔ 权威里存在该条目」。
    实机现场 `4210DB95`（2B 白色长剑）：`wishes.json` stage=claimed、收件箱
    写着"已领取并入库"，但世界状态 `objectStates` 里没有它、
    `layoutReceipts` 里也没有 `claimed.<jobID>`。
  * **B-2 文件缺失必须可见**：库/档案里声明"可用"的产物，其 blob 必须能按
    sha256 打开并通过校验；否则必须报出来（绝不静默当成可用）。
  * **B-3 内容寻址去重**：同一 sha256 在磁盘上应只有一份（今天
    `ResidentAttachments/` 里同一张 PNG 存了 4 份）。

**只读纪律**：本脚本以 SQLite `mode=ro` 打开数据库，只 `stat`/`read` 文件，
从不写入、从不删除、从不改名、从不创建目录。它也不启动 app、不碰 taskd socket、
不碰 DGX、不碰凭据。

用法：

    python3 tools/reconcile-generation-results.py [--root DIR] [--json OUT] [--quiet]

默认 root = `~/Library/Application Support/gmgn radio/TaskService`。
退出码：0 = 无 FAIL；1 = 至少一条 FAIL（可直接当门禁用）。

注意：本脚本**未**登记进 Makefile。P-B1 的门禁登记等总门禁转绿后再做。
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import sqlite3
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 常量：与生产代码同一口径（不自造第二套）
# ---------------------------------------------------------------------------

#: taskd 私根内，产物/输入图今天的扁平命名（不是内容寻址）。
#: 证据：daemon.rs 的 `s.root.join(format!("{}.glb", id))` / `{}.pdf` 同族写法。
GLB_SUFFIX = ".glb"
COLLIDER_SUFFIX = ".collider.glb"
PNG_SUFFIX = ".png"

#: 世界状态里那只 metadata 键（WorldSimulation.swift:129-133）。
PROP_METADATA_KEY = "gmgn.generated-prop.v1"

#: 与 model.rs 的上限同源，用来判定"声明 bytes 是否可信"。
MODEL_LIMIT = 32 * 1024 * 1024
COLLIDER_LIMIT = 4 * 1024 * 1024
PNG_LIMIT = 8 * 1024 * 1024

OK, WARN, FAIL = "OK", "WARN", "FAIL"


def sha256_file(path: Path) -> str | None:
    """流的 sha256。读不到就返回 None（**不抛**：缺失本身是要报告的发现）。"""
    try:
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def canonical_hash(value: object) -> str | None:
    """64 位小写十六进制才算哈希；其它一律 None（不静默当合法）。"""
    if not isinstance(value, str):
        return None
    text = value.strip().lower()
    if len(text) != 64 or any(c not in "0123456789abcdef" for c in text):
        return None
    return text


# ---------------------------------------------------------------------------
# 四个来源
# ---------------------------------------------------------------------------


def read_daemon_jobs(db_path: Path) -> dict[str, dict]:
    """来源 1：taskd `jobs` 表（`data` 里的 job JSON blob）。

    只读打开；缺表/缺列都当成"这个来源没有数据"，而不是崩溃。
    """
    if not db_path.exists():
        return {}
    uri = f"file:{db_path}?mode=ro"
    jobs: dict[str, dict] = {}
    try:
        connection = sqlite3.connect(uri, uri=True)
    except sqlite3.Error:
        return {}
    try:
        connection.row_factory = sqlite3.Row
        rows = connection.execute("SELECT id, data FROM jobs").fetchall()
        for row in rows:
            try:
                stored = json.loads(row["data"])
            except (TypeError, ValueError):
                continue
            job = stored.get("job") if isinstance(stored, dict) else None
            if not isinstance(job, dict):
                continue
            jobs[str(row["id"])] = job
    except sqlite3.Error:
        return {}
    finally:
        connection.close()
    return jobs


def read_wishes(path: Path) -> dict:
    """来源 2：`WishMachine/wishes.json`（整份档案）。"""
    try:
        with path.open("r", encoding="utf-8") as handle:
            archive = json.load(handle)
    except (OSError, ValueError):
        return {}
    return archive if isinstance(archive, dict) else {}


def read_world_states(base: Path) -> list[tuple[Path, dict]]:
    """来源 3：所有世界状态 `state.json`（`<base>/<packageID>/[<version>/]state.json`）。"""
    found: list[tuple[Path, dict]] = []
    if not base.is_dir():
        return found
    for state_path in sorted(base.glob("*/state.json")) + sorted(base.glob("*/*/state.json")):
        try:
            with state_path.open("r", encoding="utf-8") as handle:
                state = json.load(handle)
        except (OSError, ValueError):
            continue
        if isinstance(state, dict):
            found.append((state_path, state))
    return found


def generated_prop(state: dict, object_id: str) -> dict | None:
    """世界状态里一件产物的 metadata blob（解不出来 = 坏了，不是"没有"）。"""
    item = (state.get("objectStates") or {}).get(object_id)
    if not isinstance(item, dict):
        return None
    metadata = item.get("metadata")
    if not isinstance(metadata, dict):
        return None
    raw = metadata.get(PROP_METADATA_KEY)
    if not isinstance(raw, str):
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return None
    return parsed if isinstance(parsed, dict) else None


def scan_files(roots: list[Path], recursive: bool = False) -> dict[str, list[Path]]:
    """来源 4：磁盘文件，按**实际内容**哈希归桶（不是按文件名）。

    可以给多个根：产物/输入图在 taskd 私根里，而**用户上传的参考图**在
    `ResidentAttachments/`、**居民自检的公开图**在 `ResidentWishReferences/`。
    去重只有在"跨这些目录一起看"时才有意义 —— 否则同一张图各存一份永远看不见。
    """
    by_hash: dict[str, list[Path]] = {}
    for root in roots:
        if not root.is_dir():
            continue
        entries = root.rglob("*") if recursive else root.iterdir()
        for entry in sorted(entries):
            if not entry.is_file() or entry.is_symlink():
                continue
            name = entry.name
            if not (name.endswith(GLB_SUFFIX) or name.endswith(PNG_SUFFIX)):
                continue
            digest = sha256_file(entry)
            if digest is None:
                continue
            by_hash.setdefault(digest, []).append(entry)
    return by_hash


# ---------------------------------------------------------------------------
# 对账
# ---------------------------------------------------------------------------


def reconcile(root: Path, world_base: Path, wishes_path: Path,
              extra_dirs: list[Path] | None = None) -> dict:
    db_path = root / "tasks.sqlite3"
    jobs = read_daemon_jobs(db_path)
    archive = read_wishes(wishes_path)
    wish_jobs = {
        str(job.get("id")): job
        for job in (archive.get("jobs") or [])
        if isinstance(job, dict) and job.get("id")
    }
    world_states = read_world_states(world_base)
    # 私根是扁平的（产物 + 输入图 + DB + socket）；额外目录要递归
    # （`ResidentAttachments/` 等直接放 PNG）。
    files_by_hash = scan_files([root])
    private_root_hashes = set(files_by_hash)
    extra_hashes: set[str] = set()
    for extra in (extra_dirs or []):
        for digest, paths in scan_files([extra], recursive=True).items():
            files_by_hash.setdefault(digest, []).extend(paths)
            extra_hashes.add(digest)

    # 反查：某个内容哈希今天落在哪些文件上（用于去重与孤立检测）
    path_to_hash = {
        str(path): digest for digest, paths in files_by_hash.items() for path in paths
    }

    receipts: list[dict] = []
    ids = sorted(set(jobs) | set(wish_jobs))

    for artifact_id in ids:
        job = jobs.get(artifact_id, {})
        wish = wish_jobs.get(artifact_id, {})
        receipt = job.get("receipt") if isinstance(job.get("receipt"), dict) else {}
        result = receipt.get("result") if isinstance(receipt.get("result"), dict) else {}
        inspection = result.get("inspection") if isinstance(result.get("inspection"), dict) else {}
        collision = result.get("collision") if isinstance(result.get("collision"), dict) else {}

        declared_model_hash = canonical_hash(inspection.get("sha256"))
        declared_model_bytes = inspection.get("bytes")
        declared_image_hash = canonical_hash(job.get("imageSHA256"))
        declared_collision_hash = canonical_hash(result.get("collision_sha256"))

        # 四处声明的产物路径
        daemon_path = job.get("localModelPath")
        wish_path = wish.get("modelPath")
        object_id = wish.get("objectID")
        stage = wish.get("stage")

        checks: list[dict] = []

        def note(level: str, code: str, detail: str) -> None:
            checks.append({"level": level, "code": code, "detail": detail})

        # ---- 来源 1 与 2 是否互相认得 ----
        if artifact_id in jobs and artifact_id not in wish_jobs:
            note(WARN, "daemon_only", "taskd 有任务行，wishes.json 里没有")
        if artifact_id in wish_jobs and artifact_id not in jobs:
            note(WARN, "wish_only", "wishes.json 有任务行，taskd 里没有")

        # ---- 路径一致（今天必须手写相等断言才敢用的那一对）----
        if daemon_path and wish_path and daemon_path != wish_path:
            note(FAIL, "path_mismatch",
                 f"taskd localModelPath={daemon_path!r} != wishes modelPath={wish_path!r}")
        elif daemon_path and wish_path:
            note(OK, "path_agrees", "两处声明的产物路径逐字相同")

        # ---- B-2：文件缺失必须可见 ----
        model_hash_on_disk = None
        if daemon_path:
            model_path = Path(daemon_path)
            if not model_path.is_file():
                note(FAIL, "model_file_missing",
                     f"声明可用但文件不存在：{daemon_path}")
            else:
                model_hash_on_disk = sha256_file(model_path)
                if declared_model_hash and model_hash_on_disk != declared_model_hash:
                    note(FAIL, "model_hash_mismatch",
                         f"磁盘 {model_hash_on_disk} != 回执声明 {declared_model_hash}")
                else:
                    note(OK, "model_verified",
                         f"{model_path.stat().st_size} B, sha256 与回执一致")
                if isinstance(declared_model_bytes, int) and model_path.stat().st_size != declared_model_bytes:
                    note(FAIL, "model_bytes_mismatch",
                         f"磁盘 {model_path.stat().st_size} B != 回执声明 {declared_model_bytes} B")

        # ---- 碰撞代理：声明了就必须在 ----
        collision_path = job.get("localCollisionPath")
        if declared_collision_hash and not collision_path:
            note(FAIL, "collider_declared_but_absent",
                 "回执声明了 collision_sha256，但 job 里没有 localCollisionPath")
        if collision_path:
            collider = Path(collision_path)
            if not collider.is_file():
                note(FAIL, "collider_file_missing", f"声明可用但文件不存在：{collision_path}")
            else:
                actual = sha256_file(collider)
                if declared_collision_hash and actual != declared_collision_hash:
                    note(FAIL, "collider_hash_mismatch",
                         f"磁盘 {actual} != 回执声明 {declared_collision_hash}")
                else:
                    note(OK, "collider_verified", "碰撞代理 sha256 与回执一致")

        # ---- 输入图：路径在、哈希对、且必须与产物哈希**不同** ----
        image_path = job.get("imagePath")
        if image_path:
            image = Path(image_path)
            if not image.is_file():
                note(WARN, "input_image_missing", f"输入图不在：{image_path}")
            elif declared_image_hash:
                actual = sha256_file(image)
                if actual != declared_image_hash:
                    note(FAIL, "input_hash_mismatch",
                         f"输入图磁盘 {actual} != job.imageSHA256 {declared_image_hash}")
                else:
                    note(OK, "input_verified", "输入图 sha256 与 job.imageSHA256 一致")

        # ---- B-4 回归护栏：输入与产物必须是两个不同的键 ----
        if declared_model_hash and declared_image_hash:
            if declared_model_hash == declared_image_hash:
                note(FAIL, "input_output_hash_collision",
                     "产物 sha256 与输入图 sha256 相同 —— 输入与产物混用了同一个键")
            else:
                note(OK, "input_output_distinct",
                     "产物哈希与输入图哈希是两个不同的键")

        # ---- 世界状态：assetID 必须等于产物 blob 的 sha256 ----
        asset_ids: list[dict] = []
        in_inventory: bool | None = None
        claimed_receipt = False
        for state_path, state in world_states:
            if object_id:
                prop = generated_prop(state, object_id)
                if prop is not None:
                    in_inventory = True
                    asset_id = prop.get("assetID")
                    suffix = canonical_hash(str(asset_id).split(":")[-1]) if isinstance(asset_id, str) else None
                    asset_ids.append({"state": str(state_path), "assetID": asset_id})
                    if declared_model_hash and suffix != declared_model_hash:
                        note(FAIL, "asset_id_not_product_hash",
                             f"{state_path.name}: assetID={asset_id!r} 的后缀 {suffix} "
                             f"!= 产物 sha256 {declared_model_hash}")
                    if declared_image_hash and suffix == declared_image_hash:
                        note(FAIL, "asset_id_is_input_hash",
                             f"{state_path.name}: assetID 指向了**输入图**的哈希")
                    if suffix and declared_model_hash and suffix == declared_model_hash:
                        note(OK, "asset_id_agrees", f"{state_path.name}: assetID 后缀 == 产物 sha256")
                if ("claimed." + artifact_id) in (state.get("layoutReceipts") or {}):
                    claimed_receipt = True

        # ---- B-1 缺陷抓手：声明的入库 ⇔ 权威里存在该条目 ----
        declares_claimed = stage == "claimed"
        if declares_claimed:
            if in_inventory is True and claimed_receipt:
                note(OK, "claimed_consistent", "stage=claimed 且库存里有它、且 claimed 回执在")
            else:
                note(FAIL, "claimed_but_not_in_inventory",
                     f"stage=claimed 但"
                     f"{'世界状态里没有该 objectID' if in_inventory is not True else ''}"
                     f"{'；layoutReceipts 里没有 claimed.' + artifact_id if not claimed_receipt else ''}")

        receipts.append({
            "artifactID": artifact_id,
            "name": wish.get("name") or job.get("name"),
            "wishStage": stage,
            "daemonStage": job.get("backendStage"),
            "objectID": object_id,
            "daemonPath": daemon_path,
            "wishPath": wish_path,
            "declaredModelSHA256": declared_model_hash,
            "declaredImageSHA256": declared_image_hash,
            "actualModelSHA256": model_hash_on_disk,
            "assetIDs": asset_ids,
            "inInventory": in_inventory,
            "claimedReceiptPresent": claimed_receipt,
            "checks": checks,
        })

    # ---- 孤立文件：磁盘上有，但没有任何一条产物事实认领它 ----
    # 注意**只对私根判孤立**：`ResidentAttachments/` 里是用户上传的原件，
    # 它们本来就不该被 `jobs` 引用，把那些算成"孤立"是假阳性。
    claimed_paths = set()
    for artifact_id in ids:
        job = jobs.get(artifact_id, {})
        for key in ("localModelPath", "localCollisionPath", "imagePath"):
            value = job.get(key)
            if value:
                claimed_paths.add(value)
        wish_path = wish_jobs.get(artifact_id, {}).get("modelPath")
        if wish_path:
            claimed_paths.add(wish_path)

    root_prefix = str(root) + os.sep
    orphans = [
        {"path": str(path), "bytes": path.stat().st_size, "sha256": digest}
        for digest, paths in sorted(files_by_hash.items())
        for path in paths
        if str(path).startswith(root_prefix) and str(path) not in claimed_paths
    ]

    # ---- B-3：同一内容多份 ----
    # 分两类，因为处置方式不同：
    #   * leftover    —— 私根内同一内容 ≥2 份：**纯浪费**，P-B2 应去重（今天 0 组）。
    #   * cross_dir   —— 同一内容同时出现在私根与额外目录（用户原件 vs 提交副本），
    #                    处置要保守（原件可能仍需保留），只报告不主张删除。
    duplicates = []
    for digest, paths in sorted(files_by_hash.items()):
        if len(paths) <= 1:
            continue
        in_root = [p for p in paths if str(p).startswith(root_prefix)]
        outside = [p for p in paths if not str(p).startswith(root_prefix)]
        kind = "leftover" if not outside else ("cross_dir" if in_root else "extra_dirs")
        duplicates.append({
            "kind": kind,
            "sha256": digest,
            "count": len(paths),
            "bytesEach": paths[0].stat().st_size,
            "wastedBytes": paths[0].stat().st_size * (len(paths) - 1) if kind == "leftover" else 0,
            "paths": [str(path) for path in paths],
        })

    # ---- 档案侧：登记了却从未生成（今天 32 份授权 vs 4 个任务）----
    authorizations = archive.get("authorizations") or []
    never_submitted = [
        {"authorizationID": str(auth.get("id")), "attachments": len(auth.get("attachments") or [])}
        for auth in authorizations
        if isinstance(auth, dict)
        and not any(
            str(wish_jobs[i].get("authorizationID")) == str(auth.get("id")) for i in wish_jobs
        )
    ]

    levels = [check["level"] for record in receipts for check in record["checks"]]
    fails = levels.count(FAIL)
    warns = levels.count(WARN)

    return {
        "generatedAt": datetime.datetime.now().isoformat(),
        "root": str(root),
        "sources": {
            "taskdJobs": len(jobs),
            "wishJobs": len(wish_jobs),
            "worldStates": len(world_states),
            "filesOnDisk": sum(len(paths) for paths in files_by_hash.values()),
            "distinctContents": len(files_by_hash),
        },
        "artifacts": receipts,
        "orphanFiles": orphans,
        "duplicateContents": duplicates,
        "authorizationsNeverSubmitted": never_submitted,
        "summary": {
            "artifacts": len(receipts),
            "fail": fails,
            "warn": warns,
            "orphans": len(orphans),
            "duplicateGroups": len(duplicates),
            "leftoverGroups": sum(1 for item in duplicates if item["kind"] == "leftover"),
            "crossDirGroups": sum(1 for item in duplicates if item["kind"] != "leftover"),
            "wastedBytes": sum(item["wastedBytes"] for item in duplicates),
        },
    }


# ---------------------------------------------------------------------------
# 自测：在临时目录里造出每一条检查项的反例，证明检查**真的会 FAIL**
# ---------------------------------------------------------------------------


def _selftest_fixture(base: Path, *, stage: str, in_inventory: bool,
                      claimed_receipt: bool, write_model: bool,
                      model_hash_matches: bool, asset_id_from_input: bool) -> tuple[Path, Path, Path]:
    """造一份最小四方数据。只写在 `base`（临时目录）里。"""
    root = base / "TaskService"
    worlds = base / "LivingWorld"
    wishes_dir = base / "WishMachine"
    for directory in (root, worlds / "pkg" / "1.0.0", wishes_dir):
        directory.mkdir(parents=True, exist_ok=True)

    model_bytes = b"glTF\x02\x00\x00\x00 model"
    image_bytes = b"\x89PNG\r\n\x1a\n image"
    model_hash = hashlib.sha256(model_bytes).hexdigest()
    image_hash = hashlib.sha256(image_bytes).hexdigest()

    artifact = "AAAAAAAA-1111-2222-3333-444444444444"
    object_id = "wish-prop-aaaaaaaa-1111-2222-3333-444444444444"
    model_path = root / f"{artifact}.glb"
    image_path = root / f"{artifact}.png"
    if write_model:
        model_path.write_bytes(model_bytes)
    image_path.write_bytes(image_bytes)

    declared_hash = model_hash if model_hash_matches else "f" * 64
    (root / "tasks.sqlite3").unlink(missing_ok=True)
    connection = sqlite3.connect(root / "tasks.sqlite3")
    connection.execute("CREATE TABLE jobs(id TEXT PRIMARY KEY, data TEXT NOT NULL)")
    connection.execute(
        "INSERT INTO jobs(id,data) VALUES(?,?)",
        (artifact, json.dumps({"job": {
            "id": artifact,
            "name": "selftest prop",
            "backendStage": "ready",
            "imagePath": str(image_path),
            "imageSHA256": image_hash,
            "localModelPath": str(model_path),
            "receipt": {"state": "completed", "result": {
                "inspection": {"sha256": declared_hash, "bytes": len(model_bytes)},
            }},
        }})),
    )
    connection.commit()
    connection.close()

    (wishes_dir / "wishes.json").write_text(json.dumps({
        "jobs": [{
            "id": artifact,
            "stage": stage,
            "modelPath": str(model_path),
            "objectID": object_id,
            "authorizationID": "auth-1",
        }],
        "authorizations": [{"id": "auth-1", "attachments": []}],
    }), encoding="utf-8")

    state = {"worldID": "world", "objectStates": {}, "layoutReceipts": {}}
    if in_inventory:
        asset_suffix = image_hash if asset_id_from_input else model_hash
        state["objectStates"][object_id] = {"isEnabled": True, "metadata": {
            PROP_METADATA_KEY: json.dumps({"objectID": object_id, "assetID": f"sha256:{asset_suffix}"})
        }}
    if claimed_receipt:
        state["layoutReceipts"][f"claimed.{artifact}"] = {"register": {"_0": {"objectID": object_id}}}
    (worlds / "pkg" / "1.0.0" / "state.json").write_text(json.dumps(state), encoding="utf-8")

    return root, worlds, wishes_dir / "wishes.json"


def self_test() -> int:
    """每条断言造一个反例 + 一个正例；反例**必须** FAIL，正例**必须**不 FAIL。"""
    import tempfile

    cases = [
        # name, kwargs, 期望出现的 FAIL code（None = 期望无 FAIL）
        ("healthy", dict(stage="claimed", in_inventory=True, claimed_receipt=True,
                         write_model=True, model_hash_matches=True, asset_id_from_input=False), None),
        ("claimed_but_not_in_inventory", dict(stage="claimed", in_inventory=False, claimed_receipt=False,
                                              write_model=True, model_hash_matches=True,
                                              asset_id_from_input=False),
         "claimed_but_not_in_inventory"),
        ("claimed_without_receipt", dict(stage="claimed", in_inventory=True, claimed_receipt=False,
                                         write_model=True, model_hash_matches=True,
                                         asset_id_from_input=False), "claimed_but_not_in_inventory"),
        ("model_file_missing", dict(stage="claimed", in_inventory=True, claimed_receipt=True,
                                    write_model=False, model_hash_matches=True,
                                    asset_id_from_input=False), "model_file_missing"),
        ("model_hash_mismatch", dict(stage="claimed", in_inventory=True, claimed_receipt=True,
                                     write_model=True, model_hash_matches=False,
                                     asset_id_from_input=False), "model_hash_mismatch"),
        ("asset_id_is_input_hash", dict(stage="claimed", in_inventory=True, claimed_receipt=True,
                                        write_model=True, model_hash_matches=True,
                                        asset_id_from_input=True), "asset_id_is_input_hash"),
    ]

    failures = 0
    with tempfile.TemporaryDirectory() as scratch:
        for index, (name, kwargs, expected) in enumerate(cases):
            base = Path(scratch) / f"case{index}"
            root, worlds, wishes = _selftest_fixture(base, **kwargs)
            report = reconcile(root, worlds, wishes)
            codes = {check["code"] for record in report["artifacts"] for check in record["checks"]
                     if check["level"] == FAIL}
            if expected is None:
                good = not codes
            else:
                good = expected in codes
            status = "PASS" if good else "FAIL"
            if not good:
                failures += 1
            detail = ("no FAIL" if not codes else ",".join(sorted(codes)))
            print(f"  [{status}] {name}: expected={expected or 'no FAIL'} got={detail}")

    print()
    if failures:
        print(f"FAIL: {failures}/{len(cases)} 自测用例没抓住")
    else:
        print(f"PASS: {len(cases)}/{len(cases)} 自测用例都抓住了该抓的缺陷"
              f"（其中 claimed_but_not_in_inventory / model_file_missing / "
              f"asset_id_is_input_hash 正是 P-B1 的三条核心判据）")
    return 1 if failures else 0


# ---------------------------------------------------------------------------
# 呈现
# ---------------------------------------------------------------------------


def render(report: dict, quiet: bool) -> None:
    summary = report["summary"]
    sources = report["sources"]
    print("=" * 78)
    print("P-B1 S0 生成结果四方对账（只读）")
    print("=" * 78)
    print(f"root                      : {report['root']}")
    print(f"生成时间                   : {report['generatedAt']}")
    print(f"来源                      : taskd jobs={sources['taskdJobs']} "
          f"wishes jobs={sources['wishJobs']} "
          f"world state.json={sources['worldStates']} "
          f"磁盘文件={sources['filesOnDisk']}（去重后 {sources['distinctContents']} 种内容）")
    print()
    if not quiet:
        for record in report["artifacts"]:
            print(f"--- {record['artifactID']}  {record['name'] or ''}")
            print(f"    stage: wishes={record['wishStage']} daemon={record['daemonStage']}")
            print(f"    objectID={record['objectID']} inInventory={record['inInventory']} "
                  f"claimedReceipt={record['claimedReceiptPresent']}")
            print(f"    产物 sha256(声明)={record['declaredModelSHA256']}")
            print(f"    产物 sha256(磁盘)={record['actualModelSHA256']}")
            print(f"    输入 sha256       ={record['declaredImageSHA256']}")
            for check in record["checks"]:
                if check["level"] != OK or check["code"] in (
                    "path_agrees", "model_verified", "asset_id_agrees",
                    "input_output_distinct", "claimed_consistent",
                ):
                    print(f"      [{check['level']}] {check['code']}: {check['detail']}")
            print()

    if report["orphanFiles"]:
        print(f"孤立文件（磁盘上有、没有事实认领）：{len(report['orphanFiles'])}")
        for item in report["orphanFiles"]:
            print(f"  [{WARN}] {item['path']}  {item['bytes']} B  sha256={item['sha256'][:12]}…")
        print()

    if report["duplicateContents"]:
        print(f"重复内容（同一 sha256 存了多份）：{len(report['duplicateContents'])} 组"
              f"（私根内浪费 {summary['wastedBytes']} B；"
              f"leftover={summary['leftoverGroups']} cross-dir={summary['crossDirGroups']}）")
        for item in report["duplicateContents"]:
            level = WARN if item["kind"] == "leftover" else OK
            print(f"  [{level}] kind={item['kind']} {item['sha256'][:16]}… × {item['count']} "
                  f"（各 {item['bytesEach']} B"
                  + (f"，浪费 {item['wastedBytes']} B" if item["wastedBytes"] else "") + "）")
            for path in item["paths"]:
                print(f"          {path}")
        print()

    if report["authorizationsNeverSubmitted"]:
        print(f"登记了却从未提交生成的人类授权：{len(report['authorizationsNeverSubmitted'])}")
        print()

    print("-" * 78)
    print(f"结论：artifact={summary['artifacts']}  "
          f"FAIL={summary['fail']}  WARN={summary['warn']}  "
          f"孤立={summary['orphans']}  重复组={summary['duplicateGroups']}  "
          f"（leftover={summary['leftoverGroups']} / cross-dir={summary['crossDirGroups']}）  "
          f"私根内浪费={summary['wastedBytes']} B")
    print("-" * 78)


def main() -> int:
    home = Path.home()
    support = home / "Library/Application Support"
    default_root = support / "gmgn radio/TaskService"
    default_worlds = support / "ai.gmgn.radio/LivingWorld"
    default_wishes = support / "gmgn radio/WishMachine/wishes.json"
    default_extras = [
        support / "gmgn radio/ResidentAttachments",
        support / "gmgn radio/ResidentWishReferences",
    ]

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=default_root,
                        help="taskd 私根（默认 %(default)s）")
    parser.add_argument("--worlds", type=Path, default=default_worlds,
                        help="LivingWorld 目录（默认 %(default)s）")
    parser.add_argument("--wishes", type=Path, default=default_wishes,
                        help="wishes.json（默认 %(default)s）")
    parser.add_argument("--extra-dir", type=Path, action="append", default=None,
                        help="额外参与去重扫描的目录（可重复；默认 ResidentAttachments + ResidentWishReferences）")
    parser.add_argument("--json", type=Path, default=None, help="把完整报告写到这个文件")
    parser.add_argument("--quiet", action="store_true", help="只打汇总，不逐件展开")
    parser.add_argument("--self-test", action="store_true",
                        help="在临时目录里造出每一条检查项的反例，证明检查真的会 FAIL（不碰真机数据）")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    extras = default_extras if args.extra_dir is None else args.extra_dir
    report = reconcile(args.root, args.worlds, args.wishes, extras)
    render(report, args.quiet)
    if args.json:
        with args.json.open("w", encoding="utf-8") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
        print(f"完整报告已写入：{args.json}")

    return 1 if report["summary"]["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
