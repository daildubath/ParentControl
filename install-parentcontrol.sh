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

    install -d -m 0755 -o root -g root /opt/parentcontrol
    install -d -m 0755 -o root -g root /opt/parentcontrol/bin
    install -d -m 0755 -o root -g root /opt/parentcontrol/lib

    install -d -m 0750 -o root -g root /etc/parentcontrol
    install -d -m 0750 -o root -g root /var/lib/parentcontrol
    install -d -m 0700 -o root -g root /var/lib/parentcontrol/backup
    install -d -m 0751 -o root -g root /var/lib/parentcontrol/queue
    install -d -m 1733 -o root -g root /var/lib/parentcontrol/queue/pending
    install -d -m 0750 -o root -g root /var/lib/parentcontrol/queue/approved
    install -d -m 0750 -o root -g root /var/lib/parentcontrol/queue/archive

    install -d -m 0750 -o root -g root /var/log/parentcontrol

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
readonly PC_POLKIT_RULE="/etc/polkit-1/rules.d/50-parentcontrol.rules"

# Managed /etc/hosts markers for ACL enforcement
readonly PC_HOSTS_FILE="/etc/hosts"
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
# ParentControl - Master CLI Router & Core State/Log Manager
# File: /opt/parentcontrol/bin/pc-ctl.sh
#
# Description:
#   Primary privileged entry point invoked by the Python GUI (via pkexec) or
#   an administrator over SSH. Routes module subcommands to /opt/parentcontrol/bin/pc-*.sh
#   and natively manages master configuration (config.json), audit logs, and
#   system health status.
#
# GUI HANDOFF:
#   Invoke via PolicyKit:
#     pkexec /opt/parentcontrol/bin/pc-ctl.sh <module> --action <verb> [OPTIONS] --json
#
#   Built-in Modules:
#     status --action check --json
#       -> Returns {"status":"ok","module":"status","action":"check","data":{...}}
#     config --action get [--key <dot.path>] --json
#       -> Returns full config.json or specific dot-path key under "data"
#     config --action set --key <dot.path> --value <val> --json
#       -> Updates config.json atomically with rollback support
#     logs   --action read [--lines <N>] [--level <INFO|WARN|ERROR|DEBUG>] --json
#       -> Returns {"count":N,"entries":[{"timestamp":"...","level":"...","module":"...","message":"..."}]}
#     logs   --action clear --json
#       -> Truncates parentcontrol.log and records a fresh admin-clear audit entry
#
#   External Sub-Modules (forwarded automatically):
#     acl | perms | ports | devices | apps | maint | queue | users | ext-bridge
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="ctl"
PC_CURRENT_ACTION="dispatch"
PC_SCRIPT_DESC="Master CLI router, configuration manager, and audit log controller for ParentControl."
PC_SCRIPT_USAGE="pc-ctl.sh <module> --action <verb> [MODULE_OPTIONS] [--json] [--verbose] [--help]"
PC_SCRIPT_FLAGS="  Built-in Modules & Actions:
    status   --action check
    config   --action <get|set> [--key <dot.path>] [--value <value>]
    logs     --action <read|clear> [--lines <N>] [--level <LEVEL>]

  Routed Modules (run 'pc-ctl.sh <module> --help' for module-specific flags):
    acl, perms, ports, devices, apps, maint, queue, users, ext-bridge"

# ------------------------------------------------------------------------------
# Resolve External Module Script Path
# ------------------------------------------------------------------------------
resolve_module_script() {
    local mod="$1"
    case "$mod" in
        acl|net-acl)
            printf '%s/pc-net-acl.sh' "$PC_BIN_DIR"
            ;;
        perms|permissions)
            printf '%s/pc-perms.sh' "$PC_BIN_DIR"
            ;;
        ports|firewall)
            printf '%s/pc-ports.sh' "$PC_BIN_DIR"
            ;;
        devices|hardware)
            printf '%s/pc-devices.sh' "$PC_BIN_DIR"
            ;;
        apps|software)
            printf '%s/pc-apps.sh' "$PC_BIN_DIR"
            ;;
        maint|maintenance)
            printf '%s/pc-maint.sh' "$PC_BIN_DIR"
            ;;
        queue|approvals)
            printf '%s/pc-queue.sh' "$PC_BIN_DIR"
            ;;
        users|profiles)
            printf '%s/pc-users.sh' "$PC_BIN_DIR"
            ;;
        ext|ext-bridge|extension)
            printf '%s/pc-ext-bridge.sh' "$PC_BIN_DIR"
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Built-in Module: status
# ------------------------------------------------------------------------------
handle_status_module() {
    PC_MODULE_NAME="status"
    local action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                action="${2:-}"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for 'status' module: $1" 2
                exit 2
                ;;
        esac
    done

    [[ -z "$action" ]] && action="check"
    PC_CURRENT_ACTION="$action"

    if [[ "$action" != "check" ]]; then
        pc_emit_error "Unsupported action '${action}' for 'status' (expected: check)." 2
        exit 2
    fi

    pc_ensure_config_exists

    local admin_exists="false"
    if id -u "$PC_ADMIN_USER" >/dev/null 2>&1; then
        admin_exists="true"
    fi

    local polkit_exists="false"
    [[ -f "$PC_POLKIT_RULE" ]] && polkit_exists="true"

    local status_json
    status_json="$(python3 -c '
import json, os, sys

cfg_path, bin_dir, log_path, admin_ok, polkit_ok = sys.argv[1:6]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

installed_scripts = sorted(
    name for name in os.listdir(bin_dir)
    if name.startswith("pc-") and name.endswith(".sh")
) if os.path.isdir(bin_dir) else []

log_size = os.path.getsize(log_path) if os.path.isfile(log_path) else 0

print(json.dumps({
    "version": cfg.get("version", "unknown"),
    "restricted_user": cfg.get("restricted_user", ""),
    "admin_user": cfg.get("admin_user", "pcadmin"),
    "admin_account_ready": admin_ok == "true",
    "polkit_rule_ready": polkit_ok == "true",
    "browser": cfg.get("browser", "firefox"),
    "installed_modules": installed_scripts,
    "log_size_bytes": log_size
}))
' "$PC_CONFIG_FILE" "$PC_BIN_DIR" "$PC_LOG_FILE" "$admin_exists" "$polkit_exists")"

    pc_emit_result "ParentControl status retrieved" "$status_json"
}

# ------------------------------------------------------------------------------
# Built-in Module: config
# ------------------------------------------------------------------------------
handle_config_module() {
    PC_MODULE_NAME="config"
    local action="" key="" raw_value="" has_value=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                action="${2:-}"
                shift 2
                ;;
            --key)
                key="${2:-}"
                shift 2
                ;;
            --value)
                raw_value="${2:-}"
                has_value=1
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for 'config' module: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$action" ]]; then
        pc_emit_error "Missing required --action <get|set> for 'config' module." 2
        exit 2
    fi

    PC_CURRENT_ACTION="$action"
    pc_ensure_config_exists

    case "$action" in
        get)
            if [[ -z "$key" ]]; then
                local full_cfg
                full_cfg="$(cat "$PC_CONFIG_FILE")"
                pc_emit_result "Retrieved full configuration" "$full_cfg"
            else
                local val_json
                if ! val_json="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    cur = json.load(f)
for part in sys.argv[2].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(1)
print(json.dumps({"key": sys.argv[2], "value": cur}))
' "$PC_CONFIG_FILE" "$key")"; then
                    pc_emit_error "Configuration key not found: '${key}'" 2
                    exit 2
                fi
                pc_emit_result "Retrieved configuration key '${key}'" "$val_json"
            fi
            ;;
        set)
            if [[ -z "$key" || "$has_value" -ne 1 ]]; then
                pc_emit_error "Action 'set' requires both --key <dot.path> and --value <val>." 2
                exit 2
            fi

            local normalized_json
            normalized_json="$(python3 -c '
