//! The **read-only capability contract** the MCP face publishes.
//!
//! Why this lives in the authority and not in `gmgn-mcpd`: the answer to "how big
//! may a thing be, which axes exist, what does a world commit accept" is a fact
//! about the authority. If the MCP server answered it from its own copy of the
//! numbers, there would be two sources for one fact and they would eventually
//! disagree — and the agent would then be reading a contract that the validator
//! does not enforce.
//!
//! So every number and every word here is **read from the same constant the
//! validating code uses**, and the error-code list is compared against the
//! authority's own sources by test. This method is purely additive: no state is
//! read, written, or advanced, and it takes no parameters.

use crate::{model, world};
use serde_json::{json, Value};

/// Every error code this authority can put on the wire.
///
/// **Not written by hand.** `the_published_codes_are_exactly_the_authoritys_own`
/// re-derives this set from the sources themselves — every shaped literal on a
/// line that raises an error (`Err(`, `.ok_or`, `map_err`, `failure(`, `code:`,
/// and the helpers that take the code as an argument: `bounded(`, `identity(`,
/// `glb_container(`, `object_text(`, `fail(`, `error(`) — in non-test code, and
/// fails in both directions. A code the code returns but this list omits is a
/// contract that lies by omission; a code this list publishes but the code no
/// longer returns is a contract that lies outright. The first live end-to-end run
/// against a real daemon is what found the omission this test now prevents
/// (`world_id_mismatch`, reachable through `world_commit`).
///
/// Known limit, stated rather than hidden: the rule is line-based, so a code that
/// reached the wire without ever appearing on an error-site line would not be
/// found by it. Nothing in this crate does that today —
/// `every_published_code_appears_in_the_sources` additionally refuses a code that
/// appears nowhere at all, which is the "invented field" direction.
///
/// The MCP face must surface these **verbatim**. It is a translator; a friendlier
/// name here would create a second vocabulary for one fact.
const ERROR_CODES: &[&str] = &[
    "absolute_path_required", "already_running", "artifact_already_ready",
    "authoritative_size_conflicts_with_intent", "blob_hash_mismatch",
    "blob_outside_private_root", "client_disconnected", "client_timeout",
    "collision_integrity_failed", "collision_not_supported", "compaction_rejected",
    "duplicate_active_source_wish", "embedding_dimension_mismatch", "endpoint_unavailable", "fact_payload_too_large",
    "fallback_profile_mismatch_would_change_collision_box", "frame_too_large",
    "generation_not_ready", "history_record_too_large", "history_unavailable",
    "http_unavailable", "idempotency_conflict", "image_integrity_failed", "import_conflict",
    "import_hash_mismatch", "incomplete_frame", "invalid_arguments",
    "invalid_authoritative_size", "invalid_blob", "invalid_blob_hash", "invalid_blob_mime",
    "invalid_blob_path", "invalid_collision_descriptor", "invalid_concurrency",
    "invalid_consumer", "invalid_context", "invalid_cursor", "invalid_domain",
    "invalid_endpoint", "invalid_event_id", "invalid_event_kind", "invalid_event_payload",
    "invalid_event_read", "invalid_file", "invalid_generated_prop",
    "invalid_generation_profile", "invalid_glb", "invalid_id", "invalid_import_hash",
    "invalid_input", "invalid_input_px", "invalid_legacy_identity", "invalid_limit",
    "invalid_memory_query", "invalid_memory_read", "invalid_memory_recall",
    "invalid_memory_status", "invalid_message", "invalid_message_ack",
    "invalid_message_cursor", "invalid_message_id", "invalid_message_kind",
    "invalid_message_payload", "invalid_message_read", "invalid_message_scope",
    "invalid_object_id", "invalid_op", "invalid_op_count", "invalid_package_id",
    "invalid_package_version", "invalid_placement_request", "invalid_placement_result", "invalid_png", "invalid_producer",
    "invalid_provider_capabilities", "invalid_query", "invalid_request", "invalid_request_id",
    "invalid_response", "invalid_revision", "invalid_scope", "invalid_size_intent",
    "invalid_source_wish_id", "invalid_state_commit", "invalid_state_key",
    "invalid_state_read", "invalid_state_value", "invalid_task_id", "invalid_token",
    "invalid_topk", "invalid_vector", "invalid_voice_input", "invalid_workflow_profile", "invalid_world_blob_get",
    "invalid_world_blob_put", "invalid_world_commit", "invalid_world_cursors",
    "invalid_world_facts", "invalid_world_facts_read", "invalid_world_id",
    "invalid_world_import", "invalid_world_records", "invalid_world_snapshot",
    "invalid_world_state",
    "ipc_unauthorized", "legacy_integrity_failed", "legacy_unavailable", "limit_exceeded",
    "memory_conflict", "memory_history_unavailable", "memory_original_text_layer_removed",
    "memory_request_conflict", "memory_snapshot_too_large", "memory_storage_failed",
    "message_id_conflict", "message_not_found", "message_payload_too_large",
    "message_scope_mismatch", "message_storage_failed", "missing_collision_descriptor",
    "missing_receipt", "missing_root", "missing_task", "missing_workflow_profile",
    "model_integrity_failed", "model_too_large", "network_unavailable", "object_not_found",
    "object_record_too_large", "object_revision_conflict", "provider_not_ready",
    "remote_id_mismatch", "report_unserializable", "request_id_conflict", "request_rejected",
    "resident_history_unavailable", "resident_storage_failed", "response_too_large_or_unsafe",
    "retry_unavailable", "revision_conflict", "runtime_unavailable", "signal_unavailable",
    "size_intent_conflict", "size_intent_echo_conflict", "size_intent_shape_conflict",
    "socket_outside_private_root",
    "socket_unavailable", "source_task_still_active", "state_value_too_large",
    "storage_unavailable", "subject_revision_regression", "subscription_failed",
    "task_not_found", "terminal_remote_task", "too_many_facts", "unknown_method",
    "unsafe_download",
    "unsafe_endpoint_path", "unsafe_legacy_path", "unsafe_path", "unsupported_voice_provider",
    "voice_backpressure", "voice_not_ready", "voice_protocol_error", "voice_provider_error",
    "voice_session_not_found", "voice_timeout", "voice_transport_error",
    "worker_failed", "world_fact_unreadable", "world_id_mismatch", "world_record_too_large",
    "world_record_unreadable", "world_request_unreadable"
];

