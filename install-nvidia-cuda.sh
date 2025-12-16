#!/usr/bin/env bash
# ============================================================
# NVIDIA Driver + (optional) CUDA Toolkit for Debian 13 (Trixie)
# "Debian-clean" edition (APT-first, no mixed installer by default)
# Author: Dennis Hilk
# Version: 1.2.0
#
# Features:
#  - Strict mode + logging
#  - Safe APT/dpkg lock handling (no blind killing)
#  - Detect NVIDIA GPU
#  - Checks non-free + non-free-firmware APT sources
#  - Stable driver install (Debian repo) or Backports install
#  - Optional CUDA Toolkit (Debian package)
#  - Nouveau enable, full clean remove
#  - Secure Boot + Wayland hints
#  - Uses /etc/X11/xorg.conf.d (modular) instead of patching xorg.conf
# ============================================================

set -Eeuo pipefail

# ----------------------------
# Logging
# ----------------------------
LOGFILE="/var/log/nvidia-optimizer.log"
mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

# ----------------------------
# Colors
# ----------------------------
GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"

# ----------------------------
# Helpers
# ----------------------------
die() { echo -e "${RED}❌ $*${NC}"; exit 1; }
info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
ok() { echo -e "${GREEN}✅ $*${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $*${NC}"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1 (please install it first)"
}

pause() {
  read -rp "Press Enter to continue..." _ </dev/tty || true
}

confirm() {
  local prompt="${1:-Are you sure?} [y/N]: "
  read -r -p "$prompt" ans </dev/tty || true
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

progress() { local msg="$1"; echo -e "${CYAN}${msg}${NC}"; }

# ----------------------------
# Root check (cleaner than sudo everywhere)
# ----------------------------
if [[ ${EUID:-0} -ne 0 ]]; then
  die "Please run as root: sudo $0"
fi

clear
echo -e "${CYAN}──────────────────────────────────────────────────────────"
echo -e "     🧠 NVIDIA Driver + CUDA Toolkit (Debian 13)  v1.2.0"
echo -e "──────────────────────────────────────────────────────────${NC}"
echo -e "Log file: ${YELLOW}${LOGFILE}${NC}"
echo

# ----------------------------
# Minimal requirements
# ----------------------------
need_cmd uname
need_cmd grep
need_cmd sed
need_cmd lspci
need_cmd apt
need_cmd dpkg
need_cmd tee

# ----------------------------
# System info
# ----------------------------
KERNEL="$(uname -r)"
SESSION="${XDG_SESSION_TYPE:-unknown}"

info "Kernel:  ${KERNEL}"
info "Session: ${SESSION}"
if [[ "$SESSION" == "wayland" ]]; then
  warn "Wayland session detected. Xorg config tweaks may be ignored (depends on DE)."
fi

# Secure Boot hint (best-effort)
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    warn "Secure Boot appears ENABLED. Unsigned NVIDIA modules may fail to load."
    warn "If the driver does not load: disable Secure Boot or enroll/sign modules (MOK)."
  fi
fi

echo

# ----------------------------
# NVIDIA GPU detection
# ----------------------------
GPU="$(lspci | grep -E "VGA|3D" | grep -i nvidia || true)"
[[ -n "$GPU" ]] || die "No NVIDIA GPU detected."
ok "NVIDIA GPU detected:"
echo "$GPU"
echo

# ----------------------------
# Debian release / codename
# ----------------------------
CODENAME="unknown"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-${CODENAME}}"
fi

info "Debian codename: ${CODENAME}"