import json, sys
raw = sys.argv[1]
try:
    parsed = json.loads(raw)
except Exception:
    parsed = raw
print(json.dumps(parsed))
' "$raw_value")"

            pc_init_transaction
            pc_json_set "$key" "$normalized_json"
            pc_commit_transaction

            local updated_payload
            updated_payload="$(python3 -c '
import json, sys
print(json.dumps({"key": sys.argv[1], "value": json.loads(sys.argv[2])}))
' "$key" "$normalized_json")"
            pc_emit_result "Updated configuration key '${key}'" "$updated_payload"
            ;;
        *)
            pc_emit_error "Unsupported action '${action}' for 'config' (expected: get, set)." 2
            exit 2
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Built-in Module: logs
# ------------------------------------------------------------------------------
handle_logs_module() {
    PC_MODULE_NAME="logs"
    local action="" max_lines=200 level_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                action="${2:-}"
                shift 2
                ;;
            --lines)
                max_lines="${2:-}"
                shift 2
                ;;
            --level)
                level_filter="${2:-}"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for 'logs' module: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$action" ]]; then
        pc_emit_error "Missing required --action <read|clear> for 'logs' module." 2
        exit 2
    fi

    PC_CURRENT_ACTION="$action"

    case "$action" in
        read)
            if ! [[ "$max_lines" =~ ^[0-9]+$ ]] || [[ "$max_lines" -le 0 ]]; then
                pc_emit_error "--lines must be a positive integer (got: '${max_lines}')." 2
                exit 2
            fi

            if [[ ! -f "$PC_LOG_FILE" ]]; then
                pc_emit_result "Audit log is currently empty" '{"count":0,"entries":[]}'
                return 0
            fi

            local logs_json
            logs_json="$(python3 -c '
import json, sys

log_path = sys.argv[1]
limit = int(sys.argv[2])
lvl_filter = sys.argv[3].strip().upper()

entries = []
with open(log_path, "r", encoding="utf-8", errors="replace") as f:
    for raw_line in f:
        line = raw_line.rstrip("\r\n")
        if not line:
            continue
        parts = [p.strip() for p in line.split("|", 3)]
        if len(parts) == 4:
            entry = {
                "timestamp": parts[0],
                "level": parts[1],
                "module": parts[2],
                "message": parts[3]
            }
        else:
            entry = {
                "timestamp": "",
                "level": "INFO",
                "module": "unknown",
                "message": line
            }
        if lvl_filter and entry["level"].upper() != lvl_filter:
            continue
        entries.append(entry)

sliced = entries[-limit:]
print(json.dumps({"count": len(sliced), "entries": sliced}))
' "$PC_LOG_FILE" "$max_lines" "$level_filter")"

            pc_emit_result "Retrieved audit log entries" "$logs_json"
            ;;
        clear)
            pc_init_transaction
            if [[ -f "$PC_LOG_FILE" ]]; then
                pc_backup_file "$PC_LOG_FILE"
                : > "$PC_LOG_FILE"
                chown root:root "$PC_LOG_FILE"
                chmod 0640 "$PC_LOG_FILE"
            fi
            pc_commit_transaction
            pc_emit_result "Audit log cleared by administrator" '{"cleared":true}'
            ;;
        *)
            pc_emit_error "Unsupported action '${action}' for 'logs' (expected: read, clear)." 2
            exit 2
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Main Dispatcher
# ------------------------------------------------------------------------------
main() {
    local leading_flags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--verbose)
                PC_VERBOSE=1
                leading_flags+=("$1")
                shift
                ;;
            --json)
                PC_JSON_OUTPUT=1
                leading_flags+=("$1")
                shift
                ;;
            --force-os)
                PC_FORCE_OS=1
                leading_flags+=("$1")
                shift
                ;;
            -h|--help)
                pc_print_help
                exit 0
                ;;
            -*)
                pc_emit_error "Unknown global flag '${1}'. Specify a module first or run --help." 2
                exit 2
                ;;
            *)
                break
                ;;
        esac
    done

    if [[ $# -eq 0 ]]; then
        pc_emit_error "No module specified. Run 'pc-ctl.sh --help' for usage." 2
        exit 2
    fi

    local target_module="$1"
    shift

    local module_script=""
    if module_script="$(resolve_module_script "$target_module")"; then
        if [[ ! -x "$module_script" ]]; then
            pc_emit_error "Module '${target_module}' (${module_script}) is not installed yet." 1
            exit 1
        fi
        exec "$module_script" "${leading_flags[@]}" "$@"
    fi

    pc_parse_common_flags "$@"
    pc_require_root
    pc_verify_mint

    case "$target_module" in
        status)
            handle_status_module "${PC_REMAINING_ARGS[@]}"
            ;;
        config)
            handle_config_module "${PC_REMAINING_ARGS[@]}"
            ;;
        logs)
            handle_logs_module "${PC_REMAINING_ARGS[@]}"
            ;;
        *)
            pc_emit_error "Unknown module '${target_module}'. Run 'pc-ctl.sh --help' for valid modules." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_CTL_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-ctl.sh
    chmod 0755 /opt/parentcontrol/bin/pc-ctl.sh
    if [[ -w /usr/local/bin ]]; then
        ln -sf /opt/parentcontrol/bin/pc-ctl.sh /usr/local/bin/pc-ctl
    fi
}

# ------------------------------------------------------------------------------
# Deploy /opt/parentcontrol/bin/pc-setup.sh (Sub-Chunk 1.3)
# ------------------------------------------------------------------------------
deploy_pc_setup_sh() {
    log_step "Writing /opt/parentcontrol/bin/pc-setup.sh..."

    cat << 'PC_SETUP_SH_EOF' > /opt/parentcontrol/bin/pc-setup.sh
#!/usr/bin/env bash
# ==============================================================================
# ParentControl - Initial System Provisioner & Privilege Lockdown
# File: /opt/parentcontrol/bin/pc-setup.sh
#
# Description:
#   Configures the hidden administrator account (pcadmin), deploys PolicyKit
#   authentication rules for the Python GUI, revokes sudo/adm privileges from
#   the restricted user account, and records baseline system settings.
#
# GUI HANDOFF:
#   Run once during initial Linux Mint 22.3 setup (interactive or via flags),
#   or invoke via pkexec when re-provisioning an account:
#     sudo /opt/parentcontrol/bin/pc-setup.sh --user <username> --admin-pass <pass> --json
#
#   Returns JSON when --json is passed:
#     {"status":"ok","module":"setup","action":"install","message":"...","data":{
#       "restricted_user":"<user>",
#       "admin_user":"pcadmin",
#       "admin_hidden":true,
#       "polkit_configured":true,
#       "sudo_revoked":true
#     }}
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="setup"
PC_CURRENT_ACTION="install"
PC_SCRIPT_DESC="Provisions hidden pcadmin user, PolicyKit rules, and revokes restricted user sudo."
PC_SCRIPT_USAGE="sudo pc-setup.sh [--user <username>] [--admin-pass <password>] [OPTIONS]"
PC_SCRIPT_FLAGS="      --user <username>       Target restricted Linux Mint user account
      --admin-pass <pass>     Password for hidden '${PC_ADMIN_USER}' admin account
      --unattended            Fail instead of prompting if required values are missing
      --keep-sudo             Keep restricted user in sudo/adm (recommended for VM testing)"

TARGET_USER=""
ADMIN_PASS=""
UNATTENDED=0
KEEP_SUDO=0

# ------------------------------------------------------------------------------
# Parse Setup Flags
# ------------------------------------------------------------------------------
parse_setup_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                TARGET_USER="${2:-}"
                shift 2
                ;;
            --admin-pass)
                ADMIN_PASS="${2:-}"
                shift 2
                ;;
            --unattended)
                UNATTENDED=1
                shift
                ;;
            --keep-sudo)
                KEEP_SUDO=1
                shift
                ;;
            *)
                pc_emit_error "Unknown flag for pc-setup.sh: $1" 2
                exit 2
                ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# Interactive Prompts (when flags are omitted on a TTY)
