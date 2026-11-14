#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Debian Package Builder (.deb)
# File: build-deb.sh
# Usage: ./build-deb.sh [--version 0.1.0] [--output-dir .]
# ==============================================================================

set -Eeuo pipefail

PKG_NAME="parentcontrol"
PKG_VERSION="0.1.0"
PKG_ARCH="all"
INSTALLER_SRC="./install-parentcontrol.sh"
OUT_DIR="."

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            cat << 'HELP_EOF'
Usage: ./build-deb.sh [OPTIONS]

Builds a standalone Debian package (parentcontrol_<version>_all.deb) from
install-parentcontrol.sh for Linux Mint 22.3 / Ubuntu 24.04.

Options:
  --version <ver>      Package version string (default: 0.1.0)
  --installer <path>   Path to install-parentcontrol.sh (default: ./install-parentcontrol.sh)
  --output-dir <dir>   Output directory for the .deb artifact (default: .)
  -h, --help           Show this help message and exit
HELP_EOF
            exit 0
            ;;
        --version)    PKG_VERSION="${2:?Missing --version value}"; shift 2 ;;
        --installer)  INSTALLER_SRC="${2:?Missing --installer value}"; shift 2 ;;
        --output-dir) OUT_DIR="${2:?Missing --output-dir value}"; shift 2 ;;
        *)            printf '[ERROR] Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$INSTALLER_SRC" ]]; then
    printf '[ERROR] Installer source not found: %s\n' "$INSTALLER_SRC" >&2
    exit 1
fi

if ! command -v dpkg-deb >/dev/null 2>&1; then
    printf '[ERROR] dpkg-deb is required to build .deb packages (run this on Linux Mint / Ubuntu).\n' >&2
    exit 1
fi

BUILD_ROOT="$(mktemp -d /tmp/parentcontrol-deb-build.XXXXXX)"
trap 'rm -rf "$BUILD_ROOT"' EXIT

PKG_DIR="${BUILD_ROOT}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}"
mkdir -p "${PKG_DIR}/DEBIAN" \
         "${PKG_DIR}/opt/parentcontrol/bin" \
         "${PKG_DIR}/opt/parentcontrol/lib" \
         "${PKG_DIR}/opt/parentcontrol/gui" \
         "${PKG_DIR}/usr/local/bin" \
         "${PKG_DIR}/usr/share/applications" \
         "${PKG_DIR}/usr/share/polkit-1/actions" \
         "${PKG_DIR}/etc/systemd/system"

printf '[INFO] Extracting suite files from %s into staging tree...\n' "$INSTALLER_SRC"

python3 - "$INSTALLER_SRC" "$PKG_DIR" << 'PYEOF'
import os
import re
import sys

installer_path, pkg_dir = sys.argv[1:3]
lines = open(installer_path, "r", encoding="utf-8").read().splitlines(keepends=True)

# Match: cat << 'DELIM' > /target/path
cat_re = re.compile(r"^\s*cat\s+<<\s*['\"]?([A-Za-z0-9_]+)['\"]?\s*>\s*(/[^\s]+)\s*$")

extracted = {}
i = 0
while i < len(lines):
    m = cat_re.match(lines[i].rstrip("\r\n"))
    if m:
        delim, target_path = m.group(1), m.group(2)
        i += 1
        buf = []
        while i < len(lines) and lines[i].strip() != delim:
            buf.append(lines[i])
            i += 1
        if target_path.startswith(("/opt/parentcontrol/", "/usr/share/", "/etc/systemd/system/")):
            extracted[target_path] = "".join(buf)
    i += 1

required = [
    "/opt/parentcontrol/lib/defaults.conf",
    "/opt/parentcontrol/lib/common.sh",
    "/opt/parentcontrol/bin/pc-ctl.sh",
    "/opt/parentcontrol/bin/pc-setup.sh",
    "/opt/parentcontrol/bin/pc-net-acl.sh",
    "/opt/parentcontrol/bin/pc-perms.sh",
    "/opt/parentcontrol/bin/pc-ports.sh",
    "/opt/parentcontrol/bin/pc-devices.sh",
    "/opt/parentcontrol/bin/pc-apps.sh",
    "/opt/parentcontrol/bin/pc-queue.sh",
    "/opt/parentcontrol/bin/pc-maint.sh",
    "/opt/parentcontrol/gui/pc-request-popup.py",
    "/opt/parentcontrol/gui/parentcontrol-gui.py",
    "/usr/share/polkit-1/actions/com.parentcontrol.gui.policy",
    "/usr/share/applications/parentcontrol.desktop",
    "/usr/share/applications/parentcontrol-request.desktop",
    "/etc/systemd/system/parentcontrol-boot.service",
]

missing = [p for p in required if p not in extracted]
if missing:
    print(f"[ERROR] Missing expected embedded files in installer: {missing}", file=sys.stderr)
    sys.exit(1)

for target_path, content in extracted.items():
    out_file = os.path.join(pkg_dir, target_path.lstrip("/"))
    os.makedirs(os.path.dirname(out_file), exist_ok=True)
    with open(out_file, "w", encoding="utf-8") as wf:
        wf.write(content)
    if target_path.endswith((".sh", ".py")):
        os.chmod(out_file, 0o755)
    else:
        os.chmod(out_file, 0o644)

print(f"[OK] Staged {len(extracted)} payload files.")
PYEOF

# Bundle installer script for clean prerm teardown and create pc-ctl symlink
cp "$INSTALLER_SRC" "${PKG_DIR}/opt/parentcontrol/install-parentcontrol.sh"
chmod 0755 "${PKG_DIR}/opt/parentcontrol/install-parentcontrol.sh"
ln -s /opt/parentcontrol/bin/pc-ctl.sh "${PKG_DIR}/usr/local/bin/pc-ctl"

