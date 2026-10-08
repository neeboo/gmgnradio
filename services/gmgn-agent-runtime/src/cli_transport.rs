//! Bounded JSONL transport for one explicitly configured, owned subprocess.
//! No discovery, credential reads, shell evaluation, or resident/model loop.
use crate::owned_process::OwnedProcess;
use serde_json::Value;
use std::{collections::BTreeMap, path::PathBuf, process::Stdio, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    process::Command,
    sync::{mpsc, oneshot, watch},
};
use tokio_util::sync::CancellationToken;

pub const MAX_FRAME_BYTES: usize = 1_048_576;
/// Outbound 4MiB typed image expands to base64 plus bounded textual context.
/// This does not relax the independent stdout/read limit.
pub const MAX_WRITE_BYTES: usize = 6 * 1_048_576;
const QUEUE_LIMIT: usize = 8;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CliError {
    InvalidConfiguration,
    LaunchFailed,
    ConnectionClosed,
    InvalidFrame,
    FrameTooLarge,
    WriteFailed,
    TimedOut,
    Cancelled,
}
impl CliError {
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidConfiguration => "cli_invalid_configuration",
            Self::LaunchFailed => "cli_launch_failed",
            Self::ConnectionClosed => "cli_connection_closed",
            Self::InvalidFrame => "cli_invalid_frame",
            Self::FrameTooLarge => "cli_frame_too_large",
            Self::WriteFailed => "cli_write_failed",
            Self::TimedOut => "cli_timed_out",
            Self::Cancelled => "cli_cancelled",
        }
    }
}
impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for CliError {}

