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
    cat <<EOF
ParentControl Bootstrap Installer v${INSTALLER_VERSION}

Description:
  Creates the ParentControl system directories, deploys core configuration
  and shared Bash libraries (defaults.conf, common.sh), applies strict file
  permissions, and runs an automated environment self-test.

Usage:
  sudo bash install-parentcontrol.sh [OPTIONS]

Tags / Options:
  -v, --verbose     Enable detailed step-by-step progress output
      --force-os    Bypass strict Linux Mint 22.3 OS version validation
      --skip-test   Skip the automated post-install self-test
  -h, --help        Show this help message and exit
EOF
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
    chmod 0750 /etc/parentcontrol

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
PC_CURRENT_ACTION="dispatch"
PC_SCRIPT_DESC="Master CLI dispatcher for all ParentControl backend modules."
PC_SCRIPT_USAGE="pc-ctl <module> [OPTIONS]"
PC_SCRIPT_FLAGS="  Modules:
      setup     Provision pcadmin, run setup wizard, configure caregiver contact
      acl       Manage Web/Network whitelist, greylist, blacklist & feeds
      perms     Manage directory permissions (RWX / modes) & home hardening
      ports     Manage UFW port blocks & risky port presets
      devices   Manage hardware peripheral locks (USB, webcam, mic, BT)
      apps      Manage application Allow/Block rules & installer locks
      queue     Manage user access requests & approvals queue
      maint     Manage daily screen-time limits, automation & senior preset
      config    Read or update keys in /etc/parentcontrol/config.json
      logs      Read or clear audit log entries
      status    Return full system, admin, accessibility & recent log status"

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
        "name": "Parent / Caregiver",
        "email": "",
        "phone": "",
        "note": "Use this form to request access to an app or website."
    })
}
tmp_path = pub_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as wf:
    json.dump(pub_data, wf, indent=2)
    wf.write("\n")
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
    printf '   [1] Child / Student Safety\n'
    printf '   [2] Dementia / Senior Care (enables larger text & disables hot-corners)\n'
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

    if [[ "$prof_choice" == "2" && -x "${PC_BIN_DIR}/pc-maint.sh" ]]; then
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
PC_SCRIPT_DESC="Manages Web/Network whitelist, greylist, blacklist, and toggleable blocklist feeds."
PC_SCRIPT_USAGE="pc-net-acl.sh --action <add|remove|list|sync|toggle-feed|set-feed|export-policy|apply> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         add, remove, list, sync, toggle-feed, set-feed, export-policy, apply
      --list <type>           whitelist | greylist | blacklist
      --target <domain|ip>    Domain, URL, or IPv4/IPv6 address
      --enabled <true|false>  Enable or disable the default web blocklist feed
      --url <feed_url>        Custom hosts blocklist feed URL"

PC_FEED_CACHE="${PC_FEED_CACHE:-${PC_VAR_DIR}/feed-blocklist.txt}"
PC_HOSTS_FILE="${PC_HOSTS_FILE:-/etc/hosts}"
PC_HOSTS_BEGIN="${PC_HOSTS_BEGIN:-# BEGIN PARENTCONTROL MANAGED BLOCKS}"
PC_HOSTS_END="${PC_HOSTS_END:-# END PARENTCONTROL MANAGED BLOCKS}"

ACL_ACTION=""
ACL_LIST=""
ACL_TARGET=""
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

normalize_target() {
    python3 -c '
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
' "$1"
}

