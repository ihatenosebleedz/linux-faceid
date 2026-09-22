#!/bin/sh
set -e

SRC="$(dirname "$0")/pam_faceid.so"
DEST=/usr/lib/security/pam_faceid.so
BAK=/etc/pam.d/doas.bak.$(date +%Y%m%d%H%M%S)

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: doas $0" >&2
    exit 1
fi

install -m 755 -o root -g root "$SRC" "$DEST"
cp /etc/pam.d/doas "$BAK"

cat > /etc/pam.d/doas <<'EOF'
#%PAM-1.0
auth            sufficient      pam_faceid.so
auth            include         system-auth
account         include         system-auth
session         include         system-auth
session         optional        pam_umask.so     usergroups umask=022
EOF

echo "pam_faceid installed. backup: $BAK"