# ------------------------------------------------------------------------------
gather_inputs() {
    if [[ -z "$TARGET_USER" ]]; then
        if [[ "$UNATTENDED" -eq 1 || "$PC_JSON_OUTPUT" -eq 1 || ! -t 0 ]]; then
            pc_emit_error "Missing required --user <username> flag." 2
            exit 2
        fi
        local default_user="${SUDO_USER:-}"
        if [[ -n "$default_user" && "$default_user" != "root" && "$default_user" != "$PC_ADMIN_USER" ]]; then
            read -r -p "Enter username to restrict [${default_user}]: " TARGET_USER
            TARGET_USER="${TARGET_USER:-$default_user}"
        else
            read -r -p "Enter username to restrict: " TARGET_USER
        fi
    fi

    if [[ -z "$TARGET_USER" ]]; then
        pc_emit_error "Restricted username cannot be empty." 2
        exit 2
    fi

    if [[ "$TARGET_USER" == "root" || "$TARGET_USER" == "$PC_ADMIN_USER" ]]; then
        pc_emit_error "Cannot restrict system/admin account '${TARGET_USER}'." 2
        exit 2
    fi

    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        pc_emit_error "Target user '${TARGET_USER}' does not exist on this system." 2
        exit 2
    fi

    if [[ -z "$ADMIN_PASS" ]]; then
        if [[ "$UNATTENDED" -eq 1 || "$PC_JSON_OUTPUT" -eq 1 || ! -t 0 ]]; then
            pc_emit_error "Missing required --admin-pass <password> flag." 2
            exit 2
        fi
        local pass_confirm=""
        while true; do
            read -r -s -p "Set password for hidden admin '${PC_ADMIN_USER}': " ADMIN_PASS
            printf '\n' >&2
            if [[ "${#ADMIN_PASS}" -lt 8 ]]; then
                printf '[WARN] Password must be at least 8 characters.\n' >&2
                continue
            fi
            read -r -s -p "Confirm password for '${PC_ADMIN_USER}': " pass_confirm
            printf '\n' >&2
            if [[ "$ADMIN_PASS" != "$pass_confirm" ]]; then
                printf '[WARN] Passwords do not match. Try again.\n' >&2
                continue
            fi
            break
        done
    fi

    if [[ "${#ADMIN_PASS}" -lt 8 ]]; then
        pc_emit_error "Admin password must be at least 8 characters long." 2
        exit 2
    fi
}

# ------------------------------------------------------------------------------
# Create & Hide Dedicated Admin User (pcadmin)
# ------------------------------------------------------------------------------
provision_admin_account() {
    pc_log "INFO" "Provisioning hidden admin account '${PC_ADMIN_USER}'..."

    if ! id -u "$PC_ADMIN_USER" >/dev/null 2>&1; then
        useradd --create-home \
                --shell /bin/bash \
                --comment "ParentControl Administrator" \
                "$PC_ADMIN_USER"
        pc_log "INFO" "Created local user '${PC_ADMIN_USER}'."
    else
        pc_log "INFO" "User '${PC_ADMIN_USER}' already exists; updating credentials and groups."
    fi

    printf '%s:%s\n' "$PC_ADMIN_USER" "$ADMIN_PASS" | chpasswd
    usermod -aG sudo "$PC_ADMIN_USER"

    # Verify password hash is active in /etc/shadow before touching restricted user
    local shadow_entry
    shadow_entry="$(getent shadow "$PC_ADMIN_USER" | cut -d: -f2)"
    if [[ -z "$shadow_entry" || "$shadow_entry" == "!"* || "$shadow_entry" == "*"* ]]; then
        pc_emit_error "Failed to verify active password hash for '${PC_ADMIN_USER}'." 1
        exit 1
    fi

    # Hide pcadmin from Linux Mint Slick-Greeter / LightDM login screen
    mkdir -p "$PC_ACCOUNTS_SERVICE_DIR"
    local acct_file="${PC_ACCOUNTS_SERVICE_DIR}/${PC_ADMIN_USER}"
    pc_backup_file "$acct_file"

    cat << 'ACCOUNTS_SERVICE_EOF' > "$acct_file"
[User]
SystemAccount=true
ACCOUNTS_SERVICE_EOF

    chown root:root "$acct_file"
    chmod 0644 "$acct_file"
    pc_log "INFO" "Configured AccountsService to hide '${PC_ADMIN_USER}' from login screen."
}

# ------------------------------------------------------------------------------
# Deploy PolicyKit Rule for GUI Elevation (pkexec)
# ------------------------------------------------------------------------------
deploy_polkit_rule() {
    pc_log "INFO" "Deploying PolicyKit rule at ${PC_POLKIT_RULE}..."

    mkdir -p "$(dirname "$PC_POLKIT_RULE")"
    pc_backup_file "$PC_POLKIT_RULE"

    cat << 'POLKIT_RULE_EOF' > "$PC_POLKIT_RULE"
// ParentControl PolicyKit Authorization Rule
// Prompts for the hidden 'pcadmin' password whenever the GUI invokes
// /opt/parentcontrol/bin/pc-* via pkexec, even after the primary user
// has been removed from the sudo group.

polkit.addAdminRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec") {
        var prog = action.lookup("program");
        if (prog && prog.indexOf("/opt/parentcontrol/bin/pc-") === 0) {
            return ["unix-user:pcadmin"];
        }
    }
    return null;
});

polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.policykit.exec") {
        var prog = action.lookup("program");
        if (prog && prog.indexOf("/opt/parentcontrol/bin/pc-") === 0) {
            return polkit.Result.AUTH_ADMIN;
        }
    }
    return polkit.Result.NOT_HANDLED;
});
POLKIT_RULE_EOF

    chown root:root "$PC_POLKIT_RULE"
    chmod 0644 "$PC_POLKIT_RULE"
}

