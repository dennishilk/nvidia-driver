#!/bin/bash
# NVIDIA Optimizer for Debian 13 (Liquorix / Stable) v2.3.1
# Author: Dennis Hilk + GPT-5

LOGFILE="/var/log/nvidia-optimizer.log"
exec > >(tee -a "$LOGFILE") 2>&1
set -e

GREEN="\033[0;32m"; RED="\033[0;31m"; YELLOW="\033[1;33m"; CYAN="\033[0;36m"; NC="\033[0m"

clear
echo -e "${CYAN}───────────────────────────────────────────────"
echo -e "     🧠 NVIDIA Optimizer for Debian 13 v2.3.1"
echo -e "───────────────────────────────────────────────${NC}"

# ───────────────────────────────────────────────
# Smart APT/dpkg Lock Monitor
# ───────────────────────────────────────────────
check_locks() {
    echo -e "${CYAN}🔒 Checking for running apt/dpkg processes...${NC}"
    local timeout=60
    local waited=0
    local locks_found=0

    while pgrep -x apt >/dev/null || pgrep -x dpkg >/dev/null; do
        locks_found=1
        if (( waited >= timeout )); then
            echo -e "${YELLOW}⚠️  Timeout reached — killing stuck APT/dpkg processes...${NC}"
            sudo pkill -9 apt || true
            sudo pkill -9 dpkg || true
            break
        fi
        echo -ne "${YELLOW}⏳ Waiting for package manager to finish... (${waited}s)\r${NC}"
        sleep 3
        (( waited+=3 ))
    done

    if (( locks_found == 1 )); then
        echo -e "\n${GREEN}✅ Locks cleared or processes terminated.${NC}"
    else
        echo -e "${GREEN}✅ No active package manager detected.${NC}"
    fi

    sudo rm -f /var/lib/dpkg/lock-frontend /var/cache/apt/archives/lock /var/lib/dpkg/lock || true
}

# ───────────────────────────────────────────────
# GPU Detection
# ───────────────────────────────────────────────
GPU=$(lspci | grep -E "VGA|3D" | grep -i nvidia || true)
if [[ -z "$GPU" ]]; then
    echo -e "${RED}❌ No NVIDIA GPU detected. Exiting.${NC}"
    exit 1
else
    echo -e "${GREEN}✅ NVIDIA GPU detected:${NC}\n$GPU"
fi

# ───────────────────────────────────────────────
# Kernel + session info
# ───────────────────────────────────────────────
KERNEL=$(uname -r)
SESSION=${XDG_SESSION_TYPE:-"unknown"}
echo -e "\n🧩 Kernel: ${YELLOW}$KERNEL${NC}"
echo -e "🖥️  Session: ${YELLOW}$SESSION${NC}"
[[ "$KERNEL" == *"liquorix"* ]] && echo -e "${CYAN}💧 Liquorix kernel detected (optimized for gaming).${NC}"

# ───────────────────────────────────────────────
# Detect current NVIDIA driver
# ───────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    CURRENT=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader)
    echo -e "${GREEN}🟢 Current NVIDIA driver: $CURRENT${NC}"
else
    echo -e "${YELLOW}⚠️  No NVIDIA driver currently installed.${NC}"
fi

# ───────────────────────────────────────────────
# Helpers: progress + xorg.conf fixer
# ───────────────────────────────────────────────
progress() { local msg=$1; echo -ne "${CYAN}$msg...${NC}"; sleep 0.4; echo -e "${GREEN} done.${NC}"; }

fix_xorg_conf() {
    local new_driver=$1
    if [[ -f /etc/X11/xorg.conf ]]; then
        if grep -q 'Driver\s*"nvidia"' /etc/X11/xorg.conf; then
            echo -e "${YELLOW}⚠️  NVIDIA driver still active in /etc/X11/xorg.conf${NC}"
            sudo cp /etc/X11/xorg.conf /etc/X11/xorg.conf.backup.$(date +%F_%H-%M-%S)
            sudo sed -i "s/Driver\s*\"nvidia\"/Driver \"${new_driver}\"/g" /etc/X11/xorg.conf
            echo -e "${GREEN}✅ xorg.conf patched → Driver \"${new_driver}\"${NC}"
        fi
    fi
}

