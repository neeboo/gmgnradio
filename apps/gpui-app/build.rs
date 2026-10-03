fn main() {
    cc::Build::new()
        .file("native/window_surface.m")
        .flag("-fobjc-arc")
        .compile("gmgn_gpui_native_surface");
    println!("cargo:rustc-link-lib=framework=AppKit");
    println!("cargo:rustc-link-lib=framework=QuartzCore");
    println!("cargo:rerun-if-changed=native/window_surface.m");
}
