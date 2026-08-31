#!/usr/bin/env bash
# ============================================================
# NVIDIA Driver + (optional) CUDA Toolkit for Debian 12/13
# "Debian-clean" edition (APT-first, no mixed installer by default)
# Author: Dennis Hilk
# Version: 1.3.0
#
# Features:
#  - Strict mode + logging
#  - Safe APT/dpkg lock handling (never kills package managers or removes locks)
#  - Detect NVIDIA GPU
#  - Checks .list and deb822 .sources files for required APT components
#  - Stable driver install (Debian repo) or Backports install
#  - Optional CUDA Toolkit (Debian package)
#  - Nouveau enable, full clean remove
#  - Secure Boot + Wayland hints
# ============================================================

set -Eeuo pipefail

# ----------------------------
# Logging
# ----------------------------
LOGFILE="/var/log/nvidia-optimizer.log"
SCRIPT_VERSION="1.3.0"
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

clear 2>/dev/null || true
echo -e "${CYAN}──────────────────────────────────────────────────────────"
echo -e "     🧠 NVIDIA Driver + CUDA Toolkit (Debian 12/13)  v${SCRIPT_VERSION}"
echo -e "──────────────────────────────────────────────────────────${NC}"
echo -e "Log file: ${YELLOW}${LOGFILE}${NC}"
echo

# ----------------------------
# Minimal requirements
# ----------------------------
need_cmd uname
need_cmd grep
need_cmd sed
need_cmd awk
need_cmd apt
need_cmd dpkg
need_cmd dpkg-query
need_cmd apt-cache
need_cmd pgrep
need_cmd tee

# ----------------------------
# System info
# ----------------------------
KERNEL="$(uname -r)"
SESSION="${XDG_SESSION_TYPE:-unknown}"
ARCH="$(dpkg --print-architecture)"
SECURE_BOOT_ENABLED=0
CODENAME="unknown"
DEBIAN_VERSION="unknown"

if [[ ! -r /etc/os-release ]]; then
  die "Cannot identify the operating system: /etc/os-release is missing."
fi

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Unsupported distribution: ${PRETTY_NAME:-${ID:-unknown}}. This script supports Debian only."

DEBIAN_VERSION="${VERSION_ID:-unknown}"
CODENAME="${VERSION_CODENAME:-unknown}"
case "${DEBIAN_VERSION}" in
  12|12.*|13|13.*) ;;
  *) die "Unsupported Debian version: ${DEBIAN_VERSION}. Supported releases: Debian 12 and 13." ;;
esac

case "${ARCH}" in
  amd64|arm64) ;;
  *) die "Unsupported architecture: ${ARCH}. Supported architectures: amd64 and arm64." ;;
esac

info "Debian:      ${DEBIAN_VERSION} (${CODENAME})"
info "Architecture: ${ARCH}"
info "Kernel:      ${KERNEL}"
info "Session:     ${SESSION}"
if [[ "$SESSION" == "wayland" ]]; then
  info "Wayland session detected."
fi

# Secure Boot hint (best-effort)
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi "enabled"; then
    SECURE_BOOT_ENABLED=1
    warn "Secure Boot appears ENABLED. Unsigned NVIDIA modules may fail to load."
    warn "If the driver does not load: disable Secure Boot or enroll/sign modules (MOK)."
  fi
fi

echo

# ----------------------------
# NVIDIA GPU detection (lspci first, sysfs fallback for minimal systems)
# ----------------------------
detect_nvidia_gpu() {
  if command -v lspci >/dev/null 2>&1; then
    lspci | grep -Ei 'VGA|3D|Display' | grep -i nvidia || true
    return
  fi

  local device vendor class
  for device in /sys/bus/pci/devices/*; do
    [[ -r "${device}/vendor" && -r "${device}/class" ]] || continue
    vendor="$(<"${device}/vendor")"
    class="$(<"${device}/class")"
    if [[ "${vendor,,}" == "0x10de" && "${class,,}" == 0x03* ]]; then
      printf 'NVIDIA PCI display device %s (class %s)\n' "${device##*/}" "${class}"
    fi
  done
}

GPU="$(detect_nvidia_gpu)"
[[ -n "$GPU" ]] || die "No NVIDIA GPU detected."
ok "NVIDIA GPU detected:"
echo "$GPU"
echo

# ----------------------------
# APT sources sanity (non-free + non-free-firmware)
# ----------------------------
collect_apt_source_files() {
  APT_SOURCE_FILES=()
  [[ -r /etc/apt/sources.list ]] && APT_SOURCE_FILES+=(/etc/apt/sources.list)

  local file
  shopt -s nullglob
  for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -r "${file}" ]] && APT_SOURCE_FILES+=("${file}")
  done
  shopt -u nullglob
}