sync_blocklist_feed() {
    pc_ensure_config_exists
    mkdir -p "$PC_VAR_DIR"

    local feed_url
    feed_url="$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
feeds = cfg.get("network", {}).get("feeds", [])
print(feeds[0] if feeds else "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts")
' "$PC_CONFIG_FILE")"

    local tmp_dl tmp_clean
    tmp_dl="$(mktemp /tmp/pc-feed-dl.XXXXXX)"
    tmp_clean="$(mktemp /tmp/pc-feed-clean.XXXXXX)"

    if curl -fsSL --connect-timeout 10 --max-time 30 "$feed_url" -o "$tmp_dl" 2>/dev/null; then
        python3 -c '
import sys
in_path, out_path = sys.argv[1:3]
domains = set()
with open(in_path, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        parts = s.split()
        dom = parts[1].lower() if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1") else parts[0].lower()
        if dom not in ("localhost", "localhost.localdomain", "broadcasthost", "local") and "." in dom:
            domains.add(dom)
with open(out_path, "w", encoding="utf-8") as wf:
    for d in sorted(domains):
        wf.write(d + "\n")
' "$tmp_dl" "$tmp_clean"
        mv "$tmp_clean" "$PC_FEED_CACHE"
        chmod 0644 "$PC_FEED_CACHE"
    else
        rm -f "$tmp_clean"
        [[ -f "$PC_FEED_CACHE" ]] || : > "$PC_FEED_CACHE"
    fi
    rm -f "$tmp_dl"
}

enforce_network_rules() {
    pc_ensure_config_exists
    pc_backup_file "$PC_HOSTS_FILE"

    local tmp_hosts
    tmp_hosts="$(mktemp /tmp/pc-hosts.XXXXXX)"

    python3 -c '
import json, os, sys

cfg_path, hosts_path, feed_path, begin_mark, end_mark, out_path = sys.argv[1:7]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

net = cfg.get("network", {})
whitelist = {x.lower() for x in net.get("whitelist", [])}
blacklist = [x.lower() for x in net.get("blacklist", [])]
feed_enabled = bool(net.get("default_feed_enabled", True))

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
    if dom not in whitelist and dom not in seen:
        seen.add(dom)
        blocked_domains.append(dom)

if feed_enabled and os.path.isfile(feed_path):
    with open(feed_path, "r", encoding="utf-8", errors="ignore") as ff:
        for line in ff:
            dom = line.strip().lower()
            if dom and dom not in whitelist and dom not in seen:
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
' "$PC_CONFIG_FILE" "$PC_HOSTS_FILE" "$PC_FEED_CACHE" "$PC_HOSTS_BEGIN" "$PC_HOSTS_END" "$tmp_hosts"

    chown root:root "$tmp_hosts"
    chmod 0644 "$tmp_hosts"
    mv "$tmp_hosts" "$PC_HOSTS_FILE"
}

build_acl_state_json() {
    pc_ensure_config_exists
    python3 -c '
import json, os, sys

cfg_path, feed_path = sys.argv[1:3]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

net = cfg.get("network", {})
white = net.get("whitelist", [])
grey  = net.get("greylist", [])
black = net.get("blacklist", [])
feed_enabled = bool(net.get("default_feed_enabled", True))
feeds = net.get("feeds", ["https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"])

feed_count = 0
if os.path.isfile(feed_path):
    with open(feed_path, "r", encoding="utf-8", errors="ignore") as ff:
        feed_count = sum(1 for _ in ff)

rules = (
    [{"list": "whitelist", "target": x} for x in white] +
    [{"list": "greylist", "target": x} for x in grey] +
    [{"list": "blacklist", "target": x} for x in black]
)

print(json.dumps({
    "default_feed_enabled": feed_enabled,
    "whitelist": white,
    "greylist": grey,
    "blacklist": black,
    "rules": rules,
    "feeds": feeds,
    "feed_domains_count": feed_count
}))
' "$PC_CONFIG_FILE" "$PC_FEED_CACHE"
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
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
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
' "$PC_CONFIG_FILE" "$ACL_LIST" "$norm_target" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    enforce_network_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Added '${norm_target}' to ${ACL_LIST}" "$state_json"
}

handle_remove() {
    local norm_target
    if ! norm_target="$(normalize_target "$ACL_TARGET")"; then
        pc_emit_error "Invalid target '${ACL_TARGET}'." 2
        exit 2
    fi

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg removed_flag
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    removed_flag="$(python3 -c '
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
' "$PC_CONFIG_FILE" "$ACL_LIST" "$norm_target" "$tmp_cfg")"

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

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Removed '${norm_target}' from ACL" "$state_json"
}

handle_toggle_feed() {
    if [[ "$FEED_ENABLED" != "true" && "$FEED_ENABLED" != "false" ]]; then
        pc_emit_error "Action 'toggle-feed' requires --enabled <true|false>." 2
        exit 2
    fi

    pc_init_transaction
    pc_json_set "network.default_feed_enabled" "$FEED_ENABLED"
    if [[ "$FEED_ENABLED" == "true" && ! -s "$PC_FEED_CACHE" ]]; then
        sync_blocklist_feed
    fi
    enforce_network_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Set default web blocklist feed enabled=${FEED_ENABLED}" "$state_json"
}

handle_set_feed() {
    if [[ -z "$FEED_URL" ]]; then
        pc_emit_error "Action 'set-feed' requires --url <feed_url>." 2
        exit 2
    fi

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"
    python3 -c '
import json, sys
cfg_path, url, out_path = sys.argv[1:4]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
net = data.setdefault("network", {})
net["feeds"] = [url]
net["default_feed_enabled"] = True
with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
' "$PC_CONFIG_FILE" "$FEED_URL" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    sync_blocklist_feed
    enforce_network_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Updated and synced web blocklist feed URL" "$state_json"
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
            sync_blocklist_feed
            enforce_network_rules
            pc_commit_transaction
            pc_emit_result "Synced web blocklist feed" "$(build_acl_state_json)"
            ;;
        list|export-policy)
            # Note: export-policy schema will be adapted to match the browser extension's
            # finalized policy template once extension integration is ready.
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
        pc_emit_error "Valid restricted_user is not configured in config.json." 2
        exit 2
    fi
    printf '%s' "$r_user"
}

