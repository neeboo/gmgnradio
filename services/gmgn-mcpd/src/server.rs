//! The MCP server handler: `tools/list` and `tools/call` over the tool catalog,
//! with every payload resolved by the authority.
//!
//! Two rules are enforced here and tested:
//!
//! 1. **The authority's error codes are returned verbatim.** `invalid_size_intent`
//!    arrives as `invalid_size_intent`. The MCP face is not allowed to have its
//!    own opinion about why something was refused.
//! 2. **"Not enough information" is a successful call.** A tool that cannot know
//!    what the caller wants returns `structured_content` with
//!    `code = "insufficient_input"`, `needs`, `question` and a `pending_id` — not
//!    an error. Guessing on the caller's behalf is the failure mode this exists
//!    to prevent, and so is dressing "I need a size" up as a malfunction.

use crate::catalog::{self, Kind};
use crate::grant::GrantSource;
use crate::taskd::{Client, TaskdError};
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ErrorData, Implementation,
    InitializeResult, ListToolsResult, PaginatedRequestParams, ServerCapabilities, Tool,
    ToolAnnotations,
};
use rmcp::service::RequestContext;
use rmcp::{RoleServer, ServerHandler};
use serde_json::{json, Map, Value};
use std::sync::Arc;

/// The structured "I need more from you" vocabulary. These string literals are
/// the ones the Swift wish machine already publishes
/// (`Agent/WishMachineContract.swift`: `Code.needsInput`, `Need.sizeAxis`,
/// `Need.sizeMeters`, `Need.pendingId`). They are repeated here rather than
/// renamed because two vocabularies for one fact is the thing being removed.
pub mod codes {
    pub const INSUFFICIENT_INPUT: &str = "insufficient_input";
    pub const NEED_SIZE_AXIS: &str = "size_axis";
    pub const NEED_SIZE_METERS: &str = "size_meters";
    pub const QUESTION: &str = "question";
    pub const PENDING_ID: &str = "pending_id";
}

pub struct GmgnMcpServer {
    client: Client,
    grant: GrantSource,
    server_name: String,
    transport: String,
}

impl GmgnMcpServer {
    pub fn new(client: Client, grant: GrantSource, server_name: String, transport: String) -> Self {
        Self {
            client,
            grant,
            server_name,
            transport,
        }
    }

    fn tools(&self) -> Vec<Tool> {
        catalog::TOOLS
            .iter()
            .map(|spec| {
                let tool = Tool::new(
                    spec.name,
                    spec.description,
                    Arc::new(schema_object((spec.input_schema)())),
                );
                // Hints only — the authority is what actually decides. Saying
                // `read_only` about a tool that writes would be a lie told to the
                // client, so it is derived from the same field the dispatcher
                // uses to decide whether a grant is required.
                let annotations = match spec.kind {
                    Kind::ReadOnly => ToolAnnotations::new().read_only(true),
                    Kind::Action => ToolAnnotations::new().read_only(false).idempotent(matches!(
                        spec.name,
                        "gmgn_prop_submit" | "gmgn_world_commit"
                    )),
                };
                tool.with_annotations(annotations)
            })
            .collect()
    }

    async fn dispatch(&self, name: &str, args: &Map<String, Value>) -> CallToolResult {
        let Some(spec) = catalog::find(name) else {
            // Not routable at all: this is a protocol-level failure, not a tool
            // result, and the client must not read it as "the world said no".
            return CallToolResult::structured_error(json!({
                "ok": false,
                "code": "unknown_tool",
                "message": format!("本 MCP 面没有工具 `{name}`；工具清单见 gmgn_capability_contract"),
            }));
        };

        if spec.kind == Kind::Action {
            if let Err(refusal) = self.grant.authorize(spec.name, self.client.endpoint_file()) {
                return CallToolResult::structured_error(json!({
                    "ok": false,
                    "code": refusal.code(),
                    "message": refusal.message(),
                    "tool": spec.name,
                }));
            }
        }

        match spec.name {
            "gmgn_capability_contract" => self.capability_contract().await,
            "gmgn_prop_submit" => self.submit(args).await,
            _ => {
                let method = spec
                    .backend
                    .expect("every translated tool names its backend");
                self.forward(method, Value::Object(args.clone())).await
            }
        }
    }