# DEBIAN/control
cat << CONTROL_EOF > "${PKG_DIR}/DEBIAN/control"
Package: ${PKG_NAME}
Version: ${PKG_VERSION}
Section: admin
Priority: optional
Architecture: ${PKG_ARCH}
Maintainer: ParentControl Team <admin@parentcontrol.local>
Depends: bash (>= 5.0), python3 (>= 3.10), python3-gi, gir1.2-gtk-3.0, acl, ufw, policykit-1 | pkexec, curl, systemd
Description: Turnkey Caregiver & Parental Control Suite for Linux Mint
 PolicyKit-isolated parental and caregiver control system for Linux Mint 22.3.
 Enforces web/network blocklists, folder permissions, firewall port locks,
 hardware device toggles, application governance, screen-time limits, and an
 unprivileged user access request popup with an interactive Setup Wizard.
CONTROL_EOF
chmod 0644 "${PKG_DIR}/DEBIAN/control"

# DEBIAN/postinst
cat << 'POSTINST_EOF' > "${PKG_DIR}/DEBIAN/postinst"
#!/usr/bin/env bash
set -e

case "$1" in
    configure)
        mkdir -p /etc/parentcontrol /var/log/parentcontrol /var/lib/parentcontrol/backup /var/spool/parentcontrol/requests
        chown root:root /etc/parentcontrol /var/log/parentcontrol /var/lib/parentcontrol /var/lib/parentcontrol/backup /var/spool/parentcontrol /var/spool/parentcontrol/requests
        chmod 0755 /etc/parentcontrol /var/spool/parentcontrol
        chmod 0750 /var/log/parentcontrol /var/lib/parentcontrol /var/lib/parentcontrol/backup
        chmod 1777 /var/spool/parentcontrol/requests

        # Initialize config.json & pcadmin user
        /opt/parentcontrol/bin/pc-setup.sh --action init --json >/dev/null 2>&1 || true

        # Only enforce pcadmin-only PolicyKit rule once pcadmin password has been configured
        if ! passwd -S pcadmin 2>/dev/null | awk '{print $2}' | grep -qx "P"; then
            rm -f /etc/polkit-1/rules.d/49-parentcontrol.rules
        fi

        if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
            systemctl daemon-reload >/dev/null 2>&1 || true
            systemctl enable parentcontrol-boot.service >/dev/null 2>&1 || true
        fi

        if command -v update-desktop-database >/dev/null 2>&1; then
            update-desktop-database /usr/share/applications >/dev/null 2>&1 || true
        fi

        # Auto-launch First-Time Setup Wizard in active desktop session if unconfigured
        if ! passwd -S pcadmin 2>/dev/null | awk '{print $2}' | grep -qx "P"; then
            DESKTOP_USER="${SUDO_USER:-$(who | awk '($2 ~ /^:/ || $5 ~ /\(:/) {print $1; exit}')}"
            if [[ -n "$DESKTOP_USER" && "$DESKTOP_USER" != "root" ]] && id -u "$DESKTOP_USER" >/dev/null 2>&1; then
                DESKTOP_UID="$(id -u "$DESKTOP_USER")"
                DESKTOP_HOME="$(getent passwd "$DESKTOP_USER" | cut -d: -f6)"
                if [[ -S "/tmp/.X11-unix/X0" || -S "/run/user/${DESKTOP_UID}/wayland-0" ]]; then
                    systemd-run --uid="$DESKTOP_UID" \
                        --setenv=DISPLAY=":0" \
                        --setenv=XAUTHORITY="${DESKTOP_HOME}/.Xauthority" \
                        --setenv=DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${DESKTOP_UID}/bus" \
                        pkexec /opt/parentcontrol/gui/parentcontrol-gui.py >/dev/null 2>&1 || true
                fi
            fi
        fi
        ;;
esac

exit 0
POSTINST_EOF
chmod 0755 "${PKG_DIR}/DEBIAN/postinst"

# DEBIAN/prerm
cat << 'PRERM_EOF' > "${PKG_DIR}/DEBIAN/prerm"
#!/usr/bin/env bash
set -e

case "$1" in
    remove|deconfigure)
        if [[ -f /opt/parentcontrol/install-parentcontrol.sh ]]; then
            cp /opt/parentcontrol/install-parentcontrol.sh /tmp/pc-prerm-uninstall.sh
            chmod 0755 /tmp/pc-prerm-uninstall.sh
            bash /tmp/pc-prerm-uninstall.sh --uninstall || true
            rm -f /tmp/pc-prerm-uninstall.sh
        fi
        ;;
esac

exit 0
PRERM_EOF
chmod 0755 "${PKG_DIR}/DEBIAN/prerm"

# DEBIAN/postrm
cat << 'POSTRM_EOF' > "${PKG_DIR}/DEBIAN/postrm"
#!/usr/bin/env bash
set -e

case "$1" in
    purge)
        rm -rf /etc/parentcontrol /var/lib/parentcontrol /var/log/parentcontrol /var/spool/parentcontrol
        ;;
esac

exit 0
POSTRM_EOF
chmod 0755 "${PKG_DIR}/DEBIAN/postrm"

mkdir -p "$OUT_DIR"
OUT_DEB="${OUT_DIR}/${PKG_NAME}_${PKG_VERSION}_${PKG_ARCH}.deb"
dpkg-deb --root-owner-group --build "$PKG_DIR" "$OUT_DEB"

printf '[SUCCESS] Built Debian package: %s\n' "$OUT_DEB"
