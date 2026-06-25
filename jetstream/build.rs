use std::process::Command;

fn main() {
    println!("cargo:rerun-if-changed=src/hvf/vmnet_shim.c");
    println!("cargo:rustc-link-lib=framework=vmnet");
    println!("cargo:rustc-link-lib=framework=System");

    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        let out_dir = std::env::var("OUT_DIR").expect("OUT_DIR not set");
        let object = format!("{out_dir}/vmnet_shim.o");
        let status = Command::new("clang")
            .args([
                "-fblocks",
                "-O2",
                "-c",
                "src/hvf/vmnet_shim.c",
                "-o",
                &object,
            ])
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