# ----------------------------
# APT sources sanity (non-free + non-free-firmware)
# ----------------------------
check_nonfree_sources() {
  # Debian 12/13 typically need: main contrib non-free non-free-firmware
  local sources=()
  [[ -f /etc/apt/sources.list ]] && sources+=("/etc/apt/sources.list")
  if compgen -G "/etc/apt/sources.list.d/*.list" >/dev/null; then
    sources+=(/etc/apt/sources.list.d/*.list)
  fi

  local all_text
  all_text="$(cat "${sources[@]}" 2>/dev/null || true)"

  if ! echo "$all_text" | grep -Eq '^[[:space:]]*deb[[:space:]].*(non-free)'; then
    warn "APT sources do not seem to include: non-free"
    warn "Enable it in your sources.list (recommended for NVIDIA)."
    return 1
  fi

  if ! echo "$all_text" | grep -Eq '^[[:space:]]*deb[[:space:]].*(non-free-firmware)'; then
    warn "APT sources do not seem to include: non-free-firmware"
    warn "Debian 13 typically needs it for firmware packages."
    return 1
  fi

  return 0
}

if ! check_nonfree_sources; then
  echo
  warn "Fix your APT sources first, then re-run this script."
  echo "Example (Debian 13 Trixie):"
  echo "  deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware"
  echo "  deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware"
  echo "  deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware"
  echo
  die "APT sources missing required components."
fi
ok "APT sources look good (non-free + non-free-firmware detected)."
echo

# ----------------------------
# Smart APT/dpkg lock monitor (SAFE)
# ----------------------------
check_locks() {
  info "Checking for running apt/dpkg processes..."
  local timeout=120
  local waited=0

  while pgrep -x apt >/dev/null 2>&1 || pgrep -x dpkg >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      warn "APT/dpkg still running after ${timeout}s."
      warn "Killing package manager processes can BREAK your system."
      if confirm "Do you want to attempt killing apt/dpkg anyway?"; then
        warn "Attempting to kill apt/dpkg..."
        pkill -9 apt 2>/dev/null || true
        pkill -9 dpkg 2>/dev/null || true
        break
      else
        die "Please wait until apt/dpkg finishes, then re-run."
      fi
    fi
    echo -ne "${YELLOW}⏳ Waiting for package manager... (${waited}s)\r${NC}"
    sleep 3
    (( waited += 3 ))
  done

  echo
  # Do NOT rm lock files blindly unless user confirms (can be dangerous)
  if [[ -e /var/lib/dpkg/lock-frontend || -e /var/lib/dpkg/lock || -e /var/cache/apt/archives/lock ]]; then
    warn "Lock files detected."
    warn "Removing lock files while apt is running can corrupt dpkg state."
    if confirm "Remove lock files now? (only do this if you are sure apt is NOT running)"; then
      rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock || true
      ok "Lock files removed."
    else
      warn "Keeping lock files."
    fi
  fi
}

# ----------------------------
# Detect current driver
# ----------------------------
if command -v nvidia-smi >/dev/null 2>&1; then
  CURRENT="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1 || true)"
  ok "Current NVIDIA driver: ${CURRENT:-unknown}"
else
  warn "No NVIDIA driver currently detected (nvidia-smi not found)."
fi
echo

# ----------------------------
# Xorg config (modular)
# ----------------------------
ensure_xorg_conf_d() {
  mkdir -p /etc/X11/xorg.conf.d
}

write_xorg_driver_snippet() {
  # $1: driver name
  local driver="$1"
  ensure_xorg_conf_d
  cat > /etc/X11/xorg.conf.d/10-gpu-driver.conf <<EOF
Section "Device"
    Identifier "GPU0"
    Driver "${driver}"
EndSection
EOF
  ok "Wrote /etc/X11/xorg.conf.d/10-gpu-driver.conf (Driver \"${driver}\")"
}

remove_xorg_driver_snippet() {
  if [[ -f /etc/X11/xorg.conf.d/10-gpu-driver.conf ]]; then
    cp -a /etc/X11/xorg.conf.d/10-gpu-driver.conf \
      "/etc/X11/xorg.conf.d/10-gpu-driver.conf.backup.$(date +%F_%H-%M-%S)"
    rm -f /etc/X11/xorg.conf.d/10-gpu-driver.conf
    ok "Removed xorg driver snippet (backup created)."
  fi
}

# ----------------------------
# Common install deps
# ----------------------------
install_common_deps() {
  progress "Updating APT index"
  apt update

  progress "Installing build deps + headers"
  apt install -y --no-install-recommends \
    dkms build-essential "linux-headers-${KERNEL}" \
    firmware-misc-nonfree
}

# ----------------------------
# Nouveau handling
# ----------------------------
blacklist_nouveau() {
  cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF
  ok "Nouveau blacklisted: /etc/modprobe.d/blacklist-nouveau.conf"
}

unblacklist_nouveau() {
  rm -f /etc/modprobe.d/blacklist-nouveau.conf || true
  ok "Nouveau blacklist removed (if it existed)."
}

# ----------------------------
# NVIDIA remove/clean
# ----------------------------
remove_nvidia() {
  progress "Purging NVIDIA packages"
  apt purge -y 'nvidia-*' || true

  progress "Autoremoving unused deps"
  apt autoremove -y || true

  progress "Cleaning DKMS remnants (best-effort)"
  rm -rf /var/lib/dkms/nvidia* 2>/dev/null || true

  progress "Removing old modprobe snippets (best-effort)"
  rm -f /etc/modprobe.d/nvidia*.conf 2>/dev/null || true

  progress "Updating initramfs"
  update-initramfs -u

  remove_xorg_driver_snippet
  ok "NVIDIA removed."
}

# ----------------------------
# CUDA Toolkit (Debian package)
# ----------------------------
install_cuda_toolkit_debian() {
  warn "Installing CUDA Toolkit from Debian repo (nvidia-cuda-toolkit)."
  warn "Note: This may not be the newest CUDA version, but it is Debian-managed and stable."
  apt install -y nvidia-cuda-toolkit
  ok "CUDA Toolkit installed (Debian package)."
  echo
  info "Verify: nvcc --version"
}

# ----------------------------
# Menu
# ----------------------------
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo -e "${CYAN}Choose your action:${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo -e "1️⃣  Install NVIDIA driver (Debian stable repo)  [recommended]"
echo -e "2️⃣  Install NVIDIA driver (Debian backports)     [recommended if you need newer]"
echo -e "3️⃣  Enable open-source nouveau driver"
echo -e "4️⃣  Remove NVIDIA driver and clean system"
echo -e "5️⃣  ADVANCED: Install NVIDIA .run driver (NOT recommended on Debian)"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
read -rp "Enter choice [1-5]: " CHOICE </dev/tty
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
echo

check_locks

case "${CHOICE}" in
  1)
    info "Installing NVIDIA driver from Debian stable repo..."
    remove_nvidia
    unblacklist_nouveau
    install_common_deps

    progress "Installing nvidia-driver"
    apt install -y nvidia-driver

    blacklist_nouveau
    progress "Updating initramfs"
    update-initramfs -u

    write_xorg_driver_snippet "nvidia"

    ok "Driver installation finished (Debian stable repo)."
    ;;

  2)
    info "Installing NVIDIA driver from Debian backports..."
    remove_nvidia
    unblacklist_nouveau
    install_common_deps

    # Try to detect backports suite name; Debian typically uses: trixie-backports
    SUITE="${CODENAME}-backports"
    warn "Using APT suite: ${SUITE}"
    warn "If you don't have backports enabled, this will fail."
    echo "Example line:"
    echo "  deb http://deb.debian.org/debian ${SUITE} main contrib non-free non-free-firmware"
    echo

    progress "Installing nvidia-driver from backports"
    apt install -y -t "${SUITE}" nvidia-driver || die "Backports install failed. Enable ${SUITE} in APT sources."

    blacklist_nouveau
    progress "Updating initramfs"
    update-initramfs -u

    write_xorg_driver_snippet "nvidia"

    ok "Driver installation finished (backports)."
    ;;

  3)
    info "Enabling nouveau driver..."
    remove_nvidia

    progress "Installing nouveau Xorg driver"
    apt install -y xserver-xorg-video-nouveau

    unblacklist_nouveau
    progress "Updating initramfs"
    update-initramfs -u

    write_xorg_driver_snippet "nouveau"

    ok "Nouveau enabled."
    ;;

  4)
    info "Removing NVIDIA driver and cleaning system..."
    remove_nvidia

    # Prefer modesetting: no explicit snippet needed
    remove_xorg_driver_snippet
    ok "System cleaned. Using default modesetting (no forced Xorg driver)."
    ;;

  5)
    warn "ADVANCED MODE: NVIDIA .run installer on Debian is NOT recommended."
    warn "This can cause APT conflicts and breaks Debian-managed updates."
    if ! confirm "Continue with .run installer anyway?"; then
      die "Aborted."
    fi

    need_cmd curl
    need_cmd wget

    remove_nvidia
    unblacklist_nouveau
    install_common_deps

    mkdir -p /root/nvidia-install
    cd /root/nvidia-install

    warn "Fetching latest driver version (best-effort)..."
    # Keep a safe fallback; API endpoints can change.
    LATEST="$(curl -fsSL https://api.nvidia.com/v1/driver-latest-version/linux 2>/dev/null | grep -oP '"version":"\K[0-9.]+' || true)"
    if [[ -z "${LATEST}" ]]; then
      LATEST="580.95.05"
      warn "Could not fetch latest version. Using fallback: ${LATEST}"
    else
      ok "Latest NVIDIA version detected: ${LATEST}"
    fi

    progress "Downloading NVIDIA-Linux-x86_64-${LATEST}.run"
    wget -O NVIDIA-Linux.run "https://us.download.nvidia.com/XFree86/Linux-x86_64/${LATEST}/NVIDIA-Linux-x86_64-${LATEST}.run"

    chmod +x NVIDIA-Linux.run

    warn "You may need to stop your display manager before running the installer."
    warn "If you are on a desktop system, consider switching to a TTY (Ctrl+Alt+F3) and stopping gdm/sddm/lightdm."
    pause

    progress "Running .run installer with DKMS"
    ./NVIDIA-Linux.run --dkms --no-cc-version-check

    blacklist_nouveau
    progress "Updating initramfs"
    update-initramfs -u

    write_xorg_driver_snippet "nvidia"

    ok ".run driver installation finished (advanced)."
    ;;

  *)
    die "Invalid choice."
    ;;
esac

echo

# ----------------------------
# Optional CUDA prompt
# ----------------------------
if [[ "${CHOICE}" == "1" || "${CHOICE}" == "2" || "${CHOICE}" == "5" ]]; then
  if confirm "Install CUDA Toolkit (Debian package: nvidia-cuda-toolkit) now?"; then
    progress "Installing CUDA Toolkit"
    apt update
    install_cuda_toolkit_debian
  else
    info "Skipping CUDA Toolkit."
  fi
fi

echo
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
ok "All tasks completed."
echo -e "Log file: ${YELLOW}${LOGFILE}${NC}"
echo -e "Reboot recommended: ${CYAN}reboot${NC}"
echo -e "Verify driver:       ${CYAN}nvidia-smi${NC}"
echo -e "Verify CUDA (if set):${CYAN}nvcc --version${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