    /// Read-only, and the only tool whose answer is assembled rather than
    /// forwarded: it prepends the MCP face's own tool list (which comes from the
    /// same catalog the server dispatches from) to the authority's contract.
    async fn capability_contract(&self) -> CallToolResult {
        match self
            .client
            .call("capability_contract", json!({}))
            .await
            .map(|reply| unwrap_result(reply))
        {
            Ok(contract) => success(
                "capability_contract",
                json!({
                    "contract": contract,
                    "mcp": catalog::contract_block(&self.server_name, &self.transport),
                }),
            ),
            Err(error) => failure(&error),
        }
    }

    async fn forward(&self, method: &str, params: Value) -> CallToolResult {
        match self.client.call(method, params).await {
            // The authority's own result, untouched, under the one key that
            // says "this is the authority talking".
            Ok(reply) => success(method, json!({"result": unwrap_result(reply)})),
            Err(error) => failure(&error),
        }
    }

    /// `submit` is the one action that can be *under-specified* rather than
    /// invalid, so it is the one that may answer through the success channel.
    async fn submit(&self, args: &Map<String, Value>) -> CallToolResult {
        let job_id = match args.get("jobID").and_then(Value::as_str) {
            Some(id) if !id.is_empty() => id.to_owned(),
            _ => {
                return failure(&TaskdError::Protocol(
                    "gmgn_prop_submit 需要 jobID（幂等编号）".to_owned(),
                ))
            }
        };
        // A resume reuses the original delegation's idempotency key, so the
        // authority answers "already have it" instead of generating twice.
        let effective_id = args
            .get("pendingID")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .unwrap_or(&job_id)
            .to_owned();

        let height = args.get("heightMeters").and_then(Value::as_f64);
        let intent = args.get("sizeIntent").filter(|value| !value.is_null());
        let intent_axis = intent
            .and_then(|value| value.get("axis"))
            .and_then(Value::as_str);
        let intent_meters = intent
            .and_then(|value| value.get("meters"))
            .and_then(Value::as_f64);

        // height_meters is part of the authority's submit shape, so it always
        // has to be sent. It can be *derived* only from the one intent that
        // means the same thing; from a `longest` intent it cannot be derived at
        // all, and inventing a number would be the app guessing again.
        let height = match (height, intent_axis, intent_meters) {
            (Some(height), _, _) => Some(height),
            (None, Some("height"), Some(meters)) => Some(meters),
            _ => None,
        };
        let Some(height) = height else {
            return insufficient_size(&effective_id, intent_axis, &self.client).await;
        };

        let mut params = Map::new();
        params.insert("id".to_owned(), Value::String(effective_id));
        for key in ["endpoint", "name", "pngBase64", "source"] {
            if let Some(value) = args.get(key) {
                params.insert(key.to_owned(), value.clone());
            }
        }
        params.insert("heightMeters".to_owned(), json!(height));
        if let Some(intent) = intent {
            params.insert("sizeIntent".to_owned(), intent.clone());
        }
        for key in ["sourceWishID", "generationProfile"] {
            if let Some(value) = args.get(key) {
                params.insert(key.to_owned(), value.clone());
            }
        }
        self.forward("submit", Value::Object(params)).await
    }
}

