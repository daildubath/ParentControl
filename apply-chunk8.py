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
    dump="$(python3 - "$PC_CONFIG_FILE" << 'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1], "r", encoding="utf-8"))
perms = cfg.get("permissions", {})
presets = perms.get("presets", {})
print("PRESET|lock_dotfiles|" + ("1" if presets.get("lock_dotfiles") else "0"))
print("PRESET|restrict_extra_home_dirs|" + ("1" if presets.get("restrict_extra_home_dirs") else "0"))
print("PRESET|noexec_user_dirs|" + ("1" if presets.get("noexec_user_dirs") else "0"))
for r in perms.get("custom_rules", []):
    p_val = r.get("path", "")
    r_val = r.get("perms", "R-X")
    print(f"RULE|{p_val}|{r_val}")
PYEOF
)"

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

    pc_init_transaction
    pc_backup_file "$PC_CONFIG_FILE"

    local tmp_cfg
    tmp_cfg="$(mktemp "${PC_ETC_DIR}/config.json.XXXXXX")"

    python3 - "$PC_CONFIG_FILE" "$resolved_path" "$rwx_val" "$mode_label" "$tmp_cfg" << 'PYEOF'
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
PYEOF

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
    removed="$(python3 - "$PC_CONFIG_FILE" "$resolved_path" "$tmp_cfg" << 'PYEOF'
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
PYEOF
)"

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

NEW_DEPLOY_PC_MAINT_SH = r"""deploy_pc_maint_sh() {
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
        tick)          exit 0 ;;
        list)          pc_emit_result "Retrieved automation and screen-time settings" "$(build_maint_state_json)" ;;
        *)             pc_emit_error "Unsupported maint action '${MAINT_ACTION}'." 2; exit 2 ;;
    esac
}

main "$@"
PC_MAINT_SH_EOF

    chown root:root /opt/parentcontrol/bin/pc-maint.sh
    chmod 0755 /opt/parentcontrol/bin/pc-maint.sh
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
}"""


def find_top_level_function_span(lines, func_name):
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
        ("deploy_pc_net_acl_sh", NEW_DEPLOY_PC_NET_ACL_SH),
        ("deploy_pc_perms_sh", NEW_DEPLOY_PC_PERMS_SH),
        ("deploy_pc_maint_sh", NEW_DEPLOY_PC_MAINT_SH),
        ("deploy_pc_request_popup_py", NEW_DEPLOY_REQUEST_POPUP),
    ]
    for fn_name, new_code in replacements:
        lines = replace_top_level_function(lines, fn_name, new_code)
        print(f"[OK] Updated {fn_name}()")

    text = "".join(lines)

    # Switch Caregiver / Student order in setup wizard & defaults
    text = text.replace('"Parent / Caregiver"', '"Caregiver / Parent"')
    old_wizard_profiles = (
        '    printf \'\\n3. Select Care Profile:\\n\'\n'
        '    printf \'   [1] Child / Student Safety\\n\'\n'
        '    printf \'   [2] Dementia / Senior Care (enables larger text & disables hot-corners)\\n\'\n'
        '    read -rp "   Choose profile [1/2, default 1]: " prof_choice'
    )
    new_wizard_profiles = (
        '    printf \'\\n3. Select Care Profile:\\n\'\n'
        '    printf \'   [1] Dementia / Senior Care (enables larger text & disables hot-corners)\\n\'\n'
        '    printf \'   [2] Child / Student Safety\\n\'\n'
        '    read -rp "   Choose profile [1/2, default 1]: " prof_choice'
    )
    if old_wizard_profiles in text:
        text = text.replace(old_wizard_profiles, new_wizard_profiles, 1)
        text = text.replace('if [[ "$prof_choice" == "2" && -x "${PC_BIN_DIR}/pc-maint.sh" ]]; then',
                            'if [[ "${prof_choice:-1}" == "1" && -x "${PC_BIN_DIR}/pc-maint.sh" ]]; then', 1)

    # Ensure sync_public_contact_info keeps /etc/parentcontrol traversable (0755)
    text = text.replace(
        'os.chmod(tmp_path, 0o644)\nos.replace(tmp_path, pub_path)',
        'os.chmod(os.path.dirname(pub_path), 0o755)\nos.chmod(tmp_path, 0o644)\nos.replace(tmp_path, pub_path)',
    )

    TARGET_FILE.write_text(text, encoding="utf-8")
    TARGET_FILE.chmod(0o755)

    check = subprocess.run(["bash", "-n", str(TARGET_FILE)], capture_output=True, text=True)
    if check.returncode != 0:
        print(f"[ERROR] Syntax check failed:\n{check.stderr}", file=sys.stderr)
        sys.exit(1)

    print("[SUCCESS] Chunk 8 applied and 'bash -n install-parentcontrol.sh' passed!")


if __name__ == "__main__":
    main()
