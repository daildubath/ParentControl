#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Automated Bootstrap & Core Library Installer (Sub-Chunk 1.1)
# File: install-parentcontrol.sh
#
# Description:
#   Automatically provisions the ParentControl directory structure, deploys
#   lib/defaults.conf and lib/common.sh, sets strict root permissions, and
#   verifies the core environment on any Linux Mint 22.3 machine.
# ==============================================================================

set -Eeuo pipefail

readonly INSTALLER_VERSION="0.1.0"
VERBOSE=0
FORCE_OS=0
SKIP_TEST=0

# ------------------------------------------------------------------------------
# Help & CLI Tag Parsing
# ------------------------------------------------------------------------------
show_help() {
    cat << 'HELP_EOF'
ParentControl (v0.1.0) — Turnkey Caregiver & Parental Control Suite for Linux Mint 22.3

DESCRIPTION:
  Deploys and manages a PolicyKit-isolated administrative control suite for Linux
  Mint 22.3 (Cinnamon). Separates a dedicated administrator account ('pcadmin')
  from the monitored desktop user ('mint'), enforces system-wide network, folder,
  port, hardware, application, and screen-time policies, and provides an unprivileged
  "Caregiver Help & Request Access" popup for the monitored user.

USAGE:
  sudo ./install-parentcontrol.sh [OPTIONS]

OPTIONS:
  -h, --help            Display this complete help message and exit (does not require root).
  -v, --verbose         Enable detailed step-by-step diagnostic logging during execution.
      --dry-run         Validate pre-flight system requirements without modifying any files.
      --skip-selftest   Deploy all scripts and configurations without running the post-install
                        automated verification self-test suite.
      --uninstall       Cleanly revert ParentControl rules (/etc/hosts blocks, UFW port rules,
                        device locks, folder ACLs, sudo/adm group membership, systemd units,
                        PolicyKit rules, and /opt/parentcontrol).
      --purge           When combined with --uninstall, also remove /etc/parentcontrol,
                        /var/lib/parentcontrol, and /var/log/parentcontrol.

DEPLOYED ARCHITECTURE:
  /opt/parentcontrol/bin/pc-ctl.sh          Unified CLI dispatcher & status/log manager
  /opt/parentcontrol/bin/pc-setup.sh        Admin separation, PolicyKit, wizard & contact info
  /opt/parentcontrol/bin/pc-net-acl.sh      Whitelist, greylist, blacklist & blocklist feeds
  /opt/parentcontrol/bin/pc-perms.sh        Folder access modes (locked/read-only/drop-box/full)
  /opt/parentcontrol/bin/pc-ports.sh        UFW firewall port & risky-service blocking
  /opt/parentcontrol/bin/pc-devices.sh      Hardware locks (USB storage, webcam, mic, bluetooth)
  /opt/parentcontrol/bin/pc-apps.sh         Desktop app scanner, Allow/Block ACLs & installer lock
  /opt/parentcontrol/bin/pc-queue.sh        Unprivileged request dropbox & admin approval queue
  /opt/parentcontrol/bin/pc-maint.sh        Screen-time limits, maintenance & Dementia/Senior preset
  /opt/parentcontrol/gui/pc-request-popup.py Unprivileged user Request Access & caregiver dialog
  /usr/local/bin/pc-ctl                     Global CLI symlink to pc-ctl.sh
  /etc/parentcontrol/config.json            Master JSON configuration (root:root 0640)

EXAMPLES:
  sudo ./install-parentcontrol.sh --verbose
  sudo pc-ctl --help
  sudo pc-ctl perms --help
  sudo pc-ctl setup --action wizard
HELP_EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            --force-os)
                FORCE_OS=1
                shift
                ;;
            --skip-test)
                SKIP_TEST=1
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                printf '[ERROR] Unknown option: %s\n\n' "$1" >&2
                show_help >&2
                exit 2
                ;;
        esac
    done
}

log_step() {
    local msg="$1"
    if [[ "$VERBOSE" -eq 1 ]]; then
        printf '[INFO] %s\n' "$msg"
    fi
}

on_install_error() {
    local exit_code="$1"
    local line_no="$2"
    local failed_cmd="$3"
    printf '[ERROR] Bootstrap failed at line %s (exit code %s): %s\n' \
        "$line_no" "$exit_code" "$failed_cmd" >&2
    exit "$exit_code"
}

trap 'on_install_error $? $LINENO "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
# Pre-flight Environment Checks
# ------------------------------------------------------------------------------
preflight_checks() {
    if [[ "${EUID}" -ne 0 ]]; then
        printf '[ERROR] This installer must be run as root (use sudo).\n' >&2
        exit 3
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        printf '[ERROR] python3 is required but not installed.\n' >&2
        exit 1
    fi

    if [[ "$FORCE_OS" -eq 0 ]]; then
        if [[ ! -r /etc/os-release ]]; then
            printf '[ERROR] Unable to read /etc/os-release.\n' >&2
            exit 4
        fi
        local os_id="" os_version=""
        # shellcheck disable=SC1091
        os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
        # shellcheck disable=SC1091
        os_version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"

        if [[ "$os_id" != "linuxmint" || "$os_version" != "22.3" ]]; then
            printf '[ERROR] Detected %s %s. Target OS is Linux Mint 22.3 (use --force-os to override).\n' \
                "$os_id" "$os_version" >&2
            exit 4
        fi
    fi

    log_step "Pre-flight checks passed."
}

# ------------------------------------------------------------------------------
# Directory Provisioning
# ------------------------------------------------------------------------------
create_directories() {
    log_step "Creating ParentControl directory structure..."

    mkdir -p /opt/parentcontrol /opt/parentcontrol/bin /opt/parentcontrol/lib /opt/parentcontrol/gui
    chown -R root:root /opt/parentcontrol
    chmod 0755 /opt/parentcontrol /opt/parentcontrol/bin /opt/parentcontrol/lib /opt/parentcontrol/gui

    mkdir -p /etc/parentcontrol
    chown root:root /etc/parentcontrol
    chmod 0755 /etc/parentcontrol

    mkdir -p /var/log/parentcontrol
    chown root:root /var/log/parentcontrol
    chmod 0750 /var/log/parentcontrol

    mkdir -p /var/lib/parentcontrol /var/lib/parentcontrol/backup
    chown -R root:root /var/lib/parentcontrol
    chmod 0750 /var/lib/parentcontrol /var/lib/parentcontrol/backup

    mkdir -p /var/spool/parentcontrol
    chown root:root /var/spool/parentcontrol
    chmod 0755 /var/spool/parentcontrol

    mkdir -p /var/spool/parentcontrol/requests
    chown root:root /var/spool/parentcontrol/requests
    chmod 1777 /var/spool/parentcontrol/requests

    log_step "Directories created and permissions applied."
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/lib/defaults.conf
# ------------------------------------------------------------------------------
deploy_defaults_conf() {
    log_step "Writing /opt/parentcontrol/lib/defaults.conf..."

    cat << 'DEFAULTS_CONF_EOF' > /opt/parentcontrol/lib/defaults.conf
# ==============================================================================
# ParentControl - Default Constants & System Configuration
# File: /opt/parentcontrol/lib/defaults.conf
# ==============================================================================

# Core filesystem paths
readonly PC_VERSION="0.1.0"
readonly PC_BASE_DIR="/opt/parentcontrol"
readonly PC_BIN_DIR="/opt/parentcontrol/bin"
readonly PC_LIB_DIR="/opt/parentcontrol/lib"
readonly PC_ETC_DIR="/etc/parentcontrol"
readonly PC_CONFIG_FILE="/etc/parentcontrol/config.json"
readonly PC_VAR_DIR="/var/lib/parentcontrol"
readonly PC_BACKUP_DIR="/var/lib/parentcontrol/backup"
readonly PC_QUEUE_DIR="/var/lib/parentcontrol/queue"
readonly PC_LOG_DIR="/var/log/parentcontrol"
readonly PC_LOG_FILE="/var/log/parentcontrol/parentcontrol.log"

# Privilege & PolicyKit settings
readonly PC_ADMIN_USER="pcadmin"
readonly PC_ACCOUNTS_SERVICE_DIR="/var/lib/AccountsService/users"
PC_POLKIT_RULE="${PC_POLKIT_RULE:-/etc/polkit-1/rules.d/49-parentcontrol.rules}"

# Managed /etc/hosts markers for ACL enforcement
PC_HOSTS_FILE="${PC_HOSTS_FILE:-/etc/hosts}"
readonly PC_HOSTS_BEGIN_MARKER="# BEGIN PARENTCONTROL MANAGED BLOCK - DO NOT EDIT"
readonly PC_HOSTS_END_MARKER="# END PARENTCONTROL MANAGED BLOCK"

# Standard Linux Mint user directories allowed by default
readonly PC_STANDARD_HOME_DIRS=(
    "Desktop"
    "Documents"
    "Downloads"
    "Music"
    "Pictures"
    "Public"
    "Templates"
    "Videos"
)

# Common non-essential Linux Mint 22.3 packages offered for removal in setup
readonly PC_DEFAULT_BLOAT_APPS=(
    "transmission-gtk"
    "warpinator"
    "hypnotix"
    "hexchat"
    "thunderbird"
    "thingy"
    "celluloid"
    "rhythmbox"
)

# Default web blocklist feed (Pi-hole / hosts compatible)
readonly PC_DEFAULT_BLOCKLIST_FEEDS=(
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
)
DEFAULTS_CONF_EOF

    chown root:root /opt/parentcontrol/lib/defaults.conf
    chmod 0644 /opt/parentcontrol/lib/defaults.conf
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/lib/common.sh
# ------------------------------------------------------------------------------
deploy_common_sh() {
    log_step "Writing /opt/parentcontrol/lib/common.sh..."

    cat << 'COMMON_SH_EOF' > /opt/parentcontrol/lib/common.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Shared Core Library
# File: /opt/parentcontrol/lib/common.sh
#
# Provides:
#   - Strict error handling & automatic transactional file rollback
#   - Structured single-line audit logging readable by the Python GUI
#   - Standardized CLI flag parsing (--verbose, --json, --help)
#   - Safe JSON state read/write helpers via Python 3
#   - OS & privilege validation helpers
#
# GUI HANDOFF:
#   All ParentControl scripts emit JSON to stdout when --json is passed:
#     Success: {"status":"ok","module":"<name>","action":"<verb>","message":"<text>","data":{...}}
#     Failure: {"status":"error","module":"<name>","action":"<verb>","message":"<text>","code":<int>}
#   Standard Exit Codes:
#     0 = Success
#     1 = Runtime / execution failure (rollback triggered if applicable)
#     2 = Invalid CLI flags or missing required parameters
#     3 = Root / PolicyKit privilege required
#     4 = Unsupported OS environment
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/defaults.conf
source "/opt/parentcontrol/lib/defaults.conf"

# Runtime state flags (modifiable via CLI tags)
PC_VERBOSE=0
PC_JSON_OUTPUT=0
PC_FORCE_OS=0
PC_REMAINING_ARGS=()

# Module metadata defaults (overridden by each calling script)
PC_MODULE_NAME="${PC_MODULE_NAME:-core}"
PC_CURRENT_ACTION="${PC_CURRENT_ACTION:-init}"
PC_SCRIPT_DESC="${PC_SCRIPT_DESC:-ParentControl system management module.}"
PC_SCRIPT_USAGE="${PC_SCRIPT_USAGE:-$(basename "$0") [OPTIONS]}"
PC_SCRIPT_FLAGS="${PC_SCRIPT_FLAGS:-}"

# Transactional rollback state
PC_TX_ACTIVE=0
PC_TX_DIR=""
PC_TX_MANIFEST=()

# ------------------------------------------------------------------------------
# Logging Subsystem
# ------------------------------------------------------------------------------
pc_log() {
    local level="$1"
    local message="$2"
    local timestamp clean_msg

    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    clean_msg="$(printf '%s' "$message" | tr '\n' ' ' | sed 's/|/\//g')"

    if [[ "${EUID}" -eq 0 ]]; then
        if [[ ! -d "$PC_LOG_DIR" ]]; then
            mkdir -p "$PC_LOG_DIR"
            chmod 0750 "$PC_LOG_DIR"
        fi
        if [[ ! -f "$PC_LOG_FILE" ]]; then
            touch "$PC_LOG_FILE"
            chmod 0640 "$PC_LOG_FILE"
            chown root:root "$PC_LOG_FILE"
        fi
        printf '%s | %-5s | %-12s | %s\n' \
            "$timestamp" "$level" "$PC_MODULE_NAME" "$clean_msg" >> "$PC_LOG_FILE"
    fi

    if [[ "$PC_VERBOSE" -eq 1 || "$level" == "ERROR" ]]; then
        printf '[%s] [%s] [%s] %s\n' \
            "$timestamp" "$level" "$PC_MODULE_NAME" "$clean_msg" >&2
    fi
}

# ------------------------------------------------------------------------------
# Standardized Output & GUI Handoff Formatting
# ------------------------------------------------------------------------------
pc_emit_result() {
    local message="$1"
    local data_json="${2:-"{}"}"

    pc_log "INFO" "$message"

    if [[ "$PC_JSON_OUTPUT" -eq 1 ]]; then
        python3 -c '
import json, sys
payload = {
    "status": "ok",
    "module": sys.argv[1],
    "action": sys.argv[2],
    "message": sys.argv[3],
    "data": json.loads(sys.argv[4])
}
print(json.dumps(payload))
' "$PC_MODULE_NAME" "$PC_CURRENT_ACTION" "$message" "$data_json"
    else
        printf '[OK] %s\n' "$message"
    fi
}

pc_emit_error() {
    local message="$1"
    local exit_code="${2:-1}"

    pc_log "ERROR" "$message"

    if [[ "$PC_JSON_OUTPUT" -eq 1 ]]; then
        python3 -c '
import json, sys
payload = {
    "status": "error",
    "module": sys.argv[1],
    "action": sys.argv[2],
    "message": sys.argv[3],
    "code": int(sys.argv[4])
}
print(json.dumps(payload))
' "$PC_MODULE_NAME" "$PC_CURRENT_ACTION" "$message" "$exit_code"
    else
        printf '[ERROR] %s\n' "$message" >&2
    fi
}

# ------------------------------------------------------------------------------
# Transactional Backup & Automatic Rollback Engine
# ------------------------------------------------------------------------------
pc_init_transaction() {
    local tx_id
    tx_id="$(date -u +"%Y%m%dT%H%M%SZ")_$$"
    PC_TX_DIR="${PC_BACKUP_DIR}/${tx_id}"
    mkdir -p "$PC_TX_DIR"
    chmod 0700 "$PC_TX_DIR"
    PC_TX_MANIFEST=()
    PC_TX_ACTIVE=1
    pc_log "DEBUG" "Initialized transaction backup directory: $PC_TX_DIR"
}

pc_backup_file() {
    local target_file="$1"

    if [[ "$PC_TX_ACTIVE" -ne 1 ]]; then
        pc_init_transaction
    fi

    if [[ -e "$target_file" ]]; then
        local safe_name backup_path
        safe_name="$(printf '%s' "$target_file" | tr '/' '_')"
        backup_path="${PC_TX_DIR}/${safe_name}.bak"
        cp -a "$target_file" "$backup_path"
        PC_TX_MANIFEST+=("MODIFIED|${target_file}|${backup_path}")
        pc_log "DEBUG" "Backed up existing file: $target_file -> $backup_path"
    else
        PC_TX_MANIFEST+=("CREATED|${target_file}|")
        pc_log "DEBUG" "Registered new file for rollback tracking: $target_file"
    fi
}

pc_commit_transaction() {
    if [[ "$PC_TX_ACTIVE" -eq 1 && -n "$PC_TX_DIR" && -d "$PC_TX_DIR" ]]; then
        rm -rf "$PC_TX_DIR"
        pc_log "DEBUG" "Committed transaction and cleaned up backup: $PC_TX_DIR"
    fi
    PC_TX_ACTIVE=0
    PC_TX_MANIFEST=()
    PC_TX_DIR=""
}

pc_rollback() {
    trap - ERR

    if [[ "$PC_TX_ACTIVE" -ne 1 || "${#PC_TX_MANIFEST[@]}" -eq 0 ]]; then
        return 0
    fi

    pc_log "WARN" "Rolling back ${#PC_TX_MANIFEST[@]} file change(s)..."

    local idx entry state orig_path backup_path
    for (( idx=${#PC_TX_MANIFEST[@]}-1; idx>=0; idx-- )); do
        entry="${PC_TX_MANIFEST[$idx]}"
        IFS='|' read -r state orig_path backup_path <<< "$entry"

        if [[ "$state" == "MODIFIED" && -e "$backup_path" ]]; then
            cp -a "$backup_path" "$orig_path"
            pc_log "INFO" "Restored original file: $orig_path"
        elif [[ "$state" == "CREATED" && -e "$orig_path" ]]; then
            rm -rf "$orig_path"
            pc_log "INFO" "Removed incomplete newly created file: $orig_path"
        fi
    done

    [[ -n "$PC_TX_DIR" && -d "$PC_TX_DIR" ]] && rm -rf "$PC_TX_DIR"
    PC_TX_ACTIVE=0
    PC_TX_MANIFEST=()
}

pc_on_error() {
    local exit_code="$1"
    local line_no="$2"
    local failed_cmd="$3"

    pc_rollback
    pc_emit_error "Command '${failed_cmd}' failed at line ${line_no} (exit code ${exit_code}). Changes rolled back." "$exit_code"
    exit "$exit_code"
}

trap 'pc_on_error $? $LINENO "$BASH_COMMAND"' ERR

# ------------------------------------------------------------------------------
# CLI Flag & Help Handling
# ------------------------------------------------------------------------------
pc_print_help() {
    cat <<EOF
ParentControl v${PC_VERSION} - Module: ${PC_MODULE_NAME}

Description:
  ${PC_SCRIPT_DESC}

Usage:
  ${PC_SCRIPT_USAGE}

Standard Flags:
  -v, --verbose       Enable detailed diagnostic output to stderr
      --json          Emit structured JSON output for GUI integration
      --force-os      Bypass strict Linux Mint 22.3 version check
  -h, --help          Display this help message and exit
${PC_SCRIPT_FLAGS:+
Module Flags:
${PC_SCRIPT_FLAGS}}
EOF
}

pc_parse_common_flags() {
    PC_REMAINING_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                PC_VERBOSE=1
                shift
                ;;
            --json)
                PC_JSON_OUTPUT=1
                shift
                ;;
            --force-os)
                PC_FORCE_OS=1
                shift
                ;;
            -h|--help)
                pc_print_help
                exit 0
                ;;
            *)
                PC_REMAINING_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Environment & Privilege Guards
# ------------------------------------------------------------------------------
pc_require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        pc_emit_error "Root privileges are required (run via pkexec or sudo)." 3
        exit 3
    fi
}

pc_verify_mint() {
    if [[ "$PC_FORCE_OS" -eq 1 ]]; then
        pc_log "WARN" "Bypassing OS verification due to --force-os flag."
        return 0
    fi

    if [[ ! -r /etc/os-release ]]; then
        pc_emit_error "Cannot read /etc/os-release to verify operating system." 4
        exit 4
    fi

    local os_id="" os_version=""
    # shellcheck disable=SC1091
    os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    # shellcheck disable=SC1091
    os_version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"

    if [[ "$os_id" != "linuxmint" || "$os_version" != "22.3" ]]; then
        pc_emit_error "Unsupported OS (${os_id} ${os_version}). ParentControl targets Linux Mint 22.3." 4
        exit 4
    fi
}

# ------------------------------------------------------------------------------
# Safe JSON Configuration Helpers (Python 3 backed)
# ------------------------------------------------------------------------------
pc_ensure_config_exists() {
    if [[ ! -f "$PC_CONFIG_FILE" ]]; then
        mkdir -p "$PC_ETC_DIR"
        chmod 0750 "$PC_ETC_DIR"
        cat <<EOF > "$PC_CONFIG_FILE"
{
  "version": "${PC_VERSION}",
  "restricted_user": "",
  "admin_user": "${PC_ADMIN_USER}",
  "browser": "firefox",
  "acl": {
    "feeds": [
      "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    ],
    "blacklist": [],
    "whitelist": []
  },
  "permissions": {
    "lock_dotfiles": false,
    "restrict_extra_home_dirs": false,
    "noexec_user_dirs": false
  },
  "ports": {
    "blocked": []
  },
  "devices": {
    "usb_storage_blocked": false,
    "webcam_blocked": false,
    "mic_blocked": false,
    "bluetooth_blocked": false
  },
  "maintenance": {
    "auto_updates": true,
    "auto_snapshots": true,
    "trash_retention_days": 7,
    "senior_accessibility": false
  }
}
EOF
        chown root:root "$PC_CONFIG_FILE"
        chmod 0640 "$PC_CONFIG_FILE"
        pc_log "INFO" "Initialized default master configuration at $PC_CONFIG_FILE"
    fi
}

pc_json_get() {
    local dot_path="$1"
    pc_ensure_config_exists

    python3 -c '
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

cur = data
for key in sys.argv[2].split("."):
    if isinstance(cur, dict) and key in cur:
        cur = cur[key]
    else:
        sys.exit(1)

if isinstance(cur, (dict, list)):
    print(json.dumps(cur))
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
' "$PC_CONFIG_FILE" "$dot_path"
}

pc_json_set() {
    local dot_path="$1"
    local raw_json_value="$2"
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_file
    tmp_file="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, dot_path, raw_val, out_path = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

val = json.loads(raw_val)
keys = dot_path.split(".")
cur = data
for k in keys[:-1]:
    if k not in cur or not isinstance(cur[k], dict):
        cur[k] = {}
    cur = cur[k]
cur[keys[-1]] = val

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$PC_CONFIG_FILE" "$dot_path" "$raw_json_value" "$tmp_file"

    chown root:root "$tmp_file"
    chmod 0640 "$tmp_file"
    mv "$tmp_file" "$PC_CONFIG_FILE"
    pc_log "DEBUG" "Updated config key '${dot_path}'"
}
COMMON_SH_EOF

    chown root:root /opt/parentcontrol/lib/common.sh
    chmod 0644 /opt/parentcontrol/lib/common.sh
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-ctl.sh (Sub-Chunk 1.2)
# ------------------------------------------------------------------------------
deploy_pc_ctl_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-ctl.sh..."

    cat << 'PC_CTL_SH_EOF' > /opt/parentcontrol/bin/pc-ctl.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Master CLI Dispatcher & GUI Entrypoint
# File: /opt/parentcontrol/bin/pc-ctl.sh
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="ctl"
PC_CURRENT_ACTION="status"
PC_SCRIPT_DESC="Unified CLI controller for ParentControl modules, system health checks, configuration keys, and audit logs."
PC_SCRIPT_USAGE="pc-ctl <module> --action <verb> [MODULE_OPTIONS] [--json] [--verbose] [--help]"
PC_SCRIPT_FLAGS="  MODULES:
      status                  Check overall system status, admin setup, and recent logs
      logs                    Read or clear /var/log/parentcontrol/parentcontrol.log
      setup                   Manage pcadmin separation, PolicyKit, caregiver contact, and setup wizard
      acl                     Manage web whitelist/greylist/blacklist and StevenBlack/Phishing Army feeds
      perms                   Manage directory permissions (locked, read-only, drop-box, full) & presets
      ports                   Manage UFW firewall blocked ports and risky port presets
      devices                 Manage hardware device locks (usb_storage, webcam, microphone, bluetooth)
      apps                    Scan installed apps, set Allow/Block rules, and lock software installers
      queue                   Submit, list, approve, deny, or remove user access requests
      maint                   Manage daily screen-time limits, maintenance, and Senior/Dementia preset

  GLOBAL FLAGS:
      -h, --help              Show this help message (use 'pc-ctl <module> --help' for module flags)
      -v, --verbose           Print detailed diagnostic messages to stderr
          --json              Emit machine-readable JSON output for GUI and automation integration

  BUILT-IN CTL ACTIONS (pc-ctl status|logs ...):
      --action check          Retrieve full system health and configuration summary (module: status)
      --action get --key <k>  Read a dot-notation key from /etc/parentcontrol/config.json
      --action set --key <k> --value <v>
                              Update a configuration key in /etc/parentcontrol/config.json
      --action read           Read recent audit log entries (supports --lines <N>, default 50)
      --action clear          Truncate the audit log file (module: logs)"

handle_status() {
    pc_parse_common_flags "$@"
    pc_ensure_config_exists

    local status_json
    status_json="$(python3 -c '
import json, os, subprocess, sys

cfg_path, bin_dir, log_file, admin_user = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

r_user = cfg.get("restricted_user", "")
admin_ready = False
admin_has_pw = False
try:
    res = subprocess.run(["id", "-u", admin_user], capture_output=True, text=True)
    admin_ready = (res.returncode == 0)
    pw_res = subprocess.run(["passwd", "-S", admin_user], capture_output=True, text=True)
    if pw_res.returncode == 0 and len(pw_res.stdout.split()) >= 2:
        admin_has_pw = (pw_res.stdout.split()[1] == "P")
except Exception:
    pass

user_has_sudo = False
if r_user:
    try:
        g_res = subprocess.run(["id", "-nG", r_user], capture_output=True, text=True)
        if g_res.returncode == 0:
            user_has_sudo = ("sudo" in g_res.stdout.split())
    except Exception:
        pass

polkit_ready = os.path.isfile("/etc/polkit-1/rules.d/49-parentcontrol.rules")
modules = sorted([f for f in os.listdir(bin_dir) if f.startswith("pc-") and f.endswith(".sh")]) if os.path.isdir(bin_dir) else []
log_size = os.path.getsize(log_file) if os.path.isfile(log_file) else 0

recent_logs = []
if os.path.isfile(log_file):
    try:
        with open(log_file, "r", encoding="utf-8", errors="replace") as lf:
            lines = [ln.strip() for ln in lf.readlines() if ln.strip()]
            recent_logs = lines[-15:]
    except Exception:
        pass

auto = cfg.get("automation", {})
print(json.dumps({
    "version": cfg.get("version", "0.2.0"),
    "restricted_user": r_user,
    "restricted_user_has_sudo": user_has_sudo,
    "admin_user": admin_user,
    "admin_account_ready": admin_ready,
    "admin_password_configured": admin_has_pw,
    "polkit_rule_ready": polkit_ready,
    "browser": cfg.get("browser", "firefox"),
    "senior_preset": bool(auto.get("senior_preset", False)),
    "admin_contact": cfg.get("admin_contact", {}),
    "installed_modules": modules,
    "log_file": log_file,
    "log_size_bytes": log_size,
    "recent_logs": recent_logs
}))
' "$PC_CONFIG_FILE" "$PC_BIN_DIR" "$PC_LOG_FILE" "$PC_ADMIN_USER")"

    PC_CURRENT_ACTION="check"
    pc_emit_result "ParentControl status retrieved" "$status_json"
}

handle_config() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    local action="" key="" value=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action) action="${2:-}"; shift 2 ;;
            --key)    key="${2:-}"; shift 2 ;;
            --value)  value="${2:-}"; shift 2 ;;
            *) pc_emit_error "Unknown flag for config: $1" 2; exit 2 ;;
        esac
    done

    PC_CURRENT_ACTION="${action:-get}"
    pc_require_root

    case "$action" in
        get)
            [[ -z "$key" ]] && { pc_emit_error "Missing --key for config get." 2; exit 2; }
            local val
            val="$(pc_json_get "$key")" || { pc_emit_error "Key '${key}' not found in config.json." 2; exit 2; }
            local escaped
            escaped="$(python3 -c 'import json, sys; print(json.dumps({"key": sys.argv[1], "value": sys.argv[2]}))' "$key" "$val")"
            pc_emit_result "Retrieved configuration key '${key}'" "$escaped"
            ;;
        set)
            [[ -z "$key" ]] && { pc_emit_error "Missing --key for config set." 2; exit 2; }
            pc_init_transaction
            pc_json_set "$key" "$value"
            pc_commit_transaction
            local escaped
            escaped="$(python3 -c 'import json, sys; print(json.dumps({"key": sys.argv[1], "value": sys.argv[2]}))' "$key" "$value")"
            pc_emit_result "Updated configuration key '${key}'" "$escaped"
            ;;
        dump)
            pc_ensure_config_exists
            local dump_json
            dump_json="$(cat "$PC_CONFIG_FILE")"
            pc_emit_result "Dumped full configuration" "$dump_json"
            ;;
        *)
            pc_emit_error "Unsupported config action '${action}' (expected: get, set, dump)." 2
            exit 2
            ;;
    esac
}