# ------------------------------------------------------------------------------
# Revoke Admin Privileges from Restricted User & Lock Directories
# ------------------------------------------------------------------------------
lockdown_restricted_user() {
    local sudo_revoked="false"

    if [[ "$KEEP_SUDO" -eq 1 ]]; then
        pc_log "WARN" "--keep-sudo specified: leaving '${TARGET_USER}' in sudo/adm groups."
    else
        for grp in sudo adm; do
            if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
                gpasswd -d "$TARGET_USER" "$grp" >/dev/null
                pc_log "INFO" "Removed '${TARGET_USER}' from '${grp}' group."
            fi
        done
        sudo_revoked="true"
    fi

    # Enforce strict root ownership across ParentControl paths
    chown -R root:root "$PC_BASE_DIR" "$PC_ETC_DIR" "$PC_VAR_DIR" "$PC_LOG_DIR"
    chmod 0755 "$PC_BASE_DIR" "$PC_BIN_DIR" "$PC_LIB_DIR"
    chmod 0750 "$PC_ETC_DIR" "$PC_VAR_DIR" "$PC_LOG_DIR"
    chmod 0640 "$PC_CONFIG_FILE"
    chmod 1733 "${PC_QUEUE_DIR}/pending"

    local target_json admin_json
    target_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$TARGET_USER")"
    admin_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$PC_ADMIN_USER")"

    pc_json_set "restricted_user" "$target_json"
    pc_json_set "admin_user" "$admin_json"

    printf '%s' "$sudo_revoked"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_setup_args "$@"
    pc_require_root
    pc_verify_mint
    gather_inputs

    pc_init_transaction
    pc_ensure_config_exists
    provision_admin_account
    deploy_polkit_rule

    local sudo_revoked
    sudo_revoked="$(lockdown_restricted_user)"
    pc_commit_transaction

    local result_json
    result_json="$(python3 -c '
import json, sys
print(json.dumps({
    "restricted_user": sys.argv[1],
    "admin_user": sys.argv[2],
    "admin_hidden": True,
    "polkit_configured": True,
    "sudo_revoked": sys.argv[3] == "true"
}))
' "$TARGET_USER" "$PC_ADMIN_USER" "$sudo_revoked")"

    pc_emit_result "ParentControl setup completed for user '${TARGET_USER}'" "$result_json"
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
# ParentControl - Network & Web Access Control List (ACL) Manager
# File: /opt/parentcontrol/bin/pc-net-acl.sh
#
# Description:
#   Manages custom domain/URL/IP whitelists and blacklists plus Pi-hole/hosts
#   blocklist feeds in config.json, enforcing them across /etc/hosts, browser
#   enterprise policies (Firefox, Chromium, Brave), and UFW (for raw IPs).
#
# GUI HANDOFF:
#   Invoked via pc-ctl.sh:
#     pkexec /opt/parentcontrol/bin/pc-ctl.sh acl --action <verb> [OPTIONS] --json
#
#   Supported Actions:
#     add         --list <whitelist|blacklist> --target <url|domain|ip> --json
#     remove      [--list <whitelist|blacklist>] --target <url|domain|ip> --json
#     list        --json
#     apply       --json
#     sync        [--url <feed_url>] --json
#     add-feed    --url <feed_url> --json
#     remove-feed --url <feed_url> --json
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="acl"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages domain/URL/IP ACLs and Pi-hole blocklist feeds across /etc/hosts and browser policies."
PC_SCRIPT_USAGE="pc-net-acl.sh --action <add|remove|list|apply|sync|add-feed|remove-feed> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         add, remove, list, apply, sync, add-feed, remove-feed
      --list <type>           Target list for add/remove: whitelist or blacklist
      --target <url|domain>   Domain, full URL, or IPv4/IPv6 address
      --url <feed_url>        Hosts/Pi-hole blocklist URL for sync/add-feed/remove-feed"

readonly PC_FEED_CACHE_FILE="${PC_VAR_DIR}/feed-domains.cache"

ACL_ACTION=""
ACL_LIST=""
ACL_TARGET=""
ACL_FEED_URL=""

# ------------------------------------------------------------------------------
# Parse Module-Specific Flags
# ------------------------------------------------------------------------------
parse_acl_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                ACL_ACTION="${2:-}"
                shift 2
                ;;
            --list)
                ACL_LIST="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            --target)
                ACL_TARGET="${2:-}"
                shift 2
                ;;
            --url)
                ACL_FEED_URL="${2:-}"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for pc-net-acl.sh: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$ACL_ACTION" ]]; then
        pc_emit_error "Missing required --action <add|remove|list|apply|sync|add-feed|remove-feed>." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$ACL_ACTION"
}

# ------------------------------------------------------------------------------
# Normalize & Validate Target (URL, Domain, or IP)
# Emits "<kind>|<normalized_value>" where kind is "domain" or "ip"
# ------------------------------------------------------------------------------
normalize_target() {
    local raw_input="$1"

    python3 -c '
import ipaddress, re, sys
from urllib.parse import urlparse

raw = sys.argv[1].strip()
if not raw:
    sys.exit(1)

candidate = raw
if "://" in candidate:
    parsed = urlparse(candidate)
    candidate = parsed.hostname or ""
else:
    candidate = candidate.split("/", 1)[0].split("?", 1)[0].split("#", 1)[0]
    if candidate.count(":") == 1 and not candidate.startswith("["):
        candidate = candidate.split(":", 1)[0]

candidate = candidate.strip().strip(".").lower()
if candidate.startswith("*."):
    candidate = candidate[2:]

# Normalize www.<domain> to root <domain> (while keeping other subdomains intact)
if candidate.startswith("www.") and candidate.count(".") >= 2:
    candidate = candidate[4:]

if not candidate:
    sys.exit(1)

try:
    ip_obj = ipaddress.ip_address(candidate)
    print(f"ip|{ip_obj.compressed}")
    sys.exit(0)
except ValueError:
    pass

if len(candidate) > 253 or "." not in candidate:
    sys.exit(1)

labels = candidate.split(".")
label_re = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$")
if any(not label_re.match(lbl) for lbl in labels):
    sys.exit(1)

print(f"domain|{candidate}")
' "$raw_input"
}

