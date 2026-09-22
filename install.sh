#!/usr/bin/env bash
# ==============================================================================
# Linux Face ID — All-in-One Installer
# ==============================================================================
set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/linux-faceid"

echo "=== Linux Face ID Installer ==="
echo "Repo directory: $REPO_DIR"

# 1. Dependency checks
echo ""
echo "[1/5] Checking dependencies..."
MISSING=""
for cmd in python3 cc; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING="$MISSING $cmd"
    fi
done

if [ -n "$MISSING" ]; then
    echo "[-] Missing required tools:$MISSING"
    echo "    Please install them with your package manager."
    exit 1
fi

if ! python3 -c "import cv2, numpy" 2>/dev/null; then
    echo "[-] Missing Python libraries (opencv, numpy)."
    echo "    Install via package manager or pip:"
    echo "    e.g. xbps-install -S opencv python3-numpy  OR  pip install opencv-python numpy"
    exit 1
fi
echo "[+] Python dependencies satisfied (OpenCV + NumPy)."

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
make -C "$REPO_DIR/pam"

echo "    Installing pam_faceid.so to /usr/lib/security/..."
ESCALATE=""
if [ "$(id -u)" -ne 0 ]; then
    if command -v doas >/dev/null 2>&1; then
        ESCALATE="doas"
    elif command -v sudo >/dev/null 2>&1; then
        ESCALATE="sudo"
    else
        echo "[-] Neither doas nor sudo found. Please run make install as root."
        exit 1
    fi
fi

$ESCALATE install -m 755 "$REPO_DIR/pam/pam_faceid.so" /usr/lib/security/pam_faceid.so
echo "[+] pam_faceid.so installed."

# 4. Install Logitech C922 udev rule (optional autosuspend fix)
echo ""
echo "[4/5] Checking hardware udev rules..."
if [ -f "$REPO_DIR/udev/99-logitech-c922.rules" ]; then
    echo "    Installing udev rule for Logitech C922 (disables USB autosuspend stalls)..."
    $ESCALATE cp "$REPO_DIR/udev/99-logitech-c922.rules" /etc/udev/rules.d/
    $ESCALATE udevadm control --reload-rules 2>/dev/null || true
    $ESCALATE udevadm trigger --subsystem-match=usb 2>/dev/null || true
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
    echo "    Run 'ambxst reload' to restart your shell."
else
    echo "    Ambxst not detected. The PAM module and daemon backend are ready for standalone use."
fi

echo ""
echo "=== Installation Complete! ==="
echo "To enroll your face:"
echo "  1. Start the daemon (if not running via Ambxst):"
echo "     python3 $REPO_DIR/payload/scripts/faceid-daemon.py"
echo "  2. Or open the Ambxst settings panel -> Face ID and click Enroll."
echo ""
echo "To enable face authentication for doas:"
echo "  Add the following line to the TOP of /etc/pam.d/doas:"
echo "    auth sufficient pam_faceid.so"
echo ""
echo "Enjoy instant Face ID! :3"
