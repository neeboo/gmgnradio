//! The MCP tool definitions. **This file is the one place they exist.**
//!
//! Before this crate, the agent's tool face was runtime-generated Swift
//! (`Agent/ResidentDSHHostToolsBridge.swift` emits a private `gmgn-host-tools.mjs`
//! plugin whose schemas come from `ResidentWorldToolSession`). The MCP face moves
//! the definitions for the methods Rust actually owns into Rust, and the
//! switching rule is written down in
//! `docs/plans/evidence/2026-10-02-rust-mcp-recon.md`: a tool name that exists in
//! both places is a duplicated definition, and duplication is the failure this
//! whole line is about.
//!
//! Every tool here is a **straight translation** of a method the daemon already
//! validates. The payload schemas are deliberately permissive (the authority
//! decides) because re-declaring the authority's rules here would be a second
//! copy of them — the one thing that must not exist. Where a field is genuinely
//! required to build the frame, it is required; everything else is passed
//! through and judged by `gmgn-taskd`.

use serde_json::{json, Value};

/// Whether a tool may change world/generation state.
///
/// Read-only tools never consult the grant; action tools always do.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    ReadOnly,
    Action,
}

pub struct ToolSpec {
    pub name: &'static str,
    pub description: &'static str,
    pub kind: Kind,
    /// The taskd method this tool translates. `None` for composed reads.
    pub backend: Option<&'static str>,
    pub input_schema: fn() -> Value,
}

