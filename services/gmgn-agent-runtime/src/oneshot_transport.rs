//! Raw UTF-8, bounded one-shot transport. No CLI discovery or credential reads.
pub use crate::cli_transport::CliConfig as OneshotConfig;
use crate::owned_process::OwnedProcess;
use std::{
    process::{ExitStatus, Stdio},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWriteExt},
    process::Command,
    sync::oneshot,
};
use tokio_util::sync::CancellationToken;
pub const MAX_STREAM_BYTES: usize = 4 * 1_048_576;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OneshotError {
    InvalidConfiguration,
    InputTooLarge,
    LaunchFailed,
    WriteFailed,
    StdoutTooLarge,
    StderrTooLarge,
    ReadFailed,
    InvalidUtf8,
    Cancelled,
    TimedOut,
    WaitFailed,
}
impl OneshotError {
    pub fn code(self) -> &'static str {
        match self {
            Self::InvalidConfiguration => "oneshot_invalid_configuration",
            Self::InputTooLarge => "oneshot_input_too_large",
            Self::LaunchFailed => "oneshot_launch_failed",
            Self::WriteFailed => "oneshot_write_failed",
            Self::StdoutTooLarge => "oneshot_stdout_too_large",
            Self::StderrTooLarge => "oneshot_stderr_too_large",
            Self::ReadFailed => "oneshot_read_failed",
            Self::InvalidUtf8 => "oneshot_invalid_utf8",
            Self::Cancelled => "oneshot_cancelled",
            Self::TimedOut => "oneshot_timed_out",
            Self::WaitFailed => "oneshot_wait_failed",
        }
    }
}
impl std::fmt::Display for OneshotError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}
impl std::error::Error for OneshotError {}
#[derive(Debug)]
pub struct OneshotOutput {
    pub stdout: String,
    pub status: ExitStatus,
}
struct CancelOnDrop(CancellationToken);
impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        self.0.cancel();
    }
}
async fn read_stream<R: AsyncRead + Unpin>(
    mut reader: R,
    keep: bool,
    stop: CancellationToken,
) -> Result<Vec<u8>, OneshotError> {
    let mut output = Vec::new();
    let mut count = 0;
    let mut buffer = [0u8; 8192];
    loop {
        // Ready bytes are drained after leader exit; a held-open inherited pipe
        // cannot keep the owned supervisor alive indefinitely.
        let n = tokio::select! { biased; r=reader.read(&mut buffer)=>r.map_err(|_|OneshotError::ReadFailed)?, _=stop.cancelled()=>return Err(OneshotError::ReadFailed) };
        if n == 0 {
            return Ok(output);
        }
        count += n;
        if count > MAX_STREAM_BYTES {
            return Err(if keep {
                OneshotError::StdoutTooLarge
            } else {
                OneshotError::StderrTooLarge
            });
        }
        if keep {
            output.extend_from_slice(&buffer[..n]);
        }
    }
}
/// Dropping this future cancels its supervisor, which still reaps its owned tree.
pub async fn run(
    config: OneshotConfig,
    input: String,
    cancellation: CancellationToken,
) -> Result<OneshotOutput, OneshotError> {
    config
        .validate()
        .map_err(|_| OneshotError::InvalidConfiguration)?;
    if input.len() > MAX_STREAM_BYTES {
        return Err(OneshotError::InputTooLarge);
    }
    let cancel = cancellation.child_token();
    let _guard = CancelOnDrop(cancel.clone());
    let (tx, rx) = oneshot::channel();
    tokio::spawn(async move {
        let result = supervise(config, input, cancel).await;
        let _ = tx.send(result);
    });
    rx.await.map_err(|_| OneshotError::WaitFailed)?
}
async fn supervise(
    config: OneshotConfig,
    input: String,
    cancel: CancellationToken,
) -> Result<OneshotOutput, OneshotError> {
    if cancel.is_cancelled() {
        return Err(OneshotError::Cancelled);
    }
    let mut command = Command::new(&config.executable);
    command
        .args(&config.arguments)
        .env_clear()
        .envs(&config.environment)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(cwd) = config.working_directory {
        command.current_dir(cwd);
    }
    let mut process = OwnedProcess::spawn(&mut command).map_err(|_| OneshotError::LaunchFailed)?;
    let mut stdin = process
        .child
        .stdin
        .take()
        .ok_or(OneshotError::LaunchFailed)?;
    let stdout = process
        .child
        .stdout
        .take()
        .ok_or(OneshotError::LaunchFailed)?;
    let stderr = process
        .child
        .stderr
        .take()
        .ok_or(OneshotError::LaunchFailed)?;
    let stop = CancellationToken::new();
    let writer_stop = stop.clone();
    let mut writer = tokio::spawn(async move {
        tokio::select! { r=async {stdin.write_all(input.as_bytes()).await?; stdin.shutdown().await}=>r.map_err(|_|OneshotError::WriteFailed), _=writer_stop.cancelled()=>Err(OneshotError::WriteFailed) }
    });
    let mut out = tokio::spawn(read_stream(stdout, true, stop.clone()));
    let mut err = tokio::spawn(read_stream(stderr, false, stop.clone()));
    let mut written = None;
    let mut output = None;
    let mut drained = None;
    let deadline = tokio::time::sleep(config.lifetime);
    tokio::pin!(deadline);
    let mut tick = tokio::time::interval(Duration::from_millis(5));
    let failure = loop {
        tokio::select! {
            _=cancel.cancelled()=>break Some(OneshotError::Cancelled),
            _=&mut deadline=>break Some(OneshotError::TimedOut),
            r=&mut writer, if written.is_none()=>{let r=r.unwrap_or(Err(OneshotError::WriteFailed)); if let Err(e)=r {written=Some(r);break Some(e)} written=Some(r);},
            r=&mut out, if output.is_none()=>{let r=r.unwrap_or(Err(OneshotError::ReadFailed)); if let Err(e)=r {output=Some(r);break Some(e)} output=Some(r);},
            r=&mut err, if drained.is_none()=>{let r=r.unwrap_or(Err(OneshotError::ReadFailed)); if let Err(e)=r {drained=Some(r);break Some(e)} drained=Some(r);},
            _=tick.tick()=>match process.has_exited() {Ok(true)=>break None,Ok(false)=>{},Err(_)=>break Some(OneshotError::WaitFailed)}
        }
    };
    let status = process
        .shutdown()
        .await
        .map_err(|_| OneshotError::WaitFailed);
    stop.cancel();
    let written = match written {
        Some(r) => r,
        None => writer.await.unwrap_or(Err(OneshotError::WriteFailed)),
    };
    let output = match output {
        Some(r) => r,
        None => out.await.unwrap_or(Err(OneshotError::ReadFailed)),
    };
    let drained = match drained {
        Some(r) => r,
        None => err.await.unwrap_or(Err(OneshotError::ReadFailed)),
    };
    if let Some(e) = failure {
        return Err(e);
    }
    written?;
    drained?;
    Ok(OneshotOutput {
        stdout: String::from_utf8(output?).map_err(|_| OneshotError::InvalidUtf8)?,
        status: status?,
    })
}
