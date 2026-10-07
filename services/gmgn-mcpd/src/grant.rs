//! Authorization for the **action** tools, inherited from the private host-tools
//! plugin rather than re-invented.
//!
//! The Swift side already writes one grant document per armed round
//! (`Agent/ResidentDSHHostToolsBridge.swift`: `{state, tools:[{name}], endpointFile,
//! secret, worldRevision}`) and its private plugin refuses every call whose tool
//! is not in `tools` while `state != "armed"`. The MCP face reads the same
//! document: read-only tools are safe in any direction, action tools require an
//! armed round that names them.
//!
//! A missing or unreadable grant is **not** "allow". It is a refusal that says
//! so, because the alternative — an MCP server that acts on the world whenever it
//! happens to be reachable — is exactly the shape this design exists to avoid.

use serde_json::Value;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// No grant document was configured for this process.
    NotConfigured,
    /// The document exists but could not be read or parsed as a grant.
    Unreadable(String),
    /// The round is not armed.
    NotArmed(String),
    /// The round is armed, but not for this tool.
    ToolNotGranted(String),
    /// The grant points at a different daemon than the one this process serves.
    EndpointMismatch { grant: String, configured: String },
}

impl Refusal {
    /// Errors are visible, not silent: the model must not read a refused action
    /// as a completed one.
    pub fn code(&self) -> &'static str {
        match self {
            Refusal::NotConfigured => "mcp_grant_not_configured",
            Refusal::Unreadable(_) => "mcp_grant_unreadable",
            Refusal::NotArmed(_) => "mcp_grant_not_armed",
            Refusal::ToolNotGranted(_) => "mcp_tool_not_granted",
            Refusal::EndpointMismatch { .. } => "mcp_grant_endpoint_mismatch",
        }
    }

    pub fn message(&self) -> String {
        match self {
            Refusal::NotConfigured => {
                "本轮没有为 MCP 面挂载授权文件，动作工具不可用；只读工具不受影响。".to_owned()
            }
            Refusal::Unreadable(detail) => format!("MCP 授权文件读不出来：{detail}"),
            Refusal::NotArmed(state) => {
                format!("本轮授权状态是 `{state}`，不是 armed；动作工具已拒绝。")
            }
            Refusal::ToolNotGranted(name) => {
                format!("本轮没有开放工具 `{name}`；动作工具已拒绝。")
            }
            Refusal::EndpointMismatch { grant, configured } => format!(
                "授权文件指向 {grant}，本进程服务的是 {configured}；拒绝沿用一份不属于本权威的授权。"
            ),
        }
    }
}

/// Where the grant lives, when the caller declared one.
#[derive(Debug, Clone, Default)]
pub struct GrantSource {
    path: Option<PathBuf>,
}

impl GrantSource {
    pub fn none() -> Self {
        Self { path: None }
    }

