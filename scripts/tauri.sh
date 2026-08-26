#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tauri_bin="$project_root/node_modules/.bin/tauri"

if [[ "${1:-}" != "build" ]] || [[ "$(uname -s)" != "Darwin" ]]; then
  exec "$tauri_bin" "$@"
fi

shift
identities="$(security find-identity -v -p codesigning)"
signing_identity="$(printf '%s\n' "$identities" | sed -E -n '/Developer ID Application/s/^ *[0-9]+\) ([0-9A-F]+).*/\1/p' | head -n 1)"

if [[ -z "$signing_identity" ]]; then
  signing_identity="$(printf '%s\n' "$identities" | sed -E -n '/Apple Development/s/^ *[0-9]+\) ([0-9A-F]+).*/\1/p' | head -n 1)"
fi

if [[ -z "$signing_identity" ]]; then
  echo "No Developer ID Application or Apple Development signing identity found." >&2
  exit 1
fi

export EKO_NAMI_SIGNING_IDENTITY="$signing_identity"
local_config="$project_root/src-tauri/target/macos-signing.json"
mkdir -p "$(dirname -- "$local_config")"
printf '{"bundle":{"macOS":{"signingIdentity":"%s"}}}\n' "$signing_identity" > "$local_config"

exec "$tauri_bin" build --config "$local_config" "$@"