# ------------------------------------------------------------------------------
# Enforce Current ACL Rules & Cached Feeds to /etc/hosts, Browsers, and UFW
# ------------------------------------------------------------------------------
enforce_acl_rules() {
    pc_ensure_config_exists

    pc_backup_file "$PC_HOSTS_FILE"
    pc_backup_file "/etc/firefox/policies/policies.json"
    pc_backup_file "/etc/chromium/policies/managed/parentcontrol.json"
    pc_backup_file "/etc/brave/policies/managed/parentcontrol.json"

    mkdir -p /etc/firefox/policies \
             /etc/chromium/policies/managed \
             /etc/brave/policies/managed

    local tmp_hosts
    tmp_hosts="$(mktemp /tmp/pc-hosts.XXXXXX)"

    local ip_actions
    ip_actions="$(python3 -c '
import ipaddress, json, os, sys

cfg_path, hosts_path, tmp_hosts_path, feed_cache_path, begin_marker, end_marker = sys.argv[1:7]

with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

acl = cfg.get("acl", {})
whitelist = sorted(set(x.strip().lower() for x in acl.get("whitelist", []) if x.strip()))
blacklist = sorted(set(x.strip().lower() for x in acl.get("blacklist", []) if x.strip()))

# Expand whitelist with www. variants so whitelisting example.com also unblocks www.example.com
wl_expanded = set()
for item in whitelist:
    wl_expanded.add(item)
    if not item.startswith("www.") and "." in item:
        wl_expanded.add(f"www.{item}")

effective_blacklist = [item for item in blacklist if item not in wl_expanded]

def is_ip(val):
    try:
        ipaddress.ip_address(val)
        return True
    except ValueError:
        return False

bl_domains = [d for d in effective_blacklist if not is_ip(d)]
bl_ips = [i for i in effective_blacklist if is_ip(i)]

# 1. Build /etc/hosts managed section (custom blacklist + cached Pi-hole feed domains)
host_entries = []
seen_hosts = set()

for dom in bl_domains:
    variants = [dom]
    if not dom.startswith("www."):
        variants.append(f"www.{dom}")
    for v in variants:
        if v not in wl_expanded and v not in seen_hosts:
            seen_hosts.add(v)
            host_entries.append(f"0.0.0.0 {v}")

if os.path.isfile(feed_cache_path):
    with open(feed_cache_path, "r", encoding="utf-8", errors="replace") as f:
        for raw_line in f:
            dom = raw_line.strip().lower()
            if not dom or dom in wl_expanded or dom in seen_hosts:
                continue
            seen_hosts.add(dom)
            host_entries.append(f"0.0.0.0 {dom}")

existing_lines = []
if os.path.exists(hosts_path):
    with open(hosts_path, "r", encoding="utf-8", errors="replace") as f:
        in_block = False
        for line in f:
            stripped = line.rstrip("\r\n")
            if stripped == begin_marker:
                in_block = True
                continue
            if stripped == end_marker:
                in_block = False
                continue
            if not in_block:
                existing_lines.append(stripped)

while existing_lines and existing_lines[-1] == "":
    existing_lines.pop()

out_lines = list(existing_lines)
if host_entries:
    out_lines.append("")
    out_lines.append(begin_marker)
    out_lines.extend(host_entries)
    out_lines.append(end_marker)

with open(tmp_hosts_path, "w", encoding="utf-8") as f:
    f.write("\n".join(out_lines) + "\n")

# 2. Update Firefox Enterprise Policy (/etc/firefox/policies/policies.json)
ff_policy_path = "/etc/firefox/policies/policies.json"
ff_data = {"policies": {}}
if os.path.exists(ff_policy_path):
    try:
        with open(ff_policy_path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
            if isinstance(loaded, dict):
                ff_data = loaded
    except Exception:
        ff_data = {"policies": {}}

ff_data.setdefault("policies", {})
if effective_blacklist or whitelist:
    ff_patterns_block = []
    for item in effective_blacklist:
        if is_ip(item):
            ff_patterns_block.append(f"*://{item}/*")
        else:
            ff_patterns_block.append(f"*://*.{item}/*")
            ff_patterns_block.append(f"*://{item}/*")
    ff_patterns_allow = []
    for item in whitelist:
        if is_ip(item):
            ff_patterns_allow.append(f"*://{item}/*")
        else:
            ff_patterns_allow.append(f"*://*.{item}/*")
            ff_patterns_allow.append(f"*://{item}/*")
    ff_data["policies"]["WebsiteFilter"] = {
        "Block": ff_patterns_block[:1000],
        "Exceptions": ff_patterns_allow[:1000]
    }
else:
    ff_data["policies"].pop("WebsiteFilter", None)

with open(ff_policy_path, "w", encoding="utf-8") as f:
    json.dump(ff_data, f, indent=2)
    f.write("\n")

# 3. Update Chromium & Brave Enterprise Policies
for chromium_path in (
    "/etc/chromium/policies/managed/parentcontrol.json",
    "/etc/brave/policies/managed/parentcontrol.json"
):
    c_data = {}
    if os.path.exists(chromium_path):
        try:
            with open(chromium_path, "r", encoding="utf-8") as f:
                loaded = json.load(f)
                if isinstance(loaded, dict):
                    c_data = loaded
        except Exception:
            c_data = {}

    if effective_blacklist:
        c_data["URLBlocklist"] = effective_blacklist
    else:
        c_data.pop("URLBlocklist", None)

    if whitelist:
        c_data["URLAllowlist"] = whitelist
    else:
        c_data.pop("URLAllowlist", None)

    with open(chromium_path, "w", encoding="utf-8") as f:
        json.dump(c_data, f, indent=2)
        f.write("\n")

print(json.dumps({"blocked_ips": bl_ips, "total_hosts_blocked": len(host_entries)}))
' "$PC_CONFIG_FILE" "$PC_HOSTS_FILE" "$tmp_hosts" "$PC_FEED_CACHE_FILE" "$PC_HOSTS_BEGIN_MARKER" "$PC_HOSTS_END_MARKER")"

    chown root:root "$tmp_hosts"
    chmod 0644 "$tmp_hosts"
    mv "$tmp_hosts" "$PC_HOSTS_FILE"

    chmod 0644 /etc/firefox/policies/policies.json \
               /etc/chromium/policies/managed/parentcontrol.json \
               /etc/brave/policies/managed/parentcontrol.json

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        local ip_list
        ip_list="$(python3 -c 'import json, sys; print("\n".join(json.loads(sys.argv[1]).get("blocked_ips", [])))' "$ip_actions")"
        while IFS= read -r ip_addr; do
            [[ -z "$ip_addr" ]] && continue
            ufw deny out to "$ip_addr" comment "ParentControl-ACL" >/dev/null 2>&1 || true
        done <<< "$ip_list"
    fi

    if command -v resolvectl >/dev/null 2>&1; then
        resolvectl flush-caches >/dev/null 2>&1 || true
    fi

    pc_log "INFO" "Enforced ACL rules across /etc/hosts and browser policies."
}

# ------------------------------------------------------------------------------
# Build Standardized ACL State JSON for GUI Hydration
# ------------------------------------------------------------------------------
build_acl_state_json() {
    pc_ensure_config_exists

    python3 -c '
import json, os, sys

cfg_path, feed_cache_path = sys.argv[1:3]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

acl = cfg.get("acl", {})
wl = sorted(set(acl.get("whitelist", [])))
bl = sorted(set(acl.get("blacklist", [])))
feeds = acl.get("feeds", [])

feed_count = 0
if os.path.isfile(feed_cache_path):
    with open(feed_cache_path, "r", encoding="utf-8", errors="replace") as f:
        feed_count = sum(1 for line in f if line.strip())

rules = [{"list": "whitelist", "target": item} for item in wl]
rules.extend({"list": "blacklist", "target": item} for item in bl)

print(json.dumps({
    "whitelist": wl,
    "blacklist": bl,
    "rules": rules,
    "feeds": feeds,
    "feed_domains_count": feed_count
}))
' "$PC_CONFIG_FILE" "$PC_FEED_CACHE_FILE"
}

# ------------------------------------------------------------------------------
# Action Handlers
# ------------------------------------------------------------------------------
handle_add() {
    if [[ "$ACL_LIST" != "whitelist" && "$ACL_LIST" != "blacklist" ]]; then
        pc_emit_error "Action 'add' requires --list <whitelist|blacklist>." 2
        exit 2
    fi

    if [[ -z "$ACL_TARGET" ]]; then
        pc_emit_error "Action 'add' requires --target <url|domain|ip>." 2
        exit 2
    fi

    local norm_pair kind normalized
    if ! norm_pair="$(normalize_target "$ACL_TARGET")"; then
        pc_emit_error "Invalid domain, URL, or IP address: '${ACL_TARGET}'" 2
        exit 2
    fi
    IFS='|' read -r kind normalized <<< "$norm_pair"

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, target_list, normalized, out_path = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

acl = data.setdefault("acl", {})
wl = set(acl.get("whitelist", []))
bl = set(acl.get("blacklist", []))

if target_list == "whitelist":
    bl.discard(normalized)
    bl.discard(f"www.{normalized}")
    wl.add(normalized)
else:
    wl.discard(normalized)
    wl.discard(f"www.{normalized}")
    bl.add(normalized)

acl["whitelist"] = sorted(wl)
acl["blacklist"] = sorted(bl)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$PC_CONFIG_FILE" "$ACL_LIST" "$normalized" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    enforce_acl_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Added '${normalized}' (${kind}) to ${ACL_LIST}" "$state_json"
}

handle_remove() {
    if [[ -n "$ACL_LIST" && "$ACL_LIST" != "whitelist" && "$ACL_LIST" != "blacklist" ]]; then
        pc_emit_error "--list must be 'whitelist' or 'blacklist' (got: '${ACL_LIST}')." 2
        exit 2
    fi

    if [[ -z "$ACL_TARGET" ]]; then
        pc_emit_error "Action 'remove' requires --target <url|domain|ip>." 2
        exit 2
    fi

    local norm_pair kind normalized
    if ! norm_pair="$(normalize_target "$ACL_TARGET")"; then
        normalized="$(printf '%s' "$ACL_TARGET" | tr '[:upper:]' '[:lower:]' | xargs)"
        kind="domain"
    else
        IFS='|' read -r kind normalized <<< "$norm_pair"
    fi

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg removed_count
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    removed_count="$(python3 -c '
import json, sys

cfg_path, target_list, normalized, out_path = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

acl = data.setdefault("acl", {})
wl = set(acl.get("whitelist", []))
bl = set(acl.get("blacklist", []))

candidates = {normalized, f"www.{normalized}"}
removed = 0
for cand in candidates:
    if target_list in ("", "whitelist") and cand in wl:
        wl.remove(cand)
        removed += 1
    if target_list in ("", "blacklist") and cand in bl:
        bl.remove(cand)
        removed += 1

acl["whitelist"] = sorted(wl)
acl["blacklist"] = sorted(bl)

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(removed)
' "$PC_CONFIG_FILE" "$ACL_LIST" "$normalized" "$tmp_cfg")"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    if [[ "$removed_count" -eq 0 ]]; then
        pc_commit_transaction
        pc_emit_error "Target '${normalized}' was not found in ACL rules." 2
        exit 2
    fi

    if [[ "$kind" == "ip" ]] && command -v ufw >/dev/null 2>&1; then
        ufw delete deny out to "$normalized" >/dev/null 2>&1 || true
    fi

    enforce_acl_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Removed '${normalized}' from ACL" "$state_json"
}

handle_sync() {
    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_FEED_CACHE_FILE"

    local tmp_cache sync_stats
    tmp_cache="$(mktemp /tmp/pc-feed-cache.XXXXXX)"

    if ! sync_stats="$(python3 -c '
import json, re, sys, urllib.request

cfg_path, override_url, out_cache_path = sys.argv[1:4]
with open(cfg_path, "r", encoding="utf-8") as f:
    cfg = json.load(f)

feeds = [override_url.strip()] if override_url.strip() else cfg.get("acl", {}).get("feeds", [])
if not feeds:
    sys.stderr.write("No blocklist feed URLs configured.\n")
    sys.exit(2)

ignore_hosts = {
    "localhost", "localhost.localdomain", "local", "broadcasthost",
    "ip6-localhost", "ip6-loopback", "ip6-localnet", "ip6-mcastprefix",
    "ip6-allnodes", "ip6-allrouters", "ip6-allhosts", "0.0.0.0", "127.0.0.1"
}
domain_re = re.compile(r"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$")

domains = set()
synced_feeds = 0

for url in feeds:
    if not url.startswith(("http://", "https://")):
        continue
    req = urllib.request.Request(url, headers={"User-Agent": "ParentControl/0.1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        for raw_bytes in resp:
            line = raw_bytes.decode("utf-8", errors="ignore").split("#", 1)[0].strip().lower()
            if not line:
                continue
            parts = line.split()
            if len(parts) >= 2 and parts[0] in ("0.0.0.0", "127.0.0.1", "::", "::1"):
                cand = parts[1].strip(".")
            elif len(parts) == 1:
                cand = parts[0].strip(".")
            else:
                continue
            if cand in ignore_hosts or len(cand) > 253:
                continue
            if domain_re.match(cand):
                domains.add(cand)
    synced_feeds += 1

sorted_domains = sorted(domains)
with open(out_cache_path, "w", encoding="utf-8") as f:
    if sorted_domains:
        f.write("\n".join(sorted_domains) + "\n")

print(json.dumps({"synced_feeds": synced_feeds, "cached_domains": len(sorted_domains)}))
' "$PC_CONFIG_FILE" "$ACL_FEED_URL" "$tmp_cache")"; then
        rm -f "$tmp_cache"
        pc_rollback
        pc_emit_error "Failed to download or parse blocklist feed(s)." 1
        exit 1
    fi

    chown root:root "$tmp_cache"
    chmod 0644 "$tmp_cache"
    mv "$tmp_cache" "$PC_FEED_CACHE_FILE"

    enforce_acl_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Synchronized Pi-hole blocklist feeds (${sync_stats})" "$state_json"
}

handle_feed_config() {
    local mode="$1" # "add" or "remove"
    if [[ -z "$ACL_FEED_URL" ]]; then
        pc_emit_error "Action '${mode}-feed' requires --url <http(s)://...>." 2
        exit 2
    fi

    if [[ "$mode" == "add" && ! "$ACL_FEED_URL" =~ ^https?:// ]]; then
        pc_emit_error "Feed URL must begin with http:// or https:// (got: '${ACL_FEED_URL}')." 2
        exit 2
    fi

    pc_init_transaction
    pc_ensure_config_exists
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, mode, feed_url, out_path = sys.argv[1:5]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

acl = data.setdefault("acl", {})
feeds = list(dict.fromkeys(acl.get("feeds", [])))

if mode == "add":
    if feed_url not in feeds:
        feeds.append(feed_url)
else:
    feeds = [u for u in feeds if u != feed_url]

acl["feeds"] = feeds
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$PC_CONFIG_FILE" "$mode" "$ACL_FEED_URL" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Updated blocklist feed list (${mode}: ${ACL_FEED_URL})" "$state_json"
}

handle_list() {
    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Retrieved network ACL rules" "$state_json"
}

handle_apply() {
    pc_init_transaction
    enforce_acl_rules
    pc_commit_transaction

    local state_json
    state_json="$(build_acl_state_json)"
    pc_emit_result "Applied network ACL rules to system and browsers" "$state_json"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_acl_args "$@"
    pc_require_root
    pc_verify_mint

    case "$ACL_ACTION" in
        add)
            handle_add
            ;;
        remove)
            handle_remove
            ;;
        list)
            handle_list
            ;;
        apply)
            handle_apply
            ;;
        sync)
            handle_sync
            ;;
        add-feed)
            handle_feed_config "add"
            ;;
        remove-feed)
            handle_feed_config "remove"
            ;;
        *)
            pc_emit_error "Unsupported action '${ACL_ACTION}' (expected: add, remove, list, apply, sync, add-feed, remove-feed)." 2
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
# ParentControl - Directory Permissions & RWX Enforcement Manager
# File: /opt/parentcontrol/bin/pc-perms.sh
#
# Description:
#   Enforces per-folder Read/Write/Execute (RWX) rules via POSIX ACLs (setfacl)
#   and manages home-directory hardening presets (lock_dotfiles,
#   restrict_extra_home_dirs, noexec_user_dirs) for the restricted user.
#
# GUI HANDOFF:
#   Invoked via pc-ctl.sh:
#     pkexec /opt/parentcontrol/bin/pc-ctl.sh perms --action <verb> [OPTIONS] --json
#
#   Supported Actions:
#     set     --path <target_path> --perms <RWX|R-X|R--|---> [--recursive] --json
#     remove  --path <target_path> --json
#     preset  --name <lock_dotfiles|restrict_extra_home_dirs|noexec_user_dirs> --enabled <true|false> --json
#     list    --json
#     apply   --json
#
#   JSON Data Schema (--action list --json):
#     {
#       "restricted_user": "mint",
#       "presets": {
#         "lock_dotfiles": false,
#         "restrict_extra_home_dirs": false,
#         "noexec_user_dirs": false
#       },
#       "custom_rules": [
#         {"path": "/home/mint/Private", "perms": "R--", "recursive": true}
#       ]
#     }
# ==============================================================================

