fn main() {
    cc::Build::new()
        .file("native.m")
        .flag("-fobjc-arc")
        .compile("scene_bridge");
    for framework in ["AppKit", "SceneKit", "QuartzCore"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
    println!("cargo:rerun-if-changed=native.m");
}