resolve_safe_user_path() {
    local raw_path="$1"
    local user_home="$2"

    python3 -c '
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
' "$raw_path" "$user_home"
}

normalize_rwx_and_label() {
    local mode="$1"
    local raw_perms="$2"
    local target_path="$3"

    if [[ -n "$mode" ]]; then
        case "$mode" in
            locked|none|block)     printf '---|Locked (No Access)'; return 0 ;;
            read-only|readonly|ro) printf 'R-X|Read-Only'; return 0 ;;
            drop-box|dropbox|wo)   printf '-WX|Drop-Box (Write Only)'; return 0 ;;
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
    local acl_str
    acl_str="$(printf '%s' "$rwx" | tr '[:upper:]' '[:lower:]')"

    [[ -e "$target_path" ]] || return 0

    if [[ -d "$target_path" ]]; then
        setfacl -R -m "u:${r_user}:${acl_str}" "$target_path" 2>/dev/null || true
        setfacl -R -m "d:u:${r_user}:${acl_str}" "$target_path" 2>/dev/null || true
    else
        setfacl -m "u:${r_user}:${acl_str}" "$target_path" 2>/dev/null || true
    fi
}

enforce_all_perms() {
    local r_user="$1"
    local user_home
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"
    pc_ensure_config_exists

    local dump
    dump="$(python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
perms = cfg.get("permissions", {})
presets = perms.get("presets", {})
print("PRESET|lock_dotfiles|" + ("1" if presets.get("lock_dotfiles") else "0"))
print("PRESET|restrict_extra_home_dirs|" + ("1" if presets.get("restrict_extra_home_dirs") else "0"))
print("PRESET|noexec_user_dirs|" + ("1" if presets.get("noexec_user_dirs") else "0"))
for r in perms.get("custom_rules", []):
    print(f"RULE|{r.get(\"path\", \"\")}|{r.get(\"perms\", \"R-X\")}")
' "$PC_CONFIG_FILE")"

    local lock_dot="0" restrict_extra="0" noexec_dirs="0"
    while IFS='|' read -r kind a b; do
        if [[ "$kind" == "PRESET" ]]; then
            [[ "$a" == "lock_dotfiles" ]] && lock_dot="$b"
            [[ "$a" == "restrict_extra_home_dirs" ]] && restrict_extra="$b"
            [[ "$a" == "noexec_user_dirs" ]] && noexec_dirs="$b"
        elif [[ "$kind" == "RULE" && -n "$a" ]]; then
            apply_single_acl_rule "$r_user" "$a" "$b"
        fi
    done <<< "$dump"

    for df in ".bashrc" ".profile" ".bash_aliases" ".zshrc"; do
        local fpath="${user_home}/${df}"
        if [[ -f "$fpath" ]]; then
            if [[ "$lock_dot" == "1" ]]; then
                chown root:root "$fpath"
                chmod 0644 "$fpath"
            else
                chown "${r_user}:$(id -gn "$r_user")" "$fpath"
            fi
        fi
    done

    if [[ "$noexec_dirs" == "1" ]]; then
        for d in "${user_home}/Downloads" "${user_home}/Desktop" "/tmp"; do
            [[ -d "$d" ]] && setfacl -R -m "u:${r_user}:rw-" "$d" 2>/dev/null || true
            [[ -d "$d" ]] && setfacl -m "u:${r_user}:rwx" "$d" 2>/dev/null || true
        done
    fi
}