set -Eeuo pipefail

# shellcheck source=/opt/parentcontrol/lib/common.sh
source "/opt/parentcontrol/lib/common.sh"

PC_MODULE_NAME="perms"
PC_CURRENT_ACTION="list"
PC_SCRIPT_DESC="Manages folder RWX permissions and home-directory hardening presets."
PC_SCRIPT_USAGE="pc-perms.sh --action <set|remove|preset|list|apply> [OPTIONS]"
PC_SCRIPT_FLAGS="      --action <verb>         set, remove, preset, list, apply
      --path <dir_or_file>    Target filesystem path for set/remove
      --perms <RWX>           3-char permission string (e.g., RWX, R-X, R--, ---)
      --recursive             Apply custom RWX rule recursively (default for directories)
      --name <preset_name>    lock_dotfiles | restrict_extra_home_dirs | noexec_user_dirs
      --enabled <true|false>  Enable or disable the specified preset"

PERMS_ACTION=""
TARGET_PATH=""
RAW_PERMS=""
RECURSIVE=1
PRESET_NAME=""
PRESET_ENABLED=""

# ------------------------------------------------------------------------------
# Parse Module-Specific Flags
# ------------------------------------------------------------------------------
parse_perms_args() {
    pc_parse_common_flags "$@"
    set -- "${PC_REMAINING_ARGS[@]}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --action)
                PERMS_ACTION="${2:-}"
                shift 2
                ;;
            --path)
                TARGET_PATH="${2:-}"
                shift 2
                ;;
            --perms)
                RAW_PERMS="${2:-}"
                shift 2
                ;;
            --recursive)
                RECURSIVE=1
                shift
                ;;
            --no-recursive)
                RECURSIVE=0
                shift
                ;;
            --name)
                PRESET_NAME="${2:-}"
                shift 2
                ;;
            --enabled)
                PRESET_ENABLED="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
                shift 2
                ;;
            *)
                pc_emit_error "Unknown flag for pc-perms.sh: $1" 2
                exit 2
                ;;
        esac
    done

    if [[ -z "$PERMS_ACTION" ]]; then
        pc_emit_error "Missing required --action <set|remove|preset|list|apply>." 2
        exit 2
    fi
    PC_CURRENT_ACTION="$PERMS_ACTION"
}