/// The one list. `tools/list`, the capability contract's `mcp.tools`, and the
/// dispatcher all read this, so they cannot disagree.
pub const TOOLS: &[ToolSpec] = &[
    ToolSpec {
        name: "gmgn_capability_contract",
        description: "只读地读回这套世界/生成能力的**唯一真相**：权威进程名、帧上限、读取窗口、尺寸意图的轴与米数范围与出处、世界操作词表、消费者名单、以及全部错误码及其触发条件。它同时列出本 MCP 面提供的工具名。任何关于\"能做什么、规则是什么\"的问题都先读它；不要凭记忆填参数。不产生任何副作用。",
        kind: Kind::ReadOnly,
        backend: Some("capability_contract"),
        input_schema: empty_object,
    },
    ToolSpec {
        name: "gmgn_world_read",
        description: "只读地读回某个世界的**权威快照**：世界记录的 revision、边界 seq、状态文档的 sha256、每个物件的编号/是否启用/是否墓碑/修订号/哈希/更新时间，以及（默认包含的）状态文档本体——物件 id、位置、朝向、是否手持、挂在哪个挂点、是否摆放都在其中。返回的字节就是权威存的那份，不做二次解释。",
        kind: Kind::ReadOnly,
        backend: Some("world_snapshot"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {
                    "worldID": {"type": "string", "description": "世界编号"},
                    "includeState": {
                        "type": "boolean",
                        "description": "是否连状态文档本体一起返回，默认 true。只要物件清单时设 false 可以少传很多字节。"
                    }
                },
                "required": ["worldID"],
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_world_records_read",
        description: "只读地读回某个世界的记录表（`worlds` 域是世界记录，`objects` 域是物件记录），每条带 id/scope/domain/key/revision/updatedAt/updatedBy/tombstone/hash/value。按 domain 过滤可只取一侧。",
        kind: Kind::ReadOnly,
        backend: Some("world_records"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {
                    "worldID": {"type": "string", "description": "世界编号"},
                    "domain": {
                        "type": "string",
                        "enum": ["worlds", "objects"],
                        "description": "只取一个域；不给就是两个域都要。"
                    }
                },
                "required": ["worldID"],
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_world_facts_read",
        description: "只读地按 seq 增量读回世界事实流（谁在什么时候把这个世界改成了什么）。`after` 给上次的 nextCursor 就是续读。用它回答\"刚才发生了什么\"，而不是重新拉整份状态。",
        kind: Kind::ReadOnly,
        backend: Some("world_facts_read"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {
                    "worldID": {"type": "string", "description": "世界编号"},
                    "after": {"type": "integer", "minimum": 0, "description": "从该 seq 之后开始，默认 0"},
                    "limit": {"type": "integer", "minimum": 1, "maximum": 500, "description": "本页条数上限，默认 100，最大 500"}
                },
                "required": ["worldID"],
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_world_cursors_read",
        description: "只读地读回这个世界各消费者（world/ui/agent/cloud/mcp）已经推进到哪个 seq。用来判断哪一侧还没跟上。",
        kind: Kind::ReadOnly,
        backend: Some("world_cursors"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {"worldID": {"type": "string", "description": "世界编号"}},
                "required": ["worldID"],
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_prop_jobs_read",
        description: "只读地读回生成任务账本（权威进程当前知道的所有许愿/生成任务及其阶段）。它只报告账本里的事实，不轮询远端、不推进任务。",
        kind: Kind::ReadOnly,
        backend: Some("snapshot"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {
                    "cursor": {"type": "string", "description": "上一页返回的 nextCursor；不给就从第一页开始"}
                },
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_prop_submit",
        description: "向权威提交**一次**生成任务。`jobID` 是幂等编号：同一编号重复提交不会产生第二件产物。尺寸必须由调用方明确给出——要么给 `sizeIntent`，要么给旧的 `heightMeters`；一个都不给时本工具**不会替你猜**，而是返回成功通道里的结构化 `insufficient_input`（含 `needs`、`question`、可原样回填的 `pending_id`）。`sizeIntent` 的轴/米数/出处由权威校验，非法或与 `heightMeters` 冲突时原样返回 `invalid_size_intent` / `size_intent_conflict`。",
        kind: Kind::Action,
        backend: Some("submit"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {
                    "jobID": {"type": "string", "description": "幂等编号（UUID）。重试必须沿用同一个编号。"},
                    "endpoint": {"type": "string", "description": "生成服务 origin，必须已 configure 过"},
                    "name": {"type": "string", "description": "物件名称"},
                    "pngBase64": {"type": "string", "description": "参考图 PNG 的 base64"},
                    "source": {
                        "type": "object",
                        "properties": {
                            "author": {"type": "string"},
                            "license": {"type": "string"}
                        },
                        "required": ["author", "license"],
                        "additionalProperties": false
                    },
                    "heightMeters": {"type": "number", "description": "高度（米）。与 sizeIntent 的 height 轴语义相同，两者都给时必须一致。轴/范围见 gmgn_capability_contract。"},
                    "sizeIntent": {
                        "type": ["object", "null"],
                        "description": "尺寸意图。轴、出处与米数范围只写在 gmgn_capability_contract 里，这里只说形状。",
                        "properties": {
                            "axis": {"type": "string", "description": "合法取值见 gmgn_capability_contract"},
                            "meters": {"type": "number", "description": "允许范围见 gmgn_capability_contract"},
                            "source": {"type": "string", "description": "合法取值见 gmgn_capability_contract"}
                        },
                        "required": ["axis", "meters", "source"],
                        "additionalProperties": false
                    },
                    "pendingID": {"type": "string", "description": "续上一次未完成的提交时原样回填：上一次 insufficient_input 回执里的 pending_id。给了它就复用同一个 jobID。"},
                    "sourceWishID": {"type": "string", "description": "可选：这笔生成对应哪一次许愿"},
                    "generationProfile": {"type": "object", "description": "可选：决定网格轮廓的生成档位，形状透传给权威"}
                },
                "required": ["jobID", "endpoint", "name", "pngBase64", "source"],
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_prop_cancel",
        description: "请求取消一笔生成任务。取消先落盘；远端可能已经跑完，那种情况会如实报告为取消过晚，不会伪称已取消。",
        kind: Kind::Action,
        backend: Some("cancel"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {"id": {"type": "string", "description": "任务编号（UUID）"}},
                "required": ["id"],
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_prop_retry",
        description: "重试一笔结果不明的提交，复用原图片与原幂等编号。不创建新任务，也不额外消费生成授权。",
        kind: Kind::Action,
        backend: Some("retry"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {"id": {"type": "string", "description": "任务编号（UUID）"}},
                "required": ["id"],
                "additionalProperties": false
            })
        },
    },
    ToolSpec {
        name: "gmgn_world_commit",
        description: "对某个世界提交一次**原子变更**。`requestID` 是幂等编号，`expectedRevision` 是乐观并发前提（不一致返回 revision_conflict，不会覆盖别人的改动）。`ops` 的每个元素是一次操作，词表与每项要求的字段见 gmgn_capability_contract 的 `world.ops`。摆放/移动/改尺寸/手持换挂点都是通过这里的物件操作表达的——本工具不替调用方解释语义，只负责把这次变更交给权威校验并落盘。",
        kind: Kind::Action,
        backend: Some("world_commit"),
        input_schema: || {
            json!({
                "type": "object",
                "properties": {
                    "worldID": {"type": "string", "description": "世界编号"},
                    "requestID": {"type": "string", "description": "幂等编号。同编号同内容重放返回同一结果，内容不同则 request_id_conflict。"},
                    "expectedRevision": {"type": "integer", "minimum": 0, "description": "本次变更基于的世界修订号"},
                    "producer": {"type": "string", "description": "可选：谁提交的，默认 taskd"},
                    "intent": {"description": "可选：这次变更为了什么的说明，只记录不决定行为"},
                    "ops": {
                        "type": "array",
                        "minItems": 1,
                        "description": "操作列表，词表见 gmgn_capability_contract 的 world.ops",
                        "items": {
                            "type": "object",
                            "properties": {
                                "op": {"type": "string"},
                                "state": {"description": "replaceState 用"},
                                "facts": {"description": "setWorldFacts 用"},
                                "object": {"description": "upsertObject 用"},
                                "objectID": {"type": "string"},
                                "expectedObjectRevision": {"type": "integer"},
                                "consumer": {"type": "string", "description": "advanceCursor 用"},
                                "seq": {"type": "integer", "description": "advanceCursor 用"}
                            },
                            "required": ["op"],
                            "additionalProperties": false
                        }
                    }
                },
                "required": ["worldID", "requestID", "expectedRevision", "ops"],
                "additionalProperties": false
            })
        },
    },
];

fn empty_object() -> Value {
    json!({"type": "object", "properties": {}, "additionalProperties": false})
}

pub fn find(name: &str) -> Option<&'static ToolSpec> {
    TOOLS.iter().find(|tool| tool.name == name)
}

pub fn names() -> Vec<&'static str> {
    TOOLS.iter().map(|tool| tool.name).collect()
}

/// The `mcp` block of the capability contract. It is generated from [`TOOLS`],
/// so the contract can never advertise a tool the server does not serve, or miss
/// one it does.
pub fn contract_block(server_name: &str, transport: &str) -> Value {
    json!({
        "server": server_name,
        "transport": transport,
        "naming": format!("tools appear to the client as mcp__{server_name}__<tool>"),
        "tools": TOOLS.iter().map(|tool| json!({
            "name": tool.name,
            "kind": match tool.kind { Kind::ReadOnly => "read_only", Kind::Action => "action" },
            "backend": tool.backend,
        })).collect::<Vec<Value>>(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn tool_names_are_unique() {
        let mut seen = BTreeSet::new();
        for tool in TOOLS {
            assert!(seen.insert(tool.name), "工具名重复：{}", tool.name);
        }
    }

    /// The single-source rule, made structural.
    ///
    /// Every name here carries the `gmgn_` prefix, and no name the private
    /// host-tools plugin publishes does (`read_owned_props`, `hold_prop`,
    /// `submit_wish_generation`, `move_to`, …). The DSH MCP client *also*
    /// namespaces these as `mcp__<serverName>__<tool>`. So a tool cannot exist
    /// "in both places" under one name: the two vocabularies cannot intersect,
    /// and a copy-paste of a Swift tool name into this catalog — the actual
    /// failure mode, one definition injected twice — fails right here.
    #[test]
    fn every_mcp_tool_name_is_namespaced_away_from_the_swift_tool_face() {
        for tool in TOOLS {
            assert!(
                tool.name.starts_with("gmgn_"),
                "`{}` 没有 gmgn_ 前缀：它会与 Swift 侧的私有工具面共用同一个名字空间",
                tool.name
            );
            assert!(
                !tool.name.contains("__"),
                "`{}` 带了双下划线：DSH 的 mcp__<server>__<tool> 命名会被它搅乱",
                tool.name
            );
        }
    }

    #[test]
    fn every_tool_declares_a_valid_schema_and_a_kind() {
        for tool in TOOLS {
            let schema = (tool.input_schema)();
            assert_eq!(
                schema.get("type").and_then(Value::as_str),
                Some("object"),
                "`{}` 的 inputSchema 不是 object",
                tool.name
            );
            assert!(
                schema.get("properties").is_some(),
                "`{}` 的 inputSchema 没有 properties",
                tool.name
            );
            assert!(!tool.description.is_empty(), "`{}` 没有描述", tool.name);
        }
    }

    /// The `insufficient_input` vocabulary is the Swift wish machine's, not a
    /// second one invented here.
    #[test]
    fn the_insufficient_input_vocabulary_is_the_published_one() {
        use crate::server::codes;
        assert_eq!(codes::INSUFFICIENT_INPUT, "insufficient_input");
        assert_eq!(codes::NEED_SIZE_AXIS, "size_axis");
        assert_eq!(codes::NEED_SIZE_METERS, "size_meters");
        assert_eq!(codes::QUESTION, "question");
        assert_eq!(codes::PENDING_ID, "pending_id");
    }

    #[test]
    fn the_contract_block_lists_exactly_the_dispatched_tools() {
        let block = contract_block("gmgn", "stdio");
        let listed: Vec<&str> = block["tools"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["name"].as_str().unwrap())
            .collect();
        assert_eq!(listed, names());
        assert_eq!(block["naming"].as_str().unwrap(), "tools appear to the client as mcp__gmgn__<tool>");
    }
}
