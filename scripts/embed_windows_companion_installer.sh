#!/bin/bash
set -euo pipefail

CANONICAL_INSTALLER_NAME="JTS-Windows-Companion-Setup.exe"
CANONICAL_MANIFEST_NAME="JTS-Windows-Companion-Setup.sha256"
MAX_INSTALLER_BYTES=2147483647
MAX_MANIFEST_BYTES=4096

mode="embed"
source_path="${JTS_WINDOWS_COMPANION_INSTALLER_PATH:-}"
manifest_path="${JTS_WINDOWS_COMPANION_INSTALLER_SHA256_PATH:-}"
resources_dir=""
required="${JTS_REQUIRE_WINDOWS_COMPANION_INSTALLER:-auto}"
temporary_installer=""
temporary_manifest=""

usage() {
  cat <<'EOF'
Usage:
  scripts/embed_windows_companion_installer.sh \
    --resources-dir PATH [--source FILE] [--manifest FILE] \
    [--required 0|1|auto]

  scripts/embed_windows_companion_installer.sh \
    --verify --resources-dir PATH

  scripts/embed_windows_companion_installer.sh \
    --preflight [--source FILE] [--manifest FILE]

The embed mode copies one hash-bound Windows Companion Setup into the fixed
app-resource names used by JTFreeRDPService. With --required auto, Release
requires the artifact and other configurations allow it to be absent.
Preflight only checks that release input files exist, without changing resources;
the embed mode still performs the complete input and hash validation.
EOF
}

cleanup_temporary_files() {
  [[ -z "$temporary_installer" ]] || rm -f -- "$temporary_installer"
  [[ -z "$temporary_manifest" ]] || rm -f -- "$temporary_manifest"
}
trap cleanup_temporary_files EXIT

installer_destination() {
  printf '%s/%s' "$resources_dir" "$CANONICAL_INSTALLER_NAME"
}

manifest_destination() {
  printf '%s/%s' "$resources_dir" "$CANONICAL_MANIFEST_NAME"
}

remove_embedded_pair() {
  if [[ -n "$resources_dir" && -d "$resources_dir" && ! -L "$resources_dir" ]]; then
    rm -f -- "$(installer_destination)" "$(manifest_destination)"
  fi
}

fail() {
  if [[ "$mode" == "embed" ]]; then
    remove_embedded_pair
  fi
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

while (( $# > 0 )); do
  case "$1" in
    --source)
      (( $# >= 2 )) || fail "--source requires a path."
      source_path="$2"
      shift 2
      ;;
    --manifest)
      (( $# >= 2 )) || fail "--manifest requires a path."
      manifest_path="$2"
      shift 2
      ;;
    --resources-dir)
      (( $# >= 2 )) || fail "--resources-dir requires a path."
      resources_dir="$2"
      shift 2
      ;;
    --required)
      (( $# >= 2 )) || fail "--required requires 0, 1, or auto."
      required="$2"
      shift 2
      ;;
    --verify)
      mode="verify"
      shift
      ;;
    --preflight)
      mode="preflight"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ -n "$source_path" && -z "$manifest_path" ]]; then
  manifest_path="${source_path%.*}.sha256"
fi

if [[ "$mode" == "preflight" ]]; then
  [[ -n "$source_path" ]] \
    || fail "Set JTS_WINDOWS_COMPANION_INSTALLER_PATH to the release Setup artifact with its SHA-256 manifest."
  [[ -f "$source_path" ]] \
    || fail "Windows Companion installer input file is missing: $source_path"
  [[ -f "$manifest_path" ]] \
    || fail "Windows Companion SHA-256 input file is missing: $manifest_path (set JTS_WINDOWS_COMPANION_INSTALLER_SHA256_PATH if stored elsewhere)."
  printf 'PASS: Windows Companion release input files exist; full validation runs during embedding.\n'
  exit 0
fi

if [[ -z "$resources_dir" &&
      -n "${TARGET_BUILD_DIR:-}" &&
      -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
  resources_dir="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
fi
[[ -n "$resources_dir" ]] || fail "A target Resources directory is required."
[[ ! -L "$resources_dir" ]] || fail "The target Resources directory cannot be a symlink."

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print tolower($1)}'
}

file_size() {
  /usr/bin/stat -f '%z' "$1"
}

validate_regular_file() {
  local path="$1"
  local description="$2"
  [[ -e "$path" ]] || fail "$description is missing: $path"
  [[ ! -L "$path" ]] || fail "$description cannot be a symlink: $path"
  [[ -f "$path" ]] || fail "$description must be a regular file: $path"
}

read_manifest() {
  local path="$1"
  local expected_name="$2"
  local line_count digest file_name extra

  validate_regular_file "$path" "Windows Companion SHA-256 manifest"
  [[ "$(file_size "$path")" -le "$MAX_MANIFEST_BYTES" ]] \
    || fail "Windows Companion SHA-256 manifest exceeds $MAX_MANIFEST_BYTES bytes."
  line_count="$(/usr/bin/awk 'END { print NR }' "$path")"
  [[ "$line_count" == "1" ]] \
    || fail "Windows Companion SHA-256 manifest must contain exactly one record."
  IFS=$' \t' read -r digest file_name extra <"$path" || true
  [[ "$digest" =~ ^[0-9a-fA-F]{64}$ && -n "$file_name" && -z "${extra:-}" ]] \
    || fail "Windows Companion SHA-256 manifest has an invalid record."
  [[ "$file_name" == "$expected_name" ]] \
    || fail "Windows Companion SHA-256 manifest names an unexpected file: $file_name"
  printf '%s' "$digest" | /usr/bin/tr '[:upper:]' '[:lower:]'
}

validate_hash_bound_pair() {
  local installer="$1"
  local manifest="$2"
  local expected_name="$3"
  local size declared_digest actual_digest

  validate_regular_file "$installer" "Windows Companion installer"
  size="$(file_size "$installer")"
  [[ "$size" -gt 0 ]] || fail "Windows Companion installer cannot be empty."
  [[ "$size" -le "$MAX_INSTALLER_BYTES" ]] \
    || fail "Windows Companion installer exceeds the bounded CLIPRDR file size."
  declared_digest="$(read_manifest "$manifest" "$expected_name")"
  actual_digest="$(sha256_file "$installer")"
  [[ "$actual_digest" == "$declared_digest" ]] \
    || fail "Windows Companion installer does not match its SHA-256 manifest."
  printf '%s' "$actual_digest"
}

if [[ "$mode" == "verify" ]]; then
  [[ -d "$resources_dir" ]] \
    || fail "The target Resources directory is missing: $resources_dir"
  embedded_digest="$(validate_hash_bound_pair \
    "$(installer_destination)" \
    "$(manifest_destination)" \
    "$CANONICAL_INSTALLER_NAME")"
  printf 'PASS: fixed Windows Companion installer resources are hash-bound (%s).\n' \
    "$embedded_digest"
  exit 0
fi

case "$required" in
  0|1)
    ;;
  auto)
    if [[ "${CONFIGURATION:-}" == "Release" ]]; then
      required=1
    else
      required=0
    fi
    ;;
  *)
    fail "--required must be 0, 1, or auto."
    ;;