# ───────────────────────────────────────────────
# Menu
# ───────────────────────────────────────────────
echo -e "\n───────────────────────────────────────────────"
echo -e " ${CYAN}Choose your action:${NC}"
echo -e "───────────────────────────────────────────────"
echo -e "1️⃣  Install stable Debian NVIDIA driver (550 series)"
echo -e "2️⃣  Install latest official NVIDIA driver (570/580)"
echo -e "3️⃣  Enable open-source nouveau driver"
echo -e "4️⃣  Remove NVIDIA driver and clean system"
echo -e "───────────────────────────────────────────────"
read -rp "Enter choice [1-4]: " CHOICE
echo -e "───────────────────────────────────────────────"

# ───────────────────────────────────────────────
# Main actions
# ───────────────────────────────────────────────
check_locks

case "$CHOICE" in
1)
    echo -e "➡️  Installing stable Debian NVIDIA driver..."
    sudo apt purge -y 'nvidia-*' || true
    sudo apt update
    sudo apt install -y dkms build-essential linux-headers-$(uname -r)
    sudo apt install -y nvidia-driver firmware-misc-nonfree
    progress "Driver installed"
    fix_xorg_conf "nvidia"
    ;;
2)
    echo -e "➡️  Installing latest NVIDIA driver..."
    sudo apt purge -y 'nvidia-*' || true
    sudo apt install -y dkms build-essential linux-headers-$(uname -r)
    mkdir -p ~/nvidia-install && cd ~/nvidia-install || exit

    # Fetch latest version via NVIDIA API (fallback 580.95.05)
    LATEST=$(curl -s https://api.nvidia.com/v1/driver-latest-version/linux | grep -oP '"version":"\K[0-9.]+' || true)
    if [[ -z "$LATEST" ]]; then
        LATEST="580.95.05"
        echo -e "${YELLOW}⚠️  Could not fetch latest version online, using fallback ${LATEST}.${NC}"
    else
        echo -e "${GREEN}✅ Latest NVIDIA driver version detected: ${LATEST}${NC}"
    fi

    echo -e "${CYAN}Downloading NVIDIA-Linux-x86_64-${LATEST}.run...${NC}"
    wget -O NVIDIA-Linux.run "https://us.download.nvidia.com/XFree86/Linux-x86_64/${LATEST}/NVIDIA-Linux-x86_64-${LATEST}.run"
    chmod +x NVIDIA-Linux.run
    sudo ./NVIDIA-Linux.run --dkms --no-cc-version-check
    progress "Latest driver ${LATEST} installed"
    fix_xorg_conf "nvidia"
    ;;
3)
    echo -e "🌀 Enabling open-source nouveau driver..."
    sudo apt purge -y 'nvidia-*'
    sudo apt install -y xserver-xorg-video-nouveau
    sudo bash -c 'echo "blacklist nvidia" > /etc/modprobe.d/blacklist-nvidia.conf'
    sudo update-initramfs -u
    fix_xorg_conf "nouveau"
    progress "Nouveau enabled"
    ;;
4)
    echo -e "🧹 Removing NVIDIA drivers and cleaning system..."
    sudo apt purge -y 'nvidia-*'
    sudo rm -rf /lib/modules/$(uname -r)/kernel/drivers/video/nvidia* /etc/modprobe.d/nvidia* || true
    sudo apt autoremove -y
    fix_xorg_conf "modesetting"
    progress "System cleaned and xorg.conf fixed"
    ;;
*)
    echo -e "${RED}❌ Invalid choice.${NC}"
    exit 1
    ;;
esac

echo -e "\n───────────────────────────────────────────────"
echo -e " ${GREEN}✅ All tasks completed successfully.${NC}"
echo -e " Log file: ${YELLOW}$LOGFILE${NC}"
echo -e " - Reboot system: ${CYAN}sudo reboot${NC}"
echo -e " - Verify driver: ${CYAN}nvidia-smi${NC}"
echo -e "───────────────────────────────────────────────"