build_perms_state_json() {
    pc_ensure_config_exists
    python3 -c '
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
perms = cfg.get("permissions", {})
print(json.dumps({
    "restricted_user": cfg.get("restricted_user", ""),
    "default_browse_dir": "/home/" + cfg.get("restricted_user", ""),
    "presets": perms.get("presets", {
        "lock_dotfiles": False,
        "restrict_extra_home_dirs": False,
        "noexec_user_dirs": False
    }),
    "custom_rules": perms.get("custom_rules", [])
}))
' "$PC_CONFIG_FILE"
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

    pc_init_transaction
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, path_val, rwx_str, label_str, out_path = sys.argv[1:6]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
perms = data.setdefault("permissions", {"presets": {}, "custom_rules": []})
rules = [r for r in perms.get("custom_rules", []) if r.get("path") != path_val]
rules.append({"path": path_val, "perms": rwx_str, "label": label_str})
rules.sort(key=lambda x: x.get("path", ""))
perms["custom_rules"] = rules

with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
' "$PC_CONFIG_FILE" "$resolved_path" "$rwx_val" "$mode_label" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    apply_single_acl_rule "$r_user" "$resolved_path" "$rwx_val"
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

    local tmp_cfg removed
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"
    removed="$(python3 -c '
import json, sys
cfg_path, p_val, out_path = sys.argv[1:4]
data = json.load(open(cfg_path, "r", encoding="utf-8"))
perms = data.setdefault("permissions", {"presets": {}, "custom_rules": []})
old = perms.get("custom_rules", [])
new = [r for r in old if r.get("path") != p_val]
perms["custom_rules"] = new
with open(out_path, "w", encoding="utf-8") as wf:
    json.dump(data, wf, indent=2)
    wf.write("\n")
print("1" if len(new) != len(old) else "0")
' "$PC_CONFIG_FILE" "$resolved_path" "$tmp_cfg")"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    if [[ "$removed" != "1" ]]; then
        pc_commit_transaction
        pc_emit_error "No saved permission rule found for '${resolved_path}'." 2
        exit 2
    fi

    if [[ -e "$resolved_path" ]]; then
        setfacl -R -x "u:${r_user}" "$resolved_path" 2>/dev/null || true
        setfacl -R -x "d:u:${r_user}" "$resolved_path" 2>/dev/null || true
    fi

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
# ParentControl - Automation, Screen-Time Limits & Maintenance Manager
# File: /opt/parentcontrol/bin/pc-maint.sh
#
# Description:
#   Manages daily screen-time limits (with systemd timer enforcement and
#   session locking), automated APT security updates, Timeshift snapshots,
#   Trash auto-purging, and the Senior/Dementia accessibility preset.
#
# GUI HANDOFF:
#   Invoked via pc-ctl.sh:
#     pkexec /opt/parentcontrol/bin/pc-ctl.sh maint --action <verb> [OPTIONS] --json
#
#   Supported Actions:
#     time-limit    --hours <0.5..24.0> [--enabled <true|false>] --json
#     check-time    --json
#     set-auto      --feature <auto_updates|auto_timeshift|auto_trash_purge> --enabled <true|false> --json
#     senior-preset --enabled <true|false> --json
#     run-now       --json
#     list          --json
#     apply         --json
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="maint"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages daily screen-time limits, automated maintenance tasks, and senior presets."
PC_SCRIPT_USAGE="pc-maint.sh --action <time-limit|check-time|set-auto|senior-preset|run-now|list|apply> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         time-limit, check-time, set-auto, senior-preset, run-now, list, apply
      --hours <float>         Daily screen-time limit in hours (0.5 to 24.0)
      --feature <name>        auto_updates | auto_timeshift | auto_trash_purge
      --enabled <true|false>  Enable or disable the specified setting"

readonly PC_TIMELIMIT_HELPER="/usr/local/bin/parentcontrol-timelimit-check"
readonly PC_TIMELIMIT_SERVICE="/etc/systemd/system/parentcontrol-timelimit.service"
readonly PC_TIMELIMIT_TIMER="/etc/systemd/system/parentcontrol-timelimit.timer"
readonly PC_USAGE_DIR="${PC_VAR_DIR}/usage"

MAINT_ACTION=""
LIMIT_HOURS=""
AUTO_FEATURE=""
FEATURE_ENABLED=""

# ------------------------------------------------------------------------------
# Parse Module-Specific Flags
# ------------------------------------------------------------------------------
parse_maint_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                MAINT_ACTION="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --hours)
                LIMIT_HOURS="${2:-}"
                shift 2
                ;;
            --feature)
                AUTO_FEATURE="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
                shift 2
                ;;
            --enabled)
                FEATURE_ENABLED="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for pc-maint.sh: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$MAINT_ACTION" ]]; then
        pc_emit_error "Missing required --action <time-limit|check-time|set-auto|senior-preset|run-now|list|apply>." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$MAINT_ACTION"
}