esac

if [[ -z "$source_path" ]]; then
  if [[ "$required" == "1" ]]; then
    fail "Set JTS_WINDOWS_COMPANION_INSTALLER_PATH to the release Setup artifact with its SHA-256 manifest."
  fi
  remove_embedded_pair
  printf 'NOTE: no Windows Companion installer was supplied for this optional build.\n'
  exit 0
fi

[[ -d "$resources_dir" ]] || mkdir -p -- "$resources_dir"
[[ -d "$resources_dir" && ! -L "$resources_dir" ]] \
  || fail "The target Resources path is not a regular directory: $resources_dir"

validate_regular_file "$source_path" "Windows Companion installer"
source_name="$(basename "$source_path")"
source_name_upper="$(printf '%s' "$source_name" | /usr/bin/tr '[:lower:]' '[:upper:]')"
[[ "$source_name" == *.exe ]] \
  || fail "Windows Companion installer input must use an .exe filename."
[[ "$source_name_upper" != *UNSIGNED-DEVELOPMENT* &&
   "$source_name_upper" != *AUTHORIZED-LAB-ONLY* ]] \
  || fail "Development and authorized-lab artifacts cannot be embedded in a release app."

source_directory="$(cd "$(dirname "$source_path")" && pwd -P)"
source_canonical="$source_directory/$source_name"
resources_canonical="$(cd "$resources_dir" && pwd -P)"
[[ "$source_canonical" != "$resources_canonical/$CANONICAL_INSTALLER_NAME" ]] \
  || fail "The source installer cannot be the destination resource itself."

digest="$(validate_hash_bound_pair "$source_path" "$manifest_path" "$source_name")"
remove_embedded_pair

temporary_installer="$(mktemp \
  "$resources_dir/.${CANONICAL_INSTALLER_NAME}.XXXXXX")"
temporary_manifest="$(mktemp \
  "$resources_dir/.${CANONICAL_MANIFEST_NAME}.XXXXXX")"
/bin/cp -p -- "$source_path" "$temporary_installer"
/bin/chmod 0644 "$temporary_installer"
printf '%s  %s\n' "$digest" "$CANONICAL_INSTALLER_NAME" \
  >"$temporary_manifest"
/bin/chmod 0644 "$temporary_manifest"

[[ "$(sha256_file "$temporary_installer")" == "$digest" ]] \
  || fail "Copied Windows Companion installer changed before activation."
[[ "$(read_manifest "$temporary_manifest" "$CANONICAL_INSTALLER_NAME")" == "$digest" ]] \
  || fail "Canonical Windows Companion manifest could not be verified."

/bin/mv -f -- "$temporary_installer" "$(installer_destination)"
temporary_installer=""
/bin/mv -f -- "$temporary_manifest" "$(manifest_destination)"
temporary_manifest=""

embedded_digest="$(validate_hash_bound_pair \
  "$(installer_destination)" \
  "$(manifest_destination)" \
  "$CANONICAL_INSTALLER_NAME")"
[[ "$embedded_digest" == "$digest" ]] \
  || fail "Activated Windows Companion resources failed final verification."
printf 'PASS: embedded fixed Windows Companion installer resources (%s).\n' \
  "$digest"
