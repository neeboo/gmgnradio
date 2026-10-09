//! Windows-only hardening: replace the secrets root's inherited ACL with an
//! explicit **owner-only** one.
//!
//! ## Why this exists at all
//!
//! `%LOCALAPPDATA%` is already per-user and already inherits an ACL that grants
//! the user, SYSTEM and Administrators and nobody else. That is *probably*
//! enough, and "probably enough" is exactly the reasoning that produces a
//! credential leak. So the root gets a DACL that grants the current user and
//! nothing else, with inheritance removed
//! (`PROTECTED_DACL_SECURITY_INFORMATION`), reproducing what `chmod 0700` means
//! on the macOS side of this same file.
//!
//! ## Honest status of this module
//!
//! It is written against the documented Win32 security API and it is
//! **type-checked for a Windows target**:
//!
//! ```text
//! cargo check --manifest-path apps/windows-host/Cargo.toml --target x86_64-pc-windows-gnu
//! ```
//!
//! This crate has no dependencies and no C, so that check really does compile
//! *this* file (it is not skipped the way a crate blocked in a `-sys` build
//! script would be). What has **not** happened is execution: no Windows machine
//! ran this, and `cargo check` does not link, so the import library names below
//! are verified by inspection against the Win32 documentation, not by the
//! loader. Treat the ACL call as "compiles, unexecuted" rather than "tested".
//! The store itself never depends on it for correctness of *content*: if the
//! ACL call fails, [`crate::credential::SecretStore::ensure_root`] returns an
//! error and no secret is written.

#![cfg(windows)]

use std::os::windows::ffi::OsStrExt as _;
use std::path::Path;

// `advapi32` and `kernel32` are the two DLLs the security APIs live in.
// (A plain comment, not `///`: rustdoc does not document `extern` blocks and
// warns about it, which on a Windows-only module is a warning nobody here sees.)
#[link(name = "advapi32")]
unsafe extern "system" {
    fn OpenProcessToken(
        process_handle: *mut core::ffi::c_void,
        desired_access: u32,
        token_handle: *mut *mut core::ffi::c_void,
    ) -> i32;

    fn GetTokenInformation(
        token_handle: *mut core::ffi::c_void,
        token_information_class: u32,
        token_information: *mut core::ffi::c_void,
        token_information_length: u32,
        return_length: *mut u32,
    ) -> i32;

    fn SetEntriesInAclW(
        count: u32,
        entries: *const ExplicitAccessW,
        old_acl: *mut core::ffi::c_void,
        new_acl: *mut *mut core::ffi::c_void,
    ) -> u32;

    fn SetNamedSecurityInfoW(
        object_name: *mut u16,
        object_type: u32,
        security_information: u32,
        owner_sid: *mut core::ffi::c_void,
        group_sid: *mut core::ffi::c_void,
        dacl: *mut core::ffi::c_void,
        sacl: *mut core::ffi::c_void,
    ) -> u32;
}

#[link(name = "kernel32")]
unsafe extern "system" {
    fn GetCurrentProcess() -> *mut core::ffi::c_void;
    fn CloseHandle(handle: *mut core::ffi::c_void) -> i32;
    fn LocalFree(memory: *mut core::ffi::c_void) -> *mut core::ffi::c_void;
}

/// `SID_AND_ATTRIBUTES`.
#[repr(C)]
struct SidAndAttributes {
    sid: *mut core::ffi::c_void,
    attributes: u32,
}

/// `TOKEN_USER` -- a single `SID_AND_ATTRIBUTES`.
#[repr(C)]
struct TokenUser {
    user: SidAndAttributes,
}

/// `TRUSTEE_W`.
#[repr(C)]
struct TrusteeW {
    multiple_trustee: *mut core::ffi::c_void,
    multiple_trustee_operation: u32,
    trustee_form: u32,
    trustee_type: u32,
    name: *mut u16,
}

/// `EXPLICIT_ACCESS_W`.
#[repr(C)]
struct ExplicitAccessW {
    access_permissions: u32,
    access_mode: u32,
    inheritance: u32,
    trustee: TrusteeW,
}

