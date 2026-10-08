//! Small native MCP grant boundary. No provider/runtime/process dependencies.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClaudeError {
    InvalidConfiguration,
    InvalidTools,
    ForbiddenTool,
    MissingCredential,
    InvalidResult,
    OutputLimit,
    InvalidGrant,
    GrantExpired,
    GrantRevoked,
    InvalidArguments,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GrantIdentity {
    pub world_id: String,
    pub scope_id: String,
    pub session_id: String,
    pub run_id: String,
    pub event_id: String,
}
/// Intentionally not Debug/Serialize: secrets never enter diagnostics automatically.
#[derive(Clone)]
pub struct ClaudeGrant {
    pub identity: GrantIdentity,
    pub secret: String,
    pub round: String,
    pub expires_at_ms: u64,
    pub armed: bool,
}
pub struct PinnedGrant {
    identity: GrantIdentity,
    secret: String,
    round: String,
}
impl PinnedGrant {
    pub fn pin(grant: &ClaudeGrant, now_ms: u64) -> Result<Self, ClaudeError> {
        if !uuid_v4(&grant.secret)
            || grant.round.is_empty()
            || grant.round.len() > 256
            || [
                &grant.identity.world_id,
                &grant.identity.scope_id,
                &grant.identity.session_id,
                &grant.identity.run_id,
                &grant.identity.event_id,
            ]
            .iter()
            .any(|s| s.is_empty() || s.len() > 256)
        {
            return Err(ClaudeError::InvalidGrant);
        }
        let pinned = Self {
            identity: grant.identity.clone(),
            secret: grant.secret.clone(),
            round: grant.round.clone(),
        };
        pinned.verify(grant, now_ms)?;
        Ok(pinned)
    }
    pub fn verify(&self, grant: &ClaudeGrant, now_ms: u64) -> Result<(), ClaudeError> {
        if !grant.armed
            || self.identity != grant.identity
            || self.secret != grant.secret
            || self.round != grant.round
        {
            return Err(ClaudeError::GrantRevoked);
        }
        if now_ms >= grant.expires_at_ms {
            return Err(ClaudeError::GrantExpired);
        }
        Ok(())
    }
}
pub fn uuid_v4(token: &str) -> bool {
    let b = token.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| {
            if [8, 13, 18, 23].contains(&i) {
                *c == b'-'
            } else {
                c.is_ascii_digit() || (*c >= b'a' && *c <= b'f')
            }
        })
        && b[14] == b'4'
        && [b'8', b'9', b'a', b'b'].contains(&b[19])
}
pub fn forbidden_tool(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    let candidate = lower.strip_prefix("gmgn_").unwrap_or(&lower);
    let candidate = candidate.rsplit("__").next().unwrap_or(candidate);
    [
        "shell",
        "bash",
        "sh",
        "zsh",
        "fish",
        "exec",
        "execute",
        "run",
        "run_command",
        "system",
        "terminal",
        "process",
        "subprocess",
        "read",
        "write",
        "edit",
        "patch",
        "apply_patch",
        "read_file",
        "write_file",
        "filesystem",
        "fs",
        "grep",
        "glob",
        "str_replace_editor",
        "web_search",
        "web_fetch",
    ]
    .contains(&candidate)
}