handle_logs() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    local action="read" lines=50
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action) action="${2:-}"; shift 2 ;;
            --lines)  lines="${2:-50}"; shift 2 ;;
            *) pc_emit_error "Unknown flag for logs: $1" 2; exit 2 ;;
        esac
    done

    PC_CURRENT_ACTION="$action"
    pc_require_root

    case "$action" in
        read)
            local entries_json
            entries_json="$(python3 -c '
import json, os, re, sys

log_path, max_lines = sys.argv[1], int(sys.argv[2])
entries = []
if os.path.isfile(log_path):
    with open(log_path, "r", encoding="utf-8", errors="replace") as f:
        raw_lines = [ln.strip() for ln in f.readlines() if ln.strip()][-max_lines:]
    pat = re.compile(r"^\[([^\]]+)\]\s+\[([^\]]+)\]\s+\[([^\]]+)\]\s+(.*)$")
    for ln in raw_lines:
        m = pat.match(ln)
        if m:
            entries.append({"timestamp": m.group(1), "level": m.group(2), "module": m.group(3), "message": m.group(4)})
        else:
            entries.append({"timestamp": "", "level": "INFO", "module": "system", "message": ln})

print(json.dumps({"log_file": log_path, "count": len(entries), "entries": entries}))
' "$PC_LOG_FILE" "$lines")"
            pc_emit_result "Retrieved audit log entries" "$entries_json"
            ;;
        clear)
            : > "$PC_LOG_FILE"
            pc_log "INFO" "Audit log cleared by administrator."
            pc_emit_result "Cleared audit log" '{"cleared": true}'
            ;;
        *)
            pc_emit_error "Unsupported logs action '${action}' (expected: read, clear)." 2
            exit 2
            ;;
    esac
}

main() {
    if [[ $# -eq 0 ]]; then
        pc_print_help
        exit 0
    fi

    case "$1" in
        -h|--help)
            pc_print_help
            exit 0
            ;;
        status)
            shift
            handle_status "$@"
            ;;
        config)
            shift
            handle_config "$@"
            ;;
        logs)
            shift
            handle_logs "$@"
            ;;
        setup|acl|perms|ports|devices|apps|queue|maint)
            local submod="$1"
            shift
            local target_script="${PC_BIN_DIR}/pc-${submod}.sh"
            [[ "$submod" == "acl" ]] && target_script="${PC_BIN_DIR}/pc-net-acl.sh"
            if [[ ! -x "$target_script" ]]; then
                pc_emit_error "Module '${submod}' (${target_script}) is not installed yet." 1
                exit 1
            fi
            exec "$target_script" "$@"
            ;;
        *)
            pc_emit_error "Unknown module '$1'. Run 'pc-ctl --help' for available modules." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_CTL_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-ctl.sh
    chmod 0755 /opt/parentcontrol/bin/pc-ctl.sh
    ln -sf /opt/parentcontrol/bin/pc-ctl.sh /usr/local/bin/pc-ctl
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-setup.sh (Sub-Chunk 1.3)
# ------------------------------------------------------------------------------
deploy_pc_setup_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-setup.sh..."

    cat << 'PC_SETUP_SH_EOF' > /opt/parentcontrol/bin/pc-setup.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - System Provisioning, Admin Separation & Setup Wizard
# File: /opt/parentcontrol/bin/pc-setup.sh
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="setup"
PC_CURRENT_ACTION="init"
PC_SCRIPT_DESC="Provisions pcadmin, enforces PolicyKit admin separation, runs setup wizard, and stores caregiver contact info."
PC_SCRIPT_USAGE="pc-setup.sh --action <init|provision-admin|restore-admin|set-contact|get-contact|wizard> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>              init, provision-admin, restore-admin, set-contact, get-contact, wizard
      --user <username>            Restricted desktop user account
      --admin-password <password>  Password to assign to hidden pcadmin account
      --strip-user-sudo <bool>     Remove restricted user from sudo/adm groups (true|false)
      --name <text>                Caregiver / Admin display name
      --email <text>               Caregiver / Admin email address
      --phone <text>               Caregiver / Admin phone / SMS number
      --note <text>                Help note displayed on restricted user popup"

PC_POLKIT_RULE="${PC_POLKIT_RULE:-/etc/polkit-1/rules.d/49-parentcontrol.rules}"
PC_PUBLIC_INFO="${PC_PUBLIC_INFO:-/etc/parentcontrol/public-info.json}"

SETUP_ACTION="init"
TARGET_USER=""
ADMIN_PASSWORD=""
STRIP_USER_SUDO=""
CONTACT_NAME=""
CONTACT_EMAIL=""
CONTACT_PHONE=""
CONTACT_NOTE=""

parse_setup_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)          SETUP_ACTION="${2:-}"; shift 2 ;;
            --user)            TARGET_USER="${2:-}"; shift 2 ;;
            --admin-password)  ADMIN_PASSWORD="${2:-}"; shift 2 ;;
            --strip-user-sudo) STRIP_USER_SUDO="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --name)            CONTACT_NAME="${2:-}"; shift 2 ;;
            --email)           CONTACT_EMAIL="${2:-}"; shift 2 ;;
            --phone)           CONTACT_PHONE="${2:-}"; shift 2 ;;
            --note)            CONTACT_NOTE="${2:-}"; shift 2 ;;
            *) pc_emit_error "Unknown flag for pc-setup.sh: $1" 2; exit 2 ;;
        esac
    done
    PC_CURRENT_ACTION="$SETUP_ACTION"
}

detect_default_desktop_user() {
    if [[ -n "$TARGET_USER" ]]; then
        printf '%s' "$TARGET_USER"
        return 0
    fi
    local existing
    existing="$(pc_json_get "restricted_user" 2>/dev/null || true)"
    if [[ -n "$existing" ]] && id -u "$existing" >/dev/null 2>&1; then
        printf '%s' "$existing"
        return 0
    fi
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" && "${SUDO_USER}" != "$PC_ADMIN_USER" ]]; then
        printf '%s' "$SUDO_USER"
        return 0
    fi
    awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" && $1 != "'"$PC_ADMIN_USER"'" {print $1; exit}' /etc/passwd
}

ensure_pcadmin_account() {
    if ! id -u "$PC_ADMIN_USER" >/dev/null 2>&1; then
        useradd -r -m -d /var/lib/pcadmin -s /bin/bash -G sudo "$PC_ADMIN_USER"
        pc_log "INFO" "Created dedicated admin account '${PC_ADMIN_USER}'."
    else
        usermod -aG sudo "$PC_ADMIN_USER" 2>/dev/null || true
    fi

    mkdir -p /var/lib/AccountsService/users
    cat << EOF > "/var/lib/AccountsService/users/${PC_ADMIN_USER}"
[User]
SystemAccount=true
EOF
    chmod 0644 "/var/lib/AccountsService/users/${PC_ADMIN_USER}"
}

deploy_polkit_rule() {
    mkdir -p /etc/polkit-1/rules.d
    cat << 'POLKIT_EOF' > "$PC_POLKIT_RULE"
// Managed by ParentControl (pc-setup.sh)
// Enforces that ParentControl administrative actions authenticate strictly
// against the dedicated 'pcadmin' account, never the restricted user.
polkit.addAdminRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec") {
        var prog = action.lookup("program");
        if (prog && prog.indexOf("/opt/parentcontrol/") === 0) {
            return ["unix-user:pcadmin"];
        }
    }
    return null;
});

polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec") {
        var prog = action.lookup("program");
        if (prog && prog.indexOf("/opt/parentcontrol/") === 0) {
            if (subject.user == "pcadmin") {
                return polkit.Result.YES;
            }
            return polkit.Result.AUTH_ADMIN_KEEP;
        }
    }
});
POLKIT_EOF
    chown root:root "$PC_POLKIT_RULE"
    chmod 0644 "$PC_POLKIT_RULE"
    systemctl restart polkit >/dev/null 2>&1 || true
}

sync_public_contact_info() {
    pc_ensure_config_exists
    python3 -c '
import json, os, sys

cfg_path, pub_path = sys.argv[1:3]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

pub_data = {
    "restricted_user": cfg.get("restricted_user", ""),
    "admin_contact": cfg.get("admin_contact", {
        "name": "Caregiver / Parent",
        "email": "",
        "phone": "",
        "note": "Use this form to request access to an app or website."
    })
}
tmp_path = pub_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as wf:
    json.dump(pub_data, wf, indent=2)
    wf.write("\n")
os.chmod(os.path.dirname(pub_path), 0o755)
os.chmod(tmp_path, 0o644)
os.replace(tmp_path, pub_path)
' "$PC_CONFIG_FILE" "$PC_PUBLIC_INFO"
}

install_user_request_shortcut() {
    local r_user="$1"
    [[ -z "$r_user" ]] && return 0
    id -u "$r_user" >/dev/null 2>&1 || return 0

    local user_home r_group
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"
    r_group="$(id -gn "$r_user")"

    if [[ -d "${user_home}/Desktop" && -f /usr/share/applications/parentcontrol-request.desktop ]]; then
        cp -f /usr/share/applications/parentcontrol-request.desktop "${user_home}/Desktop/parentcontrol-request.desktop"
        chown "${r_user}:${r_group}" "${user_home}/Desktop/parentcontrol-request.desktop"
        chmod 0755 "${user_home}/Desktop/parentcontrol-request.desktop"
    fi
}

handle_init() {
    pc_ensure_config_exists
    ensure_pcadmin_account
    if passwd -S "$PC_ADMIN_USER" 2>/dev/null | awk '{print $2}' | grep -qx "P"; then
        deploy_polkit_rule
    fi

    local r_user
    r_user="$(detect_default_desktop_user)"
    if [[ -n "$r_user" ]]; then
        pc_json_set "restricted_user" "\"${r_user}\""
        install_user_request_shortcut "$r_user"
    fi
    sync_public_contact_info

    local pw_ready="false"
    if passwd -S "$PC_ADMIN_USER" 2>/dev/null | awk '{print $2}' | grep -qx "P"; then
        pw_ready="true"
    fi

    local out_json
    out_json="$(python3 -c '
import json, sys
print(json.dumps({
    "restricted_user": sys.argv[1],
    "admin_user": sys.argv[2],
    "admin_password_configured": sys.argv[3] == "true",
    "polkit_rule": sys.argv[4]
}))
' "$r_user" "$PC_ADMIN_USER" "$pw_ready" "$PC_POLKIT_RULE")"

    pc_emit_result "Initialized ParentControl system foundation" "$out_json"
}

handle_provision_admin() {
    pc_ensure_config_exists
    ensure_pcadmin_account
    deploy_polkit_rule

    local r_user
    r_user="$(detect_default_desktop_user)"
    [[ -n "$r_user" ]] && pc_json_set "restricted_user" "\"${r_user}\""

    if [[ -n "$ADMIN_PASSWORD" ]]; then
        if [[ ${#ADMIN_PASSWORD} -lt 6 ]]; then
            pc_emit_error "Admin password must be at least 6 characters long." 2
            exit 2
        fi
        printf '%s:%s\n' "$PC_ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
        usermod -s /bin/bash -U "$PC_ADMIN_USER" 2>/dev/null || true
        faillock --user "$PC_ADMIN_USER" --reset 2>/dev/null || true
        pc_log "INFO" "Updated dedicated password for '${PC_ADMIN_USER}'."
    fi

    local pw_status
    pw_status="$(passwd -S "$PC_ADMIN_USER" 2>/dev/null | awk '{print $2}' || true)"

    local stripped="false"
    if [[ "$STRIP_USER_SUDO" == "true" ]]; then
        if [[ "$pw_status" != "P" ]]; then
            pc_emit_error "Refusing to strip sudo from '${r_user}' until '${PC_ADMIN_USER}' has a password configured (--admin-password)." 2
            exit 2
        fi
        if [[ -n "$r_user" && "$r_user" != "root" && "$r_user" != "$PC_ADMIN_USER" ]]; then
            gpasswd -d "$r_user" sudo >/dev/null 2>&1 || true
            gpasswd -d "$r_user" adm >/dev/null 2>&1 || true
            stripped="true"
            pc_json_set "user_sudo_stripped" "true"
            pc_log "INFO" "Removed '${r_user}' from sudo and adm groups."
        fi
    fi

    install_user_request_shortcut "$r_user"
    sync_public_contact_info

    local out_json
    out_json="$(python3 -c '
import json, sys
print(json.dumps({
    "restricted_user": sys.argv[1],
    "admin_user": sys.argv[2],
    "admin_password_configured": sys.argv[3] == "P",
    "user_sudo_stripped": sys.argv[4] == "true"
}))
' "$r_user" "$PC_ADMIN_USER" "$pw_status" "$stripped")"

    pc_emit_result "Configured ParentControl administrator relationship" "$out_json"
}

handle_restore_admin() {
    pc_ensure_config_exists
    local r_user
    r_user="$(detect_default_desktop_user)"
    if [[ -z "$r_user" ]] || ! id -u "$r_user" >/dev/null 2>&1; then
        pc_emit_error "Could not find valid restricted_user to restore sudo privileges." 2
        exit 2
    fi
    usermod -aG sudo,adm "$r_user"
    pc_json_set "user_sudo_stripped" "false"
    pc_log "INFO" "Restored sudo and adm group membership for '${r_user}'."
    pc_emit_result "Restored sudo privileges for '${r_user}'" "{\"restricted_user\": \"${r_user}\", \"user_sudo_stripped\": false}"
}

handle_set_contact() {
    pc_ensure_config_exists
    pc_init_transaction
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, c_name, c_email, c_phone, c_note, out_path = sys.argv[1:7]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

contact = data.setdefault("admin_contact", {})
if c_name:  contact["name"] = c_name
if c_email: contact["email"] = c_email
if c_phone: contact["phone"] = c_phone
if c_note:  contact["note"] = c_note

with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
' "$PC_CONFIG_FILE" "$CONTACT_NAME" "$CONTACT_EMAIL" "$CONTACT_PHONE" "$CONTACT_NOTE" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"
    sync_public_contact_info
    pc_commit_transaction

    local contact_json
    contact_json="$(python3 -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])).get("admin_contact", {})))' "$PC_CONFIG_FILE")"
    pc_emit_result "Updated caregiver/admin contact details" "$contact_json"
}

handle_get_contact() {
    sync_public_contact_info
    local contact_json
    contact_json="$(cat "$PC_PUBLIC_INFO")"
    pc_emit_result "Retrieved caregiver/admin contact details" "$contact_json"
}

handle_wizard() {
    printf '\n============================================================\n'
    printf '  ParentControl Interactive Setup Wizard (Linux Mint 22.3)\n'
    printf '============================================================\n\n'

    local default_user
    default_user="$(detect_default_desktop_user)"
    read -rp "1. Monitored / restricted desktop username [${default_user}]: " input_user
    TARGET_USER="${input_user:-$default_user}"
    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        printf '[ERROR] User "%s" does not exist.\n' "$TARGET_USER" >&2
        exit 1
    fi

    printf '\n2. Create Dedicated ParentControl Admin Password (for "%s")\n' "$PC_ADMIN_USER"
    printf '   (This separates admin controls from %s'\''s login password.)\n' "$TARGET_USER"
    local pw1 pw2
    while true; do
        read -rsp "   Enter new password for ${PC_ADMIN_USER} (min 6 chars): " pw1
        printf '\n'
        read -rsp "   Confirm password for ${PC_ADMIN_USER}: " pw2
        printf '\n'
        if [[ "$pw1" != "$pw2" ]]; then
            printf '   [WARN] Passwords did not match. Try again.\n'
        elif [[ ${#pw1} -lt 6 ]]; then
            printf '   [WARN] Password must be at least 6 characters.\n'
        else
            ADMIN_PASSWORD="$pw1"
            break
        fi
    done

    read -rp "   Strip sudo/admin rights from '${TARGET_USER}' so they cannot bypass controls? [Y/n]: " strip_ans
    if [[ "${strip_ans,,}" == "n" ]]; then
        STRIP_USER_SUDO="false"
    else
        STRIP_USER_SUDO="true"
    fi

    printf '\n3. Select Care Profile:\n'
    printf '   [1] Dementia / Senior Care (enables larger text & disables hot-corners)\n'
    printf '   [2] Child / Student Safety\n'
    read -rp "   Choose profile [1/2, default 1]: " prof_choice

    printf '\n4. Caregiver / Admin Contact Info (shown on the user'\''s "Request Access" popup):\n'
    read -rp "   Caregiver Name [Parent / Caregiver]: " CONTACT_NAME
    CONTACT_NAME="${CONTACT_NAME:-Parent / Caregiver}"
    read -rp "   Phone / SMS (optional): " CONTACT_PHONE
    read -rp "   Email (optional): " CONTACT_EMAIL
    read -rp "   Help Note [Click Send Request if you need a site or app unlocked.]: " CONTACT_NOTE
    CONTACT_NOTE="${CONTACT_NOTE:-Click Send Request if you need a site or app unlocked.}"

    printf '\nApplying configuration...\n'
    PC_JSON_OUTPUT=0
    handle_provision_admin
    handle_set_contact

    if [[ "${prof_choice:-1}" == "1" && -x "${PC_BIN_DIR}/pc-maint.sh" ]]; then
        "${PC_BIN_DIR}/pc-maint.sh" --action senior-preset --enabled true >/dev/null
    fi
    if [[ -x "${PC_BIN_DIR}/pc-ports.sh" ]]; then
        "${PC_BIN_DIR}/pc-ports.sh" --action block-preset --preset risky >/dev/null
    fi
    if [[ -x "${PC_BIN_DIR}/pc-net-acl.sh" ]]; then
        "${PC_BIN_DIR}/pc-net-acl.sh" --action toggle-feed --enabled true >/dev/null
    fi

    printf '\n[OK] Setup complete!\n'
    printf '  - Restricted User : %s (sudo stripped: %s)\n' "$TARGET_USER" "$STRIP_USER_SUDO"
    printf '  - Admin Account   : %s (use this password when GUI prompts)\n' "$PC_ADMIN_USER"
    printf '  - Request Popup   : Installed to %s'\''s Desktop & Application Menu\n\n' "$TARGET_USER"
}

main() {
    parse_setup_args "$@"

    if [[ "$SETUP_ACTION" == "get-contact" ]]; then
        handle_get_contact
        exit 0
    fi

    pc_require_root
    pc_verify_mint

    case "$SETUP_ACTION" in
        init)            handle_init ;;
        provision-admin) handle_provision_admin ;;
        restore-admin)   handle_restore_admin ;;
        set-contact)     handle_set_contact ;;
        wizard)          handle_wizard ;;
        *)
            pc_emit_error "Unsupported setup action '${SETUP_ACTION}'." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_SETUP_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-setup.sh
    chmod 0755 /opt/parentcontrol/bin/pc-setup.sh
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-net-acl.sh (Sub-Chunk 2.1)
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-net-acl.sh (Sub-Chunks 2.1 & 2.2)
# ------------------------------------------------------------------------------
deploy_pc_net_acl_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-net-acl.sh..."

    cat << 'PC_NET_ACL_SH_EOF' > /opt/parentcontrol/bin/pc-net-acl.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Web & Network Access Control Manager
# File: /opt/parentcontrol/bin/pc-net-acl.sh
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="acl"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages Web/Network whitelist, greylist, blacklist, and toggleable blocklist feeds (StevenBlack & Phishing Army)."
PC_SCRIPT_USAGE="pc-net-acl.sh --action <add|remove|list|sync|toggle-feed|set-feed|export-policy|apply> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         add, remove, list, sync, toggle-feed, set-feed, export-policy, apply
      --list <type>           whitelist | greylist | blacklist
      --target <domain|ip>    Domain, URL, or IPv4/IPv6 address
      --feed <id>             stevenblack | phishing_army (defaults to stevenblack)
      --enabled <true|false>  Enable or disable the specified blocklist feed
      --url <feed_url>        Custom hosts blocklist feed URL"

PC_HOSTS_FILE="${PC_HOSTS_FILE:-/etc/hosts}"
PC_HOSTS_BEGIN="${PC_HOSTS_BEGIN:-# BEGIN PARENTCONTROL MANAGED BLOCKS}"
PC_HOSTS_END="${PC_HOSTS_END:-# END PARENTCONTROL MANAGED BLOCKS}"

readonly PC_STEVENBLACK_URL="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
readonly PC_PHISHING_ARMY_URL="https://phishing.army/download/phishing_army_blocklist_extended.txt"
readonly PC_FEED_SB_CACHE="${PC_VAR_DIR}/feed-stevenblack.txt"
readonly PC_FEED_PA_CACHE="${PC_VAR_DIR}/feed-phishing_army.txt"

ACL_ACTION=""
ACL_LIST=""
ACL_TARGET=""
FEED_ID=""
FEED_ENABLED=""
FEED_URL=""

parse_acl_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)  ACL_ACTION="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --list)    ACL_LIST="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --target)  ACL_TARGET="${2:-}"; shift 2 ;;
            --feed)    FEED_ID="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --enabled) FEED_ENABLED="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --url)     FEED_URL="${2:-}"; shift 2 ;;
            *) pc_emit_error "Unknown flag for pc-net-acl.sh: $1" 2; exit 2 ;;
        esac
    done

    if [[ -z "$ACL_ACTION" ]]; then
        pc_emit_error "Missing required --action flag." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$ACL_ACTION"
}

ensure_feed_schema() {
    pc_ensure_config_exists
    python3 - "$PC_CONFIG_FILE" "$PC_STEVENBLACK_URL" "$PC_PHISHING_ARMY_URL" << 'PYEOF'
import json, os, sys

cfg_path, sb_url, pa_url = sys.argv[1:4]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

net = data.setdefault("network", {})
changed = False

if "feed_sources" not in net or not isinstance(net["feed_sources"], dict):
    legacy_enabled = bool(net.get("default_feed_enabled", True))
    legacy_feeds = net.get("feeds", [])
    custom_sb = legacy_feeds[0] if legacy_feeds else sb_url
    net["feed_sources"] = {
        "stevenblack": {
            "id": "stevenblack",
            "label": "StevenBlack Hosts (Ads & Malware)",
            "url": custom_sb,
            "enabled": legacy_enabled
        },
        "phishing_army": {
            "id": "phishing_army",
            "label": "Phishing Army (Phishing & Scams)",
            "url": pa_url,
            "enabled": False
        }
    }
    changed = True
else:
    if "stevenblack" not in net["feed_sources"]:
        net["feed_sources"]["stevenblack"] = {
            "id": "stevenblack",
            "label": "StevenBlack Hosts (Ads & Malware)",
            "url": sb_url,
            "enabled": bool(net.get("default_feed_enabled", True))
        }
        changed = True
    if "phishing_army" not in net["feed_sources"]:
        net["feed_sources"]["phishing_army"] = {
            "id": "phishing_army",
            "label": "Phishing Army (Phishing & Scams)",
            "url": pa_url,
            "enabled": False
        }
        changed = True

if changed:
    tmp_path = cfg_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as wf:
        json.dump(data, wf, indent=2)
        wf.write("\n")
    os.chmod(tmp_path, 0o640)
    os.replace(tmp_path, cfg_path)
PYEOF
}

normalize_target() {
    python3 - "$1" << 'PYEOF'
import re, sys
from urllib.parse import urlparse

raw = sys.argv[1].strip().lower()
if not raw:
    sys.exit(1)
if "://" in raw:
    host = urlparse(raw).hostname or ""
else:
    host = raw.split("/")[0].split(":")[0]
host = host.strip(".")
if not host or not re.match(r"^[a-z0-9._:-]+$", host):
    sys.exit(1)
print(host)
PYEOF
}

download_single_feed() {
    local url="$1"
    local cache_file="$2"
    mkdir -p "$PC_VAR_DIR"

    local tmp_dl tmp_clean
    tmp_dl="$(mktemp /tmp/pc-feed-dl.XXXXXX)"
    tmp_clean="$(mktemp /tmp/pc-feed-clean.XXXXXX)"

    if curl -fsSL --connect-timeout 10 --max-time 35 "$url" -o "$tmp_dl" 2>/dev/null; then
        python3 - "$tmp_dl" "$tmp_clean" << 'PYEOF'
import re, sys

in_path, out_path = sys.argv[1:3]
domains = set()
dom_re = re.compile(r"^[a-z0-9.-]+\.[a-z]{2,}$")
skip = {"localhost", "localhost.localdomain", "broadcasthost", "local", "ip6-localhost", "ip6-loopback"}

with open(in_path, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("!"):
            continue
        s = s.split("#", 1)[0].strip()
        parts = s.split()
        if not parts:
            continue
        if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1", "::", "::1"):
            dom = parts[1].lower()
        else:
            dom = parts[0].lower()
        if dom not in skip and dom_re.match(dom):
            domains.add(dom)

with open(out_path, "w", encoding="utf-8") as wf:
    for d in sorted(domains):
        wf.write(d + "\n")
PYEOF
        mv "$tmp_clean" "$cache_file"
        chmod 0644 "$cache_file"
    else
        rm -f "$tmp_clean"
        [[ -f "$cache_file" ]] || : > "$cache_file"
    fi
    rm -f "$tmp_dl"
}

sync_enabled_feeds() {
    ensure_feed_schema
    local feed_dump
    feed_dump="$(python3 - "$PC_CONFIG_FILE" << 'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
sources = cfg.get("network", {}).get("feed_sources", {})
for fid, info in sources.items():
    en = "1" if info.get("enabled") else "0"
    print(f"{fid}|{en}|{info.get('url', '')}")
PYEOF
)"
    while IFS='|' read -r fid enabled url; do
        [[ "$enabled" == "1" && -n "$url" ]] || continue
        if [[ "$fid" == "stevenblack" ]]; then
            download_single_feed "$url" "$PC_FEED_SB_CACHE"
        elif [[ "$fid" == "phishing_army" ]]; then
            download_single_feed "$url" "$PC_FEED_PA_CACHE"
        fi
    done <<< "$feed_dump"
}