// The constants below are the Win32 ones, spelled out rather than pulled from a
// crate so this file has no dependency to keep in step with.
const TOKEN_QUERY: u32 = 0x0008;
const TOKEN_USER_CLASS: u32 = 1;
const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
const ERROR_SUCCESS: u32 = 0;
const SE_FILE_OBJECT: u32 = 1;
const DACL_SECURITY_INFORMATION: u32 = 0x0000_0004;
const PROTECTED_DACL_SECURITY_INFORMATION: u32 = 0x8000_0000;
const NO_MULTIPLE_TRUSTEE: u32 = 0;
const TRUSTEE_IS_SID: u32 = 0;
const TRUSTEE_IS_USER: u32 = 1;
const SET_ACCESS: u32 = 2;
const GENERIC_ALL: u32 = 0x1000_0000;
const SUB_CONTAINERS_AND_OBJECTS_INHERIT: u32 = 0x3;

/// Replace `path`'s DACL with one ACE: the current user, full control,
/// inherited by children.
pub fn restrict_to_current_user(path: &Path) -> Result<(), super::credential::StoreError> {
    use super::credential::StoreError;

    // SAFETY: every call below is checked for failure before its output is
    // used; the buffers handed to Win32 are sized by the API's own
    // two-call size query; the ACL that `SetEntriesInAclW` allocates with
    // `LocalAlloc` is released with `LocalFree` on every exit path.
    unsafe {
        let process = GetCurrentProcess();
        let mut token: *mut core::ffi::c_void = std::ptr::null_mut();
        if OpenProcessToken(process, TOKEN_QUERY, &mut token) == 0 {
            return Err(StoreError::Io("OpenProcessToken"));
        }
        // Everything after the token exists needs the handle closed.
        let outcome = restrict_with_token(token, path);
        CloseHandle(token);
        outcome
    }
}

unsafe fn restrict_with_token(
    token: *mut core::ffi::c_void,
    path: &Path,
) -> Result<(), super::credential::StoreError> {
    use super::credential::StoreError;

    // First call sizes the TOKEN_USER (it embeds a variable-length SID).
    let mut needed: u32 = 0;
    let probe = unsafe {
        GetTokenInformation(token, TOKEN_USER_CLASS, std::ptr::null_mut(), 0, &mut needed)
    };
    if probe != 0 || needed == 0 {
        return Err(StoreError::Io("GetTokenInformation(size)"));
    }

    let mut buffer = vec![0u8; needed as usize];
    let ok = unsafe {
        GetTokenInformation(
            token,
            TOKEN_USER_CLASS,
            buffer.as_mut_ptr().cast(),
            needed,
            &mut needed,
        )
    };
    if ok == 0 {
        return Err(StoreError::Io("GetTokenInformation"));
    }
    let _ = ERROR_INSUFFICIENT_BUFFER;

    // SAFETY: `buffer` is `needed` bytes and Win32 wrote a TOKEN_USER into it.
    let sid = unsafe { (*buffer.as_ptr().cast::<TokenUser>()).user.sid };
    if sid.is_null() {
        return Err(StoreError::Io("GetTokenInformation(sid)"));
    }

    let entries = [ExplicitAccessW {
        access_permissions: GENERIC_ALL,
        access_mode: SET_ACCESS,
        inheritance: SUB_CONTAINERS_AND_OBJECTS_INHERIT,
        trustee: TrusteeW {
            multiple_trustee: std::ptr::null_mut(),
            multiple_trustee_operation: NO_MULTIPLE_TRUSTEE,
            trustee_form: TRUSTEE_IS_SID,
            trustee_type: TRUSTEE_IS_USER,
            // `TRUSTEE_IS_SID` means this is a PSID, not a name string.
            name: sid.cast::<u16>(),
        },
    }];

    let mut acl: *mut core::ffi::c_void = std::ptr::null_mut();
    let status = unsafe { SetEntriesInAclW(1, entries.as_ptr(), std::ptr::null_mut(), &mut acl) };
    if status != ERROR_SUCCESS || acl.is_null() {
        return Err(StoreError::Io("SetEntriesInAclW"));
    }

    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    wide.push(0);
    let status = unsafe {
        SetNamedSecurityInfoW(
            wide.as_mut_ptr(),
            SE_FILE_OBJECT,
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            acl,
            std::ptr::null_mut(),
        )
    };
    unsafe { LocalFree(acl) };

    if status != ERROR_SUCCESS {
        return Err(StoreError::Io("SetNamedSecurityInfoW"));
    }
    Ok(())
}
