use crate::model::Result;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
};

pub fn directory(path: &Path) -> Result<()> {
    if let Ok(m) = fs::symlink_metadata(path) {
        if !m.is_dir() || m.file_type().is_symlink() {
            return Err("unsafe_path");
        }
    }
    fs::create_dir_all(path).map_err(|_| "storage_unavailable")?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|_| "storage_unavailable")
}
pub fn open_private(path: &Path) -> Result<File> {
    let f = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| "unsafe_path")?;
    if !f.metadata().map_err(|_| "storage_unavailable")?.is_file() {
        return Err("unsafe_path");
    }
    f.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|_| "storage_unavailable")?;
    Ok(f)
}
pub fn read(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| "unsafe_path")?;
    let m = f.metadata().map_err(|_| "storage_unavailable")?;
    if !m.is_file() || m.len() > limit as u64 {
        return Err("invalid_file");
    }
    let mut bytes = vec![];
    f.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "storage_unavailable")?;
    if bytes.len() > limit {
        return Err("invalid_file");
    }
    Ok(bytes)
}
pub fn publish(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Ok(m) = fs::symlink_metadata(path) {
        if !m.is_file() || m.file_type().is_symlink() {
            return Err("unsafe_path");
        }
    }
    let parent = path.parent().ok_or("unsafe_path")?;
    let tmp = parent.join(format!("{}.partial", uuid::Uuid::new_v4()));
    let result = (|| {
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)
            .map_err(|_| "storage_unavailable")?;
        f.write_all(bytes).map_err(|_| "storage_unavailable")?;
        f.sync_all().map_err(|_| "storage_unavailable")?;
        fs::rename(&tmp, path).map_err(|_| "storage_unavailable")?;
        File::open(parent)
            .and_then(|d| d.sync_all())
            .map_err(|_| "storage_unavailable")
    })();
    if tmp.exists() {
        let _ = fs::remove_file(tmp);
    }
    result
}