get_restricted_user() {
    pc_ensure_config_exists
    local r_user
    r_user="$(pc_json_get "restricted_user" 2>/dev/null || true)"
    if [[ -z "$r_user" ]]; then
        pc_emit_error "No restricted_user configured in config.json." 2
        exit 2
    fi
    printf '%s' "$r_user"
}

# ------------------------------------------------------------------------------
# Install / Configure Screen-Time Watcher & Systemd Timer
# ------------------------------------------------------------------------------
install_timelimit_units() {
    mkdir -p "$PC_USAGE_DIR"
    chown root:root "$PC_USAGE_DIR"
    chmod 0750 "$PC_USAGE_DIR"

    cat << 'HELPER_EOF' > "$PC_TIMELIMIT_HELPER"
#!/usr/bin/env bash
set -euo pipefail
exec /opt/parentcontrol/bin/pc-maint.sh --action check-time --json >/dev/null
HELPER_EOF
    chown root:root "$PC_TIMELIMIT_HELPER"
    chmod 0755 "$PC_TIMELIMIT_HELPER"

    cat << 'SERVICE_EOF' > "$PC_TIMELIMIT_SERVICE"
[Unit]
Description=ParentControl Daily Screen-Time Enforcement Check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/parentcontrol-timelimit-check
SERVICE_EOF

    cat << 'TIMER_EOF' > "$PC_TIMELIMIT_TIMER"
[Unit]
Description=Run ParentControl Daily Screen-Time Check Every Minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=parentcontrol-timelimit.service

[Install]
WantedBy=timers.target
TIMER_EOF

    chmod 0644 "$PC_TIMELIMIT_SERVICE" "$PC_TIMELIMIT_TIMER"
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
}

sync_timelimit_timer_state() {
    pc_ensure_config_exists
    local enabled
    enabled="$(pc_json_get "automation.time_limit_enabled" 2>/dev/null || printf 'false')"

    install_timelimit_units
    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        if [[ "$enabled" == "true" ]]; then
            systemctl enable --now parentcontrol-timelimit.timer >/dev/null 2>&1 || true
        else
            systemctl disable --now parentcontrol-timelimit.timer >/dev/null 2>&1 || true
        fi
    fi
}

