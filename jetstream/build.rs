use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=src/hvf/vmnet_shim.c");
    println!("cargo:rustc-link-lib=framework=vmnet");
    println!("cargo:rustc-link-lib=framework=System");

    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR not set");
        let object = format!("{out_dir}/vmnet_shim.o");
        let clang = xcrun(&["-f", "clang"]).unwrap_or_else(|| "clang".to_string());
        let sdk_path = xcrun(&["--sdk", "macosx", "--show-sdk-path"]);
        let mut clang_command = Command::new(clang);
        clang_command.args(["-fblocks", "-O2"]);
        if let Some(sdk_path) = sdk_path.as_deref() {
            clang_command.args(["-isysroot", sdk_path]);
        }
        let status = clang_command
            .args(["-c", "src/hvf/vmnet_shim.c", "-o", &object])
            .status()
            .expect("failed to invoke clang for vmnet shim");
        assert!(status.success(), "clang failed to compile vmnet shim");

        let library = format!("{out_dir}/libjetstream_vmnet_shim.a");
        let status = Command::new("ar")
            .args(["crs", &library, &object])
            .status()
            .expect("failed to archive vmnet shim");
        assert!(status.success(), "ar failed to archive vmnet shim");

        println!("cargo:rustc-link-search=native={out_dir}");
        println!("cargo:rustc-link-lib=static=jetstream_vmnet_shim");
    }
}

#[cfg(all(target_os = "macos", target_arch = "aarch64"))]
fn xcrun(args: &[&str]) -> Option<String> {
    let output = Command::new("xcrun").args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}
