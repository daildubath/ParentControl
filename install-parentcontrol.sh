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

    bash -c '
        source /opt/parentcontrol/lib/common.sh
        PC_MODULE_NAME="selftest"
        PC_CURRENT_ACTION="verify"
        pc_parse_common_flags "$@"
        pc_require_root
        pc_verify_mint
        pc_ensure_config_exists
        pc_emit_result "Sub-Chunk 1.1 library verified successfully" "{\"mint_verified\":true}"
    ' _ "${test_flags[@]}"
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
    deploy_initial_config

    if [[ "$SKIP_TEST" -eq 0 ]]; then
        run_self_test
    else
        printf '[OK] ParentControl Sub-Chunk 1.3 deployed (self-test skipped).\n'
    fi
}

main "$@"