/// What a code means, for the codes reachable through the MCP face's tools.
///
/// The rest are published with a `null` reason rather than an invented one: the
/// vocabulary is the authority's, and inventing a meaning for a code this face
/// never surfaces would be exactly the kind of second-hand truth the contract
/// exists to remove.
const ERROR_REASONS: &[(&str, &str)] = &[
    ("invalid_size_intent", "尺寸意图的形状/轴/出处/米数/三轴毫米数不合法"),
    ("size_intent_conflict", "sizeIntent 的 height 轴（或三轴的 y）与 heightMeters 说的不是同一个数"),
    ("size_intent_echo_conflict", "回执里的尺寸意图与已落盘的意图不是同一份"),
    ("size_intent_shape_conflict", "sizeIntent 同时给了 axis/meters 与 mode=dimensions 两种形状，说不清是哪一种"),
    ("invalid_input", "提交字段本身不合法（名字、出处、heightMeters 范围、PNG 大小等）"),
    ("invalid_png", "参考图不是合法 PNG，或边长超出 1—2048"),
    ("invalid_endpoint", "生成服务 origin 不合法（必须 https，或 loopback 上的 http，且无路径/查询/凭据）"),
    ("invalid_id", "任务编号不是合法 UUID"),
    ("invalid_response", "远端或自身的响应形状不符合契约"),
    ("invalid_generation_profile", "生成档位不合法"),
    ("invalid_workflow_profile", "生成档位指纹不合法"),
    ("invalid_provider_capabilities", "生成服务自报的能力声明整块不可信"),
    ("invalid_source_wish_id", "sourceWishID 不合法"),
    ("invalid_context", "提交里的 context 不合法"),
    ("duplicate_active_source_wish", "同一个 sourceWishID 已经有一笔活跃任务"),
    ("source_task_still_active", "换后端时原任务仍未结束"),
    ("artifact_already_ready", "该产物已就绪，无需重开"),
    ("fallback_profile_mismatch_would_change_collision_box", "回退重试沿用了不同的生成档位指纹"),
    ("missing_workflow_profile", "两端都没有生成档位指纹"),
    ("terminal_remote_task", "远端任务已终结，不能重试"),
    ("retry_unavailable", "该任务当前不可重试"),
    ("missing_task", "任务不存在"),
    ("missing_receipt", "缺少远端回执，结果不明"),
    ("invalid_cursor", "游标不合法（负数或无法解析）"),
    ("invalid_limit", "读取条数为 0 或超过上限"),
    ("invalid_world_id", "世界编号不合法"),
    ("invalid_domain", "记录域不合法"),
    ("invalid_request_id", "幂等编号不合法"),
    ("invalid_revision", "expectedRevision 为负"),
    ("invalid_op_count", "ops 为空或超过上限"),
    ("invalid_op", "ops 里出现未知操作，或该操作缺少必需字段"),
    ("request_id_conflict", "同一 requestID 被用于不同内容"),
    ("revision_conflict", "expectedRevision 与当前世界修订不一致"),
    ("world_id_mismatch", "变更里的 worldID 与世界状态文档里的不是同一个"),
    ("subject_revision_regression", "提交的状态修订低于已存的那份"),
    ("invalid_object_id", "物件编号不合法"),
    ("object_not_found", "要改的物件不存在"),
    ("object_revision_conflict", "物件的 expectedObjectRevision 与当前不一致"),
    ("invalid_world_state", "世界状态文档不合法"),
    ("invalid_world_facts", "世界事实负载不合法"),
    ("invalid_generated_prop", "物件的生成信息保留键不合法"),
    ("invalid_consumer", "消费者名不在允许名单里"),
    ("too_many_facts", "一次提交产生的事实数超过上限"),
    ("fact_payload_too_large", "单条事实负载超过上限"),
    ("world_record_too_large", "世界记录超过上限"),
    ("object_record_too_large", "物件记录超过上限"),
    ("world_record_unreadable", "世界记录无法读回"),
    ("world_fact_unreadable", "世界事实无法读回"),
    ("world_request_unreadable", "世界请求记录无法读回"),
    ("invalid_world_snapshot", "world_snapshot 的请求形状不合法"),
    ("invalid_world_records", "world_records 的请求形状不合法"),
    ("invalid_world_facts_read", "world_facts_read 的请求形状不合法"),
    ("invalid_world_cursors", "world_cursors 的请求形状不合法"),
    ("invalid_world_commit", "world_commit 的请求形状不合法，或参数里出现了已配置的凭据"),
    ("invalid_world_import", "world_import 的请求形状不合法，或参数里出现了已配置的凭据"),
    ("invalid_arguments", "参数不符合方法本身的要求"),
    ("storage_unavailable", "存储层不可用"),
    ("frame_too_large", "帧超过上限"),
    ("incomplete_frame", "连接关闭时留下了半帧"),
    ("client_timeout", "写回超时"),
    ("client_disconnected", "客户端在写回前断开"),
    ("unknown_method", "请求的方法名不存在"),
    ("invalid_request", "请求不是一个合法的 JSON 对象"),
];