/// Supplied by a trusted host. Environment is exact: nothing is inherited.
/// Permissions and provider-specific argv/config checks belong to protocol policy.
pub struct CliConfig {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub environment: BTreeMap<String, String>,
    pub working_directory: Option<PathBuf>,
    pub lifetime: Duration,
}
impl CliConfig {
    pub(crate) fn validate(&self) -> Result<(), CliError> {
        let bad = self.executable.as_os_str().is_empty()
            || !self.executable.is_absolute()
            || self
                .working_directory
                .as_ref()
                .is_some_and(|p| !p.is_absolute())
            || self.lifetime.is_zero()
            || self.lifetime > Duration::from_secs(3600)
            || self.arguments.len() > 128
            || self.arguments.iter().any(|s| s.contains('\0'))
            || self.arguments.iter().map(String::len).sum::<usize>() > 65536
            || self.environment.len() > 128
            || self
                .environment
                .iter()
                .any(|(k, v)| k.is_empty() || k.contains(['\0', '=']) || v.contains('\0'))
            || self
                .environment
                .iter()
                .map(|(k, v)| k.len() + v.len())
                .sum::<usize>()
                > 65536;
        if bad {
            Err(CliError::InvalidConfiguration)
        } else {
            Ok(())
        }
    }
}
struct WriteRequest {
    bytes: Vec<u8>,
    reply: oneshot::Sender<Result<(), CliError>>,
}
struct BoundedFrame {
    bytes: Vec<u8>,
    overflow: bool,
}
impl std::io::Write for BoundedFrame {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if bytes.len() > MAX_WRITE_BYTES.saturating_sub(self.bytes.len()) {
            self.overflow = true;
            return Err(std::io::ErrorKind::InvalidData.into());
        }
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}
pub struct OwnedCliTransport {
    pid: u32,
    writes: mpsc::Sender<WriteRequest>,
    frames: mpsc::Receiver<Value>,
    terminal: watch::Receiver<Option<CliError>>,
    cancellation: CancellationToken,
}
impl Drop for OwnedCliTransport {
    fn drop(&mut self) {
        self.cancellation.cancel();
    }
}
impl OwnedCliTransport {
    pub async fn spawn(config: CliConfig) -> Result<Self, CliError> {
        config.validate()?;
        let mut command = Command::new(config.executable);
        command
            .args(config.arguments)
            .env_clear()
            .envs(config.environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        if let Some(cwd) = config.working_directory {
            command.current_dir(cwd);
        }
        let mut process = OwnedProcess::spawn(&mut command).map_err(|_| CliError::LaunchFailed)?;
        let pid = process.child.id().ok_or(CliError::LaunchFailed)?;
        let mut stdin = process.child.stdin.take().ok_or(CliError::LaunchFailed)?;
        let mut stdout = process.child.stdout.take().ok_or(CliError::LaunchFailed)?;
        let mut stderr = process.child.stderr.take().ok_or(CliError::LaunchFailed)?;
        let (writes_tx, mut writes) = mpsc::channel::<WriteRequest>(QUEUE_LIMIT);
        let (frames_tx, frames) = mpsc::channel(QUEUE_LIMIT);
        let (terminal_tx, terminal) = watch::channel(None);
        let cancellation = CancellationToken::new();
        let cancel = cancellation.clone();
        tokio::spawn(async move {
            // Never retain, return, classify by raw content, or log stderr.
            let stderr_task = tokio::spawn(async move {
                let mut bytes = [0u8; 8192];
                loop {
                    match stderr.read(&mut bytes).await {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                }
            });
            let deadline = tokio::time::Instant::now() + config.lifetime;
            let write_cancel = cancel.clone();
            let mut write_task = tokio::spawn(async move {
                loop {
                    let request = tokio::select! {
                        _=write_cancel.cancelled()=>return CliError::Cancelled,
                        _=tokio::time::sleep_until(deadline)=>return CliError::TimedOut,
                        request=writes.recv()=>match request {Some(r)=>r,None=>return CliError::Cancelled},
                    };
                    let written = tokio::select! {
                        _=write_cancel.cancelled()=>Err(CliError::Cancelled),
                        _=tokio::time::sleep_until(deadline)=>Err(CliError::TimedOut),
                        write=stdin.write_all(&request.bytes)=>write.map_err(|_|CliError::WriteFailed),
                    };
                    let _ = request.reply.send(written);
                    if let Err(e) = written {
                        return e;
                    }
                }
            });
            let mut buffer = Vec::new();
            let mut chunk = [0u8; 8192];
            let reason = loop {
                tokio::select! {
                    biased;
                    _=cancel.cancelled()=>break CliError::Cancelled,
                    _=tokio::time::sleep_until(deadline)=>break CliError::TimedOut,
                    written=&mut write_task=>break written.unwrap_or(CliError::WriteFailed),
                    read=stdout.read(&mut chunk)=>{
                        let n=match read {Ok(0)=>break if buffer.is_empty(){CliError::ConnectionClosed}else{CliError::InvalidFrame},Ok(n)=>n,Err(_)=>break CliError::ConnectionClosed};
                        let mut failure=None;
                        for byte in &chunk[..n] {
                            if *byte==b'\n' {
                                if buffer.last()==Some(&b'\r') {buffer.pop();}
                                let frame=serde_json::from_slice::<Value>(&buffer).ok().filter(Value::is_object);
                                buffer.clear();
                                let Some(frame)=frame else {failure=Some(CliError::InvalidFrame);break;};
                                let sent=tokio::select! {
                                    _=cancel.cancelled()=>Err(CliError::Cancelled),
                                    _=tokio::time::sleep_until(deadline)=>Err(CliError::TimedOut),
                                    sent=frames_tx.send(frame)=>sent.map_err(|_|CliError::Cancelled),
                                };
                                if let Err(e)=sent {failure=Some(e);break;}
                            } else {
                                if buffer.len()>=MAX_FRAME_BYTES {failure=Some(CliError::FrameTooLarge);break;}
                                buffer.push(*byte);
                            }
                        }
                        if let Some(e)=failure {break e;}
                    },
                }
            };
            // Unix: reclaim only the group created for this owned spawn. Other
            // platforms retain exact-Child cleanup; no Windows claim is made.
            cancel.cancel();
            let _ = process.shutdown().await;
            if !write_task.is_finished() {
                let _ = write_task.await;
            }
            stderr_task.abort();
            let _ = stderr_task.await;
            let _ = terminal_tx.send(Some(reason));
        });
        Ok(Self {
            pid,
            writes: writes_tx,
            frames,
            terminal,
            cancellation,
        })
    }
    pub fn process_id(&self) -> u32 {
        self.pid
    }
    pub fn cancel(&self) {
        self.cancellation.cancel();
    }
    pub async fn send(&self, value: &Value) -> Result<(), CliError> {
        if !value.is_object() {
            return Err(CliError::InvalidFrame);
        }
        let mut frame = BoundedFrame {
            bytes: Vec::new(),
            overflow: false,
        };
        if serde_json::to_writer(&mut frame, value).is_err() {
            return Err(if frame.overflow {
                CliError::FrameTooLarge
            } else {
                CliError::InvalidFrame
            });
        }
        let mut bytes = frame.bytes;
        bytes.push(b'\n');
        let (reply, result) = oneshot::channel();
        tokio::select! {
            _=self.cancellation.cancelled()=>return Err(CliError::Cancelled),
            sent=self.writes.send(WriteRequest{bytes,reply})=>sent.map_err(|_|CliError::ConnectionClosed)?,
        }
        tokio::select! {_=self.cancellation.cancelled()=>Err(CliError::Cancelled),result=result=>result.map_err(|_|CliError::ConnectionClosed)?}
    }
    pub async fn receive(&mut self) -> Result<Value, CliError> {
        loop {
            if let Ok(frame) = self.frames.try_recv() {
                return Ok(frame);
            }
            if let Some(e) = *self.terminal.borrow() {
                return Err(e);
            }
            tokio::select! {
                biased;
                frame=self.frames.recv()=>if let Some(frame)=frame {return Ok(frame);}else{return Err(self.terminal.borrow().unwrap_or(CliError::ConnectionClosed));},
                changed=self.terminal.changed()=>if changed.is_err(){return Err(CliError::ConnectionClosed);},
            }
        }
    }
    /// Returns only after the owned child has been waited/reaped.
    pub async fn wait_closed(&mut self) -> CliError {
        loop {
            if let Some(e) = *self.terminal.borrow() {
                return e;
            }
            if self.terminal.changed().await.is_err() {
                return CliError::ConnectionClosed;
            }
        }
    }
}
