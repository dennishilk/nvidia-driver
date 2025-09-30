# nvidia-driver
NVIDIA Driver + CUDA Toolkit Installer for Debian 11/12/13

This script installs the latest **NVIDIA GPU drivers** and the **CUDA Toolkit** on **Debian 11 (Bullseye)**, **Debian 12 (Bookworm)**, and **Debian 13 (Trixie)** — automatically and reliably.  
It sets up the official NVIDIA repositories, installs drivers & libraries, and configures environment variables system-wide.

---

## ✨ Features
- ✅ Auto-detects Debian **11/12/13** and **amd64/arm64** architecture
- ✅ Uses official NVIDIA CUDA APT repository
- ✅ **Debian 13 fallback:** tries `debian13` repo first; if unavailable, falls back to `debian12` with a warning
- ✅ Installs build tools: `build-essential`, `dkms`, `linux-headers-$(uname -r)`
- ✅ Installs driver + CUDA via the `cuda` meta-package
- ✅ Sets CUDA env vars via `/etc/profile.d/cuda.sh`
- ✅ Optionally blacklists **nouveau** to avoid conflicts
- ✅ Warns if **Secure Boot** is enabled


🧭 Debian 13 (Trixie) Notes

The script first tries NVIDIA’s debian13 repo.
If it’s not available yet, it falls back to debian12. This often works, but compatibility depends on kernel & driver versions.

If the module fails to build or load, check kernel headers, Secure Boot, and nouveau status (see Troubleshooting).

🛡️ Secure Boot

If Secure Boot is enabled, DKMS may fail to load unsigned modules. Options:

Disable Secure Boot in firmware, or

Enroll a Machine Owner Key (MOK) and sign the module.

The script prints a note when Secure Boot appears enabled.


🚫 Nouveau (Open-Source Driver)

The script blacklists nouveau to prevent conflicts:

Config: /etc/modprobe.d/blacklist-nouveau.conf

Rebuilds initramfs automatically

If you prefer to keep nouveau, remove that file and run sudo update-initramfs -u.


🧰 Troubleshooting

Black screen or login loop: Likely driver conflict or Secure Boot. Boot to recovery/TTY, remove conflicting drivers, verify blacklist, check mokutil --sb-state.

DKMS build fails: Ensure headers match the running kernel:

uname -r
apt-cache policy linux-headers-$(uname -r)


nvidia-smi not found: Ensure /usr/local/cuda/bin and driver packages are installed; re-login or source /etc/profile.d/cuda.sh.


🧩 Uninstall

To remove CUDA & drivers:

sudo apt remove --purge 'cuda*' 'nvidia*'
sudo rm -f /etc/apt/sources.list.d/nvidia-cuda.list \
           /usr/share/keyrings/nvidia-cuda-archive-keyring.gpg \
           /etc/profile.d/cuda.sh \
           /etc/modprobe.d/blacklist-nouveau.conf
sudo update-initramfs -u
sudo apt autoremove -y
sudo reboot



## 📦 Installation

1. Clone the repository or download the script:
   git clone https://github.com/dennishilk/nvidia-driver.git
   
   cd nvidia-cuda-installer
  
3. Make the script executable:
   chmod +x install-nvidia-cuda.sh

4. Run with root privileges:
   sudo ./install-nvidia-cuda.sh

5. Reboot to load the NVIDIA kernel module:
   sudo reboot

6. Check After reboot:
   nvidia-smi
   nvcc --version

    <a href="https://www.buymeacoffee.com/dennishilk" target="_blank"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="41" width="174"></a>



No Warranty Disclaimer

The software in this repository is provided "as is", without warranty of any kind.
I make no guarantees regarding the functionality, correctness, or suitability of this code for any purpose.
Use it at your own risk. I am not responsible for any damages, data loss, or issues that may arise from using this software.
