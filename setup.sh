#!/usr/bin/env bash
# Set up Mesa Rusticl + patched mesa-libclc for DaVinci Resolve in davincibox.
# Tested on Fedora 44 Distrobox, Mesa 26.2.6, LLVM 22.1.8, PS5 Oberon/GFX1013.
set -Eeuo pipefail

readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CLC_VERSION="22.1.8.3"
readonly CLC_ARCHIVE="mesa-libclc-${CLC_VERSION}.tar.bz2"
readonly CLC_URL="https://gitlab.freedesktop.org/karolherbst/mesa-libclc/-/archive/${CLC_VERSION}/${CLC_ARCHIVE}"
readonly CLC_SHA256="ff6c01fb68c4b885e13400c50298ee6a8bfcf3ac5995cf3039565f6814095226"
readonly CONTAINER_NAME="${CONTAINER_NAME:-davincibox}"
readonly WORK_ROOT="${WORK_ROOT:-$HOME/.local/src/ps5-resolve-rusticl}"
readonly ICD_DIR="$HOME/rusticl-only"
readonly CLC_DEST="/usr/lib64/clc"

log()  { printf '\n\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

cleanup_on_error() {
    local rc=$?
    printf '\n\033[1;31m[ERROR]\033[0m Setup stopped (exit code %s).\n' "$rc" >&2
    printf 'No original SPIR-V file is intentionally deleted. Review the output above.\n' >&2
    exit "$rc"
}
trap cleanup_on_error ERR

usage() {
    cat <<USAGE
Usage: ./setup.sh [--no-launcher] [--help]

Run this script as your normal user from inside the Fedora Distrobox named
"${CONTAINER_NAME}". It installs Rusticl and build tools, builds the pinned
patched mesa-libclc ${CLC_VERSION}, backs up and replaces the two SPIR-V files,
checks OpenCL, and creates a host-side XDG application launcher when run-davinci is present.

Environment overrides:
  CONTAINER_NAME  Distrobox name (default: davincibox)
  WORK_ROOT       Build/work directory (default: ~/.local/src/ps5-resolve-rusticl)
USAGE
}

CREATE_LAUNCHER=1
while (($#)); do
    case "$1" in
        --no-launcher) CREATE_LAUNCHER=0 ;;
        --help|-h) usage; exit 0 ;;
        *) die "Unknown argument: $1 (try --help)" ;;
    esac
    shift
done

[[ "${EUID}" -ne 0 ]] || die "Run as your regular Distrobox user, not root. The script uses sudo only when needed."
[[ -n "${HOME:-}" && -d "$HOME" ]] || die 'HOME is not set correctly.'

# Verify that we are inside the expected Distrobox, not on the immutable host.
if [[ "${CONTAINER_ID:-}" != "$CONTAINER_NAME" ]]; then
    die "This does not look like Distrobox '$CONTAINER_NAME'. Enter it first: distrobox enter $CONTAINER_NAME"
fi

# This build recipe is intentionally pinned to the configuration actually tested.
if [[ ! -r /etc/os-release ]]; then die 'Cannot read /etc/os-release.'; fi
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == fedora && "${VERSION_ID:-}" == "44" ]] || \
    die "This tested recipe expects Fedora 44 in Distrobox; detected ${PRETTY_NAME:-unknown}. Do not force it on another release without adapting LLVM/libclc versions."

if ! command -v sudo >/dev/null 2>&1; then
    die 'sudo is missing in the container. Install/configure sudo and retry.'
fi

log "Installing Rusticl, clinfo and build dependencies inside ${CONTAINER_NAME}"
sudo dnf install -y \
    mesa-libOpenCL libclc libclc-spirv clinfo \
    cmake ninja-build llvm-devel clang \
    spirv-llvm-translator-devel spirv-llvm-translator-tools \
    curl tar bzip2 coreutils findutils xdg-user-dirs

# Verify the exact build toolchain instead of silently compiling against a different LLVM.
command -v cmake >/dev/null || die 'cmake was not installed.'
command -v ninja >/dev/null || die 'ninja was not installed.'
command -v llvm-config-22 >/dev/null || die 'llvm-config-22 is missing; this recipe requires LLVM 22.'
command -v llvm-spirv >/dev/null || die 'llvm-spirv is missing; install spirv-llvm-translator-tools.'
command -v clinfo >/dev/null || die 'clinfo is missing.'

LLVM_VERSION="$(llvm-config-22 --version)"
[[ "$LLVM_VERSION" == "22.1.8" ]] || die "This pinned mesa-libclc build was tested with LLVM 22.1.8; detected ${LLVM_VERSION}. Refusing to build against a different LLVM version."

# Verify Rusticl's ICD file and construct an isolated ICD directory.
[[ -r /etc/OpenCL/vendors/rusticl.icd ]] || die 'Rusticl ICD not found at /etc/OpenCL/vendors/rusticl.icd after package installation.'
mkdir -p "$ICD_DIR"
install -m 0644 /etc/OpenCL/vendors/rusticl.icd "$ICD_DIR/rusticl.icd"

