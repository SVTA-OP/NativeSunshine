#!/usr/bin/env bash
# =============================================================================
# install.sh — Dependency checker and first-run setup wizard
#
# Usage:
#   ./install.sh            # Check and install missing dependencies
#   ./install.sh --check    # Check only, no installs
#   ./install.sh --apk      # Build and install Android APK (requires Android SDK)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    R='\033[0m' G='\033[0;32m' Y='\033[0;33m' C='\033[0;36m' E='\033[0;31m' B='\033[1m'
else
    R='' G='' Y='' C='' E='' B=''
fi
ok()   { echo -e "${G}  ✓${R}  $*"; }
warn() { echo -e "${Y}  ⚠${R}  $*"; }
err()  { echo -e "${E}  ✗${R}  $*" >&2; }
step() { echo -e "\n${B}── $* ──${R}"; }

# ── Flags ──────────────────────────────────────────────────────────────────
CHECK_ONLY=false
BUILD_APK=false
for arg in "$@"; do
    case "$arg" in
        --check)  CHECK_ONLY=true ;;
        --apk)    BUILD_APK=true ;;
        --help)
            echo "Usage: install.sh [--check] [--apk]"
            echo "  --check  Verify dependencies only, do not install anything"
            echo "  --apk    Build and install the Android APK after dep check"
            exit 0 ;;
    esac
done

# ── Package manager detection ───────────────────────────────────────────────
detect_pkg_manager() {
    if command -v apt-get &>/dev/null;  then echo "apt"
    elif command -v pacman &>/dev/null; then echo "pacman"
    elif command -v dnf &>/dev/null;    then echo "dnf"
    elif command -v zypper &>/dev/null; then echo "zypper"
    else echo "unknown"
    fi
}

PKG_MANAGER=$(detect_pkg_manager)

install_pkg() {
    local pkg="$1"
    if [[ "${CHECK_ONLY}" == "true" ]]; then
        warn "Would install: ${pkg}"
        return
    fi
    echo -e "  → Installing ${pkg}..."
    case "${PKG_MANAGER}" in
        apt)    sudo apt-get install -y "$pkg" ;;
        pacman) sudo pacman -S --noconfirm "$pkg" ;;
        dnf)    sudo dnf install -y "$pkg" ;;
        zypper) sudo zypper install -y "$pkg" ;;
        *)      warn "Unknown package manager. Please install '${pkg}' manually." ;;
    esac
}

# ── Package name mapping per distro ─────────────────────────────────────────
# Format: "command:apt_pkg:pacman_pkg:dnf_pkg"
declare -A PKG_MAP=(
    [adb]="adb:android-tools:android-tools:android-tools"
    [jq]="jq:jq:jq:jq"
    [pw-dump]="pw-dump:pipewire:pipewire:pipewire"
    [gdbus]="gdbus:libglib2.0-bin:glib2:glib2"
    [gst-launch-1.0]="gst-launch-1.0:gstreamer1.0-tools:gstreamer:gstreamer1"
    [gst-inspect-1.0]="gst-inspect-1.0:gstreamer1.0-tools:gstreamer:gstreamer1"
)

get_pkg_name() {
    local cmd="$1"
    local entry="${PKG_MAP[$cmd]:-}"
    [[ -z "$entry" ]] && { echo "$cmd"; return; }
    case "${PKG_MANAGER}" in
        apt)    echo "${entry}" | cut -d: -f2 ;;
        pacman) echo "${entry}" | cut -d: -f3 ;;
        dnf)    echo "${entry}" | cut -d: -f4 ;;
        *)      echo "${entry}" | cut -d: -f2 ;;  # default to apt name
    esac
}

# ── GStreamer plugin packages per distro ─────────────────────────────────────
gst_pkgs_apt=(
    gstreamer1.0-tools
    gstreamer1.0-plugins-base
    gstreamer1.0-plugins-good
    gstreamer1.0-plugins-bad
    gstreamer1.0-plugins-ugly
    gstreamer1.0-pipewire
    gstreamer1.0-vaapi
    libgstreamer1.0-dev
    libgstreamer-plugins-base1.0-dev
)
gst_pkgs_pacman=(
    gstreamer
    gst-plugins-base
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-plugin-pipewire
    gstreamer-vaapi
)
gst_pkgs_dnf=(
    gstreamer1
    gstreamer1-plugins-base
    gstreamer1-plugins-good
    gstreamer1-plugins-bad-free
    gstreamer1-plugins-ugly-free
    gstreamer1-plugin-pipewire
    gstreamer1-vaapi
)