/// The success-channel answer for "this submission cannot be built yet".
///
/// `pending_id` is the effective job id: it is the authority's own idempotency
/// key, so handing it back is a *true* resume handle — resubmitting with it
/// cannot produce a second artifact. No draft ledger is invented here.
///
/// The `needs` are not a canned string. A `longest` intent already says how big
/// the thing is; what is missing then is the other axis the authority's submit
/// shape requires, and asking "how big should it be?" would be asking a question
/// the caller already answered.
async fn insufficient_size(
    pending_id: &str,
    intent_axis: Option<&str>,
    client: &Client,
) -> CallToolResult {
    let (needs, question) = match intent_axis {
        Some("longest") => (
            vec![json!("height_meters")],
            "最长边已经说明；权威的提交形状还需要一个 heightMeters（高度）。这不是「多大」的问题，是另一根轴上的既有事实。",
        ),
        _ => (
            vec![
                json!(codes::NEED_SIZE_AXIS),
                json!(codes::NEED_SIZE_METERS),
            ],
            "这件东西要做多大？告诉我是按最长边还是按高度、多少米（这两条规则见 gmgn_capability_contract）。",
        ),
    };
    // The limits are read from the authority so the question can state a range
    // that is actually true. If the contract cannot be read, the question is
    // still asked — it simply carries no range instead of a made-up one.
    let contract = client
        .call("capability_contract", json!({}))
        .await
        .ok()
        .map(unwrap_result)
        .and_then(|contract| contract.get("size_intent").cloned());
    let mut payload = json!({
        "ok": false,
        "code": codes::INSUFFICIENT_INPUT,
        // The Swift receipt carries both keys with the same value; keeping that
        // shape means a client written against either face reads the same thing.
        "status": codes::INSUFFICIENT_INPUT,
        "needs": needs,
        codes::QUESTION: question,
        codes::PENDING_ID: pending_id,
        "resume": "拿到缺的那一项后用同一个 pending_id 再调一次 gmgn_prop_submit，会续上同一次委托，不会重复生成。",
    });
    if let Some(size_intent) = contract {
        payload["size_intent"] = size_intent;
    }
    success("submit", payload)
}

/// A completed call.
///
/// The channel verdict is MCP's `isError`; the tool's own verdict is the
/// payload's `ok`. They are deliberately not the same field, and this is the
/// convention the Swift wish machine already publishes
/// (`Agent/WishMachineContract.swift`: the `insufficient_input` receipt is
/// `ok: false` and still `isError: false`, because "I need a size" is not a
/// malfunction). A payload that states its own `ok` keeps it.
fn success(method: &str, payload: Value) -> CallToolResult {
    let mut object = match payload {
        Value::Object(object) => object,
        other => {
            let mut object = Map::new();
            object.insert("value".to_owned(), other);
            object
        }
    };
    object.entry("ok").or_insert(json!(true));
    object.insert("authority".to_owned(), json!("gmgn-taskd"));
    object.insert("method".to_owned(), json!(method));
    CallToolResult::structured(Value::Object(object))
}

fn failure(error: &TaskdError) -> CallToolResult {
    CallToolResult::structured_error(json!({
        "ok": false,
        // Verbatim: the code is the authority's, not this face's.
        "code": error.code(),
        "message": error.detail(),
    }))
}

/// `{"id":..,"method":..,"result":{..}}` -> `{..}`. Every other shape is a
/// protocol fault, reported as such rather than papered over.
fn unwrap_result(reply: Value) -> Value {
    reply.get("result").cloned().unwrap_or(reply)
}

fn schema_object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(object) => object,
        other => {
            let mut object = Map::new();
            object.insert("type".to_owned(), json!("object"));
            object.insert("x-invalid-schema".to_owned(), other);
            object
        }
    }
}

impl ServerHandler for GmgnMcpServer {
    fn get_info(&self) -> InitializeResult {
        let mut info = InitializeResult::new(ServerCapabilities::builder().enable_tools().build());
        info.server_info = Implementation::new("gmgn-mcpd", env!("CARGO_PKG_VERSION"));
        info.instructions = Some(
            "这是 gmgn 生活空间的权威面。工具定义在 Rust 侧，数据由 gmgn-taskd 校验并落盘。\
             任何\"能做什么、规则是什么\"的问题先调 gmgn_capability_contract（空参数、只读）；\
             它给出轴、米数范围、世界操作词表与全部错误码。只读工具不需要授权；\
             动作工具只有在宿主本轮 arm 过、且白名单里有这个名字时才可用。"
                .to_owned(),
        );
        info
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        Ok(ListToolsResult::with_all_items(self.tools()))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let args = request.arguments.unwrap_or_default();
        Ok(self.dispatch(&request.name, &args).await.into())
    }
}