enforce_network_rules() {
    ensure_feed_schema
    pc_backup_file "$PC_HOSTS_FILE"

    local tmp_hosts
    tmp_hosts="$(mktemp /tmp/pc-hosts.XXXXXX)"

    python3 - "$PC_CONFIG_FILE" "$PC_HOSTS_FILE" "$PC_FEED_SB_CACHE" "$PC_FEED_PA_CACHE" "$PC_HOSTS_BEGIN" "$PC_HOSTS_END" "$tmp_hosts" << 'PYEOF'
import json, os, sys

cfg_path, hosts_path, sb_cache, pa_cache, begin_mark, end_mark, out_path = sys.argv[1:8]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

net = cfg.get("network", {})
whitelist = {x.lower() for x in net.get("whitelist", [])}
greylist = {x.lower() for x in net.get("greylist", [])}
allowed = whitelist | greylist
blacklist = [x.lower() for x in net.get("blacklist", [])]
sources = net.get("feed_sources", {})

sb_enabled = bool(sources.get("stevenblack", {}).get("enabled", False))
pa_enabled = bool(sources.get("phishing_army", {}).get("enabled", False))

existing = []
if os.path.isfile(hosts_path):
    with open(hosts_path, "r", encoding="utf-8", errors="replace") as hf:
        in_block = False
        for line in hf:
            if line.strip() == begin_mark:
                in_block = True
                continue
            if line.strip() == end_mark:
                in_block = False
                continue
            if not in_block:
                existing.append(line.rstrip("\n"))

blocked_domains = []
seen = set()

for dom in blacklist:
    if dom not in allowed and dom not in seen:
        seen.add(dom)
        blocked_domains.append(dom)

for enabled, cache_file in ((sb_enabled, sb_cache), (pa_enabled, pa_cache)):
    if enabled and os.path.isfile(cache_file):
        with open(cache_file, "r", encoding="utf-8", errors="ignore") as ff:
            for line in ff:
                dom = line.strip().lower()
                if dom and dom not in allowed and dom not in seen:
                    seen.add(dom)
                    blocked_domains.append(dom)

with open(out_path, "w", encoding="utf-8") as wf:
    for ln in existing:
        wf.write(ln + "\n")
    if blocked_domains:
        wf.write(begin_mark + "\n")
        for dom in blocked_domains:
            wf.write(f"0.0.0.0 {dom}\n")
        wf.write(end_mark + "\n")
PYEOF

    chown root:root "$tmp_hosts"
    chmod 0644 "$tmp_hosts"
    mv "$tmp_hosts" "$PC_HOSTS_FILE"
}

build_acl_state_json() {
    ensure_feed_schema
    python3 - "$PC_CONFIG_FILE" "$PC_FEED_SB_CACHE" "$PC_FEED_PA_CACHE" << 'PYEOF'
import json, os, sys

cfg_path, sb_cache, pa_cache = sys.argv[1:4]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

net = cfg.get("network", {})
white = net.get("whitelist", [])
grey  = net.get("greylist", [])
black = net.get("blacklist", [])
sources = net.get("feed_sources", {})

def count_lines(p):
    if not os.path.isfile(p):
        return 0
    with open(p, "r", encoding="utf-8", errors="ignore") as ff:
        return sum(1 for ln in ff if ln.strip())

sb_count = count_lines(sb_cache)
pa_count = count_lines(pa_cache)

sb_info = dict(sources.get("stevenblack", {}))
sb_info["domains_count"] = sb_count
pa_info = dict(sources.get("phishing_army", {}))
pa_info["domains_count"] = pa_count

any_enabled = bool(sb_info.get("enabled") or pa_info.get("enabled"))
active_domains = (sb_count if sb_info.get("enabled") else 0) + (pa_count if pa_info.get("enabled") else 0)

rules = (
    [{"list": "whitelist", "target": x} for x in white] +
    [{"list": "greylist", "target": x} for x in grey] +
    [{"list": "blacklist", "target": x} for x in black]
)

print(json.dumps({
    "default_feed_enabled": any_enabled,
    "feed_sources": {
        "stevenblack": sb_info,
        "phishing_army": pa_info
    },
    "whitelist": white,
    "greylist": grey,
    "blacklist": black,
    "rules": rules,
    "feeds": [sb_info.get("url", ""), pa_info.get("url", "")],
    "feed_domains_count": active_domains
}))
PYEOF
}

handle_add() {
    case "$ACL_LIST" in
        whitelist|greylist|blacklist) ;;
        *) pc_emit_error "Action 'add' requires --list <whitelist|greylist|blacklist>." 2; exit 2 ;;
    esac

    local norm_target
    if ! norm_target="$(normalize_target "$ACL_TARGET")"; then
        pc_emit_error "Invalid domain, URL, or IP address: '${ACL_TARGET}'" 2
        exit 2
    fi

    pc_init_transaction
    ensure_feed_schema
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 - "$PC_CONFIG_FILE" "$ACL_LIST" "$norm_target" "$tmp_cfg" << 'PYEOF'
import json, sys

cfg_path, target_list, item, out_path = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

net = data.setdefault("network", {})
for lst in ("whitelist", "greylist", "blacklist"):
    arr = [x for x in net.get(lst, []) if x.lower() != item]
    if lst == target_list:
        arr.append(item)
        arr.sort()
    net[lst] = arr

with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
PYEOF

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    enforce_network_rules
    pc_commit_transaction

    pc_emit_result "Added '${norm_target}' to ${ACL_LIST}" "$(build_acl_state_json)"
}

handle_remove() {
    local norm_target
    if ! norm_target="$(normalize_target "$ACL_TARGET")"; then
        pc_emit_error "Invalid target '${ACL_TARGET}'." 2
        exit 2
    fi

    pc_init_transaction
    ensure_feed_schema
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg removed_flag
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    removed_flag="$(python3 - "$PC_CONFIG_FILE" "$ACL_LIST" "$norm_target" "$tmp_cfg" << 'PYEOF'
import json, sys

cfg_path, target_list, item, out_path = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

net = data.setdefault("network", {})
found = False
lists_to_check = [target_list] if target_list in ("whitelist", "greylist", "blacklist") else ["whitelist", "greylist", "blacklist"]
for lst in lists_to_check:
    old = net.get(lst, [])
    new = [x for x in old if x.lower() != item]
    if len(new) != len(old):
        found = True
    net[lst] = new

with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
print("1" if found else "0")
PYEOF
)"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    if [[ "$removed_flag" != "1" ]]; then
        pc_commit_transaction
        pc_emit_error "Target '${norm_target}' was not found in ACL rules." 2
        exit 2
    fi

    enforce_network_rules
    pc_commit_transaction

    pc_emit_result "Removed '${norm_target}' from ACL" "$(build_acl_state_json)"
}

handle_toggle_feed() {
    if [[ "$FEED_ENABLED" != "true" && "$FEED_ENABLED" != "false" ]]; then
        pc_emit_error "Action 'toggle-feed' requires --enabled <true|false>." 2
        exit 2
    fi

    local target_feed="${FEED_ID:-stevenblack}"
    case "$target_feed" in
        stevenblack|phishing_army|all) ;;
        *) pc_emit_error "Invalid --feed '${target_feed}' (expected: stevenblack, phishing_army, all)." 2; exit 2 ;;
    esac

    pc_init_transaction
    ensure_feed_schema
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 - "$PC_CONFIG_FILE" "$target_feed" "$FEED_ENABLED" "$tmp_cfg" << 'PYEOF'
import json, sys

cfg_path, fid, enabled_str, out_path = sys.argv[1:5]
enabled = (enabled_str == "true")
data = json.load(open(cfg_path, "r", encoding="utf-8"))
sources = data.setdefault("network", {}).setdefault("feed_sources", {})

if fid == "all":
    for key in sources:
        sources[key]["enabled"] = enabled
else:
    if fid in sources:
        sources[fid]["enabled"] = enabled

data["network"]["default_feed_enabled"] = any(v.get("enabled", False) for v in sources.values())

with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
PYEOF

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    if [[ "$FEED_ENABLED" == "true" ]]; then
        if [[ "$target_feed" == "stevenblack" || "$target_feed" == "all" ]] && [[ ! -s "$PC_FEED_SB_CACHE" ]]; then
            download_single_feed "$PC_STEVENBLACK_URL" "$PC_FEED_SB_CACHE"
        fi
        if [[ "$target_feed" == "phishing_army" || "$target_feed" == "all" ]] && [[ ! -s "$PC_FEED_PA_CACHE" ]]; then
            download_single_feed "$PC_PHISHING_ARMY_URL" "$PC_FEED_PA_CACHE"
        fi
    fi

    enforce_network_rules
    pc_commit_transaction

    pc_emit_result "Set blocklist feed '${target_feed}' enabled=${FEED_ENABLED}" "$(build_acl_state_json)"
}

handle_set_feed() {
    if [[ -z "$FEED_URL" ]]; then
        pc_emit_error "Action 'set-feed' requires --url <feed_url>." 2
        exit 2
    fi
    local target_feed="${FEED_ID:-stevenblack}"
    case "$target_feed" in
        stevenblack|phishing_army) ;;
        *) pc_emit_error "Invalid --feed '${target_feed}' (expected: stevenblack, phishing_army)." 2; exit 2 ;;
    esac

    pc_init_transaction
    ensure_feed_schema
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"
    python3 - "$PC_CONFIG_FILE" "$target_feed" "$FEED_URL" "$tmp_cfg" << 'PYEOF'
import json, sys
cfg_path, fid, url, out_path = sys.argv[1:5]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
sources = data.setdefault("network", {}).setdefault("feed_sources", {})
if fid in sources:
    sources[fid]["url"] = url
    sources[fid]["enabled"] = True
data["network"]["default_feed_enabled"] = True
with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
PYEOF

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    if [[ "$target_feed" == "stevenblack" ]]; then
        download_single_feed "$FEED_URL" "$PC_FEED_SB_CACHE"
    else
        download_single_feed "$FEED_URL" "$PC_FEED_PA_CACHE"
    fi
    enforce_network_rules
    pc_commit_transaction

    pc_emit_result "Updated and synced blocklist feed '${target_feed}'" "$(build_acl_state_json)"
}

main() {
    parse_acl_args "$@"
    pc_require_root
    pc_verify_mint

    case "$ACL_ACTION" in
        add)           handle_add ;;
        remove)        handle_remove ;;
        toggle-feed)   handle_toggle_feed ;;
        set-feed)      handle_set_feed ;;
        sync)
            pc_init_transaction
            sync_enabled_feeds
            enforce_network_rules
            pc_commit_transaction
            pc_emit_result "Synced enabled web blocklist feeds" "$(build_acl_state_json)"
            ;;
        list|export-policy)
            pc_emit_result "Retrieved network ACL rules" "$(build_acl_state_json)"
            ;;
        apply)
            pc_init_transaction
            enforce_network_rules
            pc_commit_transaction
            pc_emit_result "Applied network ACL rules" "$(build_acl_state_json)"
            ;;
        *)
            pc_emit_error "Unsupported ACL action '${ACL_ACTION}'." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_NET_ACL_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-net-acl.sh
    chmod 0755 /opt/parentcontrol/bin/pc-net-acl.sh
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-perms.sh (Part 3)
# ------------------------------------------------------------------------------
deploy_pc_perms_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-perms.sh..."

    cat << 'PC_PERMS_SH_EOF' > /opt/parentcontrol/bin/pc-perms.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Folder Permissions (RWX / Modes) & Home Hardening Manager
# File: /opt/parentcontrol/bin/pc-perms.sh
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="perms"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages directory access rules (locked, read-only, drop-box, full, or RWX) and home-directory hardening."
PC_SCRIPT_USAGE="pc-perms.sh --action <set|remove|preset|list|apply> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         set, remove, preset, list, apply
      --path <dir>            Target folder (relative paths resolve inside restricted user's home)
      --perms <RWX>           3-character permission mask (e.g., R-X, ---, RWX)
      --mode <level>          Intuitive access level: locked | read-only | drop-box | full
      --name <preset>         lock_dotfiles | restrict_extra_home_dirs | noexec_user_dirs
      --enabled <true|false>  Enable or disable preset"

PERMS_ACTION=""
TARGET_PATH=""
TARGET_PERMS=""
TARGET_MODE=""
PRESET_NAME=""
PRESET_ENABLED=""

parse_perms_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)  PERMS_ACTION="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --path)    TARGET_PATH="${2:-}"; shift 2 ;;
            --perms)   TARGET_PERMS="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
            --mode)    TARGET_MODE="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --name)    PRESET_NAME="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --enabled) PRESET_ENABLED="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            *) pc_emit_error "Unknown flag for pc-perms.sh: $1" 2; exit 2 ;;
        esac
    done

    if [[ -z "$PERMS_ACTION" ]]; then
        pc_emit_error "Missing required --action flag." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$PERMS_ACTION"
}

get_restricted_user() {
    pc_ensure_config_exists
    local r_user
    r_user="$(pc_json_get "restricted_user" 2>/dev/null || true)"
    if [[ -z "$r_user" ]] || ! id -u "$r_user" >/dev/null 2>&1; then
        r_user="$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" && $1 != "pcadmin" {print $1; exit}' /etc/passwd)"
    fi
    if [[ -z "$r_user" ]] || ! id -u "$r_user" >/dev/null 2>&1; then
        pc_emit_error "Valid restricted_user is not configured in config.json." 2
        exit 2
    fi
    printf '%s' "$r_user"
}

resolve_safe_user_path() {
    local raw_path="$1"
    local user_home="$2"

    python3 - "$raw_path" "$user_home" << 'PYEOF'
import os, sys

raw, home = sys.argv[1].strip(), sys.argv[2].strip()
if not raw:
    sys.exit(1)

if raw == "~":
    resolved = home
elif raw.startswith("~/"):
    resolved = os.path.join(home, raw[2:])
elif not raw.startswith("/"):
    resolved = os.path.join(home, raw)
else:
    resolved = raw

resolved = os.path.abspath(resolved)
forbidden = {
    "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64",
    "/media", "/mnt", "/opt", "/proc", "/root", "/run", "/sbin", "/sys", "/usr", "/var"
}
if resolved in forbidden:
    sys.exit(2)

print(resolved)
PYEOF
}

normalize_rwx_and_label() {
    local mode="$1"
    local raw_perms="$2"
    local target_path="$3"

    if [[ -n "$mode" ]]; then
        case "$mode" in
            locked|none|block)     printf '%s' '---|Locked (No Access)'; return 0 ;;
            read-only|readonly|ro) printf 'R-X|Read-Only'; return 0 ;;
            drop-box|dropbox|wo)   printf '%s' '-WX|Drop-Box (Write Only)'; return 0 ;;
            full|rw|rwx|allow)     printf 'RWX|Full Access'; return 0 ;;
            *) pc_emit_error "Invalid --mode '${mode}' (expected: locked, read-only, drop-box, full)." 2; exit 2 ;;
        esac
    fi

    if [[ ! "$raw_perms" =~ ^[R-][W-][X-]$ ]]; then
        pc_emit_error "Invalid --perms '${raw_perms}'. Must be 3 chars like R-X, ---, or RWX." 2
        exit 2
    fi

    local r_bit="${raw_perms:0:1}"
    local w_bit="${raw_perms:1:1}"
    local x_bit="${raw_perms:2:1}"

    if [[ -d "$target_path" && ( "$r_bit" == "R" || "$w_bit" == "W" ) && "$x_bit" == "-" ]]; then
        x_bit="X"
    fi

    local final_rwx="${r_bit}${w_bit}${x_bit}"
    local label="Custom (${final_rwx})"
    case "$final_rwx" in
        ---) label="Locked (No Access)" ;;
        R-X) label="Read-Only" ;;
        -WX) label="Drop-Box (Write Only)" ;;
        RWX) label="Full Access" ;;
    esac
    printf '%s|%s' "$final_rwx" "$label"
}

apply_single_acl_rule() {
    local r_user="$1"
    local target_path="$2"
    local rwx="$3"
    local orig_owner="${4:-$r_user}"
    local orig_group="${5:-$(id -gn "$r_user")}"

    [[ -e "$target_path" ]] || return 0

    case "$rwx" in
        "---")
            # Complete lockdown: root owns path, non-owners have zero base bits, explicit --- ACL
            chown -R root:root "$target_path"
            chmod -R go-rwx "$target_path"
            setfacl -R -b "$target_path" 2>/dev/null || true
            setfacl -R -m "u:${r_user}:---" "$target_path" 2>/dev/null || true
            if [[ -d "$target_path" ]]; then
                setfacl -R -m "d:u:${r_user}:---" "$target_path" 2>/dev/null || true
            fi
            ;;
        "R-X")
            # Read-only: root owns path so user cannot chmod/delete; user gets r-X via ACL
            chown -R root:root "$target_path"
            if [[ -d "$target_path" ]]; then
                find "$target_path" -type d -exec chmod 0750 {} +
                find "$target_path" -type f -exec chmod 0640 {} +
                setfacl -R -b "$target_path" 2>/dev/null || true
                setfacl -R -m "u:${r_user}:r-X" "$target_path"
                setfacl -R -m "d:u:${r_user}:r-X" "$target_path"
                setfacl -R -m "m::r-X" "$target_path"
            else
                chmod 0640 "$target_path"
                setfacl -b "$target_path" 2>/dev/null || true
                setfacl -m "u:${r_user}:r--" "$target_path"
                setfacl -m "m::r--" "$target_path"
            fi
            ;;
        "-WX")
            # Drop-box: user can write/create files in directory, cannot list or read existing files
            chown -R root:root "$target_path"
            if [[ -d "$target_path" ]]; then
                find "$target_path" -type d -exec chmod 0750 {} +
                find "$target_path" -type f -exec chmod 0640 {} +
                setfacl -R -b "$target_path" 2>/dev/null || true
                setfacl -m "u:${r_user}:-wx" "$target_path"
                setfacl -m "d:u:${r_user}:rw-" "$target_path"
                setfacl -m "m::rwx" "$target_path"
            else
                chmod 0640 "$target_path"
                setfacl -b "$target_path" 2>/dev/null || true
                setfacl -m "u:${r_user}:-w-" "$target_path"
                setfacl -m "m::-w-" "$target_path"
            fi
            ;;
        "RWX")
            # Full access: restore original user ownership and clear restriction ACLs
            setfacl -R -b "$target_path" 2>/dev/null || true
            chown -R "${orig_owner}:${orig_group}" "$target_path"
            if [[ -d "$target_path" ]]; then
                find "$target_path" -type d -exec chmod 0755 {} +
                find "$target_path" -type f -exec chmod 0644 {} +
            else
                chmod 0644 "$target_path"
            fi
            ;;
        *)
            local acl_str
            acl_str="$(printf '%s' "$rwx" | tr '[:upper:]' '[:lower:]')"
            chown -R root:root "$target_path"
            chmod -R go-rwx "$target_path"
            setfacl -R -b "$target_path" 2>/dev/null || true
            setfacl -R -m "u:${r_user}:${acl_str}" "$target_path"
            if [[ -d "$target_path" ]]; then
                setfacl -R -m "d:u:${r_user}:${acl_str}" "$target_path"
            fi
            ;;
    esac
}