# ------------------------------------------------------------------------------
# Ensure setfacl & Restricted User Are Ready
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
# Validate Target Path & Normalize RWX String
# ------------------------------------------------------------------------------
validate_and_resolve_path() {
    local input_path="$1"
    if [[ -z "$input_path" ]]; then
        pc_emit_error "Target --path cannot be empty." 2
        exit 2
    fi

    if [[ ! -e "$input_path" ]]; then
        pc_emit_error "Target path does not exist: '${input_path}'" 2
        exit 2
    fi

    local resolved
    resolved="$(realpath -e "$input_path")"

    # Guard critical OS system roots from accidental permission lockouts
    case "$resolved" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib32|/lib64|/libx32|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            pc_emit_error "Refusing to modify permissions on critical system directory: '${resolved}'" 2
            exit 2
            ;;
        /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib64/*|/proc/*|/root/*|/run/*|/sbin/*|/sys/*|/usr/*|/var/*)
            pc_emit_error "Refusing to modify permissions inside protected OS path: '${resolved}'" 2
            exit 2
            ;;
    esac

    printf '%s' "$resolved"
}

normalize_rwx_string() {
    local input_perms="$1"
    python3 -c '
import sys
raw = sys.argv[1].strip().upper()
if len(raw) != 3:
    sys.exit(1)
if raw[0] not in ("R", "-") or raw[1] not in ("W", "-") or raw[2] not in ("X", "-"):
    sys.exit(1)
print(raw)
' "$input_perms"
}

# ------------------------------------------------------------------------------
# Low-Level POSIX ACL Application Helpers
# ------------------------------------------------------------------------------
apply_single_rwx_rule() {
    local r_user="$1"
    local target_path="$2"
    local rwx_upper="$3"
    local is_recursive="$4"

    [[ -e "$target_path" ]] || return 0

    local acl_perms
    acl_perms="$(printf '%s' "$rwx_upper" | tr '[:upper:]' '[:lower:]')"

    local rec_flag=()
    if [[ "$is_recursive" -eq 1 && -d "$target_path" ]]; then
        rec_flag=(-R)
    fi

    setfacl "${rec_flag[@]}" -m "u:${r_user}:${acl_perms}" "$target_path"

    if [[ -d "$target_path" ]]; then
        # Ensure newly created files/dirs inside this directory inherit the rule
        setfacl "${rec_flag[@]}" -d -m "u:${r_user}:${acl_perms}" "$target_path" 2>/dev/null || true
    fi
}

clear_single_rwx_rule() {
    local r_user="$1"
    local target_path="$2"

    [[ -e "$target_path" ]] || return 0

    if [[ -d "$target_path" ]]; then
        setfacl -R -x "u:${r_user}" "$target_path" 2>/dev/null || true
        setfacl -R -d -x "u:${r_user}" "$target_path" 2>/dev/null || true
    else
        setfacl -x "u:${r_user}" "$target_path" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Home Directory Security Presets
# ------------------------------------------------------------------------------
apply_preset_state() {
    local r_user="$1"
    local preset="$2"
    local enabled="$3"
    local user_home
    user_home="$(getent passwd "$r_user" | cut -d: -f6)"

    if [[ -z "$user_home" || ! -d "$user_home" ]]; then
        pc_emit_error "Home directory not found for user '${r_user}'." 1
        exit 1
    fi

    local r_group
    r_group="$(id -gn "$r_user")"

    case "$preset" in
        lock_dotfiles)
            local critical_files=(".bashrc" ".profile" ".bash_profile" ".zshrc" ".xinitrc" ".xsessionrc")
            local critical_dirs=(".config/autostart" ".local/share/applications")

            for f in "${critical_files[@]}"; do
                local fp="${user_home}/${f}"
                if [[ "$enabled" == "true" ]]; then
                    [[ ! -e "$fp" ]] && touch "$fp"
                    chown root:root "$fp"
                    chmod 0644 "$fp"
                elif [[ -e "$fp" ]]; then
                    chown "${r_user}:${r_group}" "$fp"
                    chmod 0644 "$fp"
                fi
            done

            for d in "${critical_dirs[@]}"; do
                local dp="${user_home}/${d}"
                if [[ "$enabled" == "true" ]]; then
                    mkdir -p "$dp"
                    chown -R root:root "$dp"
                    chmod -R go-w "$dp"
                    chmod 0755 "$dp"
                elif [[ -d "$dp" ]]; then
                    chown -R "${r_user}:${r_group}" "$dp"
                    chmod 0755 "$dp"
                fi
            done
            ;;

        restrict_extra_home_dirs)
            shopt -s nullglob
            for entry in "${user_home}"/*; do
                local base_name
                base_name="$(basename "$entry")"
                local is_standard=0
                for std_dir in "${PC_STANDARD_HOME_DIRS[@]}"; do
                    if [[ "$base_name" == "$std_dir" ]]; then
                        is_standard=1
                        break
                    fi
                done
                if [[ "$is_standard" -eq 0 ]]; then
                    if [[ "$enabled" == "true" ]]; then
                        setfacl -R -m "u:${r_user}:---" "$entry"
                        [[ -d "$entry" ]] && setfacl -R -d -m "u:${r_user}:---" "$entry" 2>/dev/null || true
                    else
                        clear_single_rwx_rule "$r_user" "$entry"
                    fi
                fi
            done
            shopt -u nullglob
            ;;

        noexec_user_dirs)
            local target_dirs=("Downloads" "Desktop" "Documents" "Public" "Templates")
            for sub in "${target_dirs[@]}"; do
                local dp="${user_home}/${sub}"
                [[ -d "$dp" ]] || continue
                if [[ "$enabled" == "true" ]]; then
                    # rwX grants execute ONLY on directories (for traversal), never on regular files
                    setfacl -R -m "u:${r_user}:rwX" "$dp"
                    setfacl -R -d -m "u:${r_user}:rw-" "$dp" 2>/dev/null || true
                    find "$dp" -type f -exec setfacl -m "u:${r_user}:rw-" {} + 2>/dev/null || true
                else
                    clear_single_rwx_rule "$r_user" "$dp"
                fi
            done
            ;;

        *)
            pc_emit_error "Unknown preset '${preset}' (expected: lock_dotfiles, restrict_extra_home_dirs, noexec_user_dirs)." 2
            exit 2
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Build Standardized Permissions State JSON for GUI Hydration
# ------------------------------------------------------------------------------
build_perms_state_json() {
    pc_ensure_config_exists
    python3 -c '
import json, sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)

perms = cfg.get("permissions", {})
print(json.dumps({
    "restricted_user": cfg.get("restricted_user", ""),
    "presets": {
        "lock_dotfiles": bool(perms.get("lock_dotfiles", False)),
        "restrict_extra_home_dirs": bool(perms.get("restrict_extra_home_dirs", False)),
        "noexec_user_dirs": bool(perms.get("noexec_user_dirs", False))
    },
    "custom_rules": perms.get("custom_rules", [])
}))
' "$PC_CONFIG_FILE"
}

# ------------------------------------------------------------------------------
# Action Handlers
# ------------------------------------------------------------------------------
handle_set() {
    local r_user resolved_path norm_perms
    r_user="$(get_restricted_user)"
    resolved_path="$(validate_and_resolve_path "$TARGET_PATH")"

    if [[ -z "$RAW_PERMS" ]]; then
        pc_emit_error "Action 'set' requires --perms <RWX|R-X|R--|--->." 2
        exit 2
    fi

    if ! norm_perms="$(normalize_rwx_string "$RAW_PERMS")"; then
        pc_emit_error "Invalid --perms '${RAW_PERMS}'. Must be 3 characters using R/W/X/- (e.g., RWX, R-X, R--, ---)." 2
        exit 2
    fi

    ensure_acl_tool
    pc_init_transaction
    pc_backup_file "$PC_CONFIG_FILE"

    apply_single_rwx_rule "$r_user" "$resolved_path" "$norm_perms" "$RECURSIVE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 -c '
import json, sys

cfg_path, target_path, perms_str, rec_flag, out_path = sys.argv[1:6]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

perms = data.setdefault("permissions", {})
rules = [r for r in perms.get("custom_rules", []) if r.get("path") != target_path]
rules.append({
    "path": target_path,
    "perms": perms_str,
    "recursive": rec_flag == "1"
})
rules.sort(key=lambda r: r.get("path", ""))
perms["custom_rules"] = rules

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
' "$PC_CONFIG_FILE" "$resolved_path" "$norm_perms" "$RECURSIVE" "$tmp_cfg"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    pc_commit_transaction

    local state_json
    state_json="$(build_perms_state_json)"
    pc_emit_result "Applied [${norm_perms}] permissions on '${resolved_path}' for '${r_user}'" "$state_json"
}

handle_remove() {
    if [[ -z "$TARGET_PATH" ]]; then
        pc_emit_error "Action 'remove' requires --path <target_path>." 2
        exit 2
    fi

    local r_user resolved_path
    r_user="$(get_restricted_user)"
    if [[ -e "$TARGET_PATH" ]]; then
        resolved_path="$(realpath -e "$TARGET_PATH")"
    else
        resolved_path="$TARGET_PATH"
    fi

    ensure_acl_tool
    pc_init_transaction
    pc_backup_file "$PC_CONFIG_FILE"

    clear_single_rwx_rule "$r_user" "$resolved_path"

    local tmp_cfg removed_count
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    removed_count="$(python3 -c '
import json, sys

cfg_path, target_path, out_path = sys.argv[1:4]
with open(cfg_path, "r", encoding="utf-8") as f:
    data = json.load(f)

perms = data.setdefault("permissions", {})
old_rules = perms.get("custom_rules", [])
new_rules = [r for r in old_rules if r.get("path") != target_path]
perms["custom_rules"] = new_rules

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(len(old_rules) - len(new_rules))
' "$PC_CONFIG_FILE" "$resolved_path" "$tmp_cfg")"

    chown root:root "$tmp_cfg"
    chmod 0640 "$tmp_cfg"
    mv "$tmp_cfg" "$PC_CONFIG_FILE"

    if [[ "$removed_count" -eq 0 ]]; then
        pc_commit_transaction
        pc_emit_error "No saved permission rule found for '${resolved_path}'." 2
        exit 2
    fi

    pc_commit_transaction

    local state_json
    state_json="$(build_perms_state_json)"
    pc_emit_result "Removed custom permission rule for '${resolved_path}'" "$state_json"
}

handle_preset() {
    if [[ -z "$PRESET_NAME" ]]; then
        pc_emit_error "Action 'preset' requires --name <lock_dotfiles|restrict_extra_home_dirs|noexec_user_dirs>." 2
        exit 2
    fi

    if [[ "$PRESET_ENABLED" != "true" && "$PRESET_ENABLED" != "false" ]]; then
        pc_emit_error "Action 'preset' requires --enabled <true|false>." 2
        exit 2
    fi

    local r_user
    r_user="$(get_restricted_user)"
    ensure_acl_tool

    pc_init_transaction
    apply_preset_state "$r_user" "$PRESET_NAME" "$PRESET_ENABLED"
    pc_json_set "permissions.${PRESET_NAME}" "$PRESET_ENABLED"
    pc_commit_transaction

    local state_json
    state_json="$(build_perms_state_json)"
    pc_emit_result "Set permission preset '${PRESET_NAME}' to ${PRESET_ENABLED}" "$state_json"
}

handle_list() {
    local state_json
    state_json="$(build_perms_state_json)"
    pc_emit_result "Retrieved directory permission rules and presets" "$state_json"
}

handle_apply() {
    local r_user
    r_user="$(get_restricted_user)"
    ensure_acl_tool

    pc_init_transaction

    for preset in lock_dotfiles restrict_extra_home_dirs noexec_user_dirs; do
        local is_on
        is_on="$(pc_json_get "permissions.${preset}" 2>/dev/null || printf 'false')"
        apply_preset_state "$r_user" "$preset" "$is_on"
    done

    local rules_lines
    rules_lines="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)
for r in cfg.get("permissions", {}).get("custom_rules", []):
    rec = "1" if r.get("recursive", True) else "0"
    print(f"{r.get(\"path\", \"\")}|{r.get(\"perms\", \"R-X\")}|{rec}")
' "$PC_CONFIG_FILE")"

    while IFS='|' read -r r_path r_perms r_rec; do
        [[ -z "$r_path" ]] && continue
        apply_single_rwx_rule "$r_user" "$r_path" "$r_perms" "$r_rec"
    done <<< "$rules_lines"

    pc_commit_transaction

    local state_json
    state_json="$(build_perms_state_json)"
    pc_emit_result "Applied all directory permissions and presets for '${r_user}'" "$state_json"
}

# ------------------------------------------------------------------------------
# Main Execution
# ------------------------------------------------------------------------------
main() {
    parse_perms_args "$@"
    pc_require_root
    pc_verify_mint

    case "$PERMS_ACTION" in
        set)
            handle_set
            ;;
        remove)
            handle_remove
            ;;
        preset)
            handle_preset
            ;;
        list)
            handle_list
            ;;
        apply)
            handle_apply
            ;;
        *)
            pc_emit_error "Unsupported action '${PERMS_ACTION}' (expected: set, remove, preset, list, apply)." 2
            exit 2
            ;;
    esac
}

main "$@"
PC_PERMS_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-perms.sh
    chmod 0755 /opt/parentcontrol/bin/pc-perms.sh
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
    deploy_initial_config

    if [[ "$SKIP_TEST" -eq 0 ]]; then
        run_self_test
    else
        printf '[OK] ParentControl Part 3 deployed (self-test skipped).\n'
    fi
}

main "$@"