/// Keys of the generated-prop metadata block. They are *data shape* owned by the
/// world document, and the authority reserves the names; the MCP face must not
/// invent new ones.
const WORLD_KEYS: &[(&str, &str)] = &[
    (
        world::GENERATED_PROP_KEY,
        "物件记录 metadata 里承载生成信息（含 size）的保留键",
    ),
    (
        world::SUPPORT_SURFACE_KEY,
        "物件记录 metadata 里承载承托面信息的保留键",
    ),
];

pub fn describe() -> Value {
    let reasons = |code: &str| -> Value {
        match ERROR_REASONS.iter().find(|(name, _)| *name == code) {
            Some((_, reason)) => Value::String((*reason).to_owned()),
            None => Value::Null,
        }
    };
    json!({
        "authority": "gmgn-taskd",
        "note": "本契约由权威进程按自己的常量生成，MCP 面原样转述；这里没有任何一处是转述者写死的。错误码表是权威**全部**的错误词汇，reason 只给 MCP 面可能触及的那些，其余为 null（不替权威编一个含义）。",
        "ipc": {
            "framing": "newline-delimited JSON, one object per line",
            "frame_limit_bytes": model::FRAME_LIMIT,
            "id_limit_bytes": world::TOKEN_LIMIT,
            "request_id_is_a_string": true,
        },
        "read_limits": {
            "default": world::DEFAULT_READ_LIMIT,
            "max": world::MAX_READ_LIMIT,
        },
        "size_intent": {
            "axes": ["longest", "height"],
            "sources": ["user", "suggested", "default"],
            "min_meters": model::SIZE_INTENT_MIN_METERS,
            "max_meters": model::SIZE_INTENT_MAX_METERS,
            "height_meters_same_range": true,
            "height_axis_equals_height_meters": true,
            "applies": ["normalize", "echo"],
            "note": "axis=height 时 meters 必须与 heightMeters 逐值相同；axis=longest 时 heightMeters 仍必须给出（权威的提交形状如此），它只是另一根轴上的既有事实。",
        },
        "world": {
            "domains": [world::WORLD_DOMAIN, world::OBJECT_DOMAIN],
            "world_key": world::WORLD_KEY,
            "consumers": world::CONSUMERS,
            "ops": world::OPS.iter().map(|op| json!({
                "op": op,
                "requires": match *op {
                    "replaceState" => vec!["state"],
                    "upsertObject" => vec!["objectID 或 object", "expectedObjectRevision（可选）"],
                    "deleteObject" => vec!["objectID"],
                    "setWorldFacts" => vec!["facts"],
                    "advanceCursor" => vec!["consumer", "seq"],
                    _ => vec![],
                },
            })).collect::<Vec<Value>>(),
            "max_operations": world::MAX_OPERATIONS,
            "max_facts": world::MAX_FACTS,
            "fact_payload_limit": world::FACT_PAYLOAD_LIMIT,
            "world_record_limit": world::WORLD_RECORD_LIMIT,
            "object_record_limit": world::OBJECT_RECORD_LIMIT,
            "reserved_metadata_keys": WORLD_KEYS.iter().map(|(key, why)| json!({
                "key": key, "why": why,
            })).collect::<Vec<Value>>(),
            "idempotency": {
                "key": "requestID",
                "replay": "同 requestID 同内容重放返回同一结果并带 replayed=true；内容不同返回 request_id_conflict",
                "cas": "expectedRevision 必须等于当前 world revision，否则 revision_conflict",
            },
        },
        "error_codes": ERROR_CODES.iter().map(|code| json!({
            "code": code, "reason": reasons(code),
        })).collect::<Vec<Value>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    /// The authority's own sources, compiled into this test. `contract.rs` is
    /// excluded on purpose: a contract that quoted itself as evidence would
    /// always agree with itself.
    const AUTHORITY_SOURCES: &[(&str, &str)] = &[
        ("artifact.rs", include_str!("artifact.rs")),
        ("cli.rs", include_str!("cli.rs")),
        ("daemon.rs", include_str!("daemon.rs")),
        ("files.rs", include_str!("files.rs")),
        ("main.rs", include_str!("main.rs")),
        ("memory.rs", include_str!("memory.rs")),
        ("messages.rs", include_str!("messages.rs")),
        ("model.rs", include_str!("model.rs")),
        ("provider.rs", include_str!("provider.rs")),
        ("resident.rs", include_str!("resident.rs")),
        ("store.rs", include_str!("store.rs")),
        ("world.rs", include_str!("world.rs")),
        ("voice.rs", include_str!("voice.rs")),
    ];

    /// Tokens that mark a line as an error site.
    ///
    /// A word is a code when it appears on a line that returns or raises an
    /// error; the same word used as a field name, a method name or a status is
    /// not a code. `bounded(`, `identity(`, `glb_container(`, `object_text(`,
    /// `fail(` and `error(` are here because those helpers take the code as an
    /// argument (`bounded(raw, "invalid_world_id")`), which is how a third of
    /// this vocabulary reaches the wire.
    const ERROR_SITES: &[&str] = &[
        "Err(",
        "ok_or",
        "map_err",
        "bounded(",
        "identity(",
        "fail(",
        "error(",
        "glb_container(",
        "object_text(",
        "failure(",
        "code:",
        "code =",
    ];

    /// Every `"…"` on this line that looks like a code: lowercase snake_case,
    /// containing an underscore, at least six characters long.
    fn shaped_literals(line: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut index = 0usize;
        while index < line.len() {
            let Some(open) = line[index..].find('"').map(|at| index + at) else {
                break;
            };
            let start = open + 1;
            let Some(end) = line[start..].find('"').map(|at| start + at) else {
                break;
            };
            let candidate = &line[start..end];
            let shaped = candidate.len() >= 6
                && candidate.contains('_')
                && candidate.starts_with(|c: char| c.is_ascii_lowercase())
                && candidate
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
            if shaped {
                out.push(candidate.to_owned());
            }
            index = end + 1;
        }
        out
    }

    /// Every code the non-test code of this authority can return.
    fn codes_the_authority_returns() -> BTreeSet<String> {
        let mut codes = BTreeSet::new();
        for (_, text) in AUTHORITY_SOURCES {
            // Test-only literals are not part of the wire contract; the first
            // `#[cfg(test)]` marks where the tests begin in every one of these
            // files.
            let text = match text.find("#[cfg(test)]") {
                Some(at) => &text[..at],
                None => text,
            };
            for line in text.lines() {
                if !ERROR_SITES.iter().any(|token| line.contains(token)) {
                    continue;
                }
                for literal in shaped_literals(line) {
                    codes.insert(literal);
                }
            }
            // ASR maps typed core errors through a single static match helper;
            // its returned literals are wire errors even without an inline Err.
            if let Some(start) = text.find("fn asr_error(") {
                let helper = &text[start..];
                let end = helper.find("\n}").expect("ASR error mapper has a closing brace");
                codes.extend(shaped_literals(&helper[..end]));
            }
        }
        codes
    }

    /// The whole point of this method: it is generated, not transcribed.
    #[test]
    fn capability_contract_matches_the_authority() {
        let contract = describe();
        assert_eq!(
            contract["size_intent"]["min_meters"].as_f64(),
            Some(model::SIZE_INTENT_MIN_METERS)
        );
        assert_eq!(
            contract["size_intent"]["max_meters"].as_f64(),
            Some(model::SIZE_INTENT_MAX_METERS)
        );
        assert_eq!(
            contract["ipc"]["frame_limit_bytes"].as_u64(),
            Some(model::FRAME_LIMIT as u64)
        );
        assert_eq!(
            contract["read_limits"]["max"].as_u64(),
            Some(world::MAX_READ_LIMIT as u64)
        );
        let consumers: Vec<&str> = contract["world"]["consumers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|value| value.as_str().unwrap())
            .collect();
        assert_eq!(consumers, world::CONSUMERS.to_vec());
        let ops: Vec<&str> = contract["world"]["ops"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["op"].as_str().unwrap())
            .collect();
        assert_eq!(ops, world::OPS.to_vec());
    }

    /// The published vocabulary is exactly the authority's — no more, no less.
    ///
    /// Adding a code to the contract without the code returning it fails; so does
    /// removing one from the contract while the code still returns it. That is
    /// what "the read-only contract agrees with the authority" means when the
    /// thing being read is a vocabulary rather than a document.
    #[test]
    fn the_published_codes_are_exactly_the_authoritys_own() {
        let published: BTreeSet<String> = ERROR_CODES.iter().map(|c| (*c).to_owned()).collect();
        let actual = codes_the_authority_returns();
        let missing: Vec<&String> = actual.difference(&published).collect();
        let invented: Vec<&String> = published.difference(&actual).collect();
        assert!(
            missing.is_empty(),
            "权威会返回这些码，契约却没有发布：{missing:?}"
        );
        assert!(
            invented.is_empty(),
            "契约发布了这些码，权威已经不再返回：{invented:?}"
        );
    }

    /// The other direction of "no invented fields": every published code must
    /// exist as a shaped literal somewhere in the authority's own sources, so a
    /// hand-typed code with no implementation behind it cannot stay.
    #[test]
    fn every_published_code_appears_in_the_sources() {
        let all: String = AUTHORITY_SOURCES
            .iter()
            .map(|(_, text)| *text)
            .collect::<Vec<&str>>()
            .join("\n");
        let literals: std::collections::BTreeSet<String> =
            shaped_literals(&all).into_iter().collect();
        for code in ERROR_CODES {
            assert!(
                literals.contains(*code),
                "契约发布了 `{code}`，但权威源码里根本没有这个字面量"
            );
        }
    }

    #[test]
    fn the_published_list_is_sorted_unique_and_snake_case() {
        let mut previous: Option<&str> = None;
        for code in ERROR_CODES {
            if let Some(previous) = previous {
                assert!(previous < *code, "错误码表必须有序且不重复：{previous} / {code}");
            }
            previous = Some(code);
            assert!(
                code.chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_'),
                "错误码不是 snake_case：{code}"
            );
        }
        for (code, _) in ERROR_REASONS {
            assert!(
                ERROR_CODES.contains(code),
                "给一个不存在的错误码写了含义：{code}"
            );
        }
    }

    /// "不许改名": the two codes the size contract is written in terms of are the
    /// ones the validator actually returns.
    #[test]
    fn the_pinned_size_codes_exist_and_are_the_validators_own() {
        assert!(ERROR_CODES.contains(&"invalid_size_intent"));
        assert!(ERROR_CODES.contains(&"size_intent_conflict"));

        let mut submit = crate::model::Submit {
            id: "0b54a1d2-6f3c-4a1e-9d77-2c9f5b8e4a01".to_owned(),
            endpoint: "https://example.test".to_owned(),
            name: "剑".to_owned(),
            png_base64: String::new(),
            source: crate::model::Source {
                author: "a".to_owned(),
                license: "l".to_owned(),
            },
            height_meters: 1.1,
            size_intent: Some(serde_json::json!({"axis": "width", "meters": 1.1, "source": "user"})),
            context: None,
            source_wish_id: None,
            generation_profile: None,
        };
        assert_eq!(submit.validate(), Err("invalid_size_intent"));
        submit.size_intent = Some(serde_json::json!({
            "axis": "height", "meters": 0.5, "source": "user"
        }));
        assert_eq!(submit.validate(), Err("size_intent_conflict"));
    }

    #[test]
    fn the_published_op_vocabulary_matches_the_match() {
        // Every op the contract advertises must still be an arm in `apply`.
        // A removed arm leaves the contract lying; this fails first.
        let source = include_str!("world.rs");
        for op in world::OPS {
            let arm = format!("\"{op}\" => {{");
            assert!(
                source.contains(&arm),
                "契约发布了 `{op}`，但 world.rs 里已经没有 `{arm}` 这个分支"
            );
        }
    }

    #[test]
    fn the_contract_has_no_parameters_and_no_side_effects() {
        // `describe` takes nothing and only reads constants: calling it twice
        // must produce identical bytes.
        assert_eq!(describe(), describe());
    }
}
