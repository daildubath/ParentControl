#!/usr/bin/env python3
import datetime
import re
import shutil
import subprocess
import sys
from pathlib import Path

TARGET_FILE = Path("install-parentcontrol.sh")

NEW_CREATE_DIRECTORIES = r"""create_directories() {
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

    log_info "Directories created and permissions applied."
}"""

NEW_DEPLOY_PC_CTL_SH = r"""deploy_pc_ctl_sh() {
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
}"""

NEW_DEPLOY_PC_SETUP_SH = r"""deploy_pc_setup_sh() {
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

readonly PC_POLKIT_RULE="/etc/polkit-1/rules.d/49-parentcontrol.rules"
readonly PC_PUBLIC_INFO="/etc/parentcontrol/public-info.json"

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
    deploy_polkit_rule

    local r_user
    r_user="$(detect_default_desktop_user)"
    if [[ -n "$r_user" ]]; then
        pc_json_set "restricted_user" "$r_user"
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
    [[ -n "$r_user" ]] && pc_json_set "restricted_user" "$r_user"

    if [[ -n "$ADMIN_PASSWORD" ]]; then
        if [[ ${#ADMIN_PASSWORD} -lt 6 ]]; then
            pc_emit_error "Admin password must be at least 6 characters long." 2
            exit 2
        fi
        printf '%s:%s\n' "$PC_ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
        usermod -U "$PC_ADMIN_USER" 2>/dev/null || true
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
}"""

NEW_DEPLOY_PC_NET_ACL_SH = r"""deploy_pc_net_acl_sh() {
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

readonly PC_FEED_CACHE="${PC_VAR_DIR}/feed-blocklist.txt"
readonly PC_HOSTS_FILE="/etc/hosts"
readonly PC_HOSTS_BEGIN="# BEGIN PARENTCONTROL MANAGED BLOCKS"
readonly PC_HOSTS_END="# END PARENTCONTROL MANAGED BLOCKS"

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
}"""

NEW_DEPLOY_PC_PERMS_SH = r"""deploy_pc_perms_sh() {
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
    "default_browse_dir": f"/home/{cfg.get(\"restricted_user\", \"\")}",
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
}"""

NEW_DEPLOY_PC_PORTS_SH = r"""deploy_pc_ports_sh() {
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
}"""

NEW_APPLY_SENIOR_PRESET = r"""apply_senior_preset() {
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
}"""

NEW_DEPLOY_REQUEST_POPUP = r"""deploy_pc_request_popup_py() {
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
}"""


def find_top_level_function_span(lines, func_name):
    """Find [start_idx, end_idx_exclusive] of a top-level Bash function, ignoring heredocs."""
    heredoc_delim = None
    heredoc_re = re.compile(r"<<-?\s*['\"]?([A-Za-z0-9_]+)['\"]?")
    func_start = None

    for idx, line in enumerate(lines):
        stripped = line.rstrip("\r\n")
        if heredoc_delim is not None:
            if stripped.strip() == heredoc_delim:
                heredoc_delim = None
            continue

        if func_start is None:
            if stripped == f"{func_name}() {{":
                func_start = idx
                continue
        else:
            if stripped == "}":
                return func_start, idx + 1

        m = heredoc_re.search(stripped)
        if m:
            heredoc_delim = m.group(1)

    return None


def replace_top_level_function(lines, func_name, new_block):
    span = find_top_level_function_span(lines, func_name)
    if span is None:
        raise RuntimeError(f"Could not find top-level function '{func_name}()' in {TARGET_FILE}")
    s, e = span
    replacement_lines = [ln + "\n" for ln in new_block.strip("\n").split("\n")]
    return lines[:s] + replacement_lines + lines[e:]


def replace_inner_function_block(lines, func_name, new_block):
    """Replace a column-0 function inside an embedded heredoc script."""
    start_idx = None
    for idx, line in enumerate(lines):
        if line.rstrip("\r\n") == f"{func_name}() {{":
            start_idx = idx
            break
    if start_idx is None:
        raise RuntimeError(f"Could not find inner function '{func_name}()' in {TARGET_FILE}")
    end_idx = None
    for idx in range(start_idx + 1, len(lines)):
        if lines[idx].rstrip("\r\n") == "}":
            end_idx = idx + 1
            break
    if end_idx is None:
        raise RuntimeError(f"Could not find closing brace for '{func_name}()'")
    replacement_lines = [ln + "\n" for ln in new_block.strip("\n").split("\n")]
    return lines[:start_idx] + replacement_lines + lines[end_idx:]