    pub fn at(path: impl Into<PathBuf>) -> Self {
        Self {
            path: Some(path.into()),
        }
    }

    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    /// Whether `tool` may act on the world right now. Read-only tools do not
    /// consult this at all.
    pub fn authorize(&self, tool: &str, configured_endpoint: &Path) -> Result<(), Refusal> {
        let Some(path) = self.path() else {
            return Err(Refusal::NotConfigured);
        };
        let text = std::fs::read_to_string(path)
            .map_err(|error| Refusal::Unreadable(format!("{}: {error}", path.display())))?;
        let document: Value = serde_json::from_str(&text)
            .map_err(|error| Refusal::Unreadable(format!("{}: {error}", path.display())))?;
        let state = document
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or("absent");
        if state != "armed" {
            return Err(Refusal::NotArmed(state.to_owned()));
        }
        // A grant written for a different daemon must not authorize this one:
        // otherwise a stale document from another private root would silently
        // widen this process's reach.
        let grant_endpoint = document
            .get("endpointFile")
            .and_then(Value::as_str)
            .ok_or_else(|| Refusal::Unreadable("missing endpointFile".to_owned()))?;
        if Path::new(grant_endpoint) != configured_endpoint {
            return Err(Refusal::EndpointMismatch {
                grant: grant_endpoint.to_owned(),
                configured: configured_endpoint.display().to_string(),
            });
        }
        let granted = document
            .get("tools")
            .and_then(Value::as_array)
            .map(|tools| {
                tools
                    .iter()
                    .any(|entry| entry.get("name").and_then(Value::as_str) == Some(tool))
            })
            .unwrap_or(false);
        if !granted {
            return Err(Refusal::ToolNotGranted(tool.to_owned()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_grant(body: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("gmgn-mcpd-grant-{}.json", uuid()));
        std::fs::write(&path, body).unwrap();
        path
    }

    fn uuid() -> String {
        use std::sync::atomic::{AtomicU64, Ordering};
        use std::time::{SystemTime, UNIX_EPOCH};
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let sequence = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        format!("{nanos}-{}-{sequence}", std::process::id())
    }

    const ENDPOINT_FILE: &str = "/tmp/gmgn-test/taskd.endpoint.json";

    #[test]
    fn no_grant_configured_is_a_refusal_not_a_permission() {
        let source = GrantSource::none();
        assert!(source.path().is_none());
        assert_eq!(
            source.authorize("gmgn_prop_submit", Path::new(ENDPOINT_FILE)),
            Err(Refusal::NotConfigured)
        );
    }

    #[test]
    fn an_unarmed_round_refuses_every_action() {
        let path = write_grant(&format!(
            r#"{{"state":"revoked","tools":[{{"name":"gmgn_prop_submit"}}],"endpointFile":"{ENDPOINT_FILE}"}}"#
        ));
        let source = GrantSource::at(&path);
        assert_eq!(source.path(), Some(path.as_path()));
        assert_eq!(
            source.authorize("gmgn_prop_submit", Path::new(ENDPOINT_FILE)),
            Err(Refusal::NotArmed("revoked".to_owned()))
        );
    }

    #[test]
    fn an_armed_round_only_opens_the_tools_it_names() {
        let path = write_grant(&format!(
            r#"{{"state":"armed","tools":[{{"name":"gmgn_world_commit"}}],"endpointFile":"{ENDPOINT_FILE}"}}"#
        ));
        let source = GrantSource::at(&path);
        assert_eq!(
            source.authorize("gmgn_world_commit", Path::new(ENDPOINT_FILE)),
            Ok(())
        );
        assert_eq!(
            source.authorize("gmgn_prop_submit", Path::new(ENDPOINT_FILE)),
            Err(Refusal::ToolNotGranted("gmgn_prop_submit".to_owned()))
        );
    }

    #[test]
    fn a_grant_for_another_daemon_does_not_authorize_this_one() {
        let path = write_grant(
            r#"{"state":"armed","tools":[{"name":"gmgn_prop_submit"}],"endpointFile":"/tmp/other/taskd.endpoint.json"}"#,
        );
        let source = GrantSource::at(&path);
        assert_eq!(
            source.authorize("gmgn_prop_submit", Path::new(ENDPOINT_FILE)),
            Err(Refusal::EndpointMismatch {
                grant: "/tmp/other/taskd.endpoint.json".to_owned(),
                configured: ENDPOINT_FILE.to_owned(),
            })
        );
    }

    #[test]
    fn an_armed_grant_without_endpoint_binding_is_refused() {
        for body in [
            r#"{"state":"armed","tools":[{"name":"gmgn_prop_submit"}]}"#,
            r#"{"state":"armed","tools":[{"name":"gmgn_prop_submit"}],"socketPath":"/tmp/gmgn-test/taskd.endpoint.json"}"#,
        ] {
            let path = write_grant(body);
            assert!(matches!(
                GrantSource::at(&path).authorize("gmgn_prop_submit", Path::new(ENDPOINT_FILE)),
                Err(Refusal::Unreadable(_))
            ));
        }
    }

    #[test]
    fn an_unreadable_or_malformed_grant_is_a_refusal() {
        let missing = GrantSource::at("/tmp/gmgn-mcpd-does-not-exist.json");
        assert!(matches!(
            missing.authorize("gmgn_prop_submit", Path::new(ENDPOINT_FILE)),
            Err(Refusal::Unreadable(_))
        ));
        let path = write_grant("not json");
        let source = GrantSource::at(&path);
        assert!(matches!(
            source.authorize("gmgn_prop_submit", Path::new(ENDPOINT_FILE)),
            Err(Refusal::Unreadable(_))
        ));
    }

    #[test]
    fn refusals_are_visible_and_named() {
        // Every refusal has its own code: a caller can tell "you were not
        // allowed" from "the world said no".
        let codes = [
            Refusal::NotConfigured.code(),
            Refusal::Unreadable(String::new()).code(),
            Refusal::NotArmed(String::new()).code(),
            Refusal::ToolNotGranted(String::new()).code(),
            Refusal::EndpointMismatch {
                grant: String::new(),
                configured: String::new(),
            }
            .code(),
        ];
        let unique: std::collections::BTreeSet<_> = codes.iter().collect();
        assert_eq!(unique.len(), codes.len());
        for code in codes {
            assert!(code.starts_with("mcp_"), "{code}");
        }
    }
}