apt_source_text() {
  (( ${#APT_SOURCE_FILES[@]} > 0 )) || return 1
  sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "${APT_SOURCE_FILES[@]}" 2>/dev/null
}

has_apt_source_token() {
  local token="$1"
  apt_source_text | grep -Eq "(^|[[:space:]])${token}([[:space:]]|$)"
}

check_nonfree_sources() {
  if (( ${#APT_SOURCE_FILES[@]} == 0 )); then
    warn "No readable APT source files found."
    warn "Checked /etc/apt/sources.list and /etc/apt/sources.list.d/*.{list,sources}."
    return 1
  fi

  if ! has_apt_source_token "non-free"; then
    warn "APT sources do not seem to include: non-free"
    warn "Enable it in your .list or deb822 .sources configuration."
    return 1
  fi

  if ! has_apt_source_token "contrib"; then
    warn "APT sources do not seem to include: contrib"
    warn "Enable it in your .list or deb822 .sources configuration."
    return 1
  fi

  if ! has_apt_source_token "non-free-firmware"; then
    warn "APT sources do not seem to include: non-free-firmware"
    warn "Debian 12/13 use it for firmware packages."
    return 1
  fi

  return 0
}

APT_SOURCE_FILES=()
collect_apt_source_files

if ! check_nonfree_sources; then
  echo
  warn "Fix your APT sources first, then re-run this script."
  echo "Example for ${CODENAME}:"
  echo "  deb http://deb.debian.org/debian ${CODENAME} main contrib non-free non-free-firmware"
  echo "  deb http://security.debian.org/debian-security ${CODENAME}-security main contrib non-free non-free-firmware"
  echo "  deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free non-free-firmware"
  echo
  die "APT sources missing required components."
fi
ok "APT sources look good (contrib + non-free + non-free-firmware detected)."
echo

has_suite_sources() {
  local suite="$1"
  has_apt_source_token "${suite}"
}

# ----------------------------
# Smart APT/dpkg lock monitor (SAFE)
# ----------------------------
check_locks() {
  info "Checking for running apt/dpkg processes..."
  local timeout=120
  local waited=0

  while pgrep -x apt >/dev/null 2>&1 ||
        pgrep -x apt-get >/dev/null 2>&1 ||
        pgrep -x dpkg >/dev/null 2>&1; do
    if (( waited >= timeout )); then
      die "APT/dpkg is still running after ${timeout}s. Let it finish, then re-run this script."
    fi
    echo -ne "${YELLOW}⏳ Waiting for package manager... (${waited}s)\r${NC}"
    sleep 3
    (( waited += 3 ))
  done

  echo
  ok "No active APT/dpkg process detected."
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
# Common install deps
# ----------------------------
install_common_deps() {
  progress "Updating APT index"
  apt update

  progress "Installing build deps + headers"
  local packages=(dkms build-essential firmware-misc-nonfree)
  local header_meta="linux-headers-${ARCH}"

  if apt-cache show "${header_meta}" >/dev/null 2>&1; then
    packages+=("${header_meta}")
  else
    warn "No architecture header metapackage found: ${header_meta}"
  fi

  if apt-cache show "linux-headers-${KERNEL}" >/dev/null 2>&1; then
    packages+=("linux-headers-${KERNEL}")
  else
    warn "No exact headers for running kernel found: linux-headers-${KERNEL}"
    warn "The ${header_meta} metapackage will install headers for Debian's current kernel."
    warn "Reboot into that kernel before expecting the NVIDIA DKMS module to load."
  fi
  apt install -y --no-install-recommends "${packages[@]}"
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
  local installed=()
  mapfile -t installed < <(
    dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' 2>/dev/null |
      awk '$2 == "installed" && $1 ~ /^nvidia-/ { print $1 }'
  )

  if (( ${#installed[@]} > 0 )); then
    warn "Installed nvidia-* packages that will be removed:"
    printf '  %s\n' "${installed[@]}"
    progress "Purging NVIDIA packages"
    apt purge -y "${installed[@]}"
  else
    info "No installed nvidia-* packages detected."
  fi

  progress "Autoremoving unused deps"
  apt autoremove -y

  unblacklist_nouveau

  progress "Updating initramfs"
  update-initramfs -u

  ok "NVIDIA removed."
}

# ----------------------------
# CUDA Toolkit (Debian package)
# ----------------------------
install_cuda_toolkit_debian() {
  warn "Installing CUDA Toolkit from Debian repo (nvidia-cuda-toolkit)."
  warn "Note: This may not be the newest CUDA version, but it is Debian-managed and stable."
  warn "If you need the newest CUDA, consider NVIDIA's official repo:"
  warn "https://developer.nvidia.com/cuda-downloads (use with caution on Debian)."
  if ! apt-cache show nvidia-cuda-toolkit >/dev/null 2>&1; then
    die "nvidia-cuda-toolkit is unavailable. Verify that non-free is enabled and apt update succeeded."
  fi
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

handle_secure_boot() {
  if (( SECURE_BOOT_ENABLED == 1 )); then
    warn "Secure Boot is enabled. NVIDIA DKMS modules may require MOK enrollment."
    warn "Debian DKMS normally stores its enrollment certificate at /var/lib/dkms/mok.pub."
    warn "After installation, import it with mokutil --import /var/lib/dkms/mok.pub, then reboot and enroll it in MOK Manager."
    if ! confirm "Continue with Secure Boot enabled?"; then
      die "Aborted."
    fi
  fi
}

case "${CHOICE}" in
  1)
    info "Installing NVIDIA driver from Debian stable repo..."
    handle_secure_boot
    unblacklist_nouveau
    install_common_deps

    progress "Installing nvidia-driver"
    apt install -y nvidia-driver

    blacklist_nouveau
    progress "Updating initramfs"
    update-initramfs -u

    ok "Driver installation finished (Debian stable repo)."
    ;;

  2)
    info "Installing NVIDIA driver from Debian backports..."
    handle_secure_boot
    unblacklist_nouveau
    install_common_deps

    # Try to detect backports suite name; Debian typically uses: trixie-backports
    SUITE="${CODENAME}-backports"
    warn "Using APT suite: ${SUITE}"
    warn "If you don't have backports enabled, this will fail."
    echo "Example line:"
    echo "  deb http://deb.debian.org/debian ${SUITE} main contrib non-free non-free-firmware"
    echo
    if ! has_suite_sources "${SUITE}"; then
      warn "Backports source (${SUITE}) not detected in APT sources."
      if ! confirm "Continue anyway?"; then
        die "Enable ${SUITE} in APT sources and re-run."
      fi
    fi

    progress "Installing nvidia-driver from backports"
    apt install -y -t "${SUITE}" nvidia-driver || die "Backports install failed. Enable ${SUITE} in APT sources."

    blacklist_nouveau
    progress "Updating initramfs"
    update-initramfs -u

    ok "Driver installation finished (backports)."
    ;;

  3)
    info "Enabling nouveau driver..."
    remove_nvidia

    progress "Installing nouveau Xorg driver"
    apt install -y xserver-xorg-video-nouveau

    progress "Updating initramfs"
    update-initramfs -u

    ok "Nouveau enabled."
    ;;

  4)
    info "Removing NVIDIA driver and cleaning system..."
    remove_nvidia
    ok "System cleaned. Nouveau is no longer blacklisted by this script."
    ;;

  5)
    warn "ADVANCED MODE: NVIDIA .run installer on Debian is NOT recommended."
    warn "This can cause APT conflicts and breaks Debian-managed updates."
    if ! confirm "Continue with .run installer anyway?"; then
      die "Aborted."
    fi

    [[ "${ARCH}" == "amd64" ]] || die "The advanced .run installer option currently supports amd64 only."

    need_cmd curl
    need_cmd wget

    if dpkg -l | grep -q '^ii[[:space:]]\+nvidia-driver'; then
      warn "Debian nvidia-driver package appears installed."
      warn "Mixing .run installer with APT can cause conflicts."
      if ! confirm "Proceed and remove Debian NVIDIA packages?"; then
        die "Aborted."
      fi
    fi

    handle_secure_boot
    remove_nvidia
    install_common_deps

    mkdir -p /root/nvidia-install
    cd /root/nvidia-install

    warn "Fetching NVIDIA's current Linux x86_64 driver metadata..."
    LATEST_LINE="$(curl -fsSL https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt)" || die "Could not fetch NVIDIA driver metadata."
    read -r LATEST RUN_PATH _ <<<"${LATEST_LINE}"
    [[ "${LATEST}" =~ ^[0-9]+(\.[0-9]+)+$ ]] || die "NVIDIA returned an invalid driver version: ${LATEST:-empty}"
    [[ "${RUN_PATH}" == "${LATEST}/NVIDIA-Linux-x86_64-${LATEST}.run" ]] || die "NVIDIA returned an unexpected download path."
    ok "Latest NVIDIA version detected: ${LATEST}"

    progress "Downloading NVIDIA-Linux-x86_64-${LATEST}.run"
    wget -O NVIDIA-Linux.run "https://download.nvidia.com/XFree86/Linux-x86_64/${RUN_PATH}"

    chmod +x NVIDIA-Linux.run

    warn "You may need to stop your display manager before running the installer."
    warn "If you are on a desktop system, consider switching to a TTY (Ctrl+Alt+F3) and stopping gdm/sddm/lightdm."
    pause

    progress "Running .run installer with DKMS"
    ./NVIDIA-Linux.run --dkms --no-cc-version-check

    blacklist_nouveau
    progress "Updating initramfs"
    update-initramfs -u

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
