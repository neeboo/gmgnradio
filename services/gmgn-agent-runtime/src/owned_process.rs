//! Shared ownership of one spawned child and its freshly-created Unix group.
use std::{io, process::ExitStatus, time::Duration};
use tokio::process::{Child, Command};

pub(crate) struct OwnedProcess {
    pub(crate) child: Child,
    #[cfg(unix)]
    group: Option<i32>,
}
#[cfg(unix)]
fn signal_owned_group(group: i32, signal: i32) {
    debug_assert!(group > 0);
    // SAFETY: this group can only originate from our process_group(0) spawn.
    unsafe {
        libc::kill(-group, signal);
    }
}
impl Drop for OwnedProcess {
    fn drop(&mut self) {
        #[cfg(unix)]
        if let Some(group) = self.group.take() {
            signal_owned_group(group, libc::SIGKILL);
        }
    }
}
impl OwnedProcess {
    pub(crate) fn spawn(command: &mut Command) -> io::Result<Self> {
        command.kill_on_drop(true);
        #[cfg(unix)]
        command.process_group(0);
        let child = command.spawn()?;
        #[cfg(unix)]
        let group = i32::try_from(child.id().ok_or(io::ErrorKind::Other)?)
            .map_err(|_| io::ErrorKind::Other)?;
        Ok(Self {
            child,
            #[cfg(unix)]
            group: Some(group),
        })
    }
    /// Observe termination without releasing the Unix leader PID/owned PGID.
    pub(crate) fn has_exited(&mut self) -> io::Result<bool> {
        #[cfg(unix)]
        {
            let pid = self.child.id().ok_or(io::ErrorKind::Other)?;
            let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
            // SAFETY: only this object's own unreaped child is observed; zeroed
            // siginfo remains valid when WNOHANG finds no child termination.
            let result = unsafe {
                libc::waitid(
                    libc::P_PID,
                    pid as libc::id_t,
                    info.as_mut_ptr(),
                    libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
                )
            };
            if result != 0 {
                return Err(io::Error::last_os_error());
            }
            return Ok(unsafe { info.assume_init().si_pid() != 0 });
        }
        #[cfg(not(unix))]
        {
            Ok(self.child.try_wait()?.is_some())
        }
    }
    pub(crate) async fn shutdown(&mut self) -> io::Result<ExitStatus> {
        #[cfg(unix)]
        if let Some(group) = self.group {
            signal_owned_group(group, libc::SIGTERM);
            // Do not reap during grace: preserve the PID so PGID cannot be reused.
            tokio::time::sleep(Duration::from_millis(250)).await;
            signal_owned_group(group, libc::SIGKILL);
            self.group = None;
        }
        let _ = self.child.start_kill();
        self.child.wait().await
    }
}