enforce_all_perms() {
    local r_user="$1"
    local user_home r_group
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"
    r_group="$(id -gn "$r_user")"
    pc_ensure_config_exists

    local dump
    dump="$(python3 - "$PC_CONFIG_FILE" "$r_user" "$r_group" << 'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
def_owner, def_group = sys.argv[2], sys.argv[3]
perms = cfg.get("permissions", {})
presets = perms.get("presets", {})
print("PRESET|lock_dotfiles|" + ("1" if presets.get("lock_dotfiles") else "0"))
print("PRESET|restrict_extra_home_dirs|" + ("1" if presets.get("restrict_extra_home_dirs") else "0"))
print("PRESET|noexec_user_dirs|" + ("1" if presets.get("noexec_user_dirs") else "0"))
for r in perms.get("custom_rules", []):
    p_val = r.get("path", "")
    r_val = r.get("perms", "R-X")
    o_val = r.get("orig_owner") or def_owner
    g_val = r.get("orig_group") or def_group
    print(f"RULE|{p_val}|{r_val}|{o_val}|{g_val}")
PYEOF
)"

    local lock_dot="0" restrict_extra="0" noexec_dirs="0"
    while IFS='|' read -r kind a b c d; do
        if [[ "$kind" == "PRESET" ]]; then
            [[ "$a" == "lock_dotfiles" ]] && lock_dot="$b"
            [[ "$a" == "restrict_extra_home_dirs" ]] && restrict_extra="$b"
            [[ "$a" == "noexec_user_dirs" ]] && noexec_dirs="$b"
        elif [[ "$kind" == "RULE" && -n "$a" ]]; then
            apply_single_acl_rule "$r_user" "$a" "$b" "$c" "$d"
        fi
    done <<< "$dump"

    for df in ".bashrc" ".profile" ".bash_aliases" ".zshrc"; do
        local fpath="${user_home}/${df}"
        if [[ -f "$fpath" ]]; then
            if [[ "$lock_dot" == "1" ]]; then
                chown root:root "$fpath"
                chmod 0644 "$fpath"
            else
                chown "${r_user}:${r_group}" "$fpath"
                chmod 0644 "$fpath"
            fi
        fi
    done

    for hdir in /home/*; do
        [[ -d "$hdir" ]] || continue
        [[ "$hdir" == "$user_home" ]] && continue
        if [[ "$restrict_extra" == "1" ]]; then
            setfacl -m "u:${r_user}:---" "$hdir" 2>/dev/null || true
        else
            setfacl -x "u:${r_user}" "$hdir" 2>/dev/null || true
        fi
    done

    if [[ "$noexec_dirs" == "1" ]]; then
        for d in "${user_home}/Downloads" "${user_home}/Desktop" "/tmp"; do
            [[ -d "$d" ]] || continue
            find "$d" -maxdepth 4 -type f -user "$r_user" -exec chmod a-x {} + 2>/dev/null || true
        done
    fi
}

build_perms_state_json() {
    pc_ensure_config_exists
    python3 - "$PC_CONFIG_FILE" << 'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
perms = cfg.get("permissions", {})
r_user = cfg.get("restricted_user", "")
print(json.dumps({
    "restricted_user": r_user,
    "default_browse_dir": "/home/" + r_user if r_user else "/home",
    "presets": perms.get("presets", {
        "lock_dotfiles": False,
        "restrict_extra_home_dirs": False,
        "noexec_user_dirs": False
    }),
    "custom_rules": perms.get("custom_rules", [])
}))
PYEOF
}

handle_set() {
    [[ -z "$TARGET_PATH" ]] && { pc_emit_error "Missing --path <directory>." 2; exit 2; }

    local r_user user_home resolved_path
    r_user="$(get_restricted_user)"
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"

    local rc=0
    resolved_path="$(resolve_safe_user_path "$TARGET_PATH" "$user_home")" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        pc_emit_error "Refusing to modify protected system directory: '${TARGET_PATH}'" 2
        exit 2
    elif [[ "$rc" -ne 0 || ! -e "$resolved_path" ]]; then
        pc_emit_error "Target path does not exist: '${resolved_path:-$TARGET_PATH}'" 2
        exit 2
    fi

    local norm_info rwx_val mode_label
    norm_info="$(normalize_rwx_and_label "$TARGET_MODE" "$TARGET_PERMS" "$resolved_path")"
    IFS='|' read -r rwx_val mode_label <<< "$norm_info"

    local cur_owner cur_group
    cur_owner="$(stat -c '%U' "$resolved_path")"
    cur_group="$(stat -c '%G' "$resolved_path")"
    [[ "$cur_owner" == "root" ]] && cur_owner="$r_user"
    [[ "$cur_group" == "root" ]] && cur_group="$(id -gn "$r_user")"

    pc_init_transaction
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg owner_pair
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    owner_pair="$(python3 - "$PC_CONFIG_FILE" "$resolved_path" "$rwx_val" "$mode_label" "$cur_owner" "$cur_group" "$tmp_cfg" << 'PYEOF'
import json, sys

cfg_path, path_val, rwx_str, label_str, def_o, def_g, out_path = sys.argv[1:8]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
perms = data.setdefault("permissions", {"presets": {}, "custom_rules": []})

orig_o, orig_g = def_o, def_g
kept = []
for r in perms.get("custom_rules", []):
    if r.get("path") == path_val:
        if r.get("orig_owner") and r.get("orig_owner") != "root":
            orig_o = r["orig_owner"]
        if r.get("orig_group") and r.get("orig_group") != "root":
            orig_g = r["orig_group"]
    else:
        kept.append(r)

kept.append({
    "path": path_val,
    "perms": rwx_str,
    "label": label_str,
    "orig_owner": orig_o,
    "orig_group": orig_g
})
kept.sort(key=lambda x: x.get("path", ""))
perms["custom_rules"] = kept

with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")

print(f"{orig_o}|{orig_g}")
PYEOF
)"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    local saved_owner saved_group
    IFS='|' read -r saved_owner saved_group <<< "$owner_pair"

    apply_single_acl_rule "$r_user" "$resolved_path" "$rwx_val" "$saved_owner" "$saved_group"
    pc_commit_transaction

    pc_emit_result "Set permissions on '${resolved_path}' to ${mode_label} (${rwx_val})" "$(build_perms_state_json)"
}

handle_remove() {
    [[ -z "$TARGET_PATH" ]] && { pc_emit_error "Missing --path <directory>." 2; exit 2; }

    local r_user user_home resolved_path
    r_user="$(get_restricted_user)"
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"
    resolved_path="$(resolve_safe_user_path "$TARGET_PATH" "$user_home" 2>/dev/null || printf '%s' "$TARGET_PATH")"

    pc_init_transaction
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg removed_info
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"
    removed_info="$(python3 - "$PC_CONFIG_FILE" "$resolved_path" "$r_user" "$(id -gn "$r_user")" "$tmp_cfg" << 'PYEOF'
import json, sys
cfg_path, p_val, def_o, def_g, out_path = sys.argv[1:6]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
perms = data.setdefault("permissions", {"presets": {}, "custom_rules": []})
old = perms.get("custom_rules", [])
new = []
orig_o, orig_g = def_o, def_g
found = False
for r in old:
    if r.get("path") == p_val:
        found = True
        orig_o = r.get("orig_owner") or def_o
        orig_g = r.get("orig_group") or def_g
    else:
        new.append(r)

perms["custom_rules"] = new
with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
print(("1" if found else "0") + f"|{orig_o}|{orig_g}")
PYEOF
)"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    local was_removed orig_owner orig_group
    IFS='|' read -r was_removed orig_owner orig_group <<< "$removed_info"

    if [[ "$was_removed" != "1" ]]; then
        pc_commit_transaction
        pc_emit_error "No saved permission rule found for '${resolved_path}'." 2
        exit 2
    fi

    apply_single_acl_rule "$r_user" "$resolved_path" "RWX" "$orig_owner" "$orig_group"

    pc_commit_transaction
    pc_emit_result "Removed permission rule for '${resolved_path}'" "$(build_perms_state_json)"
}

handle_preset() {
    case "$PRESET_NAME" in
        lock_dotfiles|restrict_extra_home_dirs|noexec_user_dirs) ;;
        *) pc_emit_error "Invalid --name '${PRESET_NAME}'." 2; exit 2 ;;
    esac
    if [[ "$PRESET_ENABLED" != "true" && "$PRESET_ENABLED" != "false" ]]; then
        pc_emit_error "Action 'preset' requires --enabled <true|false>." 2
        exit 2
    fi

    local r_user
    r_user="$(get_restricted_user)"
    pc_init_transaction
    pc_json_set "permissions.presets.${PRESET_NAME}" "$PRESET_ENABLED"
    enforce_all_perms "$r_user"
    pc_commit_transaction

    pc_emit_result "Set preset '${PRESET_NAME}' to ${PRESET_ENABLED}" "$(build_perms_state_json)"
}

main() {
    parse_perms_args "$@"
    pc_require_root
    pc_verify_mint

    case "$PERMS_ACTION" in
        set)    handle_set ;;
        remove) handle_remove ;;
        preset) handle_preset ;;
        list)   pc_emit_result "Retrieved directory permission rules and presets" "$(build_perms_state_json)" ;;
        apply)
            local r_user
            r_user="$(get_restricted_user)"
            pc_init_transaction
            enforce_all_perms "$r_user"
            pc_commit_transaction
            pc_emit_result "Applied all directory permission rules" "$(build_perms_state_json)"
            ;;
        *) pc_emit_error "Unsupported perms action '${PERMS_ACTION}'." 2; exit 2 ;;
    esac
}

main "$@"
PC_PERMS_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-perms.sh
    chmod 0755 /opt/parentcontrol/bin/pc-perms.sh
}


# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-ports.sh (Sub-Chunk 4.1)
# ------------------------------------------------------------------------------
deploy_pc_ports_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-ports.sh..."

    cat << 'PC_PORTS_SH_EOF' > /opt/parentcontrol/bin/pc-ports.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Network Port & Risky Service Firewall Manager
# File: /opt/parentcontrol/bin/pc-ports.sh
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="ports"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages UFW network port blocks (defaulting to BOTH TCP+UDP) and risky service presets."
PC_SCRIPT_USAGE="pc-ports.sh --action <block|unblock|block-preset|list-presets|list|apply> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>     block, unblock, block-preset, list-presets, list, apply
      --port <1-65535>    Port number to block or unblock
      --protocol <proto>  TCP | UDP | BOTH (defaults to BOTH)
      --preset <name>     risky | ftp | ssh | telnet | smb | rdp | vnc"

PORTS_ACTION=""
TARGET_PORT=""
TARGET_PROTOCOL="BOTH"
TARGET_PRESET=""

parse_ports_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)   PORTS_ACTION="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --port)     TARGET_PORT="${2:-}"; shift 2 ;;
            --protocol) TARGET_PROTOCOL="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
            --preset)   TARGET_PRESET="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            *) pc_emit_error "Unknown flag for pc-ports.sh: $1" 2; exit 2 ;;
        esac
    done

    if [[ -z "$PORTS_ACTION" ]]; then
        pc_emit_error "Missing required --action flag." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$PORTS_ACTION"
}

get_service_label_for_port() {
    case "$1" in
        21)   printf 'FTP (21)' ;;
        22)   printf 'SSH (22)' ;;
        23)   printf 'Telnet (23)' ;;
        139)  printf 'NetBIOS / SMB (139)' ;;
        445)  printf 'SMB File Sharing (445)' ;;
        3389) printf 'RDP Remote Desktop (3389)' ;;
        5900) printf 'VNC Screen Sharing (5900)' ;;
        *)    printf 'Port %s' "$1" ;;
    esac
}

expand_preset_ports() {
    case "$1" in
        ftp)    printf '21' ;;
        ssh)    printf '22' ;;
        telnet) printf '23' ;;
        smb)    printf '139 445' ;;
        rdp)    printf '3389' ;;
        vnc)    printf '5900' ;;
        risky|default|all) printf '21 22 23 139 445 3389 5900' ;;
        *) return 1 ;;
    esac
}

ensure_ufw_ready() {
    if ! command -v ufw >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null
    fi
    if ! ufw status 2>/dev/null | grep -q "^Status: active"; then
        ufw --force enable >/dev/null 2>&1 || true
    fi
}

apply_ufw_port_rule() {
    local mode="$1"
    local port="$2"
    local proto="$3"

    ensure_ufw_ready
    local protos=()
    if [[ "$proto" == "BOTH" ]]; then
        protos=("tcp" "udp")
    else
        protos=("$(printf '%s' "$proto" | tr '[:upper:]' '[:lower:]')")
    fi

    for p in "${protos[@]}"; do
        if [[ "$mode" == "block" ]]; then
            ufw deny out "${port}/${p}" comment "ParentControl-Port" >/dev/null 2>&1 || true
            ufw deny in "${port}/${p}" comment "ParentControl-Port" >/dev/null 2>&1 || true
        else
            ufw delete deny out "${port}/${p}" >/dev/null 2>&1 || true
            ufw delete deny in "${port}/${p}" >/dev/null 2>&1 || true
        fi
    done
}

build_ports_state_json() {
    pc_ensure_config_exists
    local ufw_on="false"
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "^Status: active"; then
        ufw_on="true"
    fi

    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
blocked = cfg.get("network", {}).get("blocked_ports", [])
print(json.dumps({
    "ufw_active": sys.argv[2] == "true",
    "default_protocol": "BOTH",
    "blocked_ports": blocked
}))
' "$PC_CONFIG_FILE" "$ufw_on"
}

save_port_entry() {
    local port_num="$1"
    local proto="$2"
    local label="$3"

    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"
    python3 -c '
import json, sys
cfg_path, p_num, proto_str, lbl, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
net = data.setdefault("network", {})
ports = [x for x in net.get("blocked_ports", []) if int(x.get("port", -1)) != p_num]
ports.append({"port": p_num, "protocol": proto_str, "label": lbl})
ports.sort(key=lambda x: int(x.get("port", 0)))
net["blocked_ports"] = ports
with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
' "$PC_CONFIG_FILE" "$port_num" "$proto" "$label" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"
}

handle_block() {
    if [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]] || (( TARGET_PORT < 1 || TARGET_PORT > 65535 )); then
        pc_emit_error "Port must be an integer between 1 and 65535." 2
        exit 2
    fi
    case "$TARGET_PROTOCOL" in
        TCP|UDP|BOTH) ;;
        *) pc_emit_error "Protocol must be TCP, UDP, or BOTH." 2; exit 2 ;;
    esac

    local label
    label="$(get_service_label_for_port "$TARGET_PORT")"

    pc_init_transaction
    save_port_entry "$TARGET_PORT" "$TARGET_PROTOCOL" "$label"
    apply_ufw_port_rule "block" "$TARGET_PORT" "$TARGET_PROTOCOL"
    pc_commit_transaction

    pc_emit_result "Blocked ${label} (${TARGET_PROTOCOL}) via UFW" "$(build_ports_state_json)"
}

handle_unblock() {
    if [[ ! "$TARGET_PORT" =~ ^[0-9]+$ ]]; then
        pc_emit_error "Missing or invalid --port <1-65535>." 2
        exit 2
    fi

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"
    python3 -c '
import json, sys
cfg_path, p_num, out_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
net = data.setdefault("network", {})
net["blocked_ports"] = [x for x in net.get("blocked_ports", []) if int(x.get("port", -1)) != p_num]
with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
' "$PC_CONFIG_FILE" "$TARGET_PORT" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    apply_ufw_port_rule "unblock" "$TARGET_PORT" "BOTH"
    pc_commit_transaction

    pc_emit_result "Unblocked port ${TARGET_PORT}" "$(build_ports_state_json)"
}

handle_block_preset() {
    local preset_key="${TARGET_PRESET:-risky}"
    local port_list
    if ! port_list="$(expand_preset_ports "$preset_key")"; then
        pc_emit_error "Unknown port preset '${preset_key}' (expected: risky, ftp, ssh, telnet, smb, rdp, vnc)." 2
        exit 2
    fi

    pc_init_transaction
    for p in $port_list; do
        local lbl
        lbl="$(get_service_label_for_port "$p")"
        save_port_entry "$p" "BOTH" "$lbl"
        apply_ufw_port_rule "block" "$p" "BOTH"
    done
    pc_commit_transaction

    pc_emit_result "Blocked port preset '${preset_key}' (TCP+UDP)" "$(build_ports_state_json)"
}

handle_list_presets() {
    local presets_json='{"presets": [
      {"id": "risky", "label": "All Common Risky Ports (FTP, SSH, Telnet, SMB, RDP, VNC)", "ports": [21, 22, 23, 139, 445, 3389, 5900]},
      {"id": "rdp", "label": "RDP - Remote Desktop (3389)", "ports": [3389]},
      {"id": "telnet", "label": "Telnet - Unencrypted Remote Access (23)", "ports": [23]},
      {"id": "ftp", "label": "FTP - File Transfer Protocol (21)", "ports": [21]},
      {"id": "smb", "label": "SMB - Network File Sharing (139, 445)", "ports": [139, 445]},
      {"id": "vnc", "label": "VNC - Remote Screen Sharing (5900)", "ports": [5900]},
      {"id": "ssh", "label": "SSH - Remote Shell (22)", "ports": [22]}
    ]}'
    pc_emit_result "Retrieved network port presets" "$presets_json"
}

main() {
    parse_ports_args "$@"
    pc_require_root
    pc_verify_mint

    case "$PORTS_ACTION" in
        block)        handle_block ;;
        unblock)      handle_unblock ;;
        block-preset) handle_block_preset ;;
        list-presets) handle_list_presets ;;
        list)         pc_emit_result "Retrieved blocked network ports" "$(build_ports_state_json)" ;;
        apply)
            pc_init_transaction
            local saved_ports
            saved_ports="$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
for p in cfg.get("network", {}).get("blocked_ports", []):
    print(f"{p.get(\"port\")}|{p.get(\"protocol\", \"BOTH\")}")
' "$PC_CONFIG_FILE")"
            while IFS='|' read -r sp spr; do
                [[ -n "$sp" ]] && apply_ufw_port_rule "block" "$sp" "$spr"
            done <<< "$saved_ports"
            pc_commit_transaction
            pc_emit_result "Applied all UFW port rules" "$(build_ports_state_json)"
            ;;
        *) pc_emit_error "Unsupported ports action '${PORTS_ACTION}'." 2; exit 2 ;;
    esac
}

main "$@"
PC_PORTS_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-ports.sh
    chmod 0755 /opt/parentcontrol/bin/pc-ports.sh
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-devices.sh (Sub-Chunk 4.2)
# ------------------------------------------------------------------------------
deploy_pc_devices_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-devices.sh..."

    cat << 'PC_DEVICES_SH_EOF' > /opt/parentcontrol/bin/pc-devices.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Hardware & Peripheral Access Control Manager
# File: /opt/parentcontrol/bin/pc-devices.sh
#
# Description:
#   Manages hardware peripheral restrictions (USB mass storage, webcam,
#   microphone, Bluetooth) in config.json and enforces them across modprobe,
#   udev rules, device nodes, and rfkill on Linux Mint 22.3.
#
# GUI HANDOFF:
#   Invoked via pc-ctl.sh:
#     pkexec /opt/parentcontrol/bin/pc-ctl.sh devices --action <verb> [OPTIONS] --json
#
#   Supported Actions:
#     block   --device <usb_storage|webcam|microphone|bluetooth> --json
#     unblock --device <usb_storage|webcam|microphone|bluetooth> --json
#     set     --device <usb_storage|webcam|microphone|bluetooth> --blocked <true|false> --json
#     list    --json
#     apply   --json
#
#   JSON Data Schema (--action list --json):
#     {
#       "devices": {
#         "usb_storage": false,
#         "webcam": false,
#         "microphone": false,
#         "bluetooth": false
#       },
#       "rules": [
#         {"device": "usb_storage", "label": "USB Mass Storage", "blocked": false},
#         {"device": "webcam", "label": "Webcam / Camera", "blocked": false},
#         {"device": "microphone", "label": "Microphone / Audio Input", "blocked": false},
#         {"device": "bluetooth", "label": "Bluetooth", "blocked": false}
#       ]
#     }
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="devices"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages hardware peripheral blocks (USB storage, webcam, microphone, Bluetooth)."
PC_SCRIPT_USAGE="pc-devices.sh --action <block|unblock|set|list|apply> [--device <name>] [--blocked <true|false>] [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         block, unblock, set, list, apply
      --device <name>         usb_storage | webcam | microphone | bluetooth
      --blocked <true|false>  Target state when using --action set"

readonly PC_MODPROBE_CONF="/etc/modprobe.d/parentcontrol-devices.conf"
readonly PC_UDEV_RULES="/etc/udev/rules.d/99-parentcontrol-devices.rules"

DEVICES_ACTION=""
TARGET_DEVICE=""
TARGET_BLOCKED=""

# ------------------------------------------------------------------------------
# Parse Module-Specific Flags
# ------------------------------------------------------------------------------
parse_devices_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                DEVICES_ACTION="${2:-}"
                shift 2
                ;;
            --device)
                TARGET_DEVICE="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
                shift 2
                ;;
            --blocked)
                TARGET_BLOCKED="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for pc-devices.sh: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$DEVICES_ACTION" ]]; then
        pc_emit_error "Missing required --action <block|unblock|set|list|apply>." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$DEVICES_ACTION"
}

validate_device_name() {
    case "$TARGET_DEVICE" in
        usb_storage|webcam|microphone|bluetooth)
            ;;
        *)
            pc_emit_error "Invalid --device '${TARGET_DEVICE}'. Must be one of: usb_storage, webcam, microphone, bluetooth." 2
            exit 2
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Enforce Device Rules via modprobe, udev, /dev/snd, and rfkill
# ------------------------------------------------------------------------------
enforce_device_rules() {
    pc_ensure_config_exists

    pc_backup_file "$PC_MODPROBE_CONF"
    pc_backup_file "$PC_UDEV_RULES"

    mkdir -p /etc/modprobe.d /etc/udev/rules.d

    local state_flags
    state_flags="$(python3 -c '
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)

devs = cfg.get("devices", {})
usb = "1" if devs.get("usb_storage", False) else "0"
cam = "1" if devs.get("webcam", False) else "0"
mic = "1" if devs.get("microphone", False) else "0"
bt  = "1" if devs.get("bluetooth", False) else "0"
print(f"{usb}|{cam}|{mic}|{bt}")
' "$PC_CONFIG_FILE")"

    local block_usb block_cam block_mic block_bt
    IFS='|' read -r block_usb block_cam block_mic block_bt <<< "$state_flags"

    local tmp_modprobe tmp_udev
    tmp_modprobe="$(mktemp /tmp/pc-modprobe.XXXXXX)"
    tmp_udev="$(mktemp /tmp/pc-udev.XXXXXX)"

    cat << 'HEADER_EOF' > "$tmp_modprobe"
# Managed by ParentControl (pc-devices.sh) - DO NOT EDIT MANUALLY
HEADER_EOF

    cat << 'HEADER_EOF' > "$tmp_udev"
# Managed by ParentControl (pc-devices.sh) - DO NOT EDIT MANUALLY
HEADER_EOF

    # 1. USB Mass Storage (preserves USB keyboards/mice via HID class 03)
    if [[ "$block_usb" == "1" ]]; then
        cat << 'EOF' >> "$tmp_modprobe"
blacklist usb-storage
install usb-storage /bin/false
blacklist uas
install uas /bin/false
EOF
        cat << 'EOF' >> "$tmp_udev"
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="08", RUN+="/bin/sh -c 'echo 0 > /sys$devpath/../authorized 2>/dev/null || true'"
EOF
        modprobe -r uas 2>/dev/null || true
        modprobe -r usb_storage 2>/dev/null || true
    fi

    # 2. Webcam / Video Capture
    if [[ "$block_cam" == "1" ]]; then
        cat << 'EOF' >> "$tmp_modprobe"
blacklist uvcvideo
install uvcvideo /bin/false
EOF
        cat << 'EOF' >> "$tmp_udev"
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="0e", RUN+="/bin/sh -c 'echo 0 > /sys$devpath/../authorized 2>/dev/null || true'"
EOF
        modprobe -r uvcvideo 2>/dev/null || true
    fi

    # 3. Microphone / ALSA Capture Nodes (preserves speaker playback nodes pcm*p)
    if [[ "$block_mic" == "1" ]]; then
        cat << 'EOF' >> "$tmp_udev"
SUBSYSTEM=="sound", KERNEL=="pcm*c", MODE="0000", OPTIONS+="last_rule"
EOF
    fi

    # 4. Bluetooth
    if [[ "$block_bt" == "1" ]]; then
        cat << 'EOF' >> "$tmp_modprobe"
blacklist btusb
install btusb /bin/false
blacklist bluetooth
install bluetooth /bin/false
EOF
        cat << 'EOF' >> "$tmp_udev"
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="e0", ATTR{bInterfaceSubClass}=="01", ATTR{bInterfaceProtocol}=="01", RUN+="/bin/sh -c 'echo 0 > /sys$devpath/../authorized 2>/dev/null || true'"
EOF
        if command -v rfkill >/dev/null 2>&1; then
            rfkill block bluetooth >/dev/null 2>&1 || true
        fi
        modprobe -r btusb 2>/dev/null || true
    else
        if command -v rfkill >/dev/null 2>&1; then
            rfkill unblock bluetooth >/dev/null 2>&1 || true
        fi
    fi

    chown root:root "$tmp_modprobe" "$tmp_udev"
    chmod 0644 "$tmp_modprobe" "$tmp_udev"
    mv "$tmp_modprobe" "$PC_MODPROBE_CONF"
    mv "$tmp_udev" "$PC_UDEV_RULES"

    if command -v udevadm >/dev/null 2>&1; then
        udevadm control --reload-rules >/dev/null 2>&1 || true
    fi

    # Apply or restore live microphone capture node permissions immediately
    if [[ "$block_mic" == "1" ]]; then
        shopt -s nullglob
        for cap_dev in /dev/snd/pcm*c; do
            setfacl -b "$cap_dev" 2>/dev/null || true
            chmod 0000 "$cap_dev" 2>/dev/null || true
        done
        shopt -u nullglob
    else
        if command -v udevadm >/dev/null 2>&1; then
            udevadm trigger --subsystem-match=sound >/dev/null 2>&1 || true
        fi
    fi

    pc_log "INFO" "Enforced device policies (usb_storage=${block_usb}, webcam=${block_cam}, microphone=${block_mic}, bluetooth=${block_bt})."
}

# ------------------------------------------------------------------------------
# Build Standardized Devices State JSON for GUI Hydration
# ------------------------------------------------------------------------------
build_devices_state_json() {
    pc_ensure_config_exists

    python3 -c '
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)

devs = cfg.get("devices", {})
state = {
    "usb_storage": bool(devs.get("usb_storage", False)),
    "webcam": bool(devs.get("webcam", False)),
    "microphone": bool(devs.get("microphone", False)),
    "bluetooth": bool(devs.get("bluetooth", False))
}

labels = {
    "usb_storage": "USB Mass Storage",
    "webcam": "Webcam / Camera",
    "microphone": "Microphone / Audio Input",
    "bluetooth": "Bluetooth"
}

rules = [
    {"device": key, "label": labels[key], "blocked": state[key]}
    for key in ("usb_storage", "webcam", "microphone", "bluetooth")
]

print(json.dumps({
    "devices": state,
    "rules": rules
}))
' "$PC_CONFIG_FILE"
}

# ------------------------------------------------------------------------------
# Action Handlers
# ------------------------------------------------------------------------------
set_device_blocked_state() {
    local dev_name="$1"
    local is_blocked="$2" # "true" or "false"

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, dev_key, blocked_str, out_path = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

devs = data.setdefault("devices", {
    "usb_storage": False,
    "webcam": False,
    "microphone": False,
    "bluetooth": False
})
devs[dev_key] = (blocked_str == "true")

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$PC_CONFIG_FILE" "$dev_name" "$is_blocked" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    enforce_device_rules
    pc_commit_transaction

    local verb_word="Blocked"
    [[ "$is_blocked" == "false" ]] && verb_word="Unblocked"

    local state_json
    state_json="$(build_devices_state_json)"
    pc_emit_result "${verb_word} hardware device '${dev_name}'" "$state_json"
}

handle_block() {
    validate_device_name
    set_device_blocked_state "$TARGET_DEVICE" "true"
}

handle_unblock() {
    validate_device_name
    set_device_blocked_state "$TARGET_DEVICE" "false"
}

handle_set() {
    validate_device_name
    if [[ "$TARGET_BLOCKED" != "true" && "$TARGET_BLOCKED" != "false" ]]; then
        pc_emit_error "Action 'set' requires --blocked <true|false>." 2
        exit 2
    fi
    set_device_blocked_state "$TARGET_DEVICE" "$TARGET_BLOCKED"
}

handle_list() {
    local state_json
    state_json="$(build_devices_state_json)"
    pc_emit_result "Retrieved hardware device control states" "$state_json"
}

handle_apply() {
    pc_init_transaction
    enforce_device_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_devices_state_json)"
    pc_emit_result "Applied all hardware device control rules" "$state_json"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_devices_args "$@"
    pc_require_root
    pc_verify_mint

    case "$DEVICES_ACTION" in
        block)
            handle_block
            ;;
        unblock)
            handle_unblock
            ;;
        set)
            handle_set
            ;;
        list)
            handle_list
            ;;
        apply)
            handle_apply
            ;;
        *)
            pc_emit_error "Unsupported action '${DEVICES_ACTION}' (expected: block, unblock, set, list, apply)." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_DEVICES_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-devices.sh
    chmod 0755 /opt/parentcontrol/bin/pc-devices.sh
}


# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-apps.sh (Part 5)
# ------------------------------------------------------------------------------
deploy_pc_apps_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-apps.sh..."

    cat << 'PC_APPS_SH_EOF' > /opt/parentcontrol/bin/pc-apps.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Application & Package Governance Manager
# File: /opt/parentcontrol/bin/pc-apps.sh
#
# Description:
#   Manages per-user application Allow/Block rules (via POSIX ACLs on binaries
#   plus root-owned .desktop menu/Desktop hiding), Software Manager/APT lock
#   policies, and explicit package uninstalls on Linux Mint 22.3.
#
# GUI HANDOFF:
#   Invoked via pc-ctl.sh:
#     pkexec /opt/parentcontrol/bin/pc-ctl.sh apps --action <verb> [OPTIONS] --json
#
#   Supported Actions:
#     block            --app <name|desktop|binary> --json
#     allow            --app <name|desktop|binary> --json   (alias: unblock)
#     set              --app <name|desktop|binary> --status <Allow|Block> --json
#     remove           --app <name|desktop|binary> --json
#     lock-installers  --enabled <true|false> --json
#     uninstall        --app <name|desktop|binary|pkg> --json
#     scan             --json
#     list             --json
#     apply            --json
#
#   JSON Data Schema (--action list --json):
#     {
#       "restricted_user": "mint",
#       "lock_installers": false,
#       "rules": [
#         {
#           "app": "Calculator",
#           "name": "Calculator",
#           "desktop_id": "org.gnome.Calculator.desktop",
#           "binary_path": "/usr/bin/gnome-calculator",
#           "flatpak_id": "",
#           "status": "block"
#         }
#       ]
#     }
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="apps"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages application Allow/Block rules, icon hiding, installer locks, and package removal."
PC_SCRIPT_USAGE="pc-apps.sh --action <block|allow|set|remove|lock-installers|uninstall|scan|list|apply> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         block, allow, set, remove, lock-installers, uninstall, scan, list, apply
      --app <identifier>      Desktop Name, .desktop filename, command, or package name
      --status <Allow|Block>  Target state when using --action set
      --enabled <true|false>  Target state when using --action lock-installers"

readonly PC_DESKTOP_QUARANTINE_BASE="${PC_VAR_DIR}/quarantine/desktop"

APPS_ACTION=""
TARGET_APP=""
TARGET_STATUS=""
LOCK_ENABLED=""

# ------------------------------------------------------------------------------
# Parse Module-Specific Flags
# ------------------------------------------------------------------------------
parse_apps_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                APPS_ACTION="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --app)
                TARGET_APP="${2:-}"
                shift 2
                ;;
            --status)
                TARGET_STATUS="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --enabled)
                LOCK_ENABLED="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for pc-apps.sh: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$APPS_ACTION" ]]; then
        pc_emit_error "Missing required --action <block|allow|set|remove|lock-installers|uninstall|scan|list|apply>." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$APPS_ACTION"
}

# ------------------------------------------------------------------------------
# Helpers: ACL Tool & Restricted User Lookup
# ------------------------------------------------------------------------------
ensure_acl_tool() {
    if ! command -v setfacl >/dev/null 2>&1; then
        pc_log "INFO" "setfacl not found; installing 'acl' package..."
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq acl >/dev/null
    fi
}

get_restricted_user() {
    pc_ensure_config_exists
    local r_user
    r_user="$(pc_json_get "restricted_user" 2>/dev/null || true)"
    if [[ -z "$r_user" ]]; then
        pc_emit_error "No restricted_user configured in config.json. Run pc-setup.sh first." 2
        exit 2
    fi
    if ! id -u "$r_user" >/dev/null 2>&1; then
        pc_emit_error "Configured restricted_user '${r_user}' does not exist on this system." 1
        exit 1
    fi
    printf '%s' "$r_user"
}

# ------------------------------------------------------------------------------
# Safeguard: Never Block Essential Desktop / Session / System Binaries
# ------------------------------------------------------------------------------
is_protected_binary() {
    local bin_path="$1"
    [[ -z "$bin_path" ]] && return 0

    local base
    base="$(basename "$bin_path")"
    case "$base" in
        bash|sh|dash|zsh|sudo|su|pkexec|polkitd|systemd|init|lightdm|slick-greeter|\
        cinnamon|cinnamon-session|cinnamon-settings|nemo|muffin|Xorg|dbus-daemon|\
        python3|python3.*|perl|env|coreutils|login|passwd|chpasswd|setfacl|getfacl|\
        flatpak|snap|apt|apt-get|dpkg)
            return 0
            ;;
    esac
    return 1
}

# ------------------------------------------------------------------------------
# Resolve Application Metadata from .desktop Files or $PATH
# Outputs JSON: {"name":..., "desktop_id":..., "exec_cmd":..., "binary_path":..., "flatpak_id":...}
# ------------------------------------------------------------------------------
resolve_app_metadata() {
    local query="$1"
    local user_home="$2"

    python3 -c '
import glob, json, os, shlex, shutil, sys

query = sys.argv[1].strip()
user_home = sys.argv[2].strip()
q_lower = query.lower()

search_dirs = [
    "/usr/share/applications",
    "/usr/local/share/applications",
    "/var/lib/flatpak/exports/share/applications",
]
if user_home:
    search_dirs.append(os.path.join(user_home, ".local/share/applications"))
    search_dirs.append(os.path.join(user_home, ".local/share/flatpak/exports/share/applications"))

def parse_desktop(path):
    name = ""
    exec_raw = ""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            in_main = False
            for line in f:
                s = line.strip()
                if s.startswith("[") and s.endswith("]"):
                    in_main = (s == "[Desktop Entry]")
                    continue
                if not in_main or "=" not in s or s.startswith("#"):
                    continue
                k, v = s.split("=", 1)
                if k == "Name" and not name:
                    name = v.strip()
                elif k == "Exec" and not exec_raw:
                    exec_raw = v.strip()
    except Exception:
        return None
    if not name and not exec_raw:
        return None
    return {"name": name, "exec_raw": exec_raw, "desktop_id": os.path.basename(path)}

def extract_exec_details(exec_raw):
    if not exec_raw:
        return "", "", ""
    try:
        tokens = shlex.split(exec_raw)
    except ValueError:
        tokens = exec_raw.split()

    # Strip env wrapper if present (e.g., env BAMF_DESKTOP_FILE_HINT=... cmd)
    idx = 0
    if tokens and os.path.basename(tokens[0]) == "env":
        idx = 1
        while idx < len(tokens) and "=" in tokens[idx] and not tokens[idx].startswith("/"):
            idx += 1
    tokens = tokens[idx:]
    if not tokens:
        return "", "", ""

    cmd = tokens[0]
    base_cmd = os.path.basename(cmd)
    flatpak_id = ""
    if base_cmd == "flatpak" and "run" in tokens[1:]:
        run_idx = tokens.index("run")
        for arg in tokens[run_idx + 1:]:
            if not arg.startswith("-") and not arg.startswith("%"):
                flatpak_id = arg
                break

    bin_path = ""
    if not flatpak_id:
        if os.path.isabs(cmd) and os.path.exists(cmd):
            bin_path = os.path.realpath(cmd)
        else:
            found = shutil.which(cmd)
            if found:
                bin_path = os.path.realpath(found)

    return base_cmd, bin_path, flatpak_id

entries = []
seen_ids = set()
for d in search_dirs:
    if not os.path.isdir(d):
        continue
    for fp in sorted(glob.glob(os.path.join(d, "*.desktop"))):
        did = os.path.basename(fp)
        if did in seen_ids:
            continue
        parsed = parse_desktop(fp)
        if parsed:
            seen_ids.add(did)
            entries.append(parsed)

matched = None
# Pass 1: Exact Name= match
for e in entries:
    if e["name"].lower() == q_lower:
        matched = e
        break

# Pass 2: Exact .desktop filename match
if not matched:
    q_did = q_lower if q_lower.endswith(".desktop") else f"{q_lower}.desktop"
    for e in entries:
        if e["desktop_id"].lower() == q_did:
            matched = e
            break

# Pass 3: Exec command match
if not matched:
    for e in entries:
        base_cmd, _, fp_id = extract_exec_details(e["exec_raw"])
        if base_cmd.lower() == q_lower or (fp_id and fp_id.lower() == q_lower):
            matched = e
            break

if matched:
    base_cmd, bin_path, fp_id = extract_exec_details(matched["exec_raw"])
    print(json.dumps({
        "name": matched["name"] or query,
        "desktop_id": matched["desktop_id"],
        "exec_cmd": base_cmd,
        "binary_path": bin_path,
        "flatpak_id": fp_id
    }))
    sys.exit(0)

# Fallback: Direct binary or Flatpak ID without .desktop file
bin_path = ""
if os.path.isabs(query) and os.path.exists(query):
    bin_path = os.path.realpath(query)
else:
    found = shutil.which(query)
    if found:
        bin_path = os.path.realpath(found)

flatpak_id = query if (query.count(".") >= 2 and "/" not in query and not bin_path) else ""

print(json.dumps({
    "name": query,
    "desktop_id": "",
    "exec_cmd": os.path.basename(bin_path) if bin_path else query,
    "binary_path": bin_path,
    "flatpak_id": flatpak_id
}))
' "$query" "$user_home"
}

# ------------------------------------------------------------------------------
# Hide or Restore .desktop Entries in Menu & ~/Desktop
# ------------------------------------------------------------------------------
hide_desktop_artifacts() {
    local r_user="$1"
    local user_home="$2"
    local desktop_id="$3"
    local app_name="$4"

    local user_apps_dir="${user_home}/.local/share/applications"
    local desktop_dir="${user_home}/Desktop"
    local quarantine_dir="${PC_DESKTOP_QUARANTINE_BASE}/${r_user}"

    # 1. Hide in Cinnamon Application Menu via root-owned override
    if [[ -n "$desktop_id" ]]; then
        mkdir -p "$user_apps_dir"
        local override_file="${user_apps_dir}/${desktop_id}"
        cat << EOF > "$override_file"
# Managed by ParentControl (pc-apps.sh) - DO NOT EDIT
[Desktop Entry]
Type=Application
Name=${app_name}
Hidden=true
NoDisplay=true
EOF
        chown root:root "$override_file"
        chmod 0644 "$override_file"
    fi

    # 2. Quarantine any matching shortcut on ~/Desktop so user sees no dead icon
    if [[ -d "$desktop_dir" ]]; then
        mkdir -p "$quarantine_dir"
        chown root:root "$quarantine_dir"
        chmod 0700 "$quarantine_dir"

        shopt -s nullglob
        for desk_file in "${desktop_dir}"/*.desktop; do
            local base_desk
            base_desk="$(basename "$desk_file")"
            local is_match=0
            if [[ -n "$desktop_id" && "$base_desk" == "$desktop_id" ]]; then
                is_match=1
            elif [[ -n "$app_name" ]] && grep -qi "^Name=${app_name}$" "$desk_file" 2>/dev/null; then
                is_match=1
            fi
            if [[ "$is_match" -eq 1 ]]; then
                mv -f "$desk_file" "${quarantine_dir}/${base_desk}"
                chown root:root "${quarantine_dir}/${base_desk}"
                chmod 0644 "${quarantine_dir}/${base_desk}"
            fi
        done
        shopt -u nullglob
    fi
}

restore_desktop_artifacts() {
    local r_user="$1"
    local user_home="$2"
    local desktop_id="$3"
    local app_name="$4"

    local r_group
    r_group="$(id -gn "$r_user")"
    local user_apps_dir="${user_home}/.local/share/applications"
    local desktop_dir="${user_home}/Desktop"
    local quarantine_dir="${PC_DESKTOP_QUARANTINE_BASE}/${r_user}"

    # 1. Remove root-owned menu override if managed by ParentControl
    if [[ -n "$desktop_id" ]]; then
        local override_file="${user_apps_dir}/${desktop_id}"
        if [[ -f "$override_file" ]] && grep -q "Managed by ParentControl" "$override_file" 2>/dev/null; then
            rm -f "$override_file"
        fi
    fi

    # 2. Restore any quarantined shortcut back to ~/Desktop
    if [[ -d "$quarantine_dir" && -d "$desktop_dir" ]]; then
        shopt -s nullglob
        for q_file in "${quarantine_dir}"/*.desktop; do
            local base_q
            base_q="$(basename "$q_file")"
            local is_match=0
            if [[ -n "$desktop_id" && "$base_q" == "$desktop_id" ]]; then
                is_match=1
            elif [[ -n "$app_name" ]] && grep -qi "^Name=${app_name}$" "$q_file" 2>/dev/null; then
                is_match=1
            fi
            if [[ "$is_match" -eq 1 ]]; then
                mv -f "$q_file" "${desktop_dir}/${base_q}"
                chown "${r_user}:${r_group}" "${desktop_dir}/${base_q}"
                chmod 0755 "${desktop_dir}/${base_q}"
            fi
        done
        shopt -u nullglob
    fi
}

# ------------------------------------------------------------------------------
# Enforce All Application Rules & Installer Locks
# ------------------------------------------------------------------------------
enforce_app_rules() {
    local r_user="$1"
    local user_home
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"

    ensure_acl_tool
    pc_ensure_config_exists

    local rules_dump
    rules_dump="$(python3 -c '
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)

apps_cfg = cfg.get("apps", {})
lock_inst = "1" if apps_cfg.get("lock_installers", False) else "0"
print(f"LOCK|{lock_inst}")

for r in apps_cfg.get("rules", []):
    status = str(r.get("status", "allow")).lower()
    name = str(r.get("name", r.get("app", ""))).replace("|", " ")
    did = str(r.get("desktop_id", "")).replace("|", "")
    bpath = str(r.get("binary_path", "")).replace("|", "")
    fpid = str(r.get("flatpak_id", "")).replace("|", "")
    print(f"RULE|{status}|{name}|{did}|{bpath}|{fpid}")
' "$PC_CONFIG_FILE")"

    local lock_installers="0"
    while IFS='|' read -r rec_type f1 f2 f3 f4 f5; do
        if [[ "$rec_type" == "LOCK" ]]; then
            lock_installers="$f1"
            continue
        fi
        [[ "$rec_type" != "RULE" ]] && continue

        local status="$f1"
        local app_name="$f2"
        local desktop_id="$f3"
        local bin_path="$f4"
        local flatpak_id="$f5"

        if [[ "$status" == "block" ]]; then
            if [[ -n "$flatpak_id" ]]; then
                for fp_dir in "/var/lib/flatpak/app/${flatpak_id}" "${user_home}/.local/share/flatpak/app/${flatpak_id}"; do
                    [[ -d "$fp_dir" ]] && setfacl -R -m "u:${r_user}:---" "$fp_dir" 2>/dev/null || true
                done
            elif [[ -n "$bin_path" && -e "$bin_path" ]] && ! is_protected_binary "$bin_path"; then
                setfacl -m "u:${r_user}:---" "$bin_path" 2>/dev/null || true
            fi
            hide_desktop_artifacts "$r_user" "$user_home" "$desktop_id" "$app_name"
        else
            if [[ -n "$flatpak_id" ]]; then
                for fp_dir in "/var/lib/flatpak/app/${flatpak_id}" "${user_home}/.local/share/flatpak/app/${flatpak_id}"; do
                    [[ -d "$fp_dir" ]] && setfacl -R -x "u:${r_user}" "$fp_dir" 2>/dev/null || true
                done
            elif [[ -n "$bin_path" && -e "$bin_path" ]]; then
                setfacl -x "u:${r_user}" "$bin_path" 2>/dev/null || true
            fi
            restore_desktop_artifacts "$r_user" "$user_home" "$desktop_id" "$app_name"
        fi
    done <<< "$rules_dump"

    # Enforce or release Software Manager / Package Manager lock
    local installer_bins=(
        "/usr/bin/mintinstall"
        "/usr/bin/flatpak"
        "/usr/bin/snap"
        "/usr/bin/apt"
        "/usr/bin/apt-get"
        "/usr/bin/dpkg"
        "/usr/bin/gdebi"
        "/usr/bin/gdebi-gtk"
        "/usr/bin/synaptic"
        "/usr/bin/synaptic-pkexec"
    )
    local installer_desktops=("mintinstall.desktop" "synaptic.desktop")

    if [[ "$lock_installers" == "1" ]]; then
        for ibin in "${installer_bins[@]}"; do
            [[ -e "$ibin" ]] && setfacl -m "u:${r_user}:---" "$ibin" 2>/dev/null || true
        done
        for idesk in "${installer_desktops[@]}"; do
            hide_desktop_artifacts "$r_user" "$user_home" "$idesk" ""
        done
    else
        for ibin in "${installer_bins[@]}"; do
            [[ -e "$ibin" ]] && setfacl -x "u:${r_user}" "$ibin" 2>/dev/null || true
        done
        for idesk in "${installer_desktops[@]}"; do
            restore_desktop_artifacts "$r_user" "$user_home" "$idesk" ""
        done
    fi

    pc_log "INFO" "Enforced application rules and installer lock (lock_installers=${lock_installers}) for '${r_user}'."
}

# ------------------------------------------------------------------------------
# Build Standardized Apps State JSON for GUI Hydration
# ------------------------------------------------------------------------------
build_apps_state_json() {
    pc_ensure_config_exists

    python3 -c '
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)

apps_cfg = cfg.get("apps", {})
print(json.dumps({
    "restricted_user": cfg.get("restricted_user", ""),
    "lock_installers": bool(apps_cfg.get("lock_installers", False)),
    "rules": apps_cfg.get("rules", [])
}))
' "$PC_CONFIG_FILE"
}

# ------------------------------------------------------------------------------
# Action Handlers
# ------------------------------------------------------------------------------
set_app_rule_status() {
    local target_status="$1" # "block" or "allow"

    if [[ -z "$TARGET_APP" ]]; then
        pc_emit_error "Missing required --app <name|desktop|binary> flag." 2
        exit 2
    fi

    local r_user user_home
    r_user="$(get_restricted_user)"
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"

    local meta_json bin_path
    meta_json="$(resolve_app_metadata "$TARGET_APP" "$user_home")"
    bin_path="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("binary_path", ""))' "$meta_json")"

    if [[ "$target_status" == "block" ]] && is_protected_binary "$bin_path"; then
        pc_emit_error "Refusing to block protected core system binary: '${bin_path}'" 2
        exit 2
    fi

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg resolved_name
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    resolved_name="$(python3 -c '
import json, sys

cfg_path, raw_query, meta_str, new_status, out_path = sys.argv[1:6]
meta = json.loads(meta_str)

with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

apps_cfg = data.setdefault("apps", {"lock_installers": False, "rules": []})
rules = apps_cfg.get("rules", [])

name = meta.get("name") or raw_query
desktop_id = meta.get("desktop_id", "")
binary_path = meta.get("binary_path", "")
flatpak_id = meta.get("flatpak_id", "")

filtered = []
for r in rules:
    if r.get("name", "").lower() == name.lower():
        continue
    if desktop_id and r.get("desktop_id", "").lower() == desktop_id.lower():
        continue
    if binary_path and r.get("binary_path", "") == binary_path:
        continue
    if flatpak_id and r.get("flatpak_id", "").lower() == flatpak_id.lower():
        continue
    filtered.append(r)

filtered.append({
    "app": raw_query,
    "name": name,
    "desktop_id": desktop_id,
    "binary_path": binary_path,
    "flatpak_id": flatpak_id,
    "status": new_status
})
filtered.sort(key=lambda x: x.get("name", "").lower())
apps_cfg["rules"] = filtered

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(name)
' "$PC_CONFIG_FILE" "$TARGET_APP" "$meta_json" "$target_status" "$tmp_cfg")"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    enforce_app_rules "$r_user"
    pc_commit_transaction

    local verb="Blocked"
    [[ "$target_status" == "allow" ]] && verb="Allowed"

    local state_json
    state_json="$(build_apps_state_json)"
    pc_emit_result "${verb} application '${resolved_name}' for '${r_user}'" "$state_json"
}

handle_remove() {
    if [[ -z "$TARGET_APP" ]]; then
        pc_emit_error "Action 'remove' requires --app <name|desktop|binary>." 2
        exit 2
    fi

    local r_user user_home
    r_user="$(get_restricted_user)"
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"

    local meta_json
    meta_json="$(resolve_app_metadata "$TARGET_APP" "$user_home")"

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg removed_info
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    removed_info="$(python3 -c '
import json, sys

cfg_path, raw_query, meta_str, out_path = sys.argv[1:5]
meta = json.loads(meta_str)
q_low = raw_query.strip().lower()
m_name = meta.get("name", "").lower()
m_did = meta.get("desktop_id", "").lower()
m_bin = meta.get("binary_path", "")
m_fp = meta.get("flatpak_id", "").lower()

with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

apps_cfg = data.setdefault("apps", {"lock_installers": False, "rules": []})
old_rules = apps_cfg.get("rules", [])

kept = []
removed = []
for r in old_rules:
    r_app = str(r.get("app", "")).lower()
    r_name = str(r.get("name", "")).lower()
    r_did = str(r.get("desktop_id", "")).lower()
    r_bin = str(r.get("binary_path", ""))
    r_fp = str(r.get("flatpak_id", "")).lower()

    if (q_low in (r_app, r_name, r_did, r_fp) or
        (m_name and r_name == m_name) or
        (m_did and r_did == m_did) or
        (m_bin and r_bin == m_bin) or
        (m_fp and r_fp == m_fp)):
        removed.append(r)
    else:
        kept.append(r)

apps_cfg["rules"] = kept

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(json.dumps(removed))
' "$PC_CONFIG_FILE" "$TARGET_APP" "$meta_json" "$tmp_cfg")"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    local removed_count
    removed_count="$(python3 -c 'import json, sys; print(len(json.loads(sys.argv[1])))' "$removed_info")"
    if [[ "$removed_count" -eq 0 ]]; then
        pc_commit_transaction
        pc_emit_error "No saved application rule found for '${TARGET_APP}'." 2
        exit 2
    fi

# Clean up ACLs and desktop artifacts for each removed rule
    local cleanup_lines
    cleanup_lines="$(python3 -c '
import json, sys
for r in json.loads(sys.argv[1]):
    vals = [r.get("name", ""), r.get("desktop_id", ""), r.get("binary_path", ""), r.get("flatpak_id", "")]
    print("|".join(vals))
' "$removed_info")"

    while IFS='|' read -r c_name c_did c_bin c_fp; do
        if [[ -n "$c_fp" ]]; then
            for fp_dir in "/var/lib/flatpak/app/${c_fp}" "${user_home}/.local/share/flatpak/app/${c_fp}"; do
                [[ -d "$fp_dir" ]] && setfacl -R -x "u:${r_user}" "$fp_dir" 2>/dev/null || true
            done
        elif [[ -n "$c_bin" && -e "$c_bin" ]]; then
            setfacl -x "u:${r_user}" "$c_bin" 2>/dev/null || true
        fi
        restore_desktop_artifacts "$r_user" "$user_home" "$c_did" "$c_name"
    done <<< "$cleanup_lines"

    pc_commit_transaction

    local state_json
    state_json="$(build_apps_state_json)"
    pc_emit_result "Removed application rule for '${TARGET_APP}'" "$state_json"
}

handle_lock_installers() {
    if [[ "$LOCK_ENABLED" != "true" && "$LOCK_ENABLED" != "false" ]]; then
        pc_emit_error "Action 'lock-installers' requires --enabled <true|false>." 2
        exit 2
    fi

    local r_user
    r_user="$(get_restricted_user)"

    pc_init_transaction
    pc_json_set "apps.lock_installers" "$LOCK_ENABLED"
    enforce_app_rules "$r_user"
    pc_commit_transaction

    local state_json
    state_json="$(build_apps_state_json)"
    pc_emit_result "Set Software Manager / package installer lock to ${LOCK_ENABLED}" "$state_json"
}

handle_uninstall() {
    if [[ -z "$TARGET_APP" ]]; then
        pc_emit_error "Action 'uninstall' requires --app <name|desktop|binary|package>." 2
        exit 2
    fi

    local r_user user_home meta_json bin_path flatpak_id
    r_user="$(get_restricted_user)"
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"
    meta_json="$(resolve_app_metadata "$TARGET_APP" "$user_home")"

    bin_path="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("binary_path", ""))' "$meta_json")"
    flatpak_id="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("flatpak_id", ""))' "$meta_json")"

    if [[ -n "$flatpak_id" ]] && command -v flatpak >/dev/null 2>&1; then
        pc_log "INFO" "Uninstalling Flatpak application '${flatpak_id}'..."
        flatpak uninstall -y --noninteractive "$flatpak_id" >/dev/null
        local state_json
        state_json="$(build_apps_state_json)"
        pc_emit_result "Uninstalled Flatpak package '${flatpak_id}'" "$state_json"
        return 0
    fi

    local pkg_name=""
    if [[ -n "$bin_path" && -e "$bin_path" ]]; then
        pkg_name="$(dpkg-query -S "$bin_path" 2>/dev/null | head -n 1 | cut -d: -f1 || true)"
    fi
    if [[ -z "$pkg_name" ]] && dpkg-query -W -f='${Status}\n' "$TARGET_APP" 2>/dev/null | grep -q "install ok installed"; then
        pkg_name="$TARGET_APP"
    fi

    if [[ -z "$pkg_name" ]]; then
        pc_emit_error "Could not map '${TARGET_APP}' to an installed APT or Flatpak package." 2
        exit 2
    fi

    # Guard critical Linux Mint / Cinnamon system packages
    case "$pkg_name" in
        mint-meta-*|mintsystem|mintdesktop|cinnamon*|lightdm*|slick-greeter|\
        systemd*|xorg*|xserver-*|ubuntu-minimal|bash|coreutils|dpkg|apt|\
        python3|python3-minimal|sudo|policykit-1|polkitd|acl|ufw)
            pc_emit_error "Refusing to uninstall protected system package: '${pkg_name}'" 2
            exit 2
            ;;
    esac

    pc_log "INFO" "Uninstalling APT package '${pkg_name}'..."
    DEBIAN_FRONTEND=noninteractive apt-get remove -y -qq "$pkg_name" >/dev/null

    local state_json
    state_json="$(build_apps_state_json)"
    pc_emit_result "Uninstalled APT package '${pkg_name}'" "$state_json"
}

handle_scan() {
    pc_ensure_config_exists
    python3 -c '
import glob, json, os, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)

rules_by_name = {}
rules_by_did = {}
for r in cfg.get("apps", {}).get("rules", []):
    st = r.get("status", "allow")
    if r.get("name"):
        rules_by_name[r["name"].lower()] = st
    if r.get("desktop_id"):
        rules_by_did[r["desktop_id"].lower()] = st

apps = {}
for d in ("/usr/share/applications", "/usr/local/share/applications", "/var/lib/flatpak/exports/share/applications"):
    if not os.path.isdir(d):
        continue
    for fp in sorted(glob.glob(os.path.join(d, "*.desktop"))):
        did = os.path.basename(fp)
        name = ""
        exec_cmd = ""
        no_display = False
        try:
            with open(fp, "r", encoding="utf-8", errors="replace") as df:
                in_main = False
                for line in df:
                    s = line.strip()
                    if s.startswith("[") and s.endswith("]"):
                        in_main = (s == "[Desktop Entry]")
                        continue
                    if not in_main or "=" not in s:
                        continue
                    k, v = s.split("=", 1)
                    if k == "Name" and not name:
                        name = v.strip()
                    elif k == "Exec" and not exec_cmd:
                        exec_cmd = v.strip()
                    elif k in ("NoDisplay", "Hidden") and v.strip().lower() == "true":
                        no_display = True
        except Exception:
            continue
        if not name or no_display:
            continue
        if name not in apps:
            status = rules_by_did.get(did.lower()) or rules_by_name.get(name.lower()) or "allow"
            apps[name] = {
                "name": name,
                "desktop_id": did,
                "exec": exec_cmd,
                "status": status
            }

sorted_apps = [apps[k] for k in sorted(apps.keys(), key=str.lower)]
out = {
    "status": "ok",
    "module": "apps",
    "action": "scan",
    "message": f"Scanned {len(sorted_apps)} installed desktop applications",
    "data": {"count": len(sorted_apps), "applications": sorted_apps}
}
print(json.dumps(out))
' "$PC_CONFIG_FILE"
}

handle_list() {
    local state_json
    state_json="$(build_apps_state_json)"
    pc_emit_result "Retrieved application governance rules" "$state_json"
}

handle_apply() {
    local r_user
    r_user="$(get_restricted_user)"

    pc_init_transaction
    enforce_app_rules "$r_user"
    pc_commit_transaction

    local state_json
    state_json="$(build_apps_state_json)"
    pc_emit_result "Applied all application governance rules for '${r_user}'" "$state_json"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_apps_args "$@"
    pc_require_root
    pc_verify_mint

    case "$APPS_ACTION" in
        block)
            set_app_rule_status "block"
            ;;
        allow|unblock)
            set_app_rule_status "allow"
            ;;
        set)
            case "$TARGET_STATUS" in
                block) set_app_rule_status "block" ;;
                allow) set_app_rule_status "allow" ;;
                *)
                    pc_emit_error "Action 'set' requires --status <Allow|Block>." 2
                    exit 2
                    ;;
            esac
            ;;
        remove)
            handle_remove
            ;;
        lock-installers)
            handle_lock_installers
            ;;
        uninstall)
            handle_uninstall
            ;;
        scan)
            handle_scan
            ;;
        list)
            handle_list
            ;;
        apply)
            handle_apply
            ;;
        *)
            pc_emit_error "Unsupported action '${APPS_ACTION}' (expected: block, allow, set, remove, lock-installers, uninstall, scan, list, apply)." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_APPS_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-apps.sh
    chmod 0755 /opt/parentcontrol/bin/pc-apps.sh
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-queue.sh (Sub-Chunk 6.1)
# ------------------------------------------------------------------------------
deploy_pc_queue_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-queue.sh..."

    cat << 'PC_QUEUE_SH_EOF' > /opt/parentcontrol/bin/pc-queue.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Approvals Queue & User Request Manager
# File: /opt/parentcontrol/bin/pc-queue.sh
#
# Description:
#   Manages restricted-user access requests (app unlocks, URL whitelists, file
#   downloads). Unprivileged users can submit requests to the sticky-bit spool
#   directory (/var/spool/parentcontrol/requests); root/admin actions ingest,
#   approve (auto-applying the rule), deny, or remove items.
#
# GUI HANDOFF:
#   Invoked via pc-ctl.sh:
#     pkexec /opt/parentcontrol/bin/pc-ctl.sh queue --action <verb> [OPTIONS] --json
#
#   Supported Actions:
#     request --type <app|web|file|other> --target <value> [--user <name>] [--reason <text>] --json
#     approve --id <req_id> | --target <value> --json
#     deny    --id <req_id> | --target <value> --json
#     remove  --id <req_id> | --target <value> --json
#     list    --json
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="queue"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages the ParentControl approvals queue for app, web, and download requests."
PC_SCRIPT_USAGE="pc-queue.sh --action <request|approve|deny|remove|list> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         request, approve, deny, remove, list
      --id <req_id>           Request ID (e.g., req-20261114-123456)
      --user <username>       Requesting user (defaults to current user)
      --type <category>       app | web | file | other
      --target <value>        Application name, URL/domain, or filename
      --reason <text>         Optional note from the user"

readonly PC_SPOOL_DIR="/var/spool/parentcontrol/requests"
readonly PC_QUEUE_FILE="${PC_VAR_DIR}/queue.json"

QUEUE_ACTION=""
REQ_ID=""
REQ_USER=""
REQ_TYPE="app"
REQ_TARGET=""
REQ_REASON=""

# ------------------------------------------------------------------------------
# Parse Module-Specific Flags
# ------------------------------------------------------------------------------
parse_queue_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                QUEUE_ACTION="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --id)
                REQ_ID="${2:-}"
                shift 2
                ;;
            --user)
                REQ_USER="${2:-}"
                shift 2
                ;;
            --type)
                REQ_TYPE="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --target)
                REQ_TARGET="${2:-}"
                shift 2
                ;;
            --reason)
                REQ_REASON="${2:-}"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for pc-queue.sh: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$QUEUE_ACTION" ]]; then
        pc_emit_error "Missing required --action <request|approve|deny|remove|list>." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$QUEUE_ACTION"
}

# ------------------------------------------------------------------------------
# Ensure Queue Store & Ingest Any New Spool Requests
# ------------------------------------------------------------------------------
ensure_queue_file() {
    mkdir -p "$PC_VAR_DIR"
    if [[ ! -f "$PC_QUEUE_FILE" ]]; then
        printf '{"requests": []}\n' > "$PC_QUEUE_FILE"
        chown root:root "$PC_QUEUE_FILE"
        chmod 0640 "$PC_QUEUE_FILE"
    fi
}

ingest_spool_requests() {
    ensure_queue_file
    [[ -d "$PC_SPOOL_DIR" ]] || return 0

    python3 -c '
import glob, json, os, sys

spool_dir, queue_path = sys.argv[1:3]
with open(queue_path, "r", encoding="utf-8") as f:
    data = json.load(f)

requests = data.setdefault("requests", [])
existing_ids = {r.get("id") for r in requests}

ingested = 0
for fp in sorted(glob.glob(os.path.join(spool_dir, "req-*.json"))):
    try:
        with open(fp, "r", encoding="utf-8") as rf:
            item = json.load(rf)
        if isinstance(item, dict) and item.get("id") and item.get("target"):
            if item["id"] not in existing_ids:
                requests.append({
                    "id": str(item["id"]),
                    "user": str(item.get("user", "unknown")),
                    "type": str(item.get("type", "Other")),
                    "target": str(item["target"]),
                    "reason": str(item.get("reason", "")),
                    "status": "Pending",
                    "created_at": str(item.get("created_at", ""))
                })
                existing_ids.add(item["id"])
                ingested += 1
        os.remove(fp)
    except Exception:
        # Remove malformed spool files so they do not stall ingestion
        try:
            os.remove(fp)
        except Exception:
            pass

if ingested > 0:
    tmp_path = queue_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as wf:
        json.dump(data, wf, indent=2)
        wf.write("\n")
    os.chmod(tmp_path, 0o640)
    os.replace(tmp_path, queue_path)
' "$PC_SPOOL_DIR" "$PC_QUEUE_FILE"
}

build_queue_state_json() {
    ingest_spool_requests
    python3 -c '
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

reqs = data.get("requests", [])
pending_count = sum(1 for r in reqs if str(r.get("status", "")).lower() == "pending")
print(json.dumps({
    "count": len(reqs),
    "pending_count": pending_count,
    "requests": reqs
}))
' "$PC_QUEUE_FILE"
}

# ------------------------------------------------------------------------------
# Unprivileged Action: Submit a New Request to Spool Dropbox
# ------------------------------------------------------------------------------
handle_request() {
    if [[ -z "$REQ_TARGET" ]]; then
        pc_emit_error "Action 'request' requires --target <app|url|file>." 2
        exit 2
    fi

    if [[ ! -d "$PC_SPOOL_DIR" ]]; then
        pc_emit_error "Request spool directory does not exist: ${PC_SPOOL_DIR}" 1
        exit 1
    fi

    local submitter="$REQ_USER"
    if [[ -z "$submitter" ]]; then
        submitter="$(id -un)"
    fi

    local display_type
    case "$REQ_TYPE" in
        app|application) display_type="App Access" ;;
        web|url|site|domain) display_type="Web Access" ;;
        file|download) display_type="Download File" ;;
        *) display_type="Other" ;;
    esac

    local created_json
    created_json="$(python3 -c '
import datetime, json, os, random, sys

spool_dir, user, req_type, target, reason = sys.argv[1:6]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y%m%d%H%M%S")
req_id = f"req-{ts}-{random.randint(1000, 9999)}"
payload = {
    "id": req_id,
    "user": user,
    "type": req_type,
    "target": target.strip(),
    "reason": reason.strip(),
    "status": "Pending",
    "created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ")
}
out_file = os.path.join(spool_dir, f"{req_id}.json")
with open(out_file, "w", encoding="utf-8") as f:
    json.dump(payload, f, indent=2)
    f.write("\n")
os.chmod(out_file, 0o644)
print(json.dumps(payload))
' "$PC_SPOOL_DIR" "$submitter" "$display_type" "$REQ_TARGET" "$REQ_REASON")"

    if [[ "${PC_JSON_OUTPUT:-${PC_OUTPUT_JSON:-0}}" -eq 1 ]]; then
        printf '{"status": "ok", "module": "queue", "action": "request", "message": "Submitted approval request", "data": %s}\n' "$created_json"
    else
        printf '[OK] Submitted approval request for %s (%s)\n' "$REQ_TARGET" "$display_type"
    fi
}

# ------------------------------------------------------------------------------
# Privileged Actions: Approve, Deny, Remove, List
# ------------------------------------------------------------------------------
update_request_decision() {
    local new_status="$1" # "Approved" or "Denied"

    if [[ -z "$REQ_ID" && -z "$REQ_TARGET" ]]; then
        pc_emit_error "Action requires --id <req_id> or --target <target>." 2
        exit 2
    fi

    ingest_spool_requests
    pc_init_transaction
    pc_backup_file "$PC_QUEUE_FILE"

    local match_info
    match_info="$(python3 -c '
import json, os, sys

queue_path, req_id, req_target, new_status = sys.argv[1:5]
with open(queue_path, "r", encoding="utf-8") as f:
    data = json.load(f)

reqs = data.get("requests", [])
matched = None
for r in reversed(reqs):
    if req_id and r.get("id") == req_id:
        r["status"] = new_status
        matched = r
        break
    if not req_id and req_target and r.get("target", "").lower() == req_target.strip().lower():
        if str(r.get("status", "")).lower() == "pending":
            r["status"] = new_status
            matched = r
            break

if not matched:
    sys.exit(1)

tmp_path = queue_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
os.chmod(tmp_path, 0o640)
os.replace(tmp_path, queue_path)

print(json.dumps(matched))
' "$PC_QUEUE_FILE" "$REQ_ID" "$REQ_TARGET" "$new_status" 2>/dev/null || true)"

    if [[ -z "$match_info" ]]; then
        pc_commit_transaction
        pc_emit_error "No matching pending request found in approvals queue." 2
        exit 2
    fi

    # Automatically enforce rule if Approved
    if [[ "$new_status" == "Approved" ]]; then
        local m_type m_target
        m_type="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("type", ""))' "$match_info")"
        m_target="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("target", ""))' "$match_info")"

        if [[ "$m_type" == "App Access" && -x "${PC_BIN_DIR}/pc-apps.sh" ]]; then
            "${PC_BIN_DIR}/pc-apps.sh" --action allow --app "$m_target" --json >/dev/null 2>&1 || true
        elif [[ "$m_type" == "Web Access" && -x "${PC_BIN_DIR}/pc-net-acl.sh" ]]; then
            "${PC_BIN_DIR}/pc-net-acl.sh" --action add --list whitelist --target "$m_target" --json >/dev/null 2>&1 || true
        fi
    fi

    pc_commit_transaction

    local state_json
    state_json="$(build_queue_state_json)"
    pc_emit_result "Marked request as ${new_status}" "$state_json"
}

handle_remove() {
    if [[ -z "$REQ_ID" && -z "$REQ_TARGET" ]]; then
        pc_emit_error "Action 'remove' requires --id <req_id> or --target <target>." 2
        exit 2
    fi

    ingest_spool_requests
    pc_init_transaction
    pc_backup_file "$PC_QUEUE_FILE"

    local removed_count
    removed_count="$(python3 -c '
import json, os, sys

queue_path, req_id, req_target = sys.argv[1:4]
with open(queue_path, "r", encoding="utf-8") as f:
    data = json.load(f)

old_reqs = data.get("requests", [])
kept = []
removed = 0
for r in old_reqs:
    if req_id and r.get("id") == req_id:
        removed += 1
        continue
    if not req_id and req_target and r.get("target", "").lower() == req_target.strip().lower():
        removed += 1
        continue
    kept.append(r)

data["requests"] = kept
tmp_path = queue_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
os.chmod(tmp_path, 0o640)
os.replace(tmp_path, queue_path)

print(removed)
' "$PC_QUEUE_FILE" "$REQ_ID" "$REQ_TARGET")"

    if [[ "$removed_count" -eq 0 ]]; then
        pc_commit_transaction
        pc_emit_error "No matching queue entry found to remove." 2
        exit 2
    fi

    pc_commit_transaction

    local state_json
    state_json="$(build_queue_state_json)"
    pc_emit_result "Removed ${removed_count} item(s) from approvals queue" "$state_json"
}

handle_list() {
    local state_json
    state_json="$(build_queue_state_json)"
    pc_emit_result "Retrieved approvals queue" "$state_json"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_queue_args "$@"

    if [[ "$QUEUE_ACTION" == "request" ]]; then
        handle_request
        exit 0
    fi

    pc_require_root
    pc_verify_mint

    case "$QUEUE_ACTION" in
        approve)
            update_request_decision "Approved"
            ;;
        deny)
            update_request_decision "Denied"
            ;;
        remove)
            handle_remove
            ;;
        list)
            handle_list
            ;;
        *)
            pc_emit_error "Unsupported action '${QUEUE_ACTION}' (expected: request, approve, deny, remove, list)." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_QUEUE_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-queue.sh
    chmod 0755 /opt/parentcontrol/bin/pc-queue.sh
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-maint.sh (Sub-Chunk 6.2)
# ------------------------------------------------------------------------------
deploy_pc_maint_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-maint.sh..."

    cat << 'PC_MAINT_SH_EOF' > /opt/parentcontrol/bin/pc-maint.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Daily Screen-Time, Maintenance & Senior Accessibility Manager
# File: /opt/parentcontrol/bin/pc-maint.sh
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="maint"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages daily screen-time limits, non-blocking automated maintenance, and Senior/Dementia accessibility presets."
PC_SCRIPT_USAGE="pc-maint.sh --action <time-limit|set-auto|senior-preset|run-now|run-worker|list> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         time-limit, set-auto, senior-preset, run-now, run-worker, list
      --hours <float>         Daily screen-time allowance in hours (e.g., 2.0)
      --feature <name>        auto_updates | auto_timeshift | auto_trash_purge
      --enabled <true|false>  Enable or disable setting
      --sync                  Run maintenance in foreground instead of detached worker"

readonly PC_MAINT_STATUS_FILE="${PC_VAR_DIR}/maint-status.json"
readonly PC_TIMELIMIT_CRON="/etc/cron.d/parentcontrol-timelimit"
readonly PC_MAINT_CRON="/etc/cron.d/parentcontrol-maintenance"

MAINT_ACTION=""
LIMIT_HOURS=""
AUTO_FEATURE=""
SETTING_ENABLED=""
RUN_SYNC="false"

parse_maint_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)  MAINT_ACTION="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --hours)   LIMIT_HOURS="${2:-}"; shift 2 ;;
            --feature) AUTO_FEATURE="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --enabled) SETTING_ENABLED="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"; shift 2 ;;
            --sync)    RUN_SYNC="true"; shift ;;
            *) pc_emit_error "Unknown flag for pc-maint.sh: $1" 2; exit 2 ;;
        esac
    done

    if [[ -z "$MAINT_ACTION" ]]; then
        pc_emit_error "Missing required --action flag." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$MAINT_ACTION"
}

get_restricted_user() {
    pc_ensure_config_exists
    local r_user
    r_user="$(pc_json_get "restricted_user" 2>/dev/null || true)"
    if [[ -z "$r_user" ]] || ! id -u "$r_user" >/dev/null 2>&1; then
        r_user="$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" && $1 != "pcadmin" {print $1; exit}' /etc/passwd)"
    fi
    printf '%s' "$r_user"
}

apply_senior_preset() {
    local enabled="$1"
    local r_user r_uid user_home r_group
    r_user="$(get_restricted_user)"
    [[ -z "$r_user" ]] && return 0
    r_uid="$(id -u "$r_user")"
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"
    r_group="$(id -gn "$r_user")"

    local autostart_dir="${user_home}/.config/autostart"
    local autostart_file="${autostart_dir}/parentcontrol-accessibility.desktop"

    if [[ "$enabled" == "true" ]]; then
        mkdir -p "$autostart_dir"
        chown "${r_user}:${r_group}" "$autostart_dir"
        cat << 'AUTO_EOF' > "$autostart_file"
[Desktop Entry]
Type=Application
Name=ParentControl Senior & Accessibility Profile
Exec=/bin/sh -c "gsettings set org.cinnamon.desktop.interface text-scaling-factor 1.25; gsettings set org.cinnamon.desktop.interface cursor-size 32; gsettings set org.cinnamon hotcorner-layout \"['scale:false:0', 'scale:false:0', 'desktop:false:0', 'desktop:false:0']\""
NoDisplay=true
X-GNOME-Autostart-enabled=true
AUTO_EOF
        chown root:root "$autostart_file"
        chmod 0644 "$autostart_file"
    else
        rm -f "$autostart_file"
    fi

    local bus_addr="unix:path=/run/user/${r_uid}/bus"
    if [[ -S "/run/user/${r_uid}/bus" ]] && command -v gsettings >/dev/null 2>&1; then
        if [[ "$enabled" == "true" ]]; then
            sudo -u "$r_user" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
                gsettings set org.cinnamon.desktop.interface text-scaling-factor 1.25 2>/dev/null || true
            sudo -u "$r_user" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
                gsettings set org.cinnamon.desktop.interface cursor-size 32 2>/dev/null || true
            sudo -u "$r_user" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
                gsettings set org.cinnamon hotcorner-layout "['scale:false:0', 'scale:false:0', 'desktop:false:0', 'desktop:false:0']" 2>/dev/null || true
        else
            sudo -u "$r_user" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
                gsettings reset org.cinnamon.desktop.interface text-scaling-factor 2>/dev/null || true
            sudo -u "$r_user" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
                gsettings reset org.cinnamon.desktop.interface cursor-size 2>/dev/null || true
            sudo -u "$r_user" DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
                gsettings reset org.cinnamon hotcorner-layout 2>/dev/null || true
        fi
    fi
}

sync_cron_schedules() {
    pc_ensure_config_exists
    local flags
    flags="$(python3 - "$PC_CONFIG_FILE" << 'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
st = cfg.get("screen_time", {})
au = cfg.get("automation", {})
any_auto = any([au.get("auto_updates"), au.get("auto_timeshift"), au.get("auto_trash_purge")])
print(("1" if st.get("enabled") else "0") + "|" + ("1" if any_auto else "0"))
PYEOF
)"
    local tl_on auto_on
    IFS='|' read -r tl_on auto_on <<< "$flags"

    if [[ "$tl_on" == "1" ]]; then
        cat << 'CRON_TL_EOF' > "$PC_TIMELIMIT_CRON"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
* * * * * root /opt/parentcontrol/bin/pc-maint.sh --action tick >/dev/null 2>&1
CRON_TL_EOF
        chmod 0644 "$PC_TIMELIMIT_CRON"
    else
        rm -f "$PC_TIMELIMIT_CRON"
    fi

    if [[ "$auto_on" == "1" ]]; then
        cat << 'CRON_MAINT_EOF' > "$PC_MAINT_CRON"
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 3 * * * root /opt/parentcontrol/bin/pc-maint.sh --action run-worker >/dev/null 2>&1
CRON_MAINT_EOF
        chmod 0644 "$PC_MAINT_CRON"
    else
        rm -f "$PC_MAINT_CRON"
    fi
}

write_maint_status() {
    local running="$1"
    local summary="$2"
    mkdir -p "$PC_VAR_DIR"
    python3 - "$PC_MAINT_STATUS_FILE" "$running" "$summary" << 'PYEOF'
import datetime, json, os, sys
st_path, run_str, summary = sys.argv[1:4]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
prev = {}
if os.path.isfile(st_path):
    try:
        prev = json.load(open(st_path, "r", encoding="utf-8"))
    except Exception:
        pass
data = {
    "maintenance_running": (run_str == "true"),
    "last_run_at": prev.get("last_run_at") if run_str == "true" else now,
    "last_run_summary": summary
}
tmp = st_path + ".tmp"
with open(tmp, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
os.chmod(tmp, 0o644)
os.replace(tmp, st_path)
PYEOF
}

execute_maintenance_tasks() {
    write_maint_status "true" "Running maintenance tasks..."
    pc_log "INFO" "Background maintenance worker started."

    local r_user user_home
    r_user="$(get_restricted_user)"
    user_home="$(getent passwd "$r_user" 2>/dev/null | cut -d: -f6 || true)"

    local tasks_done=()

    if command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq </dev/null >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" </dev/null >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq </dev/null >/dev/null 2>&1 || true
        tasks_done+=("system packages updated")
    fi

    if command -v timeshift >/dev/null 2>&1; then
        timeshift --create --comments "ParentControl Scheduled Snapshot" --scripted </dev/null >/dev/null 2>&1 || true
        tasks_done+=("timeshift snapshot checked")
    fi

    if [[ -n "$user_home" && -d "${user_home}/.local/share/Trash" ]]; then
        rm -rf "${user_home}/.local/share/Trash/files/"* "${user_home}/.local/share/Trash/info/"* 2>/dev/null || true
        tasks_done+=("trash purged")
    fi

    local summary="Completed: ${tasks_done[*]:-all checks}"
    write_maint_status "false" "$summary"
    pc_log "INFO" "Maintenance worker finished: ${summary}"
}

build_maint_state_json() {
    pc_ensure_config_exists
    python3 - "$PC_CONFIG_FILE" "$PC_MAINT_STATUS_FILE" << 'PYEOF'
import json, os, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
st = cfg.get("screen_time", {})
au = cfg.get("automation", {})
worker = {"maintenance_running": False, "last_run_at": None, "last_run_summary": ""}
if os.path.isfile(sys.argv[2]):
    try:
        worker.update(json.load(open(sys.argv[2], "r", encoding="utf-8")))
    except Exception:
        pass
print(json.dumps({
    "restricted_user": cfg.get("restricted_user", ""),
    "time_limit_enabled": bool(st.get("enabled", False)),
    "daily_limit_hours": float(st.get("daily_limit_hours", 2.0)),
    "used_minutes_today": int(st.get("used_minutes_today", 0)),
    "auto_updates": bool(au.get("auto_updates", False)),
    "auto_timeshift": bool(au.get("auto_timeshift", False)),
    "auto_trash_purge": bool(au.get("auto_trash_purge", False)),
    "senior_preset": bool(au.get("senior_preset", False)),
    "maintenance_running": bool(worker.get("maintenance_running", False)),
    "last_run_at": worker.get("last_run_at"),
    "last_run_summary": worker.get("last_run_summary", "")
}))
PYEOF
}

handle_time_limit() {
    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"
    python3 - "$PC_CONFIG_FILE" "$LIMIT_HOURS" "$SETTING_ENABLED" "$tmp_cfg" << 'PYEOF'
import json, sys
cfg_path, hrs_str, en_str, out_path = sys.argv[1:5]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
st = data.setdefault("screen_time", {"enabled": False, "daily_limit_hours": 2.0, "used_minutes_today": 0})
if hrs_str:
    st["daily_limit_hours"] = float(hrs_str)
if en_str in ("true", "false"):
    st["enabled"] = (en_str == "true")
with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
PYEOF

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"
    sync_cron_schedules
    pc_commit_transaction

    pc_emit_result "Updated screen-time limit settings" "$(build_maint_state_json)"
}

handle_set_auto() {
    case "$AUTO_FEATURE" in
        auto_updates|auto_timeshift|auto_trash_purge) ;;
        *) pc_emit_error "Invalid --feature '${AUTO_FEATURE}'." 2; exit 2 ;;
    esac
    if [[ "$SETTING_ENABLED" != "true" && "$SETTING_ENABLED" != "false" ]]; then
        pc_emit_error "Requires --enabled <true|false>." 2
        exit 2
    fi

    pc_init_transaction
    pc_json_set "automation.${AUTO_FEATURE}" "$SETTING_ENABLED"
    sync_cron_schedules
    pc_commit_transaction

    pc_emit_result "Set automation feature '${AUTO_FEATURE}' to ${SETTING_ENABLED}" "$(build_maint_state_json)"
}

handle_senior_preset() {
    if [[ "$SETTING_ENABLED" != "true" && "$SETTING_ENABLED" != "false" ]]; then
        pc_emit_error "Requires --enabled <true|false>." 2
        exit 2
    fi

    pc_init_transaction
    pc_json_set "automation.senior_preset" "$SETTING_ENABLED"
    apply_senior_preset "$SETTING_ENABLED"
    pc_commit_transaction

    pc_emit_result "Set Senior/Dementia accessibility preset to ${SETTING_ENABLED}" "$(build_maint_state_json)"
}

handle_run_now() {
    if [[ "$RUN_SYNC" == "true" ]]; then
        execute_maintenance_tasks
        pc_emit_result "Completed maintenance tasks" "$(build_maint_state_json)"
        return 0
    fi

    write_maint_status "true" "Maintenance started in background..."
    nohup /opt/parentcontrol/bin/pc-maint.sh --action run-worker </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true

    pc_emit_result "Maintenance tasks started in background" "$(build_maint_state_json)"
}

main() {
    parse_maint_args "$@"
    pc_require_root
    pc_verify_mint

    case "$MAINT_ACTION" in
        time-limit)    handle_time_limit ;;
        set-auto)      handle_set_auto ;;
        senior-preset) handle_senior_preset ;;
        run-now)       handle_run_now ;;
        run-worker)    execute_maintenance_tasks ;;
        tick|check-time) exit 0 ;;
        list)          pc_emit_result "Retrieved automation and screen-time settings" "$(build_maint_state_json)" ;;
        *)             pc_emit_error "Unsupported maint action '${MAINT_ACTION}'." 2; exit 2 ;;
    esac
}

main "$@"
PC_MAINT_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-maint.sh
    chmod 0755 /opt/parentcontrol/bin/pc-maint.sh
}

deploy_parentcontrol_admin_gui_py() {
    log_step "Writing /opt/parentcontrol/gui/parentcontrol-gui.py, PolicyKit GUI policy, and desktop launcher..."

    cat << 'PC_ADMIN_GUI_EOF' > /opt/parentcontrol/gui/parentcontrol-gui.py
#!/usr/bin/env python3
import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib
import json
import logging
import os
import subprocess
import sys
import traceback

logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s', handlers=[logging.StreamHandler(sys.stdout)])


class SetupWizardDialog(Gtk.Dialog):
    """Step-by-step interactive first-run setup wizard matching pc-setup.sh --action wizard."""

    def __init__(self, parent, status_data):
        super().__init__(
            title="ParentControl — First-Time Setup Wizard",
            transient_for=parent,
            flags=Gtk.DialogFlags.MODAL | Gtk.DialogFlags.DESTROY_WITH_PARENT,
        )
        self.parent_app = parent
        self.status_data = status_data or {}
        self.set_default_size(620, 470)
        self.set_border_width(12)

        content = self.get_content_area()
        content.set_spacing(10)

        header = Gtk.Label()
        header.set_markup(
            "<big><b>Welcome to ParentControl Setup</b></big>\n"
            "Complete these 4 quick steps to lock down the monitored account and configure caregiver settings."
        )
        header.set_xalign(0)
        header.set_line_wrap(True)
        content.pack_start(header, False, False, 0)

        self.stack = Gtk.Stack()
        self.stack.set_transition_type(Gtk.StackTransitionType.SLIDE_LEFT_RIGHT)
        self.stack.set_transition_duration(200)
        content.pack_start(self.stack, True, True, 0)

        self._build_step1_admin()
        self._build_step2_profile()
        self._build_step3_contact()
        self._build_step4_baseline()

        self.step_names = ["step1", "step2", "step3", "step4"]
        self.current_step = 0

        # Navigation bar
        nav_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.step_lbl = Gtk.Label(label="Step 1 of 4: Administrator Separation")
        self.step_lbl.set_xalign(0)
        nav_box.pack_start(self.step_lbl, True, True, 0)

        self.btn_cancel = Gtk.Button(label="Skip for Now")
        self.btn_cancel.connect("clicked", lambda _: self.response(Gtk.ResponseType.CANCEL))
        nav_box.pack_start(self.btn_cancel, False, False, 0)

        self.btn_back = Gtk.Button(label="< Back")
        self.btn_back.set_sensitive(False)
        self.btn_back.connect("clicked", self._on_back)
        nav_box.pack_start(self.btn_back, False, False, 0)

        self.btn_next = Gtk.Button(label="Next >")
        self.btn_next.get_style_context().add_class("suggested-action")
        self.btn_next.connect("clicked", self._on_next_or_finish)
        nav_box.pack_start(self.btn_next, False, False, 0)

        content.pack_start(nav_box, False, False, 0)
        self.show_all()

    def _build_step1_admin(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        info = Gtk.Label(
            label="ParentControl separates a dedicated administrator account ('pcadmin') from the daily "
                  "desktop user so settings cannot be bypassed."
        )
        info.set_xalign(0)
        info.set_line_wrap(True)
        box.pack_start(info, False, False, 0)

        grid = Gtk.Grid(column_spacing=12, row_spacing=10)
        grid.attach(Gtk.Label(label="Monitored Desktop User:", xalign=0), 0, 0, 1, 1)
        self.wiz_user_entry = Gtk.Entry()
        self.wiz_user_entry.set_text(self.status_data.get("restricted_user") or "mint")
        self.wiz_user_entry.set_hexpand(True)
        grid.attach(self.wiz_user_entry, 1, 0, 1, 1)

        grid.attach(Gtk.Label(label="New 'pcadmin' Password:", xalign=0), 0, 1, 1, 1)
        self.wiz_pw1_entry = Gtk.Entry()
        self.wiz_pw1_entry.set_visibility(False)
        self.wiz_pw1_entry.set_placeholder_text("Minimum 6 characters")
        grid.attach(self.wiz_pw1_entry, 1, 1, 1, 1)

        grid.attach(Gtk.Label(label="Confirm Password:", xalign=0), 0, 2, 1, 1)
        self.wiz_pw2_entry = Gtk.Entry()
        self.wiz_pw2_entry.set_visibility(False)
        grid.attach(self.wiz_pw2_entry, 1, 2, 1, 1)
        box.pack_start(grid, False, False, 0)

        self.wiz_strip_chk = Gtk.CheckButton(
            label="Strip sudo / admin privileges from the monitored user (Recommended)"
        )
        self.wiz_strip_chk.set_active(True)
        box.pack_start(self.wiz_strip_chk, False, False, 0)

        self.stack.add_named(box, "step1")

    def _build_step2_profile(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(10)

        intro = Gtk.Label(label="Choose the primary care profile for this computer:")
        intro.set_xalign(0)
        box.pack_start(intro, False, False, 0)

        self.wiz_radio_senior = Gtk.RadioButton.new_with_label_from_widget(
            None,
            "Dementia / Senior Care Profile (Recommended for older adults)"
        )
        senior_desc = Gtk.Label(
            label="   • Increases desktop text scaling to 1.25x and enlarges mouse cursor\n"
                  "   • Disables confusing screen hot-corners across logins"
        )
        senior_desc.set_xalign(0)

        self.wiz_radio_child = Gtk.RadioButton.new_with_label_from_widget(
            self.wiz_radio_senior,
            "Child / Student Safety Profile"
        )
        child_desc = Gtk.Label(
            label="   • Keeps standard desktop sizing and hot-corners\n"
                  "   • Focuses on web filtering, app locks, and screen-time limits"
        )
        child_desc.set_xalign(0)

        if self.status_data.get("senior_preset", True):
            self.wiz_radio_senior.set_active(True)
        else:
            self.wiz_radio_child.set_active(True)

        box.pack_start(self.wiz_radio_senior, False, False, 0)
        box.pack_start(senior_desc, False, False, 0)
        box.pack_start(self.wiz_radio_child, False, False, 0)
        box.pack_start(child_desc, False, False, 0)

        self.stack.add_named(box, "step2")

    def _build_step3_contact(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        intro = Gtk.Label(
            label="This contact information appears in the monitored user's 'Caregiver Help & Request Access' popup:"
        )
        intro.set_xalign(0)
        intro.set_line_wrap(True)
        box.pack_start(intro, False, False, 0)

        contact = self.status_data.get("admin_contact", {})
        grid = Gtk.Grid(column_spacing=12, row_spacing=10)

        grid.attach(Gtk.Label(label="Caregiver Name:", xalign=0), 0, 0, 1, 1)
        self.wiz_cname = Gtk.Entry()
        self.wiz_cname.set_text(contact.get("name", ""))
        self.wiz_cname.set_placeholder_text("e.g., Sarah (Daughter) or Mom & Dad")
        self.wiz_cname.set_hexpand(True)
        grid.attach(self.wiz_cname, 1, 0, 1, 1)

        grid.attach(Gtk.Label(label="Phone / SMS:", xalign=0), 0, 1, 1, 1)
        self.wiz_cphone = Gtk.Entry()
        self.wiz_cphone.set_text(contact.get("phone", ""))
        self.wiz_cphone.set_placeholder_text("e.g., 555-0199")
        grid.attach(self.wiz_cphone, 1, 1, 1, 1)

        grid.attach(Gtk.Label(label="Email:", xalign=0), 0, 2, 1, 1)
        self.wiz_cemail = Gtk.Entry()
        self.wiz_cemail.set_text(contact.get("email", ""))
        self.wiz_cemail.set_placeholder_text("e.g., caregiver@example.com")
        grid.attach(self.wiz_cemail, 1, 2, 1, 1)

        grid.attach(Gtk.Label(label="Help Note:", xalign=0), 0, 3, 1, 1)
        self.wiz_cnote = Gtk.Entry()
        self.wiz_cnote.set_text(
            contact.get("note") or "Need a website or application unlocked? Send a request below."
        )
        grid.attach(self.wiz_cnote, 1, 3, 1, 1)

        box.pack_start(grid, False, False, 0)
        self.stack.add_named(box, "step3")

    def _build_step4_baseline(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(10)

        intro = Gtk.Label(
            label="Select recommended baseline protections to activate immediately:"
        )
        intro.set_xalign(0)
        box.pack_start(intro, False, False, 0)

        self.wiz_chk_feeds = Gtk.CheckButton(
            label="Enable StevenBlack (Ads/Malware) & Phishing Army web blocklists"
        )
        self.wiz_chk_feeds.set_active(True)
        box.pack_start(self.wiz_chk_feeds, False, False, 0)

        self.wiz_chk_ports = Gtk.CheckButton(
            label="Block common risky remote-access ports (FTP, SSH, Telnet, SMB, RDP, VNC)"
        )
        self.wiz_chk_ports.set_active(True)
        box.pack_start(self.wiz_chk_ports, False, False, 0)

        self.wiz_chk_installers = Gtk.CheckButton(
            label="Lock software installers (Software Manager, Synaptic, Flatpak, GDebi)"
        )
        self.wiz_chk_installers.set_active(True)
        box.pack_start(self.wiz_chk_installers, False, False, 0)

        note = Gtk.Label(
            label="You can customize websites, folders, apps, hardware locks, and screen-time limits anytime "
                  "in the main ParentControl tabs."
        )
        note.set_xalign(0)
        note.set_line_wrap(True)
        box.pack_end(note, False, False, 0)

        self.stack.add_named(box, "step4")

    def _update_nav_ui(self):
        titles = [
            "Step 1 of 4: Administrator Separation",
            "Step 2 of 4: Care Profile Selection",
            "Step 3 of 4: Caregiver Contact Info",
            "Step 4 of 4: Baseline Security Protections",
        ]
        self.step_lbl.set_text(titles[self.current_step])
        self.stack.set_visible_child_name(self.step_names[self.current_step])
        self.btn_back.set_sensitive(self.current_step > 0)
        if self.current_step == len(self.step_names) - 1:
            self.btn_next.set_label("Finish & Apply Setup")
        else:
            self.btn_next.set_label("Next >")

    def _on_back(self, _widget):
        if self.current_step > 0:
            self.current_step -= 1
            self._update_nav_ui()

    def _on_next_or_finish(self, _widget):
        if self.current_step == 0:
            user = self.wiz_user_entry.get_text().strip()
            pw1 = self.wiz_pw1_entry.get_text()
            pw2 = self.wiz_pw2_entry.get_text()
            if not user:
                self.parent_app._show_msg(Gtk.MessageType.WARNING, "Missing User", "Enter the monitored username.")
                return
            if len(pw1) < 6:
                self.parent_app._show_msg(Gtk.MessageType.WARNING, "Weak Password", "Please enter a 'pcadmin' password of at least 6 characters.")
                return
            if pw1 != pw2:
                self.parent_app._show_msg(Gtk.MessageType.WARNING, "Password Mismatch", "The two password fields do not match.")
                return

        if self.current_step < len(self.step_names) - 1:
            self.current_step += 1
            self._update_nav_ui()
            return

        self._apply_wizard()

    def _apply_wizard(self):
        self.btn_next.set_sensitive(False)
        self.btn_back.set_sensitive(False)
        try:
            user = self.wiz_user_entry.get_text().strip()
            pw1 = self.wiz_pw1_entry.get_text()
            strip_flag = "true" if self.wiz_strip_chk.get_active() else "false"
            senior_flag = "true" if self.wiz_radio_senior.get_active() else "false"

            self.parent_app._backend_command(
                "setup", "--action", "provision-admin",
                "--user", user,
                "--admin-password", pw1,
                "--strip-user-sudo", strip_flag,
            )

            self.parent_app._backend_command(
                "setup", "--action", "set-contact",
                "--name", self.wiz_cname.get_text().strip(),
                "--phone", self.wiz_cphone.get_text().strip(),
                "--email", self.wiz_cemail.get_text().strip(),
                "--note", self.wiz_cnote.get_text().strip(),
            )

            self.parent_app._backend_command(
                "maint", "--action", "senior-preset", "--enabled", senior_flag
            )

            if self.wiz_chk_feeds.get_active():
                self.parent_app._backend_command(
                    "acl", "--action", "toggle-feed", "--feed", "all", "--enabled", "true"
                )

            if self.wiz_chk_ports.get_active():
                self.parent_app._backend_command(
                    "ports", "--action", "block-preset", "--preset", "risky"
                )

            if self.wiz_chk_installers.get_active():
                self.parent_app._backend_command(
                    "apps", "--action", "lock-installers", "--enabled", "true"
                )

            self.parent_app._show_msg(
                Gtk.MessageType.INFO,
                "Setup Complete",
                "ParentControl has been configured and all selected protections are now active."
            )
            self.response(Gtk.ResponseType.OK)
        except Exception as exc:
            self.btn_next.set_sensitive(True)
            self.btn_back.set_sensitive(True)
            self.parent_app._show_msg(Gtk.MessageType.ERROR, "Setup Failed", str(exc))


class ParentControlApp(Gtk.Window):
    def __init__(self):
        super().__init__(title='ParentControl - Admin Interface')
        self.set_default_size(950, 750)
        self.set_border_width(10)
        self._loading = False

        self.vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.add(self.vbox)

        self._create_menu()
        self.notebook = Gtk.Notebook()
        self.vbox.pack_start(self.notebook, True, True, 0)

        # Build UI Tabs
        self._build_acl_tab()
        self._build_network_tab()
        self._build_rwx_tab()
        self._build_device_tab()
        self._build_apps_tab()
        self._build_queue_tab()
        self._build_maint_tab()
        self._build_setup_tab()
        self._build_status_tab()

        self.refresh_all()
        logging.info('ParentControl GTK3 GUI initialized.')

    def _create_menu(self):
        menubar = Gtk.MenuBar()

        help_menu_item = Gtk.MenuItem(label='Help')
        help_menu = Gtk.Menu()
        help_menu_item.set_submenu(help_menu)

        setup_guide_item = Gtk.MenuItem(label='Setup & Admin Guide')
        setup_guide_item.connect('activate', self._show_admin_guide)
        help_menu.append(setup_guide_item)

        paths_item = Gtk.MenuItem(label='System Paths & Logs')
        paths_item.connect('activate', self._show_paths)
        help_menu.append(paths_item)

        wizard_item = Gtk.MenuItem(label='Run Setup Wizard')
        wizard_item.connect('activate', lambda _: self._open_setup_wizard(force=True))
        help_menu.append(wizard_item)

        about_item = Gtk.MenuItem(label='About')
        about_item.connect('activate', self._show_about)
        help_menu.append(about_item)

        menubar.append(help_menu_item)
        self.vbox.pack_start(menubar, False, False, 0)

    def _show_admin_guide(self, widget):
        text = (
            "Admin Separation:\n"
            "This application configures a separate 'pcadmin' user. The restricted user has sudo stripped, "
            "and PolicyKit (pkexec) is mapped to authenticate against 'pcadmin'.\n\n"
            "If GUI is unavailable, use CLI setup:\n"
            "sudo pc-ctl setup --action wizard\n\n"
            "Users can request access dynamically using the Desktop shortcut which spawns the Request popup."
        )
        self._show_msg(Gtk.MessageType.INFO, 'Setup & Admin Guide', text)

    def _show_paths(self, widget):
        text = (
            "Configuration: /etc/parentcontrol/config.json\n"
            "Log File: /var/log/parentcontrol/parentcontrol.log\n"
            "Popup Script: /opt/parentcontrol/gui/pc-request-popup.py"
        )
        self._show_msg(Gtk.MessageType.INFO, 'System Paths & Logs', text)

    def _show_about(self, widget):
        self._show_msg(Gtk.MessageType.INFO, 'About', 'ParentControl GTK3 Admin Interface for Linux Mint 22.3\nManage restrictions, rules, and approvals.')

    def _show_msg(self, msg_type, title, text):
        dialog = Gtk.MessageDialog(
            transient_for=self, flags=0, message_type=msg_type,
            buttons=Gtk.ButtonsType.OK, text=title
        )
        dialog.format_secondary_text(text)
        dialog.run()
        dialog.destroy()

    def _script_path(self):
        return '/opt/parentcontrol/bin/pc-ctl.sh'

    def _backend_command(self, module, *args):
        script = self._script_path()
        if not os.path.exists(script):
            raise FileNotFoundError(f'ParentControl backend script not found: {script}')

        cmd = [script, module] + list(args) + ['--json']

        if os.geteuid() != 0:
            cmd = ['pkexec'] + cmd

        completed = subprocess.run(cmd, capture_output=True, text=True)
        stdout = (completed.stdout or '').strip()

        if completed.returncode != 0:
            try:
                data = json.loads(stdout)
                raise RuntimeError(data.get('message', stdout))
            except json.JSONDecodeError:
                raise RuntimeError(stdout or f"Command failed with exit code {completed.returncode}")

        if not stdout:
            return {'status': 'ok', 'data': {}}

        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            return {'status': 'ok', 'message': stdout, 'data': {}}

    def _create_list_view(self, column_title):
        liststore = Gtk.ListStore(str, str)
        treeview = Gtk.TreeView(model=liststore)
        renderer = Gtk.CellRendererText()
        column = Gtk.TreeViewColumn(column_title, renderer, text=1)
        treeview.append_column(column)
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(treeview)
        return liststore, treeview, scroll

    def _remove_selected_from_tree(self, treeview, store):
        selection = treeview.get_selection()
        model, treeiter = selection.get_selected()
        if treeiter:
            store.remove(treeiter)

    # --- ACL TAB ---
    def _build_acl_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Feed Controls
        feed_frame = Gtk.Frame(label='Blocklist Feeds')
        
        self.acl_grid = Gtk.Grid()
        self.acl_grid.set_column_spacing(20)
        self.acl_grid.set_row_spacing(10)
        self.acl_grid.set_border_width(10)
        
        # Create the switches
        self.switch_stevenblack = Gtk.Switch()
        self.switch_phishing = Gtk.Switch()
        
        self.switch_stevenblack.set_valign(Gtk.Align.CENTER)
        self.switch_phishing.set_valign(Gtk.Align.CENTER)
        
        # Connect the toggle signals, passing the feed name as user data
        self.switch_stevenblack.connect("notify::active", self._on_feed_toggle, "stevenblack")
        self.switch_phishing.connect("notify::active", self._on_feed_toggle, "phishing_army")
        
        # Add them to the layout
        self.acl_grid.attach(Gtk.Label(label="StevenBlack Ad/Malware Blocklist", xalign=0), 0, 0, 1, 1)
        self.acl_grid.attach(self.switch_stevenblack, 1, 0, 1, 1)
        
        self.acl_grid.attach(Gtk.Label(label="Phishing Army Blocklist", xalign=0), 0, 1, 1, 1)
        self.acl_grid.attach(self.switch_phishing, 1, 1, 1, 1)

        btn_sync = Gtk.Button(label='Sync Feeds Now')
        btn_sync.connect('clicked', self._sync_acl_feed)
        self.acl_grid.attach(btn_sync, 0, 2, 2, 1)
        
        feed_frame.add(self.acl_grid)
        box.pack_start(feed_frame, False, False, 0)

        # Target Inputs
        input_frame = Gtk.Frame(label='Add New URL / IP')
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        self.acl_entry = Gtk.Entry()
        self.acl_entry.set_placeholder_text('example.com or 192.168.1.10')
        input_box.pack_start(self.acl_entry, True, True, 0)

        for l_type in ['Whitelist', 'Greylist', 'Blacklist']:
            btn = Gtk.Button(label=l_type)
            btn.connect('clicked', lambda _, t=l_type.lower(): self._add_acl_entry(t))
            input_box.pack_start(btn, False, False, 0)

        input_frame.add(input_box)
        box.pack_start(input_frame, False, False, 0)

        # List
        list_frame = Gtk.Frame(label='Current Access Control List')
        self.acl_store, self.acl_tree, scroll = self._create_list_view('Rules')
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_remove = Gtk.Button(label='Remove Selected')
        btn_remove.connect('clicked', self._remove_acl_entry)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Web & ACL'))

    def _load_acl_rules(self):
        self._loading = True
        try:
            payload = self._backend_command('acl', '--action', 'list').get('data', {})
            rules = payload.get('rules', [])
            self.acl_store.clear()
            for rule in rules:
                target = rule.get('target', '')
                l_type = rule.get('list', 'unknown').lower()
                if target:
                    self.acl_store.append([f"{l_type}|{target}", f"[{l_type.upper()}] {target}"])
            
            # Safely extract dynamic feed states
            feeds = payload.get("feed_sources", {})
            sb_enabled = feeds.get("stevenblack", {}).get("enabled", False)
            phish_enabled = feeds.get("phishing_army", {}).get("enabled", False)
            
            # Block signals so setting the state programmatically doesn't fire the toggle callback
            self.switch_stevenblack.handler_block_by_func(self._on_feed_toggle)
            self.switch_stevenblack.set_active(sb_enabled)
            self.switch_stevenblack.handler_unblock_by_func(self._on_feed_toggle)
            
            self.switch_phishing.handler_block_by_func(self._on_feed_toggle)
            self.switch_phishing.set_active(phish_enabled)
            self.switch_phishing.handler_unblock_by_func(self._on_feed_toggle)
            
        except Exception as exc:
            logging.exception('ACL Load Error: %s', exc)
        finally:
            self._loading = False

    def _on_feed_toggle(self, switch, gparam, feed_name):
        if self._loading: return
        is_enabled = 'true' if switch.get_active() else 'false'
        try:
            self._backend_command('acl', '--action', 'toggle-feed', '--feed', feed_name, '--enabled', is_enabled)
            logging.info(f"Successfully toggled {feed_name} to {is_enabled}")
            self._load_acl_rules()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Feed Error', str(exc))
            
            # Revert the UI switch state if the backend command failed
            switch.handler_block_by_func(self._on_feed_toggle)
            switch.set_active(not switch.get_active())
            switch.handler_unblock_by_func(self._on_feed_toggle)

    def _sync_acl_feed(self, widget):
        try:
            self._backend_command('acl', '--action', 'sync')
            self._load_acl_rules()
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Feeds synced successfully.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Sync Error', str(exc))

    def _add_acl_entry(self, list_type):
        target = self.acl_entry.get_text().strip()
        if not target: return
        try:
            self._backend_command('acl', '--action', 'add', '--list', list_type, '--target', target)
            self.acl_entry.set_text('')
            self._load_acl_rules()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Error', str(exc))

    def _remove_acl_entry(self, widget):
        selection = self.acl_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        hidden_val = model[treeiter][0]
        l_type, target = hidden_val.split('|', 1)
        try:
            self._backend_command('acl', '--action', 'remove', '--list', l_type, '--target', target)
            self._remove_selected_from_tree(self.acl_tree, self.acl_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'ACL Error', str(exc))

    # --- PORTS TAB ---
    def _build_network_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Presets Block
        preset_frame = Gtk.Frame(label='Quick Presets')
        preset_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        preset_box.set_border_width(10)
        
        self.preset_combo = Gtk.ComboBoxText()
        preset_box.pack_start(self.preset_combo, True, True, 0)
        
        btn_block_preset = Gtk.Button(label='Block Selected Preset')
        btn_block_preset.connect('clicked', self._block_preset)
        preset_box.pack_start(btn_block_preset, False, False, 0)

        btn_block_all_risky = Gtk.Button(label='Block All Common Risky Ports')
        btn_block_all_risky.connect('clicked', lambda _: self._block_risky_preset('risky'))
        preset_box.pack_start(btn_block_all_risky, False, False, 0)
        
        preset_frame.add(preset_box)
        box.pack_start(preset_frame, False, False, 0)

        # Manual Block
        input_frame = Gtk.Frame(label='Block Port Manually')
        input_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        input_box.set_border_width(10)
        
        input_box.pack_start(Gtk.Label(label='Port Number:'), False, False, 0)
        self.port_entry = Gtk.Entry()
        self.port_entry.set_placeholder_text('8080')
        input_box.pack_start(self.port_entry, False, False, 0)
        
        expander = Gtk.Expander(label="Protocol Options")
        self.protocol_combo = Gtk.ComboBoxText()
        for proto in ['BOTH', 'TCP', 'UDP']:
            self.protocol_combo.append_text(proto)
        self.protocol_combo.set_active(0)
        expander.add(self.protocol_combo)
        input_box.pack_start(expander, False, False, 0)

        btn_block = Gtk.Button(label='Block Port')
        btn_block.connect('clicked', self._block_port)
        input_box.pack_start(btn_block, False, False, 0)

        input_frame.add(input_box)
        box.pack_start(input_frame, False, False, 0)

        # List
        list_frame = Gtk.Frame(label='Currently Blocked Ports')
        self.net_store, self.net_tree, scroll = self._create_list_view('Blocked Ports')
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_remove = Gtk.Button(label='Remove Rule')
        btn_remove.connect('clicked', self._remove_port_rule)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Network & Ports'))

    def _load_ports(self):
        try:
            payload = self._backend_command('ports', '--action', 'list').get('data', {})
            self.net_store.clear()
            for rule in payload.get('blocked_ports', []):
                port = rule.get('port')
                proto = rule.get('protocol', 'BOTH')
                label = rule.get('label', f"Port {port} [{proto}]")
                self.net_store.append([f"{port}|{proto}", label])
            
            # Load presets if empty
            if not len(self.preset_combo.get_model() or []):
                preset_data = self._backend_command('ports', '--action', 'list-presets').get('data', {})
                self.port_preset_ids = []
                for p in preset_data.get('presets', []):
                    self.preset_combo.append_text(p.get('label'))
                    self.port_preset_ids.append(p.get('id'))
                if self.port_preset_ids:
                    self.preset_combo.set_active(0)
        except Exception as exc:
            logging.exception('Ports Load Error: %s', exc)

    def _block_port(self, widget):
        port = self.port_entry.get_text().strip()
        proto = self.protocol_combo.get_active_text() or 'BOTH'
        if not port.isdigit(): return
        try:
            self._backend_command('ports', '--action', 'block', '--port', port, '--protocol', proto)
            self.port_entry.set_text('')
            self._load_ports()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Error', str(exc))

    def _block_preset(self, widget):
        idx = self.preset_combo.get_active()
        if idx < 0: return
        p_id = self.port_preset_ids[idx]
        self._block_risky_preset(p_id)

    def _block_risky_preset(self, preset_id):
        try:
            self._backend_command('ports', '--action', 'block-preset', '--preset', preset_id)
            self._load_ports()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Preset Error', str(exc))

    def _remove_port_rule(self, widget):
        selection = self.net_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        val = model[treeiter][0]
        port, proto = val.split('|')
        try:
            self._backend_command('ports', '--action', 'unblock', '--port', port, '--protocol', proto)
            self._remove_selected_from_tree(self.net_tree, self.net_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Ports Error', str(exc))

    # --- PERMISSIONS TAB ---
    def _build_rwx_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Presets
        preset_frame = Gtk.Frame(label='Home Directory Hardening Presets')
        preset_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        preset_box.set_border_width(10)
        
        self.rwx_presets = {
            'lock_dotfiles': Gtk.CheckButton(label='Protect shell dotfiles like .bashrc / .profile'),
            'restrict_extra_home_dirs': Gtk.CheckButton(label='Restrict access to other users\' home folders'),
            'noexec_user_dirs': Gtk.CheckButton(label='Block running executables from Downloads, Desktop & /tmp')
        }
        for name, chk in self.rwx_presets.items():
            chk.connect('toggled', lambda c, n=name: self._toggle_rwx_preset(c, n))
            preset_box.pack_start(chk, False, False, 0)
        
        preset_frame.add(preset_box)
        box.pack_start(preset_frame, False, False, 0)

        # Target 
        input_frame = Gtk.Frame(label='Modify Folder Permissions')
        vbox_input = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        vbox_input.set_border_width(10)

        path_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        path_box.pack_start(Gtk.Label(label='Target Path:'), False, False, 0)
        self.dir_entry = Gtk.Entry()
        path_box.pack_start(self.dir_entry, True, True, 0)
        
        btn_browse = Gtk.Button(label='Browse')
        btn_browse.connect('clicked', self._browse_directory)
        path_box.pack_start(btn_browse, False, False, 0)
        vbox_input.pack_start(path_box, False, False, 0)

        mode_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        mode_box.pack_start(Gtk.Label(label='Access Mode:'), False, False, 0)
        
        self.mode_combo = Gtk.ComboBoxText()
        self.modes = ['locked', 'read-only', 'drop-box', 'full']
        self.mode_combo.append_text('Locked (No Access)')
        self.mode_combo.append_text('Read-Only')
        self.mode_combo.append_text('Drop-Box (Write Only)')
        self.mode_combo.append_text('Full Access')
        self.mode_combo.set_active(0)
        mode_box.pack_start(self.mode_combo, False, False, 0)

        btn_apply = Gtk.Button(label='Apply Permissions')
        btn_apply.connect('clicked', self._apply_rwx)
        mode_box.pack_end(btn_apply, False, False, 0)
        vbox_input.pack_start(mode_box, False, False, 0)

        input_frame.add(vbox_input)
        box.pack_start(input_frame, False, False, 0)

        # List
        list_frame = Gtk.Frame(label='Applied Rules')
        self.rwx_store, self.rwx_tree, scroll = self._create_list_view('Permissions')
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        btn_remove = Gtk.Button(label='Remove Rule')
        btn_remove.connect('clicked', self._remove_rwx_rule)
        action_box.pack_end(btn_remove, False, False, 0)
        box.pack_start(action_box, False, False, 0)

        self.notebook.append_page(box, Gtk.Label(label='Permissions (RWX)'))

    def _load_permissions(self):
        self._loading = True
        try:
            payload = self._backend_command('perms', '--action', 'list').get('data', {})
            self.default_browse_dir = payload.get('default_browse_dir', '/home')
            
            # Presets
            presets = payload.get('presets', {})
            for p_name, chk in self.rwx_presets.items():
                chk.set_active(presets.get(p_name, False))
                
            # Custom Rules
            self.rwx_store.clear()
            for rule in payload.get('custom_rules', []):
                path = rule.get('path')
                perms = rule.get('perms', '---')
                self.rwx_store.append([path, f'[{perms}] {path}'])
        except Exception as exc:
            logging.exception('Perms Load Error: %s', exc)
        finally:
            self._loading = False

    def _toggle_rwx_preset(self, chk, preset_name):
        if self._loading: return
        state = 'true' if chk.get_active() else 'false'
        try:
            self._backend_command('perms', '--action', 'preset', '--name', preset_name, '--enabled', state)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Preset Error', str(exc))

    def _browse_directory(self, widget):
        dialog = Gtk.FileChooserDialog(
            title='Select Folder', parent=self, action=Gtk.FileChooserAction.SELECT_FOLDER
        )
        dialog.add_buttons(Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL, Gtk.STOCK_OPEN, Gtk.ResponseType.OK)
        if hasattr(self, 'default_browse_dir') and os.path.isdir(self.default_browse_dir):
            dialog.set_current_folder(self.default_browse_dir)
            
        if dialog.run() == Gtk.ResponseType.OK:
            self.dir_entry.set_text(dialog.get_filename())
        dialog.destroy()

    def _apply_rwx(self, widget):
        target = self.dir_entry.get_text().strip()
        mode_idx = self.mode_combo.get_active()
        if not target or mode_idx < 0: return
        try:
            self._backend_command('perms', '--action', 'set', '--path', target, '--mode', self.modes[mode_idx])
            self.dir_entry.set_text('')
            self._load_permissions()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Permissions Error', str(exc))

    def _remove_rwx_rule(self, widget):
        selection = self.rwx_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        path = model[treeiter][0]
        try:
            self._backend_command('perms', '--action', 'remove', '--path', path)
            self._remove_selected_from_tree(self.rwx_tree, self.rwx_store)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Permissions Error', str(exc))

    # --- DEVICES TAB ---
    def _build_device_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        frame = Gtk.Frame(label='Hardware Device Controls')
        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        vbox.set_border_width(10)

        self.device_checks = {
            'usb_storage': Gtk.CheckButton(label='USB Mass Storage'),
            'webcam': Gtk.CheckButton(label='Webcam / Camera'),
            'microphone': Gtk.CheckButton(label='Microphone / Audio Input'),
            'bluetooth': Gtk.CheckButton(label='Bluetooth'),
        }
        for check in self.device_checks.values():
            vbox.pack_start(check, False, False, 0)

        apply_btn = Gtk.Button(label='Apply Device Rules')
        apply_btn.connect('clicked', self._apply_device_rules)
        vbox.pack_start(apply_btn, False, False, 0)
        
        frame.add(vbox)
        box.pack_start(frame, True, True, 0)
        self.notebook.append_page(box, Gtk.Label(label='Devices'))

    def _load_devices(self):
        try:
            payload = self._backend_command('devices', '--action', 'list').get('data', {})
            self.device_states = payload.get('devices', {})
            for key, chk in self.device_checks.items():
                chk.set_active(bool(self.device_states.get(key, False)))
        except Exception as exc:
            logging.exception('Devices Load Error: %s', exc)

    def _apply_device_rules(self, widget):
        try:
            for key, check in self.device_checks.items():
                active = check.get_active()
                if active != bool(self.device_states.get(key, False)):
                    self._backend_command('devices', '--action', 'set', '--device', key, '--blocked', 'true' if active else 'false')
            self._load_devices()
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Device rules applied.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Devices Error', str(exc))

   # --- APPS TAB ---
    def _build_apps_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Settings
        settings_frame = Gtk.Frame(label='Application Settings')
        settings_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        settings_box.set_border_width(10)
        
        self.lock_installers_switch = Gtk.Switch()
        self.lock_installers_switch.connect('notify::active', self._on_lock_installers_toggle)
        settings_box.pack_start(Gtk.Label(label='Lock Software Installers:'), False, False, 0)
        settings_box.pack_start(self.lock_installers_switch, False, False, 0)
        
        btn_scan = Gtk.Button(label='Scan Installed Apps')
        btn_scan.connect('clicked', self._scan_apps)
        settings_box.pack_end(btn_scan, False, False, 0)
        
        settings_frame.add(settings_box)
        box.pack_start(settings_frame, False, False, 0)

        # List (Checkbox, ID, Name, Exec)
        list_frame = Gtk.Frame(label='Application Permissions')
        self.apps_store = Gtk.ListStore(bool, str, str, str)
        self.apps_tree = Gtk.TreeView(model=self.apps_store)
        
        # Checkbox Column (Allow / Block)
        toggle_renderer = Gtk.CellRendererToggle()
        toggle_renderer.connect("toggled", self._on_app_toggled)
        toggle_column = Gtk.TreeViewColumn("Allowed", toggle_renderer, active=0)
        self.apps_tree.append_column(toggle_column)

        # Text Columns
        headers = ["Name", "Exec"]
        for i, header in enumerate(headers):
            renderer = Gtk.CellRendererText()
            column = Gtk.TreeViewColumn(header, renderer, text=i+2) # +2 because index 0 is bool, 1 is hidden ID
            self.apps_tree.append_column(column)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.apps_tree)
        list_frame.add(scroll)
        box.pack_start(list_frame, True, True, 0)

        self.notebook.append_page(box, Gtk.Label(label='Applications'))

    def _populate_apps_list(self, apps):
        """Helper to populate the TreeView from an apps array."""
        self.apps_store.clear()
        for app in apps:
            name = app.get('name', '')
            exec_cmd = app.get('exec', '')
            status = app.get('status', 'allow').lower()
            desktop_id = app.get('desktop_id', name)
            
            # True if allowed, False if blocked
            is_allowed = (status != 'block')
            
            if name:
                self.apps_store.append([is_allowed, desktop_id, name, exec_cmd])

    def _load_apps(self):
        self._loading = True
        try:
            payload = self._backend_command('apps', '--action', 'list').get('data', {})
            self.lock_installers_switch.set_active(payload.get('lock_installers', False))
            
            apps = payload.get('applications', [])
            self._populate_apps_list(apps)
        except Exception as exc:
            logging.exception('Apps Load Error: %s', exc)
        finally:
            self._loading = False

    def _scan_apps(self, widget):
        try:
            payload = self._backend_command('apps', '--action', 'scan').get('data', {})
            apps = payload.get('applications', [])
            self._populate_apps_list(apps)
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Scan complete.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Scan Error', str(exc))

    def _on_app_toggled(self, widget, path):
        # Invert the current boolean value in the store
        current_state = self.apps_store[path][0]
        new_state = not current_state
        self.apps_store[path][0] = new_state
        
        # Get the App Name from column 2 (index 2)
        app_name = self.apps_store[path][2]
        status_str = 'Allow' if new_state else 'Block'
        
        try:
            self._backend_command('apps', '--action', 'set', '--app', app_name, '--status', status_str)
        except Exception as exc:
            # Revert the checkbox if the backend command fails
            self.apps_store[path][0] = current_state
            self._show_msg(Gtk.MessageType.ERROR, 'App Rule Error', str(exc))

    def _on_lock_installers_toggle(self, switch, gparam):
        if self._loading: return
        state = 'true' if switch.get_active() else 'false'
        try:
            self._backend_command('apps', '--action', 'lock-installers', '--enabled', state)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'App Error', str(exc))
    # --- QUEUE TAB ---
    def _build_queue_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # List
        self.queue_store = Gtk.ListStore(str, str, str, str, str, str, str) # ID, Status, Type, Target, Reason, User, Created
        self.queue_tree = Gtk.TreeView(model=self.queue_store)
        
        headers = ["Status", "Type", "Target", "Reason", "User", "Created At"]
        for i, header in enumerate(headers):
            renderer = Gtk.CellRendererText()
            column = Gtk.TreeViewColumn(header, renderer, text=i+1)
            self.queue_tree.append_column(column)
            
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(self.queue_tree)
        box.pack_start(scroll, True, True, 0)

        action_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        btn_approve = Gtk.Button(label='Approve')
        btn_approve.connect('clicked', lambda _: self._handle_queue_action('approve'))
        action_box.pack_start(btn_approve, False, False, 0)

        btn_deny = Gtk.Button(label='Deny')
        btn_deny.connect('clicked', lambda _: self._handle_queue_action('deny'))
        action_box.pack_start(btn_deny, False, False, 0)
        
        btn_remove = Gtk.Button(label='Remove Entry')
        btn_remove.connect('clicked', lambda _: self._handle_queue_action('remove'))
        action_box.pack_start(btn_remove, False, False, 0)

        btn_refresh = Gtk.Button(label='Refresh Queue')
        btn_refresh.connect('clicked', lambda _: self._load_queue())
        action_box.pack_end(btn_refresh, False, False, 0)
        
        box.pack_start(action_box, False, False, 0)
        self.notebook.append_page(box, Gtk.Label(label='Approvals Queue'))

    def _load_queue(self):
        try:
            payload = self._backend_command('queue', '--action', 'list').get('data', {})
            self.queue_store.clear()
            for req in payload.get('requests', []):
                self.queue_store.append([
                    req.get('id', ''), req.get('status', ''), req.get('type', ''),
                    req.get('target', ''), req.get('reason', ''), req.get('user', ''),
                    req.get('created_at', '')
                ])
        except Exception as exc:
            logging.exception('Queue Load Error: %s', exc)

    def _handle_queue_action(self, action):
        selection = self.queue_tree.get_selection()
        model, treeiter = selection.get_selected()
        if not treeiter: return
        req_id = model[treeiter][0]
        try:
            self._backend_command('queue', '--action', action, '--id', req_id)
            self._load_queue()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Queue Error', str(exc))

    # --- MAINT TAB ---
    def _build_maint_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Access & Limits
        limit_frame = Gtk.Frame(label='Screen Time & Accessibility')
        limit_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        limit_box.set_border_width(10)
        
        row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.senior_switch = Gtk.Switch()
        self.senior_switch.connect('notify::active', self._on_senior_preset)
        row1.pack_start(Gtk.Label(label='Senior/Dementia Accessibility Preset:'), False, False, 0)
        row1.pack_start(self.senior_switch, False, False, 0)
        limit_box.pack_start(row1, False, False, 0)

        row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        self.time_limit_switch = Gtk.Switch()
        self.time_limit_spin = Gtk.SpinButton.new_with_range(0.5, 24.0, 0.5)
        btn_apply_time = Gtk.Button(label='Apply Time Limit')
        btn_apply_time.connect('clicked', self._apply_time_limit)
        
        self.used_time_lbl = Gtk.Label(label='Used Today: 0m')
        row2.pack_start(Gtk.Label(label='Daily Screen-Time Limit (Hrs):'), False, False, 0)
        row2.pack_start(self.time_limit_switch, False, False, 0)
        row2.pack_start(self.time_limit_spin, False, False, 0)
        row2.pack_start(btn_apply_time, False, False, 0)
        row2.pack_end(self.used_time_lbl, False, False, 0)
        limit_box.pack_start(row2, False, False, 0)
        
        limit_frame.add(limit_box)
        box.pack_start(limit_frame, False, False, 0)

        # Automation
        auto_frame = Gtk.Frame(label='Automated Maintenance')
        auto_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        auto_box.set_border_width(10)
        
        self.auto_checks = {
            'auto_updates': Gtk.CheckButton(label='System Updates'),
            'auto_timeshift': Gtk.CheckButton(label='Timeshift Backups'),
            'auto_trash_purge': Gtk.CheckButton(label='Purge Trash')
        }
        for name, chk in self.auto_checks.items():
            chk.connect('toggled', lambda c, n=name: self._toggle_auto_feature(c, n))
            auto_box.pack_start(chk, False, False, 0)
            
        btn_run_maint = Gtk.Button(label='Run Maintenance Now')
        btn_run_maint.connect('clicked', lambda _: self._run_maint_now())
        auto_box.pack_start(btn_run_maint, False, False, 0)

        auto_frame.add(auto_box)
        box.pack_start(auto_frame, False, False, 0)
        self.notebook.append_page(box, Gtk.Label(label='Automation & Access'))

    def _load_maint(self):
        self._loading = True
        try:
            payload = self._backend_command('maint', '--action', 'list').get('data', {})
            self.senior_switch.set_active(payload.get('senior_preset', False))
            self.time_limit_switch.set_active(payload.get('time_limit_enabled', False))
            self.time_limit_spin.set_value(float(payload.get('daily_limit_hours', 2.0)))
            self.used_time_lbl.set_text(f"Used Today: {payload.get('used_minutes_today', 0)}m")
            
            for key, chk in self.auto_checks.items():
                chk.set_active(payload.get(key, False))
        except Exception as exc:
            logging.exception('Maint Load Error: %s', exc)
        finally:
            self._loading = False

    def _on_senior_preset(self, switch, gparam):
        if self._loading: return
        state = 'true' if switch.get_active() else 'false'
        try:
            self._backend_command('maint', '--action', 'senior-preset', '--enabled', state)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Preset Error', str(exc))

    def _apply_time_limit(self, widget):
        state = 'true' if self.time_limit_switch.get_active() else 'false'
        hours = str(self.time_limit_spin.get_value())
        try:
            self._backend_command('maint', '--action', 'time-limit', '--enabled', state, '--hours', hours)
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Time limit saved.')
            self._load_maint()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Time Limit Error', str(exc))

    def _toggle_auto_feature(self, chk, feature):
        if self._loading: return
        state = 'true' if chk.get_active() else 'false'
        try:
            self._backend_command('maint', '--action', 'set-auto', '--feature', feature, '--enabled', state)
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Maint Error', str(exc))

    def _run_maint_now(self):
        try:
            # Backend handles detachment now; will return near-instantly without freezing GTK
            self._backend_command('maint', '--action', 'run-now')
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Maintenance task triggered successfully and is running in the background.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Maint Error', str(exc))

    # --- SETUP TAB ---
    def _build_setup_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(10)

        # Admin Setup
        admin_frame = Gtk.Frame(label='Admin Separation')
        admin_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        admin_box.set_border_width(10)
        
        row1 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        row1.pack_start(Gtk.Label(label='Target Restricted User:'), False, False, 0)
        self.setup_user_entry = Gtk.Entry()
        row1.pack_start(self.setup_user_entry, True, True, 0)
        admin_box.pack_start(row1, False, False, 0)

        row2 = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        row2.pack_start(Gtk.Label(label='pcadmin Password:'), False, False, 0)
        self.setup_pw_entry = Gtk.Entry()
        self.setup_pw_entry.set_visibility(False)
        row2.pack_start(self.setup_pw_entry, True, True, 0)
        
        row2.pack_start(Gtk.Label(label='Confirm:'), False, False, 0)
        self.setup_pw2_entry = Gtk.Entry()
        self.setup_pw2_entry.set_visibility(False)
        row2.pack_start(self.setup_pw2_entry, True, True, 0)
        admin_box.pack_start(row2, False, False, 0)

        self.strip_sudo_chk = Gtk.CheckButton(label='Strip sudo/admin rights from restricted user')
        self.strip_sudo_chk.set_active(True)
        admin_box.pack_start(self.strip_sudo_chk, False, False, 0)

        btn_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        btn_apply = Gtk.Button(label='Apply Admin Setup')
        btn_apply.connect('clicked', self._apply_admin_setup)
        btn_row.pack_start(btn_apply, False, False, 0)
        
        btn_wizard = Gtk.Button(label='Launch Setup Wizard')
        btn_wizard.connect('clicked', lambda _: self._open_setup_wizard(force=True))
        btn_row.pack_start(btn_wizard, False, False, 0)

        btn_restore = Gtk.Button(label='Restore User Sudo')
        btn_restore.connect('clicked', self._restore_user_sudo)
        btn_row.pack_end(btn_restore, False, False, 0)
        admin_box.pack_start(btn_row, False, False, 0)
        
        admin_frame.add(admin_box)
        box.pack_start(admin_frame, False, False, 0)

        # Contact Setup
        contact_frame = Gtk.Frame(label='Caregiver Contact Info (Shown on User Access Popup)')
        contact_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        contact_box.set_border_width(10)
        
        self.contact_entries = {}
        for field in ['Name', 'Phone', 'Email', 'Note']:
            row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
            row.pack_start(Gtk.Label(label=f'{field}:'), False, False, 0)
            entry = Gtk.Entry()
            self.contact_entries[field.lower()] = entry
            row.pack_start(entry, True, True, 0)
            contact_box.pack_start(row, False, False, 0)

        btn_save_contact = Gtk.Button(label='Save Contact Info')
        btn_save_contact.connect('clicked', self._save_contact)
        contact_box.pack_start(btn_save_contact, False, False, 0)

        contact_frame.add(contact_box)
        box.pack_start(contact_frame, False, False, 0)
        
        self.notebook.append_page(box, Gtk.Label(label='Setup & Caregiver'))

    def _load_setup(self):
        try:
            payload = self._backend_command('status', '--action', 'check').get('data', {})
            self.setup_user_entry.set_text(payload.get('restricted_user', ''))
            contact = payload.get('admin_contact', {})
            self.contact_entries['name'].set_text(contact.get('name', ''))
            self.contact_entries['phone'].set_text(contact.get('phone', ''))
            self.contact_entries['email'].set_text(contact.get('email', ''))
            self.contact_entries['note'].set_text(contact.get('note', ''))
        except Exception as exc:
            logging.exception('Setup Load Error: %s', exc)

    def _apply_admin_setup(self, widget):
        user = self.setup_user_entry.get_text().strip()
        pw1 = self.setup_pw_entry.get_text()
        pw2 = self.setup_pw2_entry.get_text()
        strip = 'true' if self.strip_sudo_chk.get_active() else 'false'
        
        if not user or not pw1:
            self._show_msg(Gtk.MessageType.WARNING, 'Input Error', 'User and Password required.')
            return
        if pw1 != pw2:
            self._show_msg(Gtk.MessageType.WARNING, 'Input Error', 'Passwords do not match.')
            return
            
        try:
            self._backend_command('setup', '--action', 'provision-admin', '--user', user, '--admin-password', pw1, '--strip-user-sudo', strip)
            self.setup_pw_entry.set_text('')
            self.setup_pw2_entry.set_text('')
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Admin provisioned successfully.')
            self.refresh_all()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Setup Error', str(exc))

    def _restore_user_sudo(self, widget):
        try:
            self._backend_command('setup', '--action', 'restore-admin')
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'User sudo restored.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Restore Error', str(exc))

    def _save_contact(self, widget):
        name = self.contact_entries['name'].get_text()
        phone = self.contact_entries['phone'].get_text()
        email = self.contact_entries['email'].get_text()
        note = self.contact_entries['note'].get_text()
        try:
            self._backend_command('setup', '--action', 'set-contact', '--name', name, '--phone', phone, '--email', email, '--note', note)
            self._show_msg(Gtk.MessageType.INFO, 'Success', 'Contact info saved.')
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Contact Error', str(exc))

    # --- STATUS TAB ---
    def _build_status_tab(self):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        box.set_border_width(10)

        self.status_label = Gtk.Label()
        self.status_label.set_xalign(0)
        self.status_label.set_line_wrap(True)
        box.pack_start(self.status_label, False, False, 0)

        btn_refresh = Gtk.Button(label='Refresh Status')
        btn_refresh.connect('clicked', lambda _: self._refresh_status())
        box.pack_start(btn_refresh, False, False, 0)

        log_frame = Gtk.Frame(label='Audit Logs')
        log_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        log_box.set_border_width(5)
        
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.log_textview = Gtk.TextView()
        self.log_textview.set_editable(False)
        css = Gtk.CssProvider()
        css.load_from_data(b'textview { font-family: monospace; font-size: 10pt; }')
        self.log_textview.get_style_context().add_provider(css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        scroll.add(self.log_textview)
        log_box.pack_start(scroll, True, True, 0)

        log_btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=5)
        btn_load_logs = Gtk.Button(label='Load Full Logs')
        btn_load_logs.connect('clicked', self._load_full_logs)
        log_btn_box.pack_start(btn_load_logs, False, False, 0)
        
        btn_clear_logs = Gtk.Button(label='Clear Logs')
        btn_clear_logs.connect('clicked', self._clear_logs)
        log_btn_box.pack_end(btn_clear_logs, False, False, 0)
        
        log_box.pack_start(log_btn_box, False, False, 0)
        log_frame.add(log_box)
        box.pack_start(log_frame, True, True, 0)

        self.notebook.append_page(box, Gtk.Label(label='Status & Logs'))

    def _refresh_status(self):
        try:
            payload = self._backend_command('status', '--action', 'check').get('data', {})
            lines = [
                f"Version: {payload.get('version', 'unknown')}",
                f"Restricted user: {payload.get('restricted_user', 'not configured')} (Has sudo: {payload.get('restricted_user_has_sudo', False)})",
                f"Admin user: {payload.get('admin_user', 'not configured')}",
                f"Admin account ready: {payload.get('admin_account_ready', False)}",
                f"Admin password configured: {payload.get('admin_password_configured', False)}",
                f"Polkit rule ready: {payload.get('polkit_rule_ready', False)}",
                f"Senior Preset: {payload.get('senior_preset', False)}",
                f"Log File: {payload.get('log_file', '')}"
            ]
            self.status_label.set_text('\n'.join(lines))
            
            buf = self.log_textview.get_buffer()
            buf.set_text('\n'.join(payload.get('recent_logs', [])))
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Status Error', str(exc))

    def _load_full_logs(self, widget):
        try:
            payload = self._backend_command('logs', '--action', 'read', '--lines', '100').get('data', {})
            entries = payload.get('entries', [])
            lines = [e.get('message', '') if isinstance(e, dict) else str(e) for e in entries]
            if not lines:
                lines = payload.get('logs', [])
            buf = self.log_textview.get_buffer()
            buf.set_text('\n'.join(lines))
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Log Error', str(exc))

    def _clear_logs(self, widget):
        try:
            self._backend_command('logs', '--action', 'clear')
            self._refresh_status()
        except Exception as exc:
            self._show_msg(Gtk.MessageType.ERROR, 'Log Error', str(exc))

    def _open_setup_wizard(self, force=False):
        try:
            status_data = self._backend_command('status', '--action', 'check').get('data', {})
        except Exception:
            status_data = {}
        if not force and status_data.get('admin_password_configured', False):
            return
        dlg = SetupWizardDialog(self, status_data)
        res = dlg.run()
        dlg.destroy()
        if res == Gtk.ResponseType.OK:
            self.refresh_all()

    def refresh_all(self):
        self._load_acl_rules()
        self._load_ports()
        self._load_permissions()
        self._load_devices()
        self._load_apps()
        self._load_queue()
        self._load_maint()
        self._load_setup()
        self._refresh_status()

if __name__ == '__main__':
    try:
        app = ParentControlApp()
        app.connect('destroy', Gtk.main_quit)
        app.show_all()
        GLib.idle_add(app._open_setup_wizard, False)
        Gtk.main()
    except Exception:
        logging.critical('Crash: %s', traceback.format_exc())
        raise
PC_ADMIN_GUI_EOF

    chown root:root /opt/parentcontrol/gui/parentcontrol-gui.py
    chmod 0755 /opt/parentcontrol/gui/parentcontrol-gui.py

    mkdir -p /usr/share/polkit-1/actions
    cat << 'POLKIT_GUI_EOF' > /usr/share/polkit-1/actions/com.parentcontrol.gui.policy
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
<policyconfig>
  <action id="com.parentcontrol.gui.run">
    <description>Run ParentControl Administrator Interface</description>
    <message>Authentication as ParentControl Administrator (pcadmin) is required</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin_keep</allow_active>
    </defaults>
    <annotate key="org.freedesktop.policykit.exec.path">/opt/parentcontrol/gui/parentcontrol-gui.py</annotate>
    <annotate key="org.freedesktop.policykit.exec.allow_gui">true</annotate>
  </action>
</policyconfig>
POLKIT_GUI_EOF

    chown root:root /usr/share/polkit-1/actions/com.parentcontrol.gui.policy
    chmod 0644 /usr/share/polkit-1/actions/com.parentcontrol.gui.policy

    cat << 'ADMIN_DESKTOP_EOF' > /usr/share/applications/parentcontrol.desktop
[Desktop Entry]
Type=Application
Name=ParentControl Admin
Comment=Configure caregiver & parental controls, web filters, permissions, and approvals
Exec=pkexec /opt/parentcontrol/gui/parentcontrol-gui.py
Icon=preferences-system-privacy
Terminal=false
Categories=System;Settings;
ADMIN_DESKTOP_EOF

    chown root:root /usr/share/applications/parentcontrol.desktop
    chmod 0644 /usr/share/applications/parentcontrol.desktop
}

deploy_pc_request_popup_py() {
    log_step "Writing /opt/parentcontrol/gui/pc-request-popup.py and launcher..."

    cat << 'PC_REQ_POPUP_EOF' > /opt/parentcontrol/gui/pc-request-popup.py
#!/usr/bin/env python3
'''
ParentControl - Restricted-User Access Request & Caregiver Contact Dialog
Runs unprivileged as the monitored user and writes requests into
/var/spool/parentcontrol/requests via pc-queue.sh.
'''
import json
import os
import subprocess
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

PUBLIC_INFO_PATH = "/etc/parentcontrol/public-info.json"
QUEUE_SCRIPT = "/opt/parentcontrol/bin/pc-queue.sh"


def load_contact_info():
    default = {
        "name": "Caregiver / Parent",
        "email": "",
        "phone": "",
        "note": "Need a website or application unlocked? Send a request below."
    }
    if os.path.isfile(PUBLIC_INFO_PATH):
        try:
            with open(PUBLIC_INFO_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            c = data.get("admin_contact", {})
            if isinstance(c, dict):
                default.update({k: v for k, v in c.items() if v})
        except Exception:
            pass
    return default


class RequestAccessWindow(Gtk.Window):
    def __init__(self):
        super().__init__(title="ParentControl - Caregiver Help & Access Request")
        self.set_default_size(500, 380)
        self.set_border_width(14)
        self.set_position(Gtk.WindowPosition.CENTER)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(vbox)

        contact = load_contact_info()
        contact_frame = Gtk.Frame(label="Caregiver / Administrator Contact")
        c_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        c_box.set_border_width(10)
        contact_frame.add(c_box)

        esc = GLib.markup_escape_text
        name_val = esc(str(contact.get("name") or "Caregiver / Parent"))
        phone_val = esc(str(contact.get("phone") or "Not listed"))
        email_val = esc(str(contact.get("email") or "Not listed"))
        note_val = esc(str(contact.get("note") or "Need a website or application unlocked? Send a request below."))

        lines = [
            f"<b>Caregiver:</b> {name_val}",
            f"<b>Phone / SMS:</b> {phone_val}",
            f"<b>Email:</b> {email_val}",
            f"\n<i>{note_val}</i>"
        ]

        lbl = Gtk.Label()
        lbl.set_markup("\n".join(lines))
        lbl.set_xalign(0)
        lbl.set_line_wrap(True)
        lbl.set_selectable(True)
        c_box.pack_start(lbl, False, False, 0)
        vbox.pack_start(contact_frame, False, False, 0)

        form_frame = Gtk.Frame(label="Submit an Access Request")
        f_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        f_box.set_border_width(10)
        form_frame.add(f_box)

        type_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        type_row.pack_start(Gtk.Label(label="Request Type:"), False, False, 0)
        self.type_combo = Gtk.ComboBoxText()
        self.type_combo.append("app", "Application Unlock")
        self.type_combo.append("web", "Website / URL Access")
        self.type_combo.append("file", "File Download")
        self.type_combo.append("other", "Help / Message Caregiver")
        self.type_combo.set_active(0)
        type_row.pack_start(self.type_combo, True, True, 0)
        f_box.pack_start(type_row, False, False, 0)

        target_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        target_row.pack_start(Gtk.Label(label="App or Site:"), False, False, 0)
        self.target_entry = Gtk.Entry()
        self.target_entry.set_placeholder_text("e.g., Calculator or pbskids.org")
        target_row.pack_start(self.target_entry, True, True, 0)
        f_box.pack_start(target_row, False, False, 0)

        reason_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        reason_row.pack_start(Gtk.Label(label="Reason / Note:"), False, False, 0)
        self.reason_entry = Gtk.Entry()
        self.reason_entry.set_placeholder_text("Optional message for your caregiver")
        reason_row.pack_start(self.reason_entry, True, True, 0)
        f_box.pack_start(reason_row, False, False, 0)

        vbox.pack_start(form_frame, True, True, 0)

        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        btn_close = Gtk.Button(label="Close")
        btn_close.connect("clicked", Gtk.main_quit)
        self.btn_send = Gtk.Button(label="Send Request")
        self.btn_send.get_style_context().add_class("suggested-action")
        self.btn_send.connect("clicked", self.on_send_clicked)
        btn_box.pack_end(self.btn_send, False, False, 0)
        btn_box.pack_end(btn_close, False, False, 0)
        vbox.pack_start(btn_box, False, False, 0)

    def on_send_clicked(self, _widget):
        req_type = self.type_combo.get_active_id() or "other"
        target = self.target_entry.get_text().strip()
        reason = self.reason_entry.get_text().strip()

        if not target:
            self._popup(Gtk.MessageType.WARNING, "Missing Info", "Please enter the app name, website, or topic.")
            return

        self.btn_send.set_sensitive(False)
        cmd = [
            QUEUE_SCRIPT,
            "--action", "request",
            "--type", req_type,
            "--target", target,
            "--reason", reason,
            "--json"
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        if res.returncode == 0:
            self._popup(
                Gtk.MessageType.INFO,
                "Request Sent",
                f"Your request for '{target}' has been sent to your caregiver.\nThis window will now close."
            )
            Gtk.main_quit()
        else:
            self.btn_send.set_sensitive(True)
            err = (res.stdout or res.stderr or "Failed to send request.").strip()
            self._popup(Gtk.MessageType.ERROR, "Error", err)

    def _popup(self, mtype, title, msg):
        dlg = Gtk.MessageDialog(transient_for=self, flags=0, message_type=mtype, buttons=Gtk.ButtonsType.OK, text=title)
        dlg.format_secondary_text(msg)
        dlg.run()
        dlg.destroy()


if __name__ == "__main__":
    win = RequestAccessWindow()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()
PC_REQ_POPUP_EOF

    chown root:root /opt/parentcontrol/gui/pc-request-popup.py
    chmod 0755 /opt/parentcontrol/gui/pc-request-popup.py

    cat << 'DESKTOP_EOF' > /usr/share/applications/parentcontrol-request.desktop
[Desktop Entry]
Type=Application
Name=Caregiver Help & Request Access
Comment=View caregiver contact info or ask to unlock a website or application
Exec=/opt/parentcontrol/gui/pc-request-popup.py
Icon=dialog-question
Terminal=false
Categories=Utility;
DESKTOP_EOF

    chown root:root /usr/share/applications/parentcontrol-request.desktop
    chmod 0644 /usr/share/applications/parentcontrol-request.desktop
}


# ------------------------------------------------------------------------------
# Deploy Initial Master Configuration (/etc/parentcontrol/config.json)
# ------------------------------------------------------------------------------
deploy_initial_config() {
    log_step "Ensuring initial configuration exists at /etc/parentcontrol/config.json..."

    bash -c '
        source /opt/parentcontrol/lib/common.sh
        pc_ensure_config_exists
    '
}

# ------------------------------------------------------------------------------
# Automated Verification Self-Test
# ------------------------------------------------------------------------------
run_self_test() {
    log_step "Running automated verification self-test..."

    local test_flags=(--json)
    [[ "$VERBOSE" -eq 1 ]] && test_flags+=(--verbose)
    [[ "$FORCE_OS" -eq 1 ]] && test_flags+=(--force-os)

    /opt/parentcontrol/bin/pc-ctl.sh status --action check "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh config --action get --key browser "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh logs --action read --lines 5 "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh acl --action list "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh perms --action list "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh ports --action list "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh devices --action list "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh apps --action list "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh queue --action list "${test_flags[@]}"
    /opt/parentcontrol/bin/pc-ctl.sh maint --action list "${test_flags[@]}"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_args "$@"
    preflight_checks
    create_directories
    deploy_defaults_conf
    deploy_common_sh
    deploy_pc_ctl_sh
    deploy_pc_setup_sh
    deploy_pc_net_acl_sh
    deploy_pc_perms_sh
    deploy_pc_ports_sh
    deploy_pc_devices_sh
    deploy_pc_apps_sh
    deploy_pc_queue_sh
    deploy_pc_maint_sh
    deploy_pc_request_popup_py
    deploy_parentcontrol_admin_gui_py
    deploy_initial_config
    /opt/parentcontrol/bin/pc-setup.sh --action init --json >/dev/null 2>&1 || true

    if [[ "$SKIP_TEST" -eq 0 ]]; then
        run_self_test
    else
        printf '[OK] ParentControl Part 6 deployed (self-test skipped).\n'
    fi
}

main "$@"