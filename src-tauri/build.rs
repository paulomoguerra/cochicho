fn main() {
    #[cfg(target_os = "macos")]
    build_apple_speech_bridge();

    tauri_build::build()
}

/// Compiles the Swift FFI bridge (SpeechAnalyzer is a Swift-only API) and links it.
///
/// Release binaries load the bridge from the app's `Contents/Resources` directory.
/// Debug binaries also retain the local SwiftPM rpath for raw `tauri dev` runs.
#[cfg(target_os = "macos")]
fn build_apple_speech_bridge() {
    use std::path::PathBuf;
    use std::process::Command;

    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let bridge_dir = manifest_dir.join("apple-speech-bridge");
    let swift_scratch = manifest_dir
        .join("target")
        .join("apple-speech-bridge-swift");

    println!(
        "cargo:rerun-if-changed={}",
        bridge_dir.join("Sources").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        bridge_dir.join("Package.swift").display()
    );

    let status = Command::new("swift")
        .args(["build", "-c", "release", "--package-path"])
        .arg(&bridge_dir)
        .arg("--scratch-path")
        .arg(&swift_scratch)
        .status()
        .expect("failed to invoke swift build for apple-speech-bridge");
    assert!(status.success(), "apple-speech-bridge swift build failed");

    let output = Command::new("swift")
        .args([
            "build",
            "-c",
            "release",
            "--show-bin-path",
            "--package-path",
        ])
        .arg(&bridge_dir)
        .arg("--scratch-path")
        .arg(&swift_scratch)
        .output()
        .expect("failed to query swift bin path");
    assert!(output.status.success(), "swift --show-bin-path failed");
    let bin_path = String::from_utf8(output.stdout).unwrap().trim().to_string();
    let bridge_path = PathBuf::from(&bin_path).join("libAppleSpeechBridge.dylib");
    let bundle_resource_dir = manifest_dir.join("target").join("bundle-resources");
    std::fs::create_dir_all(&bundle_resource_dir)
        .expect("failed to create AppleSpeechBridge bundle resource directory");
    std::fs::copy(
        &bridge_path,
        bundle_resource_dir.join("libAppleSpeechBridge.dylib"),
    )
    .expect("failed to stage AppleSpeechBridge dylib for bundling");

    println!("cargo:rustc-link-search=native={bin_path}");
    println!("cargo:rustc-link-lib=dylib=AppleSpeechBridge");
    println!("cargo:rustc-link-arg=-Wl,-rpath,@loader_path/../Resources");
    if std::env::var("PROFILE").as_deref() == Ok("debug") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,{bin_path}");
    }
}
