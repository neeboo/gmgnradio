use std::{env, path::PathBuf, process::Command};
fn main() {
    assert_eq!(env::var("CARGO_CFG_TARGET_OS").unwrap(), "macos");
    let out=PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let object=out.join("OverlayHost.o");
    assert!(Command::new("clang").args(["-fobjc-arc","-fmodules","-c","host/OverlayHost.m","-o"]).arg(&object).status().unwrap().success());
    assert!(Command::new("ar").arg("rcs").arg(out.join("liboverlay_host.a")).arg(object).status().unwrap().success());
    println!("cargo:rustc-link-search=native={}",out.display());
    println!("cargo:rustc-link-lib=static=overlay_host");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rerun-if-changed=host/OverlayHost.m");
}
