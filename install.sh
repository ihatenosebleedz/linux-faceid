#!/usr/bin/env bash
# ==============================================================================
# Linux Face ID — Universal Multi-Distro Installer
# ==============================================================================
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/linux-faceid"

echo "=== Linux Face ID Installer ==="
echo "Repo directory: $REPO_DIR"

# Privilege escalation helper
ESCALATE=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v doas >/dev/null 2>&1; then
        ESCALATE="doas"
    elif command -v sudo >/dev/null 2>&1; then
        ESCALATE="sudo"
    fi
fi

# Detect Linux Distribution
DISTRO="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO="$ID"
fi

# 1. Dependency checks
echo ""
echo "[1/5] Checking dependencies (detected system: $DISTRO)..."

install_instructions() {
    echo ""
    echo "To install all prerequisites on your distribution:"
    case "$DISTRO" in
        arch|manjaro|endeavouros)
            echo "  sudo pacman -S --needed gcc make pam python python-opencv python-numpy"
            ;;
        debian|ubuntu|pop|mint)
            echo "  sudo apt update && sudo apt install -y build-essential libpam0g-dev python3 python3-opencv python3-numpy"
            ;;
        fedora|rhel|centos|rocky|alma)
            echo "  sudo dnf install -y gcc make pam-devel python3 python3-opencv python3-numpy"
            ;;
        opensuse*|suse)
            echo "  sudo zypper install -y gcc make pam-devel python3 python3-opencv python3-numpy"
            ;;
        gentoo)
            echo "  sudo emerge --ask sys-libs/pam dev-python/numpy media-libs/opencv"
            ;;
        alpine)
            echo "  doas apk add build-base linux-pam-dev python3 py3-numpy py3-opencv"
            ;;
        void)
            echo "  doas xbps-install -S base-devel pam-devel python3 opencv python3-numpy"
            ;;
        *)
            echo "  Please install a C compiler, make, PAM development headers, Python 3, OpenCV, and NumPy."
            ;;
    esac
    echo ""
}

MISSING_CMDS=""
for cmd in python3 cc make; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_CMDS="$MISSING_CMDS $cmd"
    fi
done

if [ -n "$MISSING_CMDS" ]; then
    echo "[-] Missing required build tools:$MISSING_CMDS"
    install_instructions
    exit 1
fi

if ! python3 -c "import cv2, numpy" 2>/dev/null; then
    echo "[-] Missing Python libraries (opencv, numpy)."
    install_instructions
    exit 1
fi
echo "[+] Core build tools and Python libraries (OpenCV + NumPy) found."

# 2. Stage ONNX Models
echo ""
echo "[2/5] Staging face detection & recognition models..."
mkdir -p "$DATA_DIR/models"
chmod 700 "$DATA_DIR"
for model in face_detection_yunet_2023mar.onnx face_recognition_sface_2021dec.onnx; do
    if [ -f "$REPO_DIR/models/$model" ]; then
        cp -u "$REPO_DIR/models/$model" "$DATA_DIR/models/"
        cp -u "$REPO_DIR/models/$model" "$DATA_DIR/"
        chmod 600 "$DATA_DIR/models/$model" "$DATA_DIR/$model"
        echo "    staged $model -> $DATA_DIR"
    else
        echo "[-] Warning: $model not found in $REPO_DIR/models/"
    fi
done

# 3. Build & Install PAM Module
echo ""
echo "[3/5] Building PAM module (pam_faceid.so)..."
make -C "$REPO_DIR/pam" clean
make -C "$REPO_DIR/pam"

echo "    Installing pam_faceid.so to /usr/lib/security/..."
if [ -z "$ESCALATE" ] && [ "$(id -u)" -ne 0 ]; then
    echo "[-] Root privileges required to install PAM module to /usr/lib/security/."
    exit 1
fi

$ESCALATE install -d /usr/lib/security
$ESCALATE install -m 755 "$REPO_DIR/pam/pam_faceid.so" /usr/lib/security/pam_faceid.so
echo "[+] pam_faceid.so installed to /usr/lib/security/pam_faceid.so."

# 4. Install Hardware Udev Rule
echo ""
echo "[4/5] Checking hardware udev rules..."
if [ -f "$REPO_DIR/udev/99-logitech-c922.rules" ]; then
    echo "    Installing udev rule for Logitech C922 (prevents USB autosuspend firmware stalls)..."
    $ESCALATE install -d /etc/udev/rules.d
    $ESCALATE cp "$REPO_DIR/udev/99-logitech-c922.rules" /etc/udev/rules.d/
    if command -v udevadm >/dev/null 2>&1; then
        $ESCALATE udevadm control --reload-rules 2>/dev/null || true
        $ESCALATE udevadm trigger --subsystem-match=usb 2>/dev/null || true
    fi
    echo "[+] udev rule installed."
fi

# 5. Ambxst Mod Integration
echo ""
echo "[5/5] Checking Ambxst desktop environment..."
if command -v ambxst >/dev/null 2>&1; then
    echo "    Found Ambxst. Installing Face ID mod..."
    ambxst mods install "$REPO_DIR" || echo "    (Already installed or updated)"
    ambxst mods enable community.linux-faceid || true
    echo ""
    echo "[+] Ambxst mod installed and enabled!"
    echo "    Run 'ambxst reload' to reload your active generation."
else
    echo "    Ambxst not detected. PAM module and standalone daemon are ready to use."
fi

echo ""
echo "=== Installation Complete! ==="
echo ""
echo "1. Enroll your face:"
echo "   - In Ambxst: Open settings panel -> Face ID -> click 'Enroll'."
echo "   - Or in terminal: run 'python3 $REPO_DIR/payload/scripts/faceid-daemon.py' and send 'enroll'."
echo ""
echo "2. Enable Face ID for elevated commands:"
echo "   - For doas: Add 'auth sufficient pam_faceid.so' to the top of /etc/pam.d/doas"
echo "   - For sudo: Add 'auth sufficient pam_faceid.so' to the top of /etc/pam.d/sudo"
echo ""
echo "Enjoy instant Face ID! :3"
