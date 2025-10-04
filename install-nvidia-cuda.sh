#!/bin/bash
# NVIDIA Driver + CUDA Toolkit installer for Debian 11/12/13
# Author: Dennis Hilk

set -euo pipefail

echo "=== NVIDIA Driver + CUDA Toolkit Installer for Debian 11/12/13 ==="

# --- Root check ---
if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root. Try again with: sudo $0"
  exit 1
fi

# --- Detect Debian version ---
. /etc/os-release
DEBIAN_VERSION="${VERSION_ID:-}"
DEBIAN_MAJOR="${DEBIAN_VERSION%%.*}"

ARCH="$(dpkg --print-architecture)"  # amd64 / arm64
case "$ARCH" in
  amd64|arm64) : ;;
  *) echo "Unsupported architecture: $ARCH (only amd64/arm64 supported)"; exit 1 ;;
esac

echo "Detected Debian $DEBIAN_VERSION ($ARCH)"

# --- Pick repo base ---
CUDA_REPO_BASE="https://developer.download.nvidia.com/compute/cuda/repos"
case "$DEBIAN_MAJOR" in
  11) CUDA_REPO_DIST="debian11" ;;
  12) CUDA_REPO_DIST="debian12" ;;
  13) 
    echo "Debian 13 detected. Using Debian 12 CUDA repo as fallback..."
    CUDA_REPO_DIST="debian12"
    ;;
  *) echo "Unsupported Debian version: $DEBIAN_VERSION"; exit 1 ;;
esac

# --- Install prerequisites ---
echo "[1/6] Installing prerequisites..."
apt-get update
apt-get install -y wget curl gnupg build-essential dkms "linux-headers-$(uname -r)"

# --- Install NVIDIA CUDA keyring ---
echo "[2/6] Adding NVIDIA CUDA repository..."
wget -q "https://developer.download.nvidia.com/compute/cuda/repos/$CUDA_REPO_DIST/x86_64/cuda-keyring_1.1-1_all.deb"
dpkg -i cuda-keyring_1.1-1_all.deb
rm -f cuda-keyring_1.1-1_all.deb
apt-get update

# --- Install CUDA ---
echo "[3/6] Installing NVIDIA driver + CUDA Toolkit..."
apt-get install -y cuda

# --- Setup environment variables ---
echo "[4/6] Configuring CUDA environment..."
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

# --- Blacklist nouveau ---
echo "[5/6] Blacklisting nouveau driver..."
BLACKLIST_FILE="/etc/modprobe.d/blacklist-nouveau.conf"
if ! grep -q "blacklist nouveau" "$BLACKLIST_FILE" 2>/dev/null; then
  echo -e "blacklist nouveau\noptions nouveau modeset=0" > "$BLACKLIST_FILE"
  update-initramfs -u
fi

# --- Finish ---
echo "[6/6] Installation complete."
echo "Please reboot your system to load the NVIDIA driver."
echo "After reboot, verify with: nvidia-smi && nvcc --version"
