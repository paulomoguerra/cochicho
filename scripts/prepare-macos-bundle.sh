#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  exit 0
fi

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bridge_dir="$project_root/src-tauri/apple-speech-bridge"
swift_scratch="$project_root/src-tauri/target/apple-speech-bridge-swift"
bundle_resources="$project_root/src-tauri/target/bundle-resources"
bridge_bin_path="$(swift build -c release --show-bin-path --package-path "$bridge_dir" --scratch-path "$swift_scratch" | tail -n 1)"
bridge="$bridge_bin_path/libAppleSpeechBridge.dylib"
destination="$bundle_resources/libAppleSpeechBridge.dylib"
signing_identity="${EKO_NAMI_SIGNING_IDENTITY:?missing EKO_NAMI_SIGNING_IDENTITY}"

if [[ ! -f "$bridge" ]]; then
  echo "AppleSpeechBridge dylib not found at $bridge" >&2
  exit 1
fi

mkdir -p "$bundle_resources"
cp "$bridge" "$destination"
codesign --force --options runtime --sign "$signing_identity" "$destination"
echo "Prepared AppleSpeechBridge for macOS bundle"
