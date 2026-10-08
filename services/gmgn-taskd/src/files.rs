use crate::model::Result;
#[cfg(not(any(unix, windows)))]
compile_error!("private task storage requires Unix permissions or Windows ACLs");
#[cfg(unix)]
use std::fs::OpenOptions;
#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::{
    fs::{self, File},
    io::{Read, Write},
    path::Path,
};

pub fn directory(path: &Path) -> Result<()> {
    reject_links(path)?;
    if let Ok(m) = fs::symlink_metadata(path) {
        if !m.is_dir() || m.file_type().is_symlink() {
            return Err("unsafe_path");
        }
    }
    #[cfg(unix)]
    {
        fs::create_dir_all(path).map_err(|_| "storage_unavailable")?;
        let handle = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open(path)
            .map_err(|_| "unsafe_path")?;
        handle
            .set_permissions(fs::Permissions::from_mode(0o700))
            .map_err(|_| "storage_unavailable")
    }
    #[cfg(windows)]
    {
        windows_private::secure_directory(path)
    }
}
pub fn open_private(path: &Path) -> Result<File> {
    reject_links(path)?;
    #[cfg(windows)]
    {
        return windows_private::open(path, true, false);
    }
    #[cfg(unix)]
    {
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
}
/// Create a brand new private file, preserving `create_new` semantics so a
/// caller can treat `ErrorKind::AlreadyExists` as an idempotent retry.
///
/// unix: `O_CREAT|O_EXCL` with mode `0600` and `O_NOFOLLOW|O_CLOEXEC`.
/// Windows: `CREATE_NEW` with a protected DACL granting only the current user.
/// Windows has no mode bits, so `0600` has no literal equivalent there; the
/// protected DACL is the control that keeps the file private.
pub fn create_new_private(path: &Path) -> std::io::Result<File> {
    reject_links(path).map_err(|_| std::io::Error::new(std::io::ErrorKind::InvalidInput, "unsafe_path"))?;
    #[cfg(unix)]
    {
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
    }
    #[cfg(windows)]
    {
        windows_private::create_new_io(path)
    }
}
pub fn read(path: &Path, limit: usize) -> Result<Vec<u8>> {
    reject_links(path)?;
    #[cfg(unix)]
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|_| "unsafe_path")?;
    #[cfg(windows)]
    let f = windows_private::open(path, false, false)?;
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
    reject_links(path)?;
    if let Ok(m) = fs::symlink_metadata(path) {
        if !m.is_file() || m.file_type().is_symlink() {
            return Err("unsafe_path");
        }
    }
    let parent = path.parent().ok_or("unsafe_path")?;
    let tmp = parent.join(format!("{}.partial", uuid::Uuid::new_v4()));
    let result = (|| {
        #[cfg(unix)]
        let mut f = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&tmp)
            .map_err(|_| "storage_unavailable")?;
        #[cfg(windows)]
        let mut f = windows_private::open(&tmp, true, true)?;
        f.write_all(bytes).map_err(|_| "storage_unavailable")?;
        f.sync_all().map_err(|_| "storage_unavailable")?;
        drop(f);
        reject_links(path)?;
        #[cfg(windows)]
        {
            windows_private::replace(&tmp, path)?;
            Ok(())
        }
        #[cfg(unix)]
        {
            fs::rename(&tmp, path).map_err(|_| "storage_unavailable")?;
            File::open(parent)
                .and_then(|d| d.sync_all())
                .map_err(|_| "storage_unavailable")
        }
    })();
    if tmp.exists() {
        let _ = fs::remove_file(tmp);
    }
    result
}

