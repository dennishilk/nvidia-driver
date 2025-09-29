#!/bin/bash
# NVIDIA Driver + CUDA Toolkit installer for Debian 11/12/13


set -euo pipefail

echo "=== NVIDIA Driver + CUDA Toolkit Installer for Debian 11/12/13 ==="
echo Author: Dennis Hilk
# --- 0) Root-Check -----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Try again with: sudo $0"
  exit 1
fi

# --- 1) Detect Debian + Arch -------------------------------------------------
. /etc/os-release
DEBIAN_VERSION="${VERSION_ID:-}"
DEBIAN_MAJOR="${DEBIAN_VERSION%%.*}"

ARCH="$(dpkg --print-architecture)"  # amd64 / arm64
case "$ARCH" in
  amd64|arm64) : ;;
  *) echo "Unsupported architecture: $ARCH (supported: amd64, arm64)"; exit 1 ;;
esac

echo "Detected Debian $DEBIAN_VERSION (major $DEBIAN_MAJOR), arch: $ARCH"

# --- 2) Choose CUDA repo path with smart fallback ----------------------------
CUDA_REPO_BASE="https://developer.download.nvidia.com/compute/cuda/repos"

choose_repo_dist() {
  case "$DEBIAN_MAJOR" in
    11) echo "debian11" ;;
    12) echo "debian12" ;;
    13)
      # Try debian13 first; if missing, fall back to debian12
      if curl -fsI "$CUDA_REPO_BASE/debian13/$ARCH/Release" >/dev/null 2>&1; then
        echo "debian13"
      else
        echo "debian12"
        echo "WARNING: No official debian13 CUDA repo found — falling back to debian12." >&2
      fi
      ;;
    *)
      echo "Unsupported Debian version: $DEBIAN_VERSION" >&2
      exit 1
      ;;
  esac
}

CUDA_REPO_DIST="$(choose_repo_dist)"
echo "Using CUDA repo dist: $CUDA_REPO_DIST"

# --- 3) Prerequisites --------------------------------------------------------
echo "[1/7] Installing prerequisites..."
apt-get update
apt-get install -y --no-install-recommends \
  curl ca-certificates gnupg lsb-release \
  build-essential dkms "linux-headers-$(uname -r)" mokutil || true

# --- 4) Add NVIDIA CUDA APT repository --------------------------------------
echo "[2/7] Adding NVIDIA CUDA repository + key..."
install -d -m 0755 /usr/share/keyrings
curl -fsSL "$CUDA_REPO_BASE/$CUDA_REPO_DIST/$ARCH/3bf863cc.pub" \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-cuda-archive-keyring.gpg

cat >/etc/apt/sources.list.d/nvidia-cuda.list <<EOF
deb [arch=$ARCH signed-by=/usr/share/keyrings/nvidia-cuda-archive-keyring.gpg] $CUDA_REPO_BASE/$CUDA_REPO_DIST/$ARCH /
EOF

# --- 5) Update and install CUDA (driver + toolkit) ---------------------------
echo "[3/7] Updating package lists..."
apt-get update

echo "[4/7] Installing NVIDIA driver + CUDA Toolkit (meta package 'cuda')..."
apt-get install -y cuda

# --- 6) Environment (system-wide) -------------------------------------------
echo "[5/7] Configuring CUDA environment..."
CUDA_PATH="/usr/local/cuda"
PROFILE_D="/etc/profile.d/cuda.sh"
if [[ ! -f "$PROFILE_D" ]]; then
  cat >"$PROFILE_D" <<'EOF'
# CUDA environment
if [ -d /usr/local/cuda ]; then
  export PATH="/usr/local/cuda/bin:$PATH"
  export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi
EOF
  chmod 0644 "$PROFILE_D"
fi

# --- 7) Optional: blacklist nouveau to avoid driver conflicts ---------------
echo "[6/7] Checking for Nouveau (open-source driver) blacklist..."
BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
if ! grep -q "blacklist nouveau" "$BLACKLIST_FILE" 2>/dev/null; then
  echo -e "blacklist nouveau\noptions nouveau modeset=0" > "$BLACKLIST_FILE"
  update-initramfs -u
  echo "Nouveau has been blacklisted and initramfs updated."
fi

# --- 8) Secure Boot warning --------------------------------------------------
if command -v mokutil >/dev/null 2>&1; then
  if mokutil --sb-state 2>/dev/null | grep -qi "SecureBoot enabled"; then
    echo "NOTE: Secure Boot appears to be ENABLED."
    echo "If the NVIDIA kernel module fails to load, you may need to disable Secure Boot"
    echo "or enroll a Machine Owner Key (MOK) for DKMS modules."
  fi
fi

# --- 9) Done ----------------------------------------------------------------
echo "[7/7] Installation complete."
echo "Please reboot your system to load the NVIDIA driver."
echo "After reboot, verify with: nvidia-smi && nvcc --version"