# ── Main ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${B}NativeSunshine — Dependency Installer${R}"
echo -e "Package manager: ${C}${PKG_MANAGER}${R}"
echo ""

MISSING=0

# ── Section 1: Core commands ─────────────────────────────────────────────────
step "Core tools"
for cmd in adb jq pw-dump gdbus gst-launch-1.0 gst-inspect-1.0; do
    if command -v "$cmd" &>/dev/null; then
        ok "${cmd}"
    else
        err "${cmd} — not found"
        MISSING=$((MISSING+1))
        pkg=$(get_pkg_name "$cmd")
        install_pkg "$pkg"
    fi
done

# ── Section 2: GStreamer elements ─────────────────────────────────────────────
step "GStreamer elements"
gst_elements=(
    "pipewiresrc:PipeWire video source"
    "vaapih264enc:VAAPI H.264 encoder (AMD/Intel)"
    "h264parse:H.264 bitstream parser"
    "tcpclientsink:TCP stream output"
    "queue:Stream queue"
    "videoconvert:Video format converter"
    "vaapipostproc:VAAPI post-processor"
)

MISSING_GST=false
for entry in "${gst_elements[@]}"; do
    elem="${entry%%:*}"
    desc="${entry#*:}"
    if gst-inspect-1.0 --no-colors "$elem" &>/dev/null; then
        ok "${elem}  (${desc})"
    else
        err "${elem} — not found  (${desc})"
        MISSING=$((MISSING+1))
        MISSING_GST=true
    fi
done

if [[ "${MISSING_GST}" == "true" ]] && [[ "${CHECK_ONLY}" != "true" ]]; then
    step "Installing GStreamer packages"
    case "${PKG_MANAGER}" in
        apt)
            sudo apt-get install -y "${gst_pkgs_apt[@]}" ;;
        pacman)
            sudo pacman -S --noconfirm "${gst_pkgs_pacman[@]}" ;;
        dnf)
            sudo dnf install -y "${gst_pkgs_dnf[@]}" ;;
        *)
            warn "Please install GStreamer packages manually for your distro." ;;
    esac
fi

# ── Section 3: VAAPI runtime check ───────────────────────────────────────────
step "VAAPI (AMD GPU)"
if command -v vainfo &>/dev/null; then
    if vainfo 2>/dev/null | grep -qi "VAEntrypointEncSlice\|VAEntrypointEncSliceLP"; then
        ok "vainfo — hardware H.264 encoding supported"
    else
        warn "vainfo found but no H.264 encode entry point. Check your GPU driver."
        warn "For AMD: ensure mesa-va-drivers or amdgpu-pro-va is installed."
    fi
else
    warn "vainfo not found (optional diagnostic tool)"
    if [[ "${CHECK_ONLY}" != "true" ]]; then
        case "${PKG_MANAGER}" in
            apt)    sudo apt-get install -y vainfo libva-dev ;;
            pacman) sudo pacman -S --noconfirm libva-utils ;;
            dnf)    sudo dnf install -y libva-utils ;;
        esac
    fi
fi

# Check render device
VAAPI_DEV="${VAAPI_DEVICE:-/dev/dri/renderD128}"
if [[ -e "${VAAPI_DEV}" ]]; then
    ok "VAAPI device: ${VAAPI_DEV}"
    # Check user has access
    if [[ -r "${VAAPI_DEV}" ]] && [[ -w "${VAAPI_DEV}" ]]; then
        ok "Device permissions OK"
    else
        warn "Cannot read/write ${VAAPI_DEV}. Add yourself to the 'video' or 'render' group:"
        warn "  sudo usermod -aG video,render \$USER   (then log out and back in)"
    fi
