fn main() {
    #[cfg(target_os = "macos")]
    build_apple_speech_bridge();

    tauri_build::build()
}

/// Compiles the Swift FFI bridge (SpeechAnalyzer is a Swift-only API) and links it.
/// The dylib is bundled into the .app at package time; for dev/test we add an rpath
/// to the SwiftPM products directory (resolved via `--show-bin-path`, since the
/// location varies with user-level SwiftPM config).
#[cfg(target_os = "macos")]
fn build_apple_speech_bridge() {
    use std::path::PathBuf;
    use std::process::Command;

    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let bridge_dir = manifest_dir.join("apple-speech-bridge");

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
        .status()
        .expect("failed to invoke swift build for apple-speech-bridge");
    assert!(status.success(), "apple-speech-bridge swift build failed");

    let output = Command::new("swift")
        .args(["build", "-c", "release", "--show-bin-path", "--package-path"])
        .arg(&bridge_dir)
        .output()
        .expect("failed to query swift bin path");
    assert!(output.status.success(), "swift --show-bin-path failed");
    let bin_path = String::from_utf8(output.stdout).unwrap().trim().to_string();

    println!("cargo:rustc-link-search=native={bin_path}");
    println!("cargo:rustc-link-lib=dylib=AppleSpeechBridge");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{bin_path}");
}