log 'Building patched mesa-libclc (pinned source archive with SHA256 verification)'
mkdir -p "$WORK_ROOT/src" "$WORK_ROOT/stage"
SRC_DIR="$WORK_ROOT/src/mesa-libclc-${CLC_VERSION}"
ARCHIVE_PATH="$WORK_ROOT/src/$CLC_ARCHIVE"
STAGE_ROOT="$WORK_ROOT/stage"

curl --fail --location --retry 3 --output "$ARCHIVE_PATH" "$CLC_URL"
printf '%s  %s\n' "$CLC_SHA256" "$ARCHIVE_PATH" | sha256sum --check --status || \
    die "SHA256 verification failed for $CLC_ARCHIVE. Refusing to build."

# Recreate only this script's own extracted source/build/staging directories.
rm -rf "$SRC_DIR" "$STAGE_ROOT/usr"
mkdir -p "$SRC_DIR" "$STAGE_ROOT"
tar -xjf "$ARCHIVE_PATH" --strip-components=1 -C "$SRC_DIR"

LLVM_CMAKE_DIR="$(llvm-config-22 --cmakedir)"
LLVM_SPIRV_PATH="$(command -v llvm-spirv)"

cmake -S "$SRC_DIR" -B "$SRC_DIR/build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DLIBCLC_TARGETS_TO_BUILD='spirv-mesa3d-;spirv64-mesa3d-' \
    -DLLVM_DIR="$LLVM_CMAKE_DIR" \
    -DLLVM_SPIRV="$LLVM_SPIRV_PATH"

