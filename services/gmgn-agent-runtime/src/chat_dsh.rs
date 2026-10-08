//! Ordinary-chat ACP policy. Native web remains mounted; no world/tool grants.
use crate::chat_cli::ChatCliError;
use crate::{
    cli_transport::{CliConfig, OwnedCliTransport},
    dsh_session::{DshEvent, DshSession, DshState},
    CancellationToken, UserInput,
};
use std::collections::BTreeMap;
use std::{path::PathBuf, time::Duration};
pub struct ChatDshConfig {
    pub node_executable: PathBuf,
    pub entry_point: PathBuf,
    pub composition_file: PathBuf,
    pub cwd: PathBuf,
    pub environment: BTreeMap<String, String>,
    pub lifetime: Duration,
    pub attachment_home: PathBuf,
    pub persistence_root: PathBuf,
    pub persona: String,
}
pub struct ChatDshSession {
    transport: OwnedCliTransport,
    protocol: DshSession<ChatDshIdentity>,
    usable: bool,
}
impl ChatDshSession {
    /// Service retains this owned actor only for the same ordinary scope/host.
    pub async fn open(
        config: ChatDshConfig,
        identity: ChatDshIdentity,
        input: UserInput,
        cancel: CancellationToken,
    ) -> Result<(Self, String), ChatCliError> {
        if cancel.is_cancelled() {
            return Err(ChatCliError::Cancelled);
        }
        let expected = composition(
            &config.attachment_home.to_string_lossy(),
            &config.persistence_root.to_string_lossy(),
            &config.persona,
        )?;
        for path in [
            &config.node_executable,
            &config.entry_point,
            &config.composition_file,
            &config.cwd,
            &config.attachment_home,
            &config.persistence_root,
        ] {
            if !path.is_absolute() {
                return Err(ChatCliError::InvalidConfiguration);
            }
        }
        if std::fs::metadata(&config.composition_file)
            .map_err(|_| ChatCliError::InvalidConfiguration)?
            .len()
            > 1_048_576
            || std::fs::read_to_string(&config.composition_file)
                .map_err(|_| ChatCliError::InvalidConfiguration)?
                != expected
        {
            return Err(ChatCliError::InvalidConfiguration);
        }
        let mut protocol =
            DshSession::new_chat(identity, config.cwd.to_string_lossy().into_owned(), input)
                .map_err(|_| ChatCliError::InvalidInput)?;
        let initialize = protocol
            .initialize()
            .map_err(|_| ChatCliError::InvalidResult)?;
        let transport = OwnedCliTransport::spawn(CliConfig {
            executable: config.node_executable,
            arguments: vec![
                config.entry_point.to_string_lossy().into_owned(),
                "--config".into(),
                config.composition_file.to_string_lossy().into_owned(),
            ],
            environment: environment(&config.environment),
            working_directory: Some(config.cwd),
            lifetime: config.lifetime,
        })
        .await
        .map_err(|_| ChatCliError::TransportFailed)?;
        let mut actor = Self {
            transport,
            protocol,
            usable: true,
        };
        if actor.transport.send(&initialize).await.is_err() {
            actor.close().await;
            return Err(ChatCliError::TransportFailed);
        }
        let reply = actor.drive(cancel).await?;
        Ok((actor, reply))
    }
    pub fn session_id(&self) -> Option<&str> {
        self.protocol.session_id()
    }
    pub fn identity(&self) -> &ChatDshIdentity {
        self.protocol.identity()
    }
    pub fn is_usable(&self) -> bool {
        self.usable
    }
    pub async fn turn(
        &mut self,
        identity: ChatDshIdentity,
        input: UserInput,
        cancel: CancellationToken,
    ) -> Result<String, ChatCliError> {
        if !self.usable {
            return Err(ChatCliError::TransportFailed);
        }
        let frame = self
            .protocol
            .next_chat_turn(identity, input)
            .map_err(|_| ChatCliError::InvalidInput)?;
        let sent = tokio::select! { biased; _=cancel.cancelled()=>Err(ChatCliError::Cancelled), sent=self.transport.send(&frame)=>sent.map_err(|_|ChatCliError::TransportFailed) };
        if let Err(error) = sent {
            self.close().await;
            return Err(error);
        }
        self.drive(cancel).await
    }
    pub async fn close(&mut self) {
        self.usable = false;
        self.transport.cancel();
        self.transport.wait_closed().await;
    }
    async fn drive(&mut self, cancel: CancellationToken) -> Result<String, ChatCliError> {
        loop {
            let frame = tokio::select! {biased; _=cancel.cancelled()=>{
                for event in self.protocol.cancel(){if let DshEvent::Send(frame)=event{let _=tokio::time::timeout(Duration::from_millis(100),self.transport.send(&frame)).await;}}
                // Send native cancel first; regardless of peer acknowledgement,
                // do not settle until the exact owned process group is reaped.
                self.close().await;return Err(ChatCliError::Cancelled)
            },frame=self.transport.receive()=>frame};
            let frame = match frame {
                Ok(frame) => frame,
                Err(error) => {
                    self.protocol.disconnected();
                    self.close().await;
                    return Err(if error == crate::cli_transport::CliError::TimedOut {
                        ChatCliError::TimedOut
                    } else {
                        ChatCliError::TransportFailed
                    });
                }
            };
            let events = match self.protocol.receive(frame) {
                Ok(events) => events,
                Err(_) => {
                    self.close().await;
                    return Err(ChatCliError::InvalidResult);
                }
            };
            for event in events {
                match event {
                    DshEvent::Send(frame) => {
                        let sent = tokio::select! { biased; _=cancel.cancelled()=>Err(ChatCliError::Cancelled), sent=self.transport.send(&frame)=>sent.map_err(|_|ChatCliError::TransportFailed) };
                        if let Err(error) = sent {
                            self.close().await;
                            return Err(error);
                        }
                    }
                    DshEvent::Terminal {
                        state: DshState::Completed,
                        reply,
                    } => return Ok(reply),
                    DshEvent::Terminal { .. } => {
                        self.close().await;
                        return Err(ChatCliError::InvalidResult);
                    }
                    _ => {}
                }
            }
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatDshIdentity {
    pub scope_id: String,
    pub host_session_id: String,
    pub request_id: String,
}
pub fn environment(source: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    let mut env = source
        .iter()
        .filter(|(k, v)| {
            ["HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "LOGNAME"].contains(&k.as_str())
                && !v.is_empty()
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect::<BTreeMap<_, _>>();
    env.insert(
        "PATH".into(),
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin".into(),
    );
    env
}
fn quote(value: &str) -> Result<String, ChatCliError> {
    if value.contains(['\0', '\n', '\r']) || value.len() > 65536 {
        return Err(ChatCliError::InvalidConfiguration);
    }
    Ok(value.replace('\'', "''"))
}
/// Exact Swift ordinary ACP composition grammar; no arbitrary YAML/plugin input.
pub fn composition(
    attachment_home: &str,
    persistence_root: &str,
    persona: &str,
) -> Result<String, ChatCliError> {
    if !std::path::Path::new(attachment_home).is_absolute()
        || !std::path::Path::new(persistence_root).is_absolute()
    {
        return Err(ChatCliError::InvalidConfiguration);
    }
    let attachment = quote(attachment_home)?;
    let persistence = quote(persistence_root)?;
    let persona = quote(persona)?;
    Ok(format!("# Generated by gmgn ResidentDSHConfiguration; re-validated by read-back before every launch.\n- id: llm-deepseek\n  name: '@deepseek-ai/dsh-llm-deepseek'\n  config:\n    reasoningEffort: low\n    maxTokens: 8192\n    models:\n      - id: deepseek-flash\n        inputModalities: [text, image]\n      - id: deepseek-v4-pro\n        inputModalities: [text]\n- id: credentials\n  name: '@deepseek-ai/dsh-credentials-local'\n- id: attachment-local\n  name: '@deepseek-ai/dsh-attachment-local'\n  config:\n    dshHome: '{attachment}'\n- id: acp-agent\n  name: '@deepseek-ai/dsh-acp-demo'\n  config:\n    provider: deepseek-official\n    model: deepseek-flash\n    persistenceRoot: '{persistence}'\n    packChunks: false\n    persistenceCompression: none\n    workspaceContext: false\n    toolBash: false\n    toolJobs: false\n    goals: false\n    skills:\n      enabled: false\n    tools:\n      mode: native\n    persona: '{persona}'\n- id: web\n  name: '@deepseek-ai/dsh-web'\n  config:\n    searchProvider: deepseek-official\n- id: web-fetch-http\n  name: '@deepseek-ai/dsh-web-fetch-http'\n- id: web-search-deepseek\n  name: '@deepseek-ai/dsh-web-search-deepseek'\n- id: tool-web\n  name: '@deepseek-ai/dsh-tool-web'"))
}