else
    err "VAAPI device not found: ${VAAPI_DEV}"
    warn "Available render nodes:"
    ls /dev/dri/ 2>/dev/null | sed 's/^/    /' || warn "(no /dev/dri/ entries)"
fi

# ── Section 4: ADB check ─────────────────────────────────────────────────────
step "ADB / USB"
if command -v adb &>/dev/null; then
    ok "adb: $(adb version 2>/dev/null | head -1)"
    echo ""
    echo "  Connected devices:"
    adb devices 2>/dev/null | sed 's/^/    /'
else
    err "adb not found"
fi

# Check USB debugging note
echo ""
warn "Remember: USB Debugging must be enabled on your Android device."
warn "Settings → About Phone → tap Build Number ×7 → Developer Options → USB Debugging"

# ── Section 5: Virtual display check ─────────────────────────────────────────
step "GNOME virtual display"
SYSTEMD_OVERRIDE="${HOME}/.config/systemd/user/org.gnome.Shell@user.service.d/persistent-virtual-monitor.conf"
if [[ -f "${SYSTEMD_OVERRIDE}" ]]; then
    ok "systemd override found: ${SYSTEMD_OVERRIDE}"
    echo "  Contents:"
    cat "${SYSTEMD_OVERRIDE}" | sed 's/^/    /'
else
    warn "No GNOME Shell systemd override found at:"
    warn "  ${SYSTEMD_OVERRIDE}"
    warn ""
    warn "Create it to add a persistent virtual monitor:"
    warn "  mkdir -p \$(dirname '${SYSTEMD_OVERRIDE}')"
    warn "  cat > '${SYSTEMD_OVERRIDE}' << 'EOF'"
    warn "  [Service]"
    warn "  ExecStart="
    warn "  ExecStart=/usr/bin/gnome-shell --mode=user --virtual-monitor 800x1340"
    warn "  EOF"
    warn "  systemctl --user daemon-reload"
    warn "  Then log out and back in."
fi

# Check if virtual monitor is currently live
if gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null | grep -q "Virtual-"; then
    ok "Virtual monitor is live in current Mutter session"
else
    warn "No 'Virtual-N' output detected in current Mutter session."
    warn "Log out and back in after setting the systemd override."
fi

# ── Section 6: Android APK ───────────────────────────────────────────────────
step "Android APK"
APK_PATH="${SCRIPT_DIR}/android/NativeSunshine/app/build/outputs/apk/debug/app-debug.apk"
if [[ -f "${APK_PATH}" ]]; then
    ok "APK built: ${APK_PATH}"
else
    warn "APK not yet built: ${APK_PATH}"
    if [[ "${BUILD_APK}" == "true" ]]; then
        step "Building APK"
        if command -v java &>/dev/null; then
            pushd "${SCRIPT_DIR}/android/NativeSunshine" >/dev/null
            chmod +x gradlew
            ./gradlew assembleDebug
            popd >/dev/null
            if [[ -f "${APK_PATH}" ]]; then
                ok "APK built successfully"
                if command -v adb &>/dev/null; then
                    echo "  Installing APK on connected device..."
                    adb install -r "${APK_PATH}" && ok "APK installed" || warn "APK install failed"
                fi
            else
                err "APK build failed. Check Android SDK setup."
            fi
        else
            err "Java not found. Install JDK 17+: sudo apt install openjdk-17-jdk"
        fi
    else
        warn "Run './install.sh --apk' to build and install the Android APK."
        warn "Or build manually:"
        warn "  cd android/NativeSunshine && ./gradlew assembleDebug"
        warn "  adb install app/build/outputs/apk/debug/app-debug.apk"
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
if [[ "${MISSING}" -eq 0 ]]; then
    echo -e "${G}  All dependencies satisfied. Ready to stream!${R}"
    echo ""
    echo -e "  Run: ${B}./native-sunshine.sh${R}"
else
    echo -e "${Y}  ${MISSING} issue(s) found.${R}"
    if [[ "${CHECK_ONLY}" == "true" ]]; then
        echo -e "  Run ${B}./install.sh${R} (without --check) to fix them."
    fi
fi
echo -e "${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}"
echo ""