BUILD_JOBS="${BUILD_JOBS:-2}"
[[ "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || die 'BUILD_JOBS must be a positive integer.'
cmake --build "$SRC_DIR/build" --parallel "$BUILD_JOBS"
DESTDIR="$STAGE_ROOT" cmake --install "$SRC_DIR/build"

readonly NEW_SPV32="$STAGE_ROOT/usr/share/mesa-clc/spirv-mesa3d-.spv"
readonly NEW_SPV64="$STAGE_ROOT/usr/share/mesa-clc/spirv64-mesa3d-.spv"
readonly OLD_SPV32="$CLC_DEST/spirv-mesa3d-.spv"
readonly OLD_SPV64="$CLC_DEST/spirv64-mesa3d-.spv"

for f in "$NEW_SPV32" "$NEW_SPV64"; do
    [[ -s "$f" ]] || die "Expected generated SPIR-V file is missing or empty: $f"
done
for f in "$OLD_SPV32" "$OLD_SPV64"; do
    [[ -s "$f" ]] || die "Expected Fedora libclc-spirv file is missing: $f (is libclc-spirv installed?)"
done

log 'Generated SPIR-V files:'
ls -lh "$NEW_SPV32" "$NEW_SPV64"

# Preserve originals before touching /usr/lib64/clc. If the exact patched files
# are already installed, keep the existing first-run backup and do not back up
# the patched files over the originals on a repeat run.
BACKUP_DIR=""
if cmp -s "$NEW_SPV32" "$OLD_SPV32" && cmp -s "$NEW_SPV64" "$OLD_SPV64"; then
    log 'Patched SPIR-V files are already installed; skipping replacement.'
    if [[ -f "$HOME/.libclc-last-backup" ]]; then
        BACKUP_DIR="$(<"$HOME/.libclc-last-backup")"
    fi
else
    BACKUP_DIR="$HOME/libclc-original-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp -a "$OLD_SPV32" "$BACKUP_DIR/"
    cp -a "$OLD_SPV64" "$BACKUP_DIR/"
    printf '%s\n' "$BACKUP_DIR" > "$HOME/.libclc-last-backup"

    log "Original SPIR-V files backed up to: $BACKUP_DIR"
    log 'Installing the patched SPIR-V files into /usr/lib64/clc'
    sudo install -D -m 0644 "$NEW_SPV32" "$OLD_SPV32"
    sudo install -D -m 0644 "$NEW_SPV64" "$OLD_SPV64"
fi

cmp -s "$NEW_SPV32" "$OLD_SPV32" || die '32-bit SPIR-V verification failed after installation.'
cmp -s "$NEW_SPV64" "$OLD_SPV64" || die '64-bit SPIR-V verification failed after installation.'
log 'Both patched SPIR-V files match the staged build.'

log 'Clearing the Mesa shader cache for this user'
rm -rf "$HOME/.cache/mesa_shader_cache"

log 'Testing OpenCL with only the Rusticl ICD (not ROCm or Intel)'
CLINFO_OUTPUT="$WORK_ROOT/clinfo-rusticl.txt"
CLINFO_ERROR="$WORK_ROOT/clinfo-rusticl.err"
if ! env RUSTICL_ENABLE=radeonsi OCL_ICD_VENDORS="$ICD_DIR" \
    timeout 30s clinfo >"$CLINFO_OUTPUT" 2>"$CLINFO_ERROR"; then
    warn 'The full clinfo test failed. Output follows:'
    cat "$CLINFO_ERROR" >&2 || true
    tail -n 80 "$CLINFO_OUTPUT" >&2 || true
    die 'Rusticl OpenCL validation failed. Review the output; do not launch Resolve yet.'
fi

if ! grep -qE 'Platform Name[[:space:]]+rusticl' "$CLINFO_OUTPUT"; then
    cat "$CLINFO_OUTPUT" >&2
    die 'clinfo did not report the Rusticl platform.'
fi
if ! grep -q 'Image support.*Yes' "$CLINFO_OUTPUT"; then
    warn 'Rusticl did not report Image support: Yes. Resolve may not work correctly.'
fi

printf '\n'
grep -iE 'Platform Name|Device Name|Device OpenCL C Version|Image support' "$CLINFO_OUTPUT" | sed -n '1,20p'
[[ ! -s "$CLINFO_ERROR" ]] || { warn 'Rusticl emitted warnings:'; cat "$CLINFO_ERROR"; }

# Create host-side launcher files in the shared home directory.
if [[ "$CREATE_LAUNCHER" -eq 1 ]]; then
    if command -v run-davinci >/dev/null 2>&1 && [[ -x /opt/resolve/bin/resolve ]]; then
        log 'Creating the host-side XDG launcher and installing the DaVinci Resolve icon'
        mkdir -p "$HOME/.local/bin" "$HOME/.local/share/applications" "$HOME/.local/share/icons"

        ICON_SOURCE="$SCRIPT_DIR/assets/davinci-resolve.png"
        ICON_PATH="applications-multimedia"
        if [[ -s "$ICON_SOURCE" ]]; then
            ICON_PATH="$HOME/.local/share/icons/davinci-resolve.png"
            install -D -m 0644 "$ICON_SOURCE" "$ICON_PATH"
            log "DaVinci Resolve icon installed to: $ICON_PATH"
        else
            warn "Icon asset not found at $ICON_SOURCE; using the generic multimedia icon."
        fi

        cat > "$HOME/.local/bin/resolve-rusticl" <<HOST_LAUNCHER
#!/usr/bin/env bash
set -euo pipefail

# This script runs on the Bazzite host. The home directory is shared with Distrobox.
exec distrobox enter --name '$CONTAINER_NAME' -- env \
    RUSTICL_ENABLE=radeonsi \
    OCL_ICD_VENDORS="\$HOME/rusticl-only" \
    run-davinci -c /opt/resolve/bin/resolve "\$@"
HOST_LAUNCHER
        chmod 0755 "$HOME/.local/bin/resolve-rusticl"

        cat > "$HOME/.local/share/applications/davinci-resolve-rusticl.desktop" <<DESKTOP_ENTRY
[Desktop Entry]
Version=1.0
Type=Application
Name=DaVinci Resolve (Rusticl)
Comment=DaVinci Resolve running through Distrobox with Mesa Rusticl OpenCL
Exec=$HOME/.local/bin/resolve-rusticl %U
Icon=$ICON_PATH
Terminal=false
Categories=AudioVideo;Video;
StartupNotify=true
DESKTOP_ENTRY
        chmod 0755 "$HOME/.local/share/applications/davinci-resolve-rusticl.desktop"

        if command -v xdg-user-dir >/dev/null 2>&1; then
            DESKTOP_DIR="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
            if [[ -n "$DESKTOP_DIR" ]]; then
                mkdir -p "$DESKTOP_DIR"
                cp "$HOME/.local/share/applications/davinci-resolve-rusticl.desktop" "$DESKTOP_DIR/"
                chmod 0755 "$DESKTOP_DIR/davinci-resolve-rusticl.desktop"
                log "Desktop shortcut copied to: $DESKTOP_DIR"
            fi
        fi
        log 'Application entry created: DaVinci Resolve (Rusticl)'
        warn 'If your desktop environment asks, mark the desktop entry as trusted or allow launching.'
    else
        warn 'run-davinci or /opt/resolve/bin/resolve was not found; skipping launcher creation.'
        warn 'Install DaVinci Resolve in this container, then rerun this script to create the launcher.'
    fi
fi

trap - ERR
log 'Setup completed successfully.'
printf 'Container: %s\n' "$CONTAINER_NAME"
printf 'Isolated Rusticl ICD directory: %s\n' "$ICD_DIR"
printf 'Patched libclc source/build: %s\n' "$SRC_DIR"
printf 'Original files backup: %s\n' "$BACKUP_DIR"
printf '\nLaunch Resolve from your application menu as: DaVinci Resolve (Rusticl)\n'
printf 'Or from the Bazzite host: %s/.local/bin/resolve-rusticl\n' "$HOME"
printf '\nNOTE: after Mesa/libclc package updates, rerun this script to reapply the patched SPIR-V files.\n'