# ------------------------------------------------------------------------------
# Evaluate & Enforce Today's Screen-Time Quota
# ------------------------------------------------------------------------------
evaluate_screen_time() {
    pc_ensure_config_exists
    mkdir -p "$PC_USAGE_DIR"

    local r_user
    r_user="$(get_restricted_user)"
    local today_str
    today_str="$(date +%Y-%m-%d)"
    local usage_file="${PC_USAGE_DIR}/${today_str}.json"

    # Check if restricted_user currently has an active graphical session
    local is_active_session="0"
    if command -v loginctl >/dev/null 2>&1; then
        while read -r sid uid uname seat tty; do
            [[ "$uname" == "$r_user" ]] || continue
            local s_type s_state s_locked
            s_type="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
            s_state="$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)"
            s_locked="$(loginctl show-session "$sid" -p LockedHint --value 2>/dev/null || true)"
            if [[ "$s_type" =~ ^(x11|wayland)$ && "$s_state" == "active" && "$s_locked" != "yes" ]]; then
                is_active_session="1"
                break
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
    fi

    local eval_json
    eval_json="$(python3 -c '
import json, os, sys

cfg_path, usage_path, r_user, active_flag = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

auto = cfg.get("automation", {})
enabled = bool(auto.get("time_limit_enabled", False))
limit_hours = float(auto.get("daily_limit_hours", 2.0))
limit_minutes = max(1, int(round(limit_hours * 60)))

usage = {"user": r_user, "used_minutes": 0}
if os.path.isfile(usage_path):
    try:
        with open(usage_path, "r", encoding="utf-8") as uf:
            usage = json.load(uf)
    except Exception:
        usage = {"user": r_user, "used_minutes": 0}

used = int(usage.get("used_minutes", 0))
if enabled and active_flag == "1":
    used += 1
    usage["used_minutes"] = used
    with open(usage_path, "w", encoding="utf-8") as wf:
        json.dump(usage, wf, indent=2)
        wf.write("\n")

remaining = max(0, limit_minutes - used)
should_lock = enabled and (active_flag == "1") and (used >= limit_minutes)
should_warn = enabled and (active_flag == "1") and (remaining == 5)

print(json.dumps({
    "enabled": enabled,
    "limit_hours": limit_hours,
    "limit_minutes": limit_minutes,
    "used_minutes_today": used,
    "remaining_minutes": remaining,
    "active_session": active_flag == "1",
    "should_warn": should_warn,
    "should_lock": should_lock
}))
' "$PC_CONFIG_FILE" "$usage_file" "$r_user" "$is_active_session")"

    local should_warn should_lock
    should_warn="$(python3 -c 'import json, sys; print("1" if json.loads(sys.argv[1]).get("should_warn") else "0")' "$eval_json")"
    should_lock="$(python3 -c 'import json, sys; print("1" if json.loads(sys.argv[1]).get("should_lock") else "0")' "$eval_json")"

    if [[ "$should_warn" == "1" ]]; then
        local r_uid
        r_uid="$(id -u "$r_user")"
        sudo -u "$r_user" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${r_uid}/bus" \
            notify-send -u critical "ParentControl Screen Time" "5 minutes of daily screen time remaining." 2>/dev/null || true
    fi

    if [[ "$should_lock" == "1" ]] && command -v loginctl >/dev/null 2>&1; then
        while read -r sid uid uname seat tty; do
            if [[ "$uname" == "$r_user" ]]; then
                loginctl lock-session "$sid" >/dev/null 2>&1 || true
            fi
        done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
        pc_log "INFO" "Daily screen-time limit reached for '${r_user}'; locked active session."
    fi

    printf '%s' "$eval_json"
}

# ------------------------------------------------------------------------------
# Automation Features & Senior Preset Enforcement
# ------------------------------------------------------------------------------
apply_auto_updates() {
    local enabled="$1"
    local val="0"
    [[ "$enabled" == "true" ]] && val="1"

    mkdir -p /etc/apt/apt.conf.d
    cat << EOF > /etc/apt/apt.conf.d/20parentcontrol-auto-upgrades
// Managed by ParentControl (pc-maint.sh)
APT::Periodic::Update-Package-Lists "${val}";
APT::Periodic::Unattended-Upgrade "${val}";
APT::Periodic::AutocleanInterval "7";
EOF
    chmod 0644 /etc/apt/apt.conf.d/20parentcontrol-auto-upgrades
}