fn reject_links(path: &Path) -> Result<()> {
    if path.as_os_str().is_empty() {
        return Err("unsafe_path");
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        if path.as_os_str().encode_wide().any(|c| c == 0) {
            return Err("unsafe_path");
        }
    }
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(metadata) => {
                if metadata.file_type().is_symlink() {
                    return Err("unsafe_path");
                }
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return Err("unsafe_path");
                    }
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(_) => return Err("unsafe_path"),
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn private_publish_replaces_and_cleans_temporary_files() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-private-{}", uuid::Uuid::new_v4()));
        directory(&root).unwrap();
        let path = root.join("state.json");
        publish(&path, b"first").unwrap();
        publish(&path, b"second").unwrap();
        assert_eq!(read(&path, 6).unwrap(), b"second");
        assert_eq!(read(&path, 5), Err("invalid_file"));
        assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
        #[cfg(windows)]
        windows_private::assert_private_acl(&path);
        #[cfg(unix)]
        {
            assert_eq!(
                fs::metadata(&root).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        assert!(publish(&root, b"bad").is_err());
        fs::remove_dir_all(&root).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn rejects_leaf_and_parent_symlinks() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-link-{}", uuid::Uuid::new_v4()));
        directory(&root).unwrap();
        let real = root.join("real");
        directory(&real).unwrap();
        publish(&real.join("state"), b"unchanged").unwrap();
        let alias = root.join("alias");
        std::os::unix::fs::symlink(&real, &alias).unwrap();
        assert_eq!(directory(&alias), Err("unsafe_path"));
        assert_eq!(read(&alias.join("state"), 100), Err("unsafe_path"));
        assert!(open_private(&alias.join("state")).is_err());
        assert_eq!(publish(&alias.join("state"), b"bad"), Err("unsafe_path"));
        let leaf = root.join("leaf");
        std::os::unix::fs::symlink(real.join("state"), &leaf).unwrap();
        assert_eq!(publish(&leaf, b"bad"), Err("unsafe_path"));
        assert_eq!(read(&real.join("state"), 100).unwrap(), b"unchanged");
        fs::remove_dir_all(&root).unwrap();
    }
}

#[cfg(windows)]
mod windows_private {
    use super::*;
    use std::os::windows::{ffi::OsStrExt, io::FromRawHandle};
    use windows_sys::Win32::{
        Foundation::*,
        Security::{Authorization::*, *},
        Storage::FileSystem::*,
        System::Threading::*,
    };
    fn wide(path: &Path) -> Vec<u16> {
        path.as_os_str().encode_wide().chain(Some(0)).collect()
    }
    struct Descriptor(PSECURITY_DESCRIPTOR);
    impl Drop for Descriptor {
        fn drop(&mut self) {
            unsafe {
                LocalFree(self.0);
            }
        }
    }
    fn descriptor() -> Result<Descriptor> {
        unsafe {
            let mut token = std::ptr::null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err("storage_unavailable");
            }
            let mut size = 0;
            GetTokenInformation(token, TokenUser, std::ptr::null_mut(), 0, &mut size);
            let mut data = vec![
                0usize;
                (size as usize + std::mem::size_of::<usize>() - 1)
                    / std::mem::size_of::<usize>()
            ];
            let ok =
                GetTokenInformation(token, TokenUser, data.as_mut_ptr().cast(), size, &mut size);
            CloseHandle(token);
            if ok == 0 {
                return Err("storage_unavailable");
            }
            let user = &*(data.as_ptr().cast::<TOKEN_USER>());
            let mut sid = std::ptr::null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut sid) == 0 {
                return Err("storage_unavailable");
            }
            let mut len = 0;
            while *sid.add(len) != 0 {
                len += 1;
            }
            let sid_text = String::from_utf16_lossy(std::slice::from_raw_parts(sid, len));
            LocalFree(sid.cast());
            // Protected DACL: only the process's current user receives access, including children.
            let sddl: Vec<u16> = format!("D:P(A;OICI;FA;;;{sid_text})")
                .encode_utf16()
                .chain(Some(0))
                .collect();
            let mut sd = std::ptr::null_mut();
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(
                sddl.as_ptr(),
                1,
                &mut sd,
                std::ptr::null_mut(),
            ) == 0
            {
                return Err("storage_unavailable");
            }
            Ok(Descriptor(sd))
        }
    }
    fn secure(handle: HANDLE, sd: &Descriptor) -> Result<()> {
        unsafe {
            let mut present = 0;
            let mut defaulted = 0;
            let mut acl = std::ptr::null_mut();
            if GetSecurityDescriptorDacl(sd.0, &mut present, &mut acl, &mut defaulted) == 0
                || present == 0
                || acl.is_null()
            {
                return Err("storage_unavailable");
            }
            if SetSecurityInfo(
                handle,
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                acl,
                std::ptr::null_mut(),
            ) != 0
            {
                return Err("storage_unavailable");
            }
            Ok(())
        }
    }
    pub fn secure_directory(path: &Path) -> Result<()> {
        let sd = descriptor()?;
        unsafe {
            if !path.exists() {
                if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
                    if !parent.exists() {
                        secure_directory(parent)?;
                    }
                }
                let attrs = SECURITY_ATTRIBUTES {
                    nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                    lpSecurityDescriptor: sd.0,
                    bInheritHandle: 0,
                };
                if CreateDirectoryW(wide(path).as_ptr(), &attrs) == 0 {
                    return Err("storage_unavailable");
                }
            }
            reject_links(path)?;
            let handle = CreateFileW(
                wide(path).as_ptr(),
                READ_CONTROL | WRITE_DAC,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                std::ptr::null(),
                OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                std::ptr::null_mut(),
            );
            if handle == INVALID_HANDLE_VALUE {
                return Err("storage_unavailable");
            }
            let result = check_handle(handle, true).and_then(|_| secure(handle, &sd));
            CloseHandle(handle);
            result
        }
    }
    fn check_handle(handle: HANDLE, directory: bool) -> Result<()> {
        unsafe {
            let mut info: BY_HANDLE_FILE_INFORMATION = std::mem::zeroed();
            if GetFileInformationByHandle(handle, &mut info) == 0 {
                return Err("storage_unavailable");
            }
            if info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT != 0
                || (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) != directory
                || (!directory && info.nNumberOfLinks != 1)
            {
                return Err("unsafe_path");
            }
            Ok(())
        }
    }
    fn acl_error() -> std::io::Error {
        std::io::Error::new(std::io::ErrorKind::Other, "storage_unavailable")
    }
    /// `open` with the OS error preserved, so `CREATE_NEW` against an existing
    /// path stays distinguishable as `ErrorKind::AlreadyExists`.
    pub fn create_new_io(path: &Path) -> std::io::Result<File> {
        open_io(path, true, true)
    }
    pub fn open(path: &Path, writable: bool, exclusive: bool) -> Result<File> {
        open_io(path, writable, exclusive).map_err(|_| "unsafe_path")
    }
    fn open_io(path: &Path, writable: bool, exclusive: bool) -> std::io::Result<File> {
        let sd = descriptor().map_err(|_| acl_error())?;
        unsafe {
            let attrs = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: sd.0,
                bInheritHandle: 0,
            };
            let access = GENERIC_READ
                | if writable {
                    GENERIC_WRITE | WRITE_DAC
                } else {
                    0
                };
            let disposition = if exclusive {
                CREATE_NEW
            } else if writable {
                OPEN_ALWAYS
            } else {
                OPEN_EXISTING
            };
            let handle = CreateFileW(
                wide(path).as_ptr(),
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                &attrs,
                disposition,
                FILE_FLAG_OPEN_REPARSE_POINT,
                std::ptr::null_mut(),
            );
            if handle == INVALID_HANDLE_VALUE {
                return Err(std::io::Error::last_os_error());
            }
            let file = File::from_raw_handle(handle);
            check_handle(handle, false).map_err(|_| acl_error())?;
            if writable {
                secure(handle, &sd).map_err(|_| acl_error())?;
            }
            Ok(file)
        }
    }
    pub fn replace(source: &Path, destination: &Path) -> Result<()> {
        unsafe {
            if MoveFileExW(
                wide(source).as_ptr(),
                wide(destination).as_ptr(),
                MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
            ) == 0
            {
                Err("storage_unavailable")
            } else {
                Ok(())
            }
        }
    }
    #[cfg(test)]
    pub fn assert_private_acl(path: &Path) {
        use std::os::windows::io::AsRawHandle;
        let file = open(path, false, false).unwrap();
        let expected = descriptor().unwrap();
        unsafe {
            let mut actual_sd = std::ptr::null_mut();
            let mut actual_acl = std::ptr::null_mut();
            assert_eq!(
                GetSecurityInfo(
                    file.as_raw_handle(),
                    SE_FILE_OBJECT,
                    DACL_SECURITY_INFORMATION,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut actual_acl,
                    std::ptr::null_mut(),
                    &mut actual_sd
                ),
                0
            );
            let actual_sd = Descriptor(actual_sd);
            let mut control = 0;
            let mut revision = 0;
            assert_ne!(
                GetSecurityDescriptorControl(actual_sd.0, &mut control, &mut revision),
                0
            );
            assert_ne!(control & SE_DACL_PROTECTED, 0);
            assert!(!actual_acl.is_null());
            assert_eq!((*actual_acl).AceCount, 1);
            let mut present = 0;
            let mut defaulted = 0;
            let mut expected_acl = std::ptr::null_mut();
            assert_ne!(
                GetSecurityDescriptorDacl(
                    expected.0,
                    &mut present,
                    &mut expected_acl,
                    &mut defaulted
                ),
                0
            );
            let mut actual_ace = std::ptr::null_mut();
            let mut expected_ace = std::ptr::null_mut();
            assert_ne!(GetAce(actual_acl, 0, &mut actual_ace), 0);
            assert_ne!(GetAce(expected_acl, 0, &mut expected_ace), 0);
            let actual = &*(actual_ace.cast::<ACCESS_ALLOWED_ACE>());
            let expected = &*(expected_ace.cast::<ACCESS_ALLOWED_ACE>());
            assert_eq!(actual.Header.AceType, 0); // ACCESS_ALLOWED_ACE_TYPE
            assert_eq!(actual.Mask, expected.Mask);
            assert_ne!(
                EqualSid(
                    std::ptr::addr_of!(actual.SidStart).cast_mut().cast(),
                    std::ptr::addr_of!(expected.SidStart).cast_mut().cast()
                ),
                0
            );
        }
    }
}
