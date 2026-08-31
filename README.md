# NVIDIA Driver + CUDA Toolkit Installer

[![Shell checks](https://github.com/dennishilk/nvidia-driver/actions/workflows/shell-checks.yml/badge.svg)](https://github.com/dennishilk/nvidia-driver/actions/workflows/shell-checks.yml)

Interactive, APT-first installer for NVIDIA drivers and the optional CUDA Toolkit on Debian 12 (Bookworm) and Debian 13 (Trixie).

The recommended paths use Debian's own packages. The script does not add NVIDIA repositories, force an Xorg configuration, kill package-manager processes, or delete APT lock files.

## Supported systems

- Debian 12 or 13
- `amd64` or `arm64`
- An NVIDIA PCI display device
- Root access
- APT sources with `main contrib non-free non-free-firmware`

The advanced NVIDIA `.run` installer is available only on `amd64` and is intentionally not recommended for normal Debian installations.

## Features

- Installs `nvidia-driver` from Debian stable or an already configured backports suite
- Installs the Debian `nvidia-cuda-toolkit` package on request
- Installs both the architecture header metapackage and exact running-kernel headers when available
- Understands classic `.list` files and modern deb822 `.sources` files
- Detects Secure Boot when `mokutil` is available and explains MOK enrollment
- Can switch back to nouveau or remove installed `nvidia-*` packages through APT
- Fetches current `.run` installer metadata from NVIDIA instead of using a stale hardcoded version
- Logs output to `/var/log/nvidia-optimizer.log`

## Installation

```bash
git clone https://github.com/dennishilk/nvidia-driver.git
cd nvidia-driver
chmod +x install-nvidia-cuda.sh
sudo ./install-nvidia-cuda.sh
```

Choose one of the five menu actions:

1. Install the Debian stable driver (recommended)
2. Install the driver from an already enabled Debian backports suite
3. Remove NVIDIA packages and enable nouveau
4. Remove NVIDIA packages and clean unused dependencies
5. Install NVIDIA's `.run` driver (advanced, `amd64` only)

After a driver change, reboot and verify:

```bash
nvidia-smi
nvcc --version  # only when the CUDA Toolkit was installed
```

## APT source requirements

The script accepts both `/etc/apt/sources.list` entries and deb822 files such as `/etc/apt/sources.list.d/debian.sources`.

For example, a classic Debian 13 source line contains:

```text
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
```

Replace `trixie` with `bookworm` on Debian 12. Backports option 2 additionally expects `${VERSION_CODENAME}-backports`, such as `trixie-backports`.

## Secure Boot

With Secure Boot enabled, the NVIDIA DKMS module may not load until its Machine Owner Key is enrolled. If Debian created `/var/lib/dkms/mok.pub`, enroll it with:

```bash
sudo mokutil --import /var/lib/dkms/mok.pub
```

Then reboot and complete enrollment in the firmware's MOK Manager. If `mokutil` is missing, install the Debian package of the same name first.

## Troubleshooting

### `Unable to locate package nvidia-cuda-toolkit`

The Debian package is named `nvidia-cuda-toolkit`, not `cuda`. Confirm that `non-free` is enabled, then refresh APT:

```bash
sudo apt update
apt-cache policy nvidia-cuda-toolkit
```

### DKMS build fails

Check whether headers exist for the running kernel:

```bash
uname -r
apt-cache policy "linux-headers-$(uname -r)"
```

If only the newer architecture header metapackage was available, reboot into the newly installed Debian kernel and run the driver installation again.

### Black screen or login loop

From a recovery shell or TTY, inspect:

```bash
cat /var/log/nvidia-optimizer.log
dkms status
sudo mokutil --sb-state
```

Secure Boot, a failed DKMS build, or an old manually installed `.run` driver are the usual causes.

## Uninstall or return to nouveau

Run the script again and choose option 3 or 4. Cleanup is performed through APT; the script does not manually erase `/var/lib/dkms` or user-owned NVIDIA configuration files.

## License and warranty

MIT License. See [LICENSE](LICENSE).

The software is provided "as is", without warranty of any kind. Use it at your own risk; the author is not responsible for damage, data loss, or other issues caused by its use.

<a href="https://www.buymeacoffee.com/dennishilk"><img src="https://cdn.buymeacoffee.com/buttons/default-orange.png" alt="Buy Me A Coffee" height="41" width="174"></a>