apply_senior_preset() {
    local enabled="$1"
    local r_user r_uid user_home r_group
    r_user="$(get_restricted_user)"
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

purge_old_trash() {
    local r_user user_home trash_files trash_info
    r_user="$(get_restricted_user)"
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"
    trash_files="${user_home}/.local/share/Trash/files"
    trash_info="${user_home}/.local/share/Trash/info"

    [[ -d "$trash_files" ]] && find "$trash_files" -mindepth 1 -mtime +7 -exec rm -rf {} + 2>/dev/null || true
    [[ -d "$trash_info" ]] && find "$trash_info" -mindepth 1 -mtime +7 -exec rm -f {} + 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Build Standardized Maintenance State JSON for GUI Hydration
# ------------------------------------------------------------------------------
build_maint_state_json() {
    pc_ensure_config_exists
    local today_str
    today_str="$(date +%Y-%m-%d)"
    local usage_file="${PC_USAGE_DIR}/${today_str}.json"

    python3 -c '
import json, os, sys

cfg_path, usage_path = sys.argv[1:3]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

auto = cfg.get("automation", {})
used = 0
if os.path.isfile(usage_path):
    try:
        with open(usage_path, "r", encoding="utf-8") as uf:
            used = int(json.load(uf).get("used_minutes", 0))
    except Exception:
        used = 0

print(json.dumps({
    "restricted_user": cfg.get("restricted_user", ""),
    "time_limit_enabled": bool(auto.get("time_limit_enabled", False)),
    "daily_limit_hours": float(auto.get("daily_limit_hours", 2.0)),
    "used_minutes_today": used,
    "auto_updates": bool(auto.get("auto_updates", False)),
    "auto_timeshift": bool(auto.get("auto_timeshift", False)),
    "auto_trash_purge": bool(auto.get("auto_trash_purge", False)),
    "senior_preset": bool(auto.get("senior_preset", False))
}))
' "$PC_CONFIG_FILE" "$usage_file"
}

# ------------------------------------------------------------------------------
# Action Handlers
# ------------------------------------------------------------------------------
handle_time_limit() {
    if [[ -z "$LIMIT_HOURS" ]]; then
        pc_emit_error "Action 'time-limit' requires --hours <0.5..24.0>." 2
        exit 2
    fi

    local valid_hours
    if ! valid_hours="$(python3 -c '
import sys
try:
    h = float(sys.argv[1])
except ValueError:
    sys.exit(1)
if h < 0.5 or h > 24.0:
    sys.exit(1)
print(round(h, 2))
' "$LIMIT_HOURS")"; then
        pc_emit_error "Invalid --hours '${LIMIT_HOURS}'. Must be between 0.5 and 24.0." 2
        exit 2
    fi

    local enabled_flag="true"
    if [[ "$FEATURE_ENABLED" == "false" ]]; then
        enabled_flag="false"
    fi

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, hours_val, enabled_str, out_path = sys.argv[1], float(sys.argv[2]), sys.argv[3], sys.argv[4]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

auto = data.setdefault("automation", {})
auto["daily_limit_hours"] = hours_val
auto["time_limit_enabled"] = (enabled_str == "true")

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$PC_CONFIG_FILE" "$valid_hours" "$enabled_flag" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    sync_timelimit_timer_state
    pc_commit_transaction

    local state_json
    state_json="$(build_maint_state_json)"
    pc_emit_result "Set daily screen-time limit to ${valid_hours} hours (enabled=${enabled_flag})" "$state_json"
}

handle_check_time() {
    local eval_json
    eval_json="$(evaluate_screen_time)"
    pc_emit_result "Evaluated daily screen-time quota" "$eval_json"
}

handle_set_auto() {
    case "$AUTO_FEATURE" in
        auto_updates|auto_timeshift|auto_trash_purge)
            ;;
        *)
            pc_emit_error "Invalid --feature '${AUTO_FEATURE}'. Must be auto_updates, auto_timeshift, or auto_trash_purge." 2
            exit 2
            ;;
    esac

    if [[ "$FEATURE_ENABLED" != "true" && "$FEATURE_ENABLED" != "false" ]]; then
        pc_emit_error "Action 'set-auto' requires --enabled <true|false>." 2
        exit 2
    fi

    pc_init_transaction
    pc_json_set "automation.${AUTO_FEATURE}" "$FEATURE_ENABLED"

    if [[ "$AUTO_FEATURE" == "auto_updates" ]]; then
        apply_auto_updates "$FEATURE_ENABLED"
    elif [[ "$AUTO_FEATURE" == "auto_trash_purge" && "$FEATURE_ENABLED" == "true" ]]; then
        purge_old_trash
    fi

    pc_commit_transaction

    local state_json
    state_json="$(build_maint_state_json)"
    pc_emit_result "Set automation feature '${AUTO_FEATURE}' to ${FEATURE_ENABLED}" "$state_json"
}

handle_senior_preset() {
    if [[ "$FEATURE_ENABLED" != "true" && "$FEATURE_ENABLED" != "false" ]]; then
        pc_emit_error "Action 'senior-preset' requires --enabled <true|false>." 2
        exit 2
    fi

    pc_init_transaction
    pc_json_set "automation.senior_preset" "$FEATURE_ENABLED"
    apply_senior_preset "$FEATURE_ENABLED"
    pc_commit_transaction

    local state_json
    state_json="$(build_maint_state_json)"
    pc_emit_result "Set Senior/Dementia accessibility preset to ${FEATURE_ENABLED}" "$state_json"
}

handle_run_now() {
    pc_ensure_config_exists
    local ran_tasks=()

    local do_trash do_timeshift
    do_trash="$(pc_json_get "automation.auto_trash_purge" 2>/dev/null || printf 'false')"
    do_timeshift="$(pc_json_get "automation.auto_timeshift" 2>/dev/null || printf 'false')"

    if [[ "$do_trash" == "true" ]]; then
        purge_old_trash
        ran_tasks+=("trash_purge")
    fi

    if [[ "$do_timeshift" == "true" ]] && command -v timeshift >/dev/null 2>&1; then
        timeshift --create --comments "ParentControl Automated Snapshot" >/dev/null 2>&1 || true
        ran_tasks+=("timeshift_snapshot")
    fi

    local state_json
    state_json="$(build_maint_state_json)"
    pc_emit_result "Completed immediate maintenance run (${ran_tasks[*]:-none_enabled})" "$state_json"
}