def main():
    if not TARGET_FILE.is_file():
        print(f"[ERROR] {TARGET_FILE} not found in current directory.", file=sys.stderr)
        sys.exit(1)

    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = Path(f"{TARGET_FILE}.bak.{ts}")
    shutil.copy2(TARGET_FILE, backup_path)
    print(f"[INFO] Backed up {TARGET_FILE} -> {backup_path}")

    lines = TARGET_FILE.read_text(encoding="utf-8").splitlines(keepends=True)

    replacements = [
        ("create_directories", NEW_CREATE_DIRECTORIES),
        ("deploy_pc_ctl_sh", NEW_DEPLOY_PC_CTL_SH),
        ("deploy_pc_setup_sh", NEW_DEPLOY_PC_SETUP_SH),
        ("deploy_pc_net_acl_sh", NEW_DEPLOY_PC_NET_ACL_SH),
        ("deploy_pc_perms_sh", NEW_DEPLOY_PC_PERMS_SH),
        ("deploy_pc_ports_sh", NEW_DEPLOY_PC_PORTS_SH),
    ]
    for fn_name, new_code in replacements:
        lines = replace_top_level_function(lines, fn_name, new_code)
        print(f"[OK] Updated {fn_name}()")

    lines = replace_inner_function_block(lines, "apply_senior_preset", NEW_APPLY_SENIOR_PRESET)
    print("[OK] Updated apply_senior_preset() inside deploy_pc_maint_sh()")

    if find_top_level_function_span(lines, "deploy_pc_request_popup_py") is not None:
        lines = replace_top_level_function(lines, "deploy_pc_request_popup_py", NEW_DEPLOY_REQUEST_POPUP)
        print("[OK] Updated existing deploy_pc_request_popup_py()")
    else:
        maint_span = find_top_level_function_span(lines, "deploy_pc_maint_sh")
        if maint_span is None:
            raise RuntimeError("Could not find deploy_pc_maint_sh() to insert deploy_pc_request_popup_py()")
        insert_at = maint_span[1]
        popup_lines = ["\n"] + [ln + "\n" for ln in NEW_DEPLOY_REQUEST_POPUP.strip("\n").split("\n")] + ["\n"]
        lines = lines[:insert_at] + popup_lines + lines[insert_at:]
        print("[OK] Inserted deploy_pc_request_popup_py()")

    # Wire deploy_pc_request_popup_py and pc-setup init into main()
    main_span = find_top_level_function_span(lines, "main")
    if main_span is None:
        raise RuntimeError("Could not find top-level main() in installer")
    ms, me = main_span
    main_text = "".join(lines[ms:me])
    if "deploy_pc_request_popup_py" not in main_text:
        main_text = main_text.replace(
            "    deploy_pc_maint_sh\n",
            "    deploy_pc_maint_sh\n    deploy_pc_request_popup_py\n",
            1,
        )
    if "pc-setup.sh --action init" not in main_text:
        main_text = main_text.replace(
            "    deploy_initial_config\n",
            "    deploy_initial_config\n    /opt/parentcontrol/bin/pc-setup.sh --action init --json >/dev/null 2>&1 || true\n",
            1,
        )
    lines = lines[:ms] + [ln + "\n" for ln in main_text.rstrip("\n").split("\n")] + lines[me:]
    print("[OK] Wired deploy_pc_request_popup_py() into main()")

    TARGET_FILE.write_text("".join(lines), encoding="utf-8")
    TARGET_FILE.chmod(0o755)

    check = subprocess.run(["bash", "-n", str(TARGET_FILE)], capture_output=True, text=True)
    if check.returncode != 0:
        print(f"[ERROR] Syntax check failed:\n{check.stderr}", file=sys.stderr)
        sys.exit(1)

    print("[SUCCESS] Chunk 7 applied and 'bash -n install-parentcontrol.sh' passed!")


if __name__ == "__main__":
    main()