handle_list() {
    local state_json
    state_json="$(build_maint_state_json)"
    pc_emit_result "Retrieved automation and screen-time settings" "$state_json"
}

handle_apply() {
    pc_ensure_config_exists
    sync_timelimit_timer_state

    local auto_up senior_on
    auto_up="$(pc_json_get "automation.auto_updates" 2>/dev/null || printf 'false')"
    senior_on="$(pc_json_get "automation.senior_preset" 2>/dev/null || printf 'false')"

    apply_auto_updates "$auto_up"
    apply_senior_preset "$senior_on"

    local state_json
    state_json="$(build_maint_state_json)"
    pc_emit_result "Applied all automation and maintenance policies" "$state_json"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_maint_args "$@"
    pc_require_root
    pc_verify_mint

    case "$MAINT_ACTION" in
        time-limit)
            handle_time_limit
            ;;
        check-time)
            handle_check_time
            ;;
        set-auto)
            handle_set_auto
            ;;
        senior-preset)
            handle_senior_preset
            ;;
        run-now)
            handle_run_now
            ;;
        list)
            handle_list
            ;;
        apply)
            handle_apply
            ;;
        *)
            pc_emit_error "Unsupported action '${MAINT_ACTION}' (expected: time-limit, check-time, set-auto, senior-preset, run-now, list, apply)." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_MAINT_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-maint.sh
    chmod 0755 /opt/parentcontrol/bin/pc-maint.sh
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
from gi.repository import Gtk

PUBLIC_INFO_PATH = "/etc/parentcontrol/public-info.json"
QUEUE_SCRIPT = "/opt/parentcontrol/bin/pc-queue.sh"


def load_contact_info():
    default = {
        "name": "Parent / Caregiver",
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
        super().__init__(title="ParentControl - Request Access & Help")
        self.set_default_size(480, 360)
        self.set_border_width(14)
        self.set_position(Gtk.WindowPosition.CENTER)

        vbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(vbox)

        contact = load_contact_info()
        contact_frame = Gtk.Frame(label="Caregiver / Administrator Contact")
        c_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        c_box.set_border_width(10)
        contact_frame.add(c_box)

        lines = [f"<b>Admin:</b> {contact.get('name', 'Parent / Caregiver')}"]
        if contact.get("phone"):
            lines.append(f"<b>Phone / SMS:</b> {contact['phone']}")
        if contact.get("email"):
            lines.append(f"<b>Email:</b> {contact['email']}")
        if contact.get("note"):
            lines.append(f"\n<i>{contact['note']}</i>")

        lbl = Gtk.Label()
        lbl.set_markup("\n".join(lines))
        lbl.set_xalign(0)
        lbl.set_line_wrap(True)
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
        btn_send = Gtk.Button(label="Send Request")
        btn_send.get_style_context().add_class("suggested-action")
        btn_send.connect("clicked", self.on_send_clicked)
        btn_box.pack_end(btn_send, False, False, 0)
        btn_box.pack_end(btn_close, False, False, 0)
        vbox.pack_start(btn_box, False, False, 0)

    def on_send_clicked(self, _widget):
        req_type = self.type_combo.get_active_id() or "other"
        target = self.target_entry.get_text().strip()
        reason = self.reason_entry.get_text().strip()

        if not target:
            self._popup(Gtk.MessageType.WARNING, "Missing Info", "Please enter the app name, website, or topic.")
            return

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
            self.target_entry.set_text("")
            self.reason_entry.set_text("")
            self._popup(Gtk.MessageType.INFO, "Request Sent", f"Your request for '{target}' has been sent to your caregiver.")
        else:
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
Name=Request Access & Caregiver Help
Comment=Ask your parent or caregiver to unlock a website or application
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
    deploy_initial_config
    /opt/parentcontrol/bin/pc-setup.sh --action init --json >/dev/null 2>&1 || true

    if [[ "$SKIP_TEST" -eq 0 ]]; then
        run_self_test
    else
        printf '[OK] ParentControl Part 6 deployed (self-test skipped).\n'
    fi
}

main "$@"