#!/usr/bin/env bash
#
# deploy.sh - Deploys the ScamShield Firefox extension and its locked policy
#             on Linux Mint (and other Debian-family systems with the deb
#             version of Firefox).
#
# Actions: install, update-config, rollback, uninstall (plus --check dry runs).
# Every change is registered with an undo step, so a failure leaves the system
# as it was found.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="0.3.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
# Must match the ID in the extension manifest and in the policy contract.
readonly EXTENSION_ID="scamshield@elder-guard.example"
readonly DEFAULT_LOG_FILE="/var/log/scamshield-deploy.log"

# Environment the script is built and tested for.
readonly TARGET_MINT_VERSION="22.3"
# The extension manifest requires Firefox 140 or newer.
readonly MIN_FIREFOX_MAJOR=140
# os-release file; overridable for testing (SCAMSHIELD_OS_RELEASE).
readonly OS_RELEASE_FILE="${SCAMSHIELD_OS_RELEASE:-/etc/os-release}"
# Groups that give a user administrator or root-equivalent power.
readonly -a PRIVILEGED_GROUPS=(sudo adm admin wheel root docker lxd disk)

# Install locations. SCAMSHIELD_PREFIX relocates them for testing only.
readonly PREFIX="${SCAMSHIELD_PREFIX:-}"
readonly XPI_DEST_DIR="${PREFIX}/usr/share/scamshield"
readonly XPI_DEST="${XPI_DEST_DIR}/scamshield.xpi"
readonly XPI_URL="file://${XPI_DEST}"
readonly STATE_DIR="${PREFIX}/var/lib/scamshield"
readonly STATE_FILE="${STATE_DIR}/state"
readonly BACKUP_DIR="${PREFIX}/var/backups/scamshield"
readonly ETC_POLICY_FILE="${PREFIX}/etc/firefox/policies/policies.json"

readonly EXIT_OK=0
readonly EXIT_ERROR=1
readonly EXIT_USAGE=2

# ---------------------------------------------------------------------------
# State (set by parse_args, read everywhere else)
# ---------------------------------------------------------------------------

VERBOSE=0
CHECK_MODE=0
ACTION=""
XPI_PATH=""
CONFIG_PATH=""
SCHEMA_PATH=""
POLICY_FILE=""
SELF_TEST_MODE=""
LOG_FILE=""
TARGET_USER=""

# Filled in by the environment checks and actions.
IS_ROOT=0
OS_VERSION_ID=""
FIREFOX_DIR=""
FIREFOX_PACKAGE=""
FIREFOX_VERSION=""
BACKUP_FILE=""
MERGED_JSON=""

# Values read back from the state file left by a previous install.
STATE_POLICY_FILE=""
STATE_POLICY_EXISTED=""
STATE_PRIVATE_ORIG=""

# Undo stack: parallel arrays, run in reverse order when the script fails.
declare -a UNDO_DESCRIPTIONS=()
declare -a UNDO_COMMANDS=()
declare -a CHECK_PLANNED_DIRS=()

COLOR_RED=""
COLOR_YELLOW=""
COLOR_DIM=""
COLOR_RESET=""

# ---------------------------------------------------------------------------
# JSON helper (python3 is part of a default Linux Mint install)
# ---------------------------------------------------------------------------
# One helper program with several modes, so all JSON handling lives in one
# place. Results go to stdout, problems to stderr with a non-zero exit.

PY_HELPER=$(cat <<'PYEOF'
import json
import os
import sys
import zipfile


def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)


def load_json(path, what):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        fail(f"{what} not found: {path}")
    except (OSError, ValueError) as error:
        fail(f"{what} is not valid JSON ({path}): {error}")


def load_policy_doc(path):
    """Existing policies.json as a dict. Missing or empty file means {}."""
    if not path or not os.path.exists(path) or os.path.getsize(path) == 0:
        return {}
    doc = load_json(path, "Existing policy file")
    if not isinstance(doc, dict):
        fail(f"Existing policy file is not a JSON object: {path}")
    return doc


def child_dict(parent, key, where):
    """Fetch (creating if needed) a nested object without clobbering other types."""
    value = parent.setdefault(key, {})
    if not isinstance(value, dict):
        fail(f"'{where}{key}' in the existing policy file is not an object; refusing to change it.")
    return value


def emit(doc):
    sys.stdout.write(json.dumps(doc, indent=2) + "\n")


def cmd_validate_config(config_path, schema_path=""):
    config = load_json(config_path, "Config file")
    if not isinstance(config, dict):
        fail("Config must be a JSON object.")
    if config.get("schema_version") != 1:
        fail("Config schema_version must be 1.")
    missing = [key for key in ("admin", "notifier", "tiers", "lists") if key not in config]
    if missing:
        fail("Config is missing required keys: " + ", ".join(missing))
    notifier = config["notifier"]
    topic = notifier.get("topic", "") if isinstance(notifier, dict) else ""
    if not isinstance(topic, str) or "REPLACE_ME" in topic:
        fail("notifier.topic is still the placeholder. Create a random one with: deploy.sh --generate-topic")
    if not schema_path:
        print("NOTE: policy.schema.json not found next to deploy.sh, so only basic config checks ran.", file=sys.stderr)
        return
    try:
        from jsonschema import Draft202012Validator
    except ImportError:
        print("NOTE: python3-jsonschema is not installed, so only basic config checks ran (optional: sudo apt install python3-jsonschema).", file=sys.stderr)
        return
    schema = load_json(schema_path, "Schema file")
    errors = sorted(Draft202012Validator(schema).iter_errors(config),
                    key=lambda error: [str(part) for part in error.path])
    if errors:
        for error in errors[:20]:
            where = "/".join(str(part) for part in error.path) or "(top level)"
            print(f"  {where}: {error.message}", file=sys.stderr)
        fail(f"Config does not match the schema ({len(errors)} problem(s)).")


def cmd_validate_xpi(xpi_path, ext_id):
    try:
        with zipfile.ZipFile(xpi_path) as archive:
            manifest = json.loads(archive.read("manifest.json").decode("utf-8-sig"))
            signed = any(name.startswith("META-INF/") and name.endswith(".rsa")
                         for name in archive.namelist())
    except (zipfile.BadZipFile, KeyError, OSError, ValueError) as error:
        fail(f"Extension file is not a valid add-on archive ({xpi_path}): {error}")
    settings = manifest.get("browser_specific_settings") or manifest.get("applications") or {}
    found_id = (settings.get("gecko") or {}).get("id")
    if found_id != ext_id:
        fail(f"Extension ID in the file is '{found_id}', expected '{ext_id}'.")
    print(f"{manifest.get('version', '?')} {'signed' if signed else 'unsigned'}")


def cmd_inspect(policy_path):
    """Print the current DisablePrivateBrowsing value: absent, true or false."""
    policies = load_policy_doc(policy_path).get("policies", {})
    if not isinstance(policies, dict) or "DisablePrivateBrowsing" not in policies:
        print("absent")
    else:
        print("true" if policies["DisablePrivateBrowsing"] is True else "false")


def cmd_merge(policy_path, config_path, ext_id, xpi_url):
    doc = load_policy_doc(policy_path)
    policies = child_dict(doc, "policies", "")
    settings = child_dict(policies, "ExtensionSettings", "policies/")
    settings[ext_id] = {"installation_mode": "force_installed", "install_url": xpi_url}
    policies["DisablePrivateBrowsing"] = True
    third_party = child_dict(policies, "3rdparty", "policies/")
    extensions = child_dict(third_party, "Extensions", "policies/3rdparty/")
    extensions[ext_id] = load_json(config_path, "Config file")
    emit(doc)


def cmd_update_config(policy_path, config_path, ext_id):
    doc = load_policy_doc(policy_path)
    policies = child_dict(doc, "policies", "")
    settings = child_dict(policies, "ExtensionSettings", "policies/")
    if ext_id not in settings:
        fail("ScamShield is not installed in this policy file. Run the install action first.")
    third_party = child_dict(policies, "3rdparty", "policies/")
    extensions = child_dict(third_party, "Extensions", "policies/3rdparty/")
    extensions[ext_id] = load_json(config_path, "Config file")
    emit(doc)


def cmd_remove(policy_path, ext_id, private_original):
    doc = load_policy_doc(policy_path)
    policies = doc.get("policies")
    if isinstance(policies, dict):
        settings = policies.get("ExtensionSettings")
        if isinstance(settings, dict):
            settings.pop(ext_id, None)
            if not settings:
                policies.pop("ExtensionSettings", None)
        third_party = policies.get("3rdparty")
        if isinstance(third_party, dict):
            extensions = third_party.get("Extensions")
            if isinstance(extensions, dict):
                extensions.pop(ext_id, None)
                if not extensions:
                    third_party.pop("Extensions", None)
            if not third_party:
                policies.pop("3rdparty", None)
        if private_original == "absent":
            policies.pop("DisablePrivateBrowsing", None)
        elif private_original in ("true", "false"):
            policies["DisablePrivateBrowsing"] = private_original == "true"
        if not policies:
            doc.pop("policies", None)
    emit(doc)


def cmd_is_empty(policy_path):
    sys.exit(0 if not load_policy_doc(policy_path) else 1)


def cmd_verify(policy_path, ext_id, xpi_url):
    doc = load_policy_doc(policy_path)
    policies = doc.get("policies") or {}
    entry = (policies.get("ExtensionSettings") or {}).get(ext_id) or {}
    if entry.get("installation_mode") != "force_installed" or entry.get("install_url") != xpi_url:
        fail("ExtensionSettings entry is missing or wrong.")
    block = ((policies.get("3rdparty") or {}).get("Extensions") or {}).get(ext_id)
    if not isinstance(block, dict) or block.get("schema_version") != 1:
        fail("3rdparty settings block is missing or wrong.")
    if policies.get("DisablePrivateBrowsing") is not True:
        fail("DisablePrivateBrowsing is not set.")


COMMANDS = {
    "validate-config": cmd_validate_config,
    "validate-xpi": cmd_validate_xpi,
    "inspect": cmd_inspect,
    "merge": cmd_merge,
    "update-config": cmd_update_config,
    "remove": cmd_remove,
    "is-empty": cmd_is_empty,
    "verify": cmd_verify,
}

if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
    fail("internal error: unknown helper command")
try:
    COMMANDS[sys.argv[1]](*sys.argv[2:])
except TypeError as error:
    fail(f"internal error: bad helper arguments ({error})")
PYEOF
)
readonly PY_HELPER

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} - deploy the ScamShield Firefox extension and policy

USAGE
    ${SCRIPT_NAME} --xpi PATH --config PATH --user NAME [--check] [--verbose]
    ${SCRIPT_NAME} --update-config PATH [--check] [--verbose]
    ${SCRIPT_NAME} --rollback [--check] [--verbose]
    ${SCRIPT_NAME} --uninstall [--check] [--verbose]
    ${SCRIPT_NAME} --generate-topic
    ${SCRIPT_NAME} --help

DESCRIPTION
    Installs the signed ScamShield extension (${EXTENSION_ID}) into Firefox
    through a root-owned policies.json, force-installs it so it cannot be
    removed or disabled, disables private browsing, and verifies the result.
    Any failure undoes the changes made during that run. Firefox must be the
    deb package (not snap or Flatpak). Changes apply after Firefox restarts.

ACTIONS
        (default)         Install: needs --xpi, --config and --user.
        --update-config PATH
                          Replace only the extension's settings block with the
                          JSON in PATH. Validated, backed up and written
                          atomically. This is the entry point for the controller.
        --rollback        Restore the most recent backup of policies.json.
                          Run again to step back further.
        --uninstall       Remove everything this script added (other Firefox
                          policies are left alone).
        --generate-topic  Print a random ntfy topic for the config file.

OPTIONS
    -h, --help       Show this help and exit.
    -v, --verbose    Print detailed progress. Debug lines are always written
                     to the log file, with or without this option.
        --version    Print the script version and exit.
        --xpi PATH   Signed extension file (.xpi). Install only.
        --config PATH
                     Initial policy block (JSON, see policy.schema.json).
                     Install only. notifier.topic must not be the placeholder.
        --user NAME  The standard (non-admin) account being protected. Install
                     only. The script checks that this account has no
                     administrator access but never changes the account.
        --policy-file PATH
                     Use this policies.json instead of auto-detecting it.
                     Install only; later actions use the path saved at install.
        --schema PATH
                     JSON schema used to validate the config. Defaults to
                     policy.schema.json next to this script, when present.
                     Full validation needs the optional python3-jsonschema.
        --check      Dry run. Report what would change and change nothing.
                     May be run without root; checks that need root are skipped.

DEVELOPER OPTIONS
        --self-test        Exercise the logging and undo framework (succeeds).
        --self-test-fail   Same, but fails on purpose to show the rollback.

FILES
    ${DEFAULT_LOG_FILE}    Log file (root only).
    ${XPI_DEST}    Installed extension file.
    ${STATE_FILE}    What the install changed, for rollback and uninstall.
    ${BACKUP_DIR}/    Timestamped backups of policies.json (root only).

ENVIRONMENT (testing only)
    SCAMSHIELD_OS_RELEASE    Path to use instead of /etc/os-release.
    SCAMSHIELD_PREFIX        Directory prepended to the install locations above.

EXIT CODES
    ${EXIT_OK}  success
    ${EXIT_ERROR}  failure (changes from this run were undone)
    ${EXIT_USAGE}  invalid command line
EOF
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

setup_colors() {
    if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
        COLOR_RED=$'\e[31m'
        COLOR_YELLOW=$'\e[33m'
        COLOR_DIM=$'\e[2m'
        COLOR_RESET=$'\e[0m'
    fi
}

# Append one line to the log file. Never fails the script if logging breaks.
log_to_file() {
    [[ -n "$LOG_FILE" ]] || return 0
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" \
        >>"$LOG_FILE" 2>/dev/null || true
}

log_info() {
    printf '[INFO] %s\n' "$*" >&2
    log_to_file INFO "$*"
}

log_warn() {
    printf '%s[WARN]%s %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
    log_to_file WARN "$*"
}

log_error() {
    printf '%s[ERROR]%s %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
    log_to_file ERROR "$*"
}

# Debug lines always go to the log file and only reach the console with -v.
log_debug() {
    if (( VERBOSE )); then
        printf '%s[DEBUG]%s %s\n' "$COLOR_DIM" "$COLOR_RESET" "$*" >&2
    fi
    log_to_file DEBUG "$*"
}

# Open the log file, falling back to console-only logging if it is not writable.
init_logging() {
    if (umask 027; : >>"$DEFAULT_LOG_FILE") 2>/dev/null; then
        LOG_FILE="$DEFAULT_LOG_FILE"
        log_debug "Logging to ${LOG_FILE}"
    else
        log_warn "Cannot write ${DEFAULT_LOG_FILE}; logging to the console only."
    fi
}

# ---------------------------------------------------------------------------
# Error handling and undo framework
# ---------------------------------------------------------------------------

# Log a fatal error and leave. The EXIT trap then runs the undo stack.
die() {
    local exit_code=$1
    shift
    log_error "$*"
    exit "$exit_code"
}

usage_error() {
    log_error "$*"
    printf 'Try: %s --help\n' "$SCRIPT_NAME" >&2
    exit "$EXIT_USAGE"
}

# Report where an unexpected command failure happened (set -e then exits).
on_err() {
    local exit_code=$1 line_number=$2 failed_command=$3
    log_error "Command failed (exit ${exit_code}) at line ${line_number}: ${failed_command}"
}

# Record how to reverse a change that was just made.
#   register_undo "description for the log" command arg1 arg2 ...
# The command is stored with its arguments quoted and run again on failure.
register_undo() {
    local description=$1
    shift
    if (( CHECK_MODE )); then
        return 0
    fi
    UNDO_DESCRIPTIONS+=("$description")
    UNDO_COMMANDS+=("$(printf '%q ' "$@")")
    log_debug "Registered undo: ${description}"
}

# Run every registered undo, newest first. A failing undo step is logged and
# the remaining steps still run.
run_undo() {
    local index failures=0
    trap - ERR
    set +e

    if (( ${#UNDO_COMMANDS[@]} == 0 )); then
        return 0
    fi

    log_warn "Rolling back ${#UNDO_COMMANDS[@]} change(s)..."
    for (( index = ${#UNDO_COMMANDS[@]} - 1; index >= 0; index-- )); do
        log_info "Undo: ${UNDO_DESCRIPTIONS[index]}"
        if ! eval "${UNDO_COMMANDS[index]}"; then
            log_error "Undo step failed: ${UNDO_DESCRIPTIONS[index]}"
            failures=$(( failures + 1 ))
        fi
    done

    UNDO_DESCRIPTIONS=()
    UNDO_COMMANDS=()

    if (( failures > 0 )); then
        log_error "${failures} undo step(s) failed. Manual cleanup may be needed; see the log."
    fi
    return 0
}

# Called once the whole run succeeded: nothing left to undo.
commit_changes() {
    UNDO_DESCRIPTIONS=()
    UNDO_COMMANDS=()
    log_debug "Changes committed; undo stack cleared."
}

# Runs on every exit. A non-zero exit triggers the undo stack.
on_exit() {
    local exit_code=$?
    trap - EXIT
    if (( exit_code != 0 )); then
        run_undo
    fi
    exit "$exit_code"
}

# Run (or, with --check, only describe) a step that changes the system.
#   run_change "description" command arg1 arg2 ...
run_change() {
    local description=$1
    shift
    if (( CHECK_MODE )); then
        log_info "[check] Would: ${description}"
        return 0
    fi
    log_info "${description}"
    log_debug "Running: $*"
    "$@" || die "$EXIT_ERROR" "Step failed: ${description}"
}

# Run the JSON helper. Its stdout is the result; anything it prints to stderr
# is logged (as errors when it failed).
run_python_helper() {
    local err_file helper_status=0 line
    err_file=$(mktemp)
    python3 -I -c "$PY_HELPER" "$@" 2>"$err_file" || helper_status=$?
    if [[ -s "$err_file" ]]; then
        while IFS= read -r line; do
            if (( helper_status != 0 )); then
                log_error "  ${line}"
            elif [[ "$line" == NOTE:* ]]; then
                log_warn "${line#NOTE: }"
            else
                log_debug "  ${line}"
            fi
        done <"$err_file"
    fi
    rm -f -- "$err_file"
    return "$helper_status"
}

# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

# Ensure an option that takes a value actually received one.
require_value() {
    if (( $# < 2 )) || [[ "$2" == -* ]]; then
        usage_error "Option $1 requires a value."
    fi
}

# Only one action may be chosen.
set_action() {
    [[ -z "$ACTION" ]] || usage_error "Choose only one action (install, --update-config, --rollback, --uninstall, --generate-topic or a self-test)."
    ACTION=$1
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                usage
                exit "$EXIT_OK"
                ;;
            --version)
                printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
                exit "$EXIT_OK"
                ;;
            -v|--verbose)
                VERBOSE=1
                ;;
            --check)
                CHECK_MODE=1
                ;;
            --rollback)
                set_action rollback
                ;;
            --uninstall)
                set_action uninstall
                ;;
            --generate-topic)
                set_action generate-topic
                ;;
            --update-config)
                require_value "$@"
                set_action update-config
                CONFIG_PATH=$2
                shift
                ;;
            --update-config=*)
                set_action update-config
                CONFIG_PATH=${1#*=}
                ;;
            --self-test)
                set_action self-test
                SELF_TEST_MODE="ok"
                ;;
            --self-test-fail)
                set_action self-test
                SELF_TEST_MODE="fail"
                ;;
            --xpi)
                require_value "$@"
                XPI_PATH=$2
                shift
                ;;
            --xpi=*)
                XPI_PATH=${1#*=}
                ;;
            --config)
                require_value "$@"
                CONFIG_PATH=$2
                shift
                ;;
            --config=*)
                CONFIG_PATH=${1#*=}
                ;;
            --user)
                require_value "$@"
                TARGET_USER=$2
                shift
                ;;
            --user=*)
                TARGET_USER=${1#*=}
                ;;
            --policy-file)
                require_value "$@"
                POLICY_FILE=$2
                shift
                ;;
            --policy-file=*)
                POLICY_FILE=${1#*=}
                ;;
            --schema)
                require_value "$@"
                SCHEMA_PATH=$2
                shift
                ;;
            --schema=*)
                SCHEMA_PATH=${1#*=}
                ;;
            *)
                usage_error "Unknown option: $1"
                ;;
        esac
        shift
    done

    ACTION=${ACTION:-install}
}

# Require that a path names an existing, readable regular file.
require_readable_file() {
    local label=$1 file_path=$2
    if [[ ! -f "$file_path" || ! -r "$file_path" ]]; then
        usage_error "${label} file not found or not readable: ${file_path}"
    fi
}

# Check that the combination of options makes sense for the chosen action.
validate_args() {
    case "$ACTION" in
        install)
            [[ -n "$XPI_PATH" ]] || usage_error "Install needs --xpi PATH."
            [[ -n "$CONFIG_PATH" ]] || usage_error "Install needs --config PATH."
            [[ -n "$TARGET_USER" ]] || usage_error "Install needs --user NAME (the standard account being protected)."
            [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
                || usage_error "--user must be a lowercase account name (letters, digits, _ and -)."
            require_readable_file "--xpi" "$XPI_PATH"
            require_readable_file "--config" "$CONFIG_PATH"
            ;;
        update-config)
            require_readable_file "--update-config" "$CONFIG_PATH"
            if [[ -n "$XPI_PATH" || -n "$TARGET_USER" || -n "$POLICY_FILE" ]]; then
                log_warn "--xpi, --user and --policy-file are ignored for --update-config."
            fi
            ;;
        rollback|uninstall)
            if [[ -n "$XPI_PATH" || -n "$CONFIG_PATH" || -n "$TARGET_USER" || -n "$POLICY_FILE" ]]; then
                log_warn "--xpi, --config, --user and --policy-file are ignored for --${ACTION}."
            fi
            ;;
    esac
    if [[ -n "$SCHEMA_PATH" ]]; then
        require_readable_file "--schema" "$SCHEMA_PATH"
    fi
}

# ---------------------------------------------------------------------------
# Environment checks (read-only: nothing here changes the system)
# ---------------------------------------------------------------------------

# Anything that changes the system needs root. --check may run without it, but
# the checks that need root are skipped.
check_root() {
    if (( EUID == 0 )); then
        IS_ROOT=1
        log_debug "Running as root."
        return 0
    fi

    if (( CHECK_MODE )); then
        log_warn "Not running as root: --check will skip the checks that need root."
        return 0
    fi
    die "$EXIT_ERROR" "This action must run as root. Try: sudo ${SCRIPT_NAME} ..."
}

# python3 reads, merges and validates the JSON policy.
check_python() {
    command -v python3 >/dev/null 2>&1 \
        || die "$EXIT_ERROR" "python3 is required (it ships with Linux Mint). Install it with: sudo apt install python3"
    log_debug "python3: $(python3 --version 2>&1)"
}

# Read one field (ID, VERSION_ID, ...) from the os-release file in a subshell
# so its variables never leak into this script.
read_os_field() {
    local field_name=$1
    ( set +u; . "$OS_RELEASE_FILE" >/dev/null 2>&1 || true; printf '%s' "${!field_name:-}" )
}

# Linux Mint is the tested target. Other Debian-family systems continue with a
# warning; anything else stops.
check_os() {
    local os_id os_like os_name

    [[ -r "$OS_RELEASE_FILE" ]] \
        || die "$EXIT_ERROR" "Cannot read ${OS_RELEASE_FILE}, so the operating system is unknown."

    os_id=$(read_os_field ID)
    os_like=$(read_os_field ID_LIKE)
    os_name=$(read_os_field PRETTY_NAME)
    OS_VERSION_ID=$(read_os_field VERSION_ID)
    log_debug "Detected OS: ${os_name:-unknown} (ID=${os_id:-?}, ID_LIKE=${os_like:-?}, VERSION_ID=${OS_VERSION_ID:-?})"

    if [[ "$os_id" == "linuxmint" ]]; then
        if [[ "$OS_VERSION_ID" != "$TARGET_MINT_VERSION" ]]; then
            log_warn "Built and tested for Linux Mint ${TARGET_MINT_VERSION}; found ${OS_VERSION_ID:-unknown}. Continuing."
        fi
    elif [[ " ${os_id} ${os_like} " =~ [[:space:]](debian|ubuntu)[[:space:]] ]]; then
        log_warn "Built for Linux Mint ${TARGET_MINT_VERSION}; found ${os_name:-$os_id} (Debian family). Continuing. After Firefox restarts, confirm the policy loaded at about:policies."
    else
        die "$EXIT_ERROR" "This script supports Linux Mint and Debian-family systems only (found: ${os_name:-unknown})."
    fi
}

# Firefox must be the deb package. Snap, Flatpak and tarball installs do not
# read the system policy file this deployment relies on.
check_firefox() {
    local firefox_link firefox_real firefox_owner version_raw major flatpak_apps policy_file
    local deb_hint="Install Firefox from Mozilla's apt repository (a deb package), then run this again."

    firefox_link=$(command -v firefox || true)
    [[ -n "$firefox_link" ]] \
        || die "$EXIT_ERROR" "Firefox is not installed (no 'firefox' command found)."
    firefox_real=$(readlink -f -- "$firefox_link")
    log_debug "Firefox command: ${firefox_link} -> ${firefox_real}"

    if [[ "$firefox_link" == /snap/* || "$firefox_real" == /snap/* ]]; then
        die "$EXIT_ERROR" "Firefox is a snap, which ignores this policy. ${deb_hint}"
    fi

    FIREFOX_DIR=${firefox_real%/*}
    if [[ ! -f "${FIREFOX_DIR}/application.ini" ]]; then
        die "$EXIT_ERROR" "'firefox' resolves to ${firefox_real}, which is not a standard Firefox install (a launcher script, such as a snap wrapper?). ${deb_hint}"
    fi

    command -v dpkg >/dev/null 2>&1 || die "$EXIT_ERROR" "dpkg not found; cannot verify the Firefox package."
    firefox_owner=$(dpkg -S -- "$firefox_real" 2>/dev/null || true)
    firefox_owner=${firefox_owner%%$'\n'*}
    FIREFOX_PACKAGE=${firefox_owner%%:*}
    [[ -n "$FIREFOX_PACKAGE" ]] \
        || die "$EXIT_ERROR" "${firefox_real} does not belong to any deb package (portable or tarball install?)."

    version_raw=$(dpkg-query -W -f='${Version}' "$FIREFOX_PACKAGE" 2>/dev/null || true)
    [[ -n "$version_raw" ]] \
        || die "$EXIT_ERROR" "Cannot read the version of package '${FIREFOX_PACKAGE}'."
    if [[ "$version_raw" == *snap* ]]; then
        die "$EXIT_ERROR" "Package '${FIREFOX_PACKAGE}' (${version_raw}) is a snap installer, not real Firefox. ${deb_hint}"
    fi
    [[ "$version_raw" =~ ^([0-9]+:)?([0-9]+)\. ]] \
        || die "$EXIT_ERROR" "Cannot understand the Firefox version '${version_raw}'."
    major=${BASH_REMATCH[2]}
    FIREFOX_VERSION=$version_raw
    if (( 10#$major < MIN_FIREFOX_MAJOR )); then
        die "$EXIT_ERROR" "Firefox ${FIREFOX_VERSION} is too old; the extension needs ${MIN_FIREFOX_MAJOR} or newer."
    fi

    # Other Firefox installs the user could start instead are a bypass route.
    if command -v flatpak >/dev/null 2>&1; then
        flatpak_apps=$(flatpak list --app --columns=application 2>/dev/null || true)
        if grep -qx 'org.mozilla.firefox' <<<"$flatpak_apps"; then
            log_warn "A Flatpak Firefox is installed. It ignores this policy and could be used to bypass protection."
        fi
    fi
    if command -v snap >/dev/null 2>&1 && snap list firefox >/dev/null 2>&1; then
        log_warn "A snap Firefox is installed. It ignores this policy and could be used to bypass protection."
    fi

    for policy_file in "${FIREFOX_DIR}/distribution/policies.json" "$ETC_POLICY_FILE"; do
        if [[ -e "$policy_file" ]]; then
            log_info "Existing Firefox policy file found: ${policy_file}"
        fi
    done
    log_info "Firefox ${FIREFOX_VERSION} (package ${FIREFOX_PACKAGE}) at ${FIREFOX_DIR}"
}

# The protected account must be a regular user without administrator access,
# otherwise the root-owned policy file can be undone. Reports only; never
# changes the account.
check_target_user() {
    local user_id group_name privileged_group
    local sudoers_hits="" sudoers_file
    local -a user_groups=() found_groups=()

    id -u -- "$TARGET_USER" >/dev/null 2>&1 \
        || die "$EXIT_ERROR" "User '${TARGET_USER}' does not exist."
    user_id=$(id -u -- "$TARGET_USER")
    if (( user_id < 1000 )); then
        die "$EXIT_ERROR" "'${TARGET_USER}' (uid ${user_id}) is a system account, not a regular user."
    fi

    read -r -a user_groups <<<"$(id -nG -- "$TARGET_USER")"
    for group_name in "${user_groups[@]}"; do
        for privileged_group in "${PRIVILEGED_GROUPS[@]}"; do
            if [[ "$group_name" == "$privileged_group" ]]; then
                found_groups+=("$group_name")
            fi
        done
    done

    if (( IS_ROOT )); then
        sudoers_hits=$(grep -rlE -e "^[[:space:]]*${TARGET_USER}[[:space:]]" \
            /etc/sudoers /etc/sudoers.d 2>/dev/null || true)
    else
        log_debug "Skipping the sudoers check (needs root)."
    fi

    if (( ${#found_groups[@]} == 0 )) && [[ -z "$sudoers_hits" ]]; then
        log_info "Account '${TARGET_USER}' has no administrator access."
        return 0
    fi

    log_warn "============================================================"
    log_warn "'${TARGET_USER}' has administrator-level access."
    log_warn "That lets the user, or a scammer guiding them, undo this protection."
    for group_name in "${found_groups[@]}"; do
        log_warn "  Member of group '${group_name}'. To remove: sudo gpasswd -d ${TARGET_USER} ${group_name}"
    done
    for sudoers_file in $sudoers_hits; do
        log_warn "  Explicit sudoers entry in ${sudoers_file}"
    done
    log_warn "No account changes were made. Continuing."
    log_warn "============================================================"
}

# Each action needs a different set of checks.
run_environment_checks() {
    check_root
    case "$ACTION" in
        install)
            check_python
            check_os
            check_firefox
            check_target_user
            ;;
        update-config|uninstall)
            check_python
            ;;
    esac
    log_info "Environment checks finished."
}

# ---------------------------------------------------------------------------
# Policy file handling
# ---------------------------------------------------------------------------

# Pick the policies.json to manage: --policy-file, else an existing file, else
# the distribution directory of the Firefox install, else /etc/firefox/policies.
determine_policy_path() {
    local dist_file="${FIREFOX_DIR}/distribution/policies.json"

    if [[ -n "$POLICY_FILE" ]]; then
        log_info "Policy file (from --policy-file): ${POLICY_FILE}"
        return 0
    fi

    if [[ -e "$dist_file" && -e "$ETC_POLICY_FILE" ]]; then
        log_warn "Policy files exist in both ${dist_file} and ${ETC_POLICY_FILE}. Using the first; check about:policies after the restart."
        POLICY_FILE=$dist_file
    elif [[ -e "$dist_file" ]]; then
        POLICY_FILE=$dist_file
    elif [[ -e "$ETC_POLICY_FILE" ]]; then
        POLICY_FILE=$ETC_POLICY_FILE
    elif [[ -d "${FIREFOX_DIR}/distribution" ]]; then
        POLICY_FILE=$dist_file
    else
        POLICY_FILE=$ETC_POLICY_FILE
    fi
    log_info "Policy file: ${POLICY_FILE}"
}

# Create a directory (and missing parents), registering an undo for each one
# that did not exist before.
ensure_dir() {
    local dir=$1 mode=${2:-0755} parent

    if [[ -d "$dir" ]]; then
        return 0
    fi
    # In --check mode nothing is created, so remember what was already reported.
    if (( CHECK_MODE )) && [[ " ${CHECK_PLANNED_DIRS[*]:-} " == *" ${dir} "* ]]; then
        return 0
    fi
    CHECK_PLANNED_DIRS+=("$dir")
    parent=$(dirname -- "$dir")
    ensure_dir "$parent" 0755
    run_change "Create directory ${dir}" install -d -m "$mode" -o root -g root -- "$dir"
    register_undo "Remove directory ${dir}" rmdir -- "$dir"
}

# Put a backed-up policy file back (atomically), or remove the file if none
# existed when the backup was taken (".absent" marker).
restore_policy_backup() {
    local backup=$1 target=$2 tmp_file

    if [[ "$backup" == *.absent ]]; then
        rm -f -- "$target"
        return 0
    fi
    tmp_file="${target}.restore.$$"
    cp -p -- "$backup" "$tmp_file" && mv -f -- "$tmp_file" "$target"
}

# Back up the current policy file; sets BACKUP_FILE. A file that does not exist
# yet is recorded with an ".absent" marker so rollback can remove it again.
backup_policy_file() {
    local stamp
    stamp="$(date '+%Y%m%dT%H%M%S').$$"

    if [[ -e "$POLICY_FILE" ]]; then
        BACKUP_FILE="${BACKUP_DIR}/policies.json.${stamp}"
        run_change "Back up ${POLICY_FILE} to ${BACKUP_FILE}" cp -p -- "$POLICY_FILE" "$BACKUP_FILE"
    else
        BACKUP_FILE="${BACKUP_DIR}/policies.json.${stamp}.absent"
        run_change "Record that ${POLICY_FILE} did not exist (${BACKUP_FILE})" touch -- "$BACKUP_FILE"
    fi
    # Registered first, so on failure it runs after the restore that needs it.
    register_undo "Remove backup ${BACKUP_FILE}" rm -f -- "$BACKUP_FILE"
}

# Write $1 to the policy file: temp file in the same directory, validate,
# set root ownership, then swap in with an atomic rename.
write_policy_file() {
    local content=$1 policy_dir tmp_file

    if (( CHECK_MODE )); then
        log_info "[check] Would: write ${#content} bytes to ${POLICY_FILE} (validated, atomic replace, root:root 0644)"
        return 0
    fi

    policy_dir=$(dirname -- "$POLICY_FILE")
    tmp_file=$(mktemp -- "${policy_dir}/.policies.json.XXXXXX") \
        || die "$EXIT_ERROR" "Cannot create a temporary file in ${policy_dir}."
    register_undo "Remove temporary file ${tmp_file}" rm -f -- "$tmp_file"

    printf '%s\n' "$content" >"$tmp_file" || die "$EXIT_ERROR" "Cannot write ${tmp_file}."
    chown root:root -- "$tmp_file" || die "$EXIT_ERROR" "Cannot set ownership on ${tmp_file}."
    chmod 0644 -- "$tmp_file" || die "$EXIT_ERROR" "Cannot set permissions on ${tmp_file}."
    python3 -I -c 'import json, sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$tmp_file" \
        || die "$EXIT_ERROR" "The new policy file is not valid JSON; leaving ${POLICY_FILE} untouched."

    register_undo "Restore previous ${POLICY_FILE}" restore_policy_backup "$BACKUP_FILE" "$POLICY_FILE"
    log_info "Writing ${POLICY_FILE}"
    mv -f -- "$tmp_file" "$POLICY_FILE" || die "$EXIT_ERROR" "Cannot replace ${POLICY_FILE}."
}

# Check the result matches what was intended: policy content, ownership,
# permissions and an identical extension file.
verify_install() {
    local policy_owner xpi_owner

    if (( CHECK_MODE )); then
        log_info "[check] Would: verify the policy content, ownership (root:root 0644) and extension file"
        return 0
    fi

    run_python_helper verify "$POLICY_FILE" "$EXTENSION_ID" "$XPI_URL" \
        || die "$EXIT_ERROR" "Verification failed: the policy file does not contain the expected settings."
    cmp -s -- "$XPI_PATH" "$XPI_DEST" \
        || die "$EXIT_ERROR" "Verification failed: ${XPI_DEST} differs from ${XPI_PATH}."
    policy_owner=$(stat -c '%U:%G %a' -- "$POLICY_FILE")
    xpi_owner=$(stat -c '%U:%G %a' -- "$XPI_DEST")
    [[ "$policy_owner" == "root:root 644" ]] \
        || die "$EXIT_ERROR" "Verification failed: ${POLICY_FILE} is '${policy_owner}', expected 'root:root 644'."
    [[ "$xpi_owner" == "root:root 644" ]] \
        || die "$EXIT_ERROR" "Verification failed: ${XPI_DEST} is '${xpi_owner}', expected 'root:root 644'."
    log_info "Verification passed."
}

# ---------------------------------------------------------------------------
# State file (remembers what the install changed, for rollback and uninstall)
# ---------------------------------------------------------------------------

# Read the state file into the STATE_* variables. Returns 1 if there is none.
load_state() {
    local key value

    [[ -r "$STATE_FILE" ]] || return 1
    while IFS='=' read -r key value; do
        case "$key" in
            POLICY_FILE)    STATE_POLICY_FILE=$value ;;
            POLICY_EXISTED) STATE_POLICY_EXISTED=$value ;;
            PRIVATE_ORIG)   STATE_PRIVATE_ORIG=$value ;;
        esac
    done <"$STATE_FILE"
    [[ -n "$STATE_POLICY_FILE" ]]
}

# Write the state file: $1 = policy existed before install (0/1),
# $2 = original DisablePrivateBrowsing value (absent/true/false).
save_state() {
    local policy_existed=$1 private_original=$2

    if (( CHECK_MODE )); then
        log_info "[check] Would: save install state to ${STATE_FILE}"
        return 0
    fi
    log_info "Saving install state to ${STATE_FILE}"
    {
        printf 'POLICY_FILE=%s\n' "$POLICY_FILE"
        printf 'POLICY_EXISTED=%s\n' "$policy_existed"
        printf 'PRIVATE_ORIG=%s\n' "$private_original"
        printf 'INSTALLED_AT=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')"
    } >"$STATE_FILE" || die "$EXIT_ERROR" "Cannot write ${STATE_FILE}."
    chmod 0644 -- "$STATE_FILE"
}

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------

# Validate the policy config; uses the schema when one is available.
validate_config_file() {
    local schema_arg=$SCHEMA_PATH

    if [[ -z "$schema_arg" && -r "${SCRIPT_DIR}/policy.schema.json" ]]; then
        schema_arg="${SCRIPT_DIR}/policy.schema.json"
    fi
    log_info "Validating config ${CONFIG_PATH}"
    run_python_helper validate-config "$CONFIG_PATH" "$schema_arg" \
        || die "$EXIT_ERROR" "Config validation failed. Nothing was changed."
}

# Validate the extension archive: a real add-on with the expected ID.
validate_xpi_file() {
    local result version signed

    log_info "Validating extension file ${XPI_PATH}"
    result=$(run_python_helper validate-xpi "$XPI_PATH" "$EXTENSION_ID") \
        || die "$EXIT_ERROR" "Extension file validation failed. Nothing was changed."
    read -r version signed <<<"$result"
    log_info "Extension version ${version} (${signed})"
    if [[ "$signed" != "signed" ]]; then
        log_warn "The extension file is NOT signed by Mozilla. Release Firefox will refuse to install it. Use the signed file from addons.mozilla.org."
    fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

action_install() {
    local policy_existed private_original xpi_backup stamp

    validate_config_file
    validate_xpi_file
    determine_policy_path

    # A repeat install keeps what the first install recorded about the system.
    if load_state; then
        policy_existed=$STATE_POLICY_EXISTED
        private_original=$STATE_PRIVATE_ORIG
        log_info "Existing install found; re-installing over it."
        if [[ "$STATE_POLICY_FILE" != "$POLICY_FILE" ]]; then
            log_warn "The earlier install used ${STATE_POLICY_FILE}; now using ${POLICY_FILE}."
        fi
    else
        policy_existed=0
        [[ -e "$POLICY_FILE" ]] && policy_existed=1
        private_original=$(run_python_helper inspect "$POLICY_FILE") \
            || die "$EXIT_ERROR" "Cannot read the existing policy file. Nothing was changed."
    fi
    log_debug "Policy existed before: ${policy_existed}; DisablePrivateBrowsing was: ${private_original}"

    MERGED_JSON=$(run_python_helper merge "$POLICY_FILE" "$CONFIG_PATH" "$EXTENSION_ID" "$XPI_URL") \
        || die "$EXIT_ERROR" "Could not build the new policy. Nothing was changed."

    ensure_dir "$BACKUP_DIR" 0700
    ensure_dir "$STATE_DIR" 0755
    ensure_dir "$XPI_DEST_DIR" 0755
    backup_policy_file

    # Keep the previous extension file if this is a re-install.
    if [[ -f "$XPI_DEST" ]]; then
        stamp="$(date '+%Y%m%dT%H%M%S').$$"
        xpi_backup="${BACKUP_DIR}/scamshield.xpi.${stamp}"
        run_change "Back up the current extension file to ${xpi_backup}" cp -p -- "$XPI_DEST" "$xpi_backup"
        register_undo "Remove extension backup ${xpi_backup}" rm -f -- "$xpi_backup"
        register_undo "Restore the previous extension file" cp -p -- "$xpi_backup" "$XPI_DEST"
    else
        register_undo "Remove ${XPI_DEST}" rm -f -- "$XPI_DEST"
    fi
    run_change "Install the extension file to ${XPI_DEST}" \
        install -m 0644 -o root -g root -- "$XPI_PATH" "$XPI_DEST"

    ensure_dir "$(dirname -- "$POLICY_FILE")" 0755
    write_policy_file "$MERGED_JSON"

    if [[ ! -e "$STATE_FILE" ]]; then
        register_undo "Remove ${STATE_FILE}" rm -f -- "$STATE_FILE"
    fi
    save_state "$policy_existed" "$private_original"

    verify_install
    commit_changes
    if (( CHECK_MODE )); then
        log_info "Check finished. Nothing was changed."
    else
        log_info "Install complete. Restart Firefox, then open about:policies to confirm the policy is active."
    fi
}

action_update_config() {
    validate_config_file

    load_state || die "$EXIT_ERROR" "ScamShield is not installed (no ${STATE_FILE}). Run the install action first."
    POLICY_FILE=$STATE_POLICY_FILE
    [[ -f "$POLICY_FILE" ]] || die "$EXIT_ERROR" "Policy file ${POLICY_FILE} is missing. Run the install action again."

    MERGED_JSON=$(run_python_helper update-config "$POLICY_FILE" "$CONFIG_PATH" "$EXTENSION_ID") \
        || die "$EXIT_ERROR" "Could not build the updated policy. Nothing was changed."

    ensure_dir "$BACKUP_DIR" 0700
    backup_policy_file
    write_policy_file "$MERGED_JSON"

    if (( ! CHECK_MODE )); then
        run_python_helper verify "$POLICY_FILE" "$EXTENSION_ID" "$XPI_URL" \
            || die "$EXIT_ERROR" "Verification failed after the update."
        log_info "Verification passed."
    fi
    commit_changes
    if (( CHECK_MODE )); then
        log_info "Check finished. Nothing was changed."
    else
        log_info "Config updated. Restart Firefox for it to take effect."
    fi
}

action_rollback() {
    local safety_copy
    local -a backups=()

    load_state || die "$EXIT_ERROR" "ScamShield is not installed (no ${STATE_FILE}); nothing to roll back."
    POLICY_FILE=$STATE_POLICY_FILE

    if [[ ! -r "$BACKUP_DIR" ]]; then
        if (( CHECK_MODE )); then
            log_warn "Cannot read ${BACKUP_DIR} without root; skipping the backup check."
            return 0
        fi
        die "$EXIT_ERROR" "Cannot read ${BACKUP_DIR}."
    fi
    mapfile -t backups < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'policies.json.*' | sort)
    (( ${#backups[@]} > 0 )) || die "$EXIT_ERROR" "No backups found in ${BACKUP_DIR}."
    BACKUP_FILE=${backups[-1]}

    # Keep a copy of the current file first, so the rollback itself can be undone by hand.
    safety_copy="${BACKUP_DIR}/rolled-back.$(date '+%Y%m%dT%H%M%S').$$"
    if [[ -e "$POLICY_FILE" ]]; then
        run_change "Save the current policy file to ${safety_copy}" cp -p -- "$POLICY_FILE" "$safety_copy"
        register_undo "Remove ${safety_copy}" rm -f -- "$safety_copy"
        register_undo "Put back ${POLICY_FILE} as it was before the rollback" \
            restore_policy_backup "$safety_copy" "$POLICY_FILE"
    else
        register_undo "Remove ${POLICY_FILE} again" rm -f -- "$POLICY_FILE"
    fi
    run_change "Restore ${POLICY_FILE} from ${BACKUP_FILE}" restore_policy_backup "$BACKUP_FILE" "$POLICY_FILE"
    run_change "Remove the used backup ${BACKUP_FILE}" rm -f -- "$BACKUP_FILE"

    commit_changes
    if (( CHECK_MODE )); then
        log_info "Check finished. Nothing was changed."
    else
        log_info "Rolled back. The safety copy of the replaced file is ${safety_copy}. Restart Firefox to apply."
    fi
}

action_uninstall() {
    local result_json xpi_backup stamp

    load_state || die "$EXIT_ERROR" "ScamShield is not installed (no ${STATE_FILE}); nothing to uninstall."
    POLICY_FILE=$STATE_POLICY_FILE
    stamp="$(date '+%Y%m%dT%H%M%S').$$"

    ensure_dir "$BACKUP_DIR" 0700

    if [[ -f "$POLICY_FILE" ]]; then
        result_json=$(run_python_helper remove "$POLICY_FILE" "$EXTENSION_ID" "$STATE_PRIVATE_ORIG") \
            || die "$EXIT_ERROR" "Could not build the cleaned policy. Nothing was changed."
        backup_policy_file

        # Delete the file only if we created it and nothing else is left in it.
        if [[ "$STATE_POLICY_EXISTED" == "0" && "$result_json" == "$(printf '{}\n')" ]]; then
            register_undo "Restore ${POLICY_FILE}" restore_policy_backup "$BACKUP_FILE" "$POLICY_FILE"
            run_change "Delete ${POLICY_FILE} (it only held ScamShield settings)" rm -f -- "$POLICY_FILE"
        else
            write_policy_file "$result_json"
        fi
    else
        log_warn "Policy file ${POLICY_FILE} is already gone."
    fi

    if [[ -f "$XPI_DEST" ]]; then
        xpi_backup="${BACKUP_DIR}/scamshield.xpi.removed.${stamp}"
        run_change "Keep a copy of the extension file at ${xpi_backup}" cp -p -- "$XPI_DEST" "$xpi_backup"
        register_undo "Remove extension copy ${xpi_backup}" rm -f -- "$xpi_backup"
        register_undo "Put back ${XPI_DEST}" cp -p -- "$xpi_backup" "$XPI_DEST"
        run_change "Remove ${XPI_DEST}" rm -f -- "$XPI_DEST"
    fi

    run_change "Remove ${STATE_FILE}" rm -f -- "$STATE_FILE"
    if (( CHECK_MODE )); then
        log_info "[check] Would: remove ${XPI_DEST_DIR} and ${STATE_DIR} if empty"
    else
        rmdir -- "$XPI_DEST_DIR" "$STATE_DIR" 2>/dev/null || log_debug "Left non-empty directories in place."
    fi

    commit_changes
    if (( CHECK_MODE )); then
        log_info "Check finished. Nothing was changed."
    else
        log_info "Uninstalled. Backups remain in ${BACKUP_DIR}. Restart Firefox to apply."
    fi
}

# Print a random topic for the ntfy notifier: 32 URL-safe characters.
action_generate_topic() {
    head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n'
    printf '\n'
}

# Exercises logging, run_change, register_undo and the exit trap with harmless
# temporary files, so the framework can be tested before real work uses it.
action_self_test() {
    local work_dir="/tmp/scamshield-selftest.$$"

    log_info "Self-test (${SELF_TEST_MODE}): creating temporary files."
    run_change "Create directory ${work_dir}" mkdir "$work_dir"
    register_undo "Remove directory ${work_dir}" rm -rf -- "$work_dir"

    run_change "Create ${work_dir}/marker" touch "${work_dir}/marker"
    register_undo "Remove ${work_dir}/marker" rm -f -- "${work_dir}/marker"

    if [[ "$SELF_TEST_MODE" == "fail" ]]; then
        log_info "Self-test: running a command that fails on purpose."
        # Deliberately unguarded so the ERR trap and the undo stack are tested.
        false
    fi

    commit_changes
    if (( ! CHECK_MODE )); then
        rm -rf -- "$work_dir"
    fi
    log_info "Self-test passed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

check_bash_version() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        printf 'Bash 4.4 or newer is required (found %s).\n' "$BASH_VERSION" >&2
        exit "$EXIT_ERROR"
    fi
}

main() {
    check_bash_version
    setup_colors
    trap on_exit EXIT
    trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
    trap 'die 130 "Interrupted (SIGINT)."' INT
    trap 'die 143 "Terminated (SIGTERM)."' TERM

    parse_args "$@"
    validate_args

    # Printing a topic needs no logging, root or environment checks.
    if [[ "$ACTION" == "generate-topic" ]]; then
        action_generate_topic
        exit "$EXIT_OK"
    fi

    init_logging
    log_info "${SCRIPT_NAME} ${SCRIPT_VERSION} starting (action: ${ACTION}, check mode: $(( CHECK_MODE )))."

    case "$ACTION" in
        install|update-config|rollback|uninstall) run_environment_checks ;;
    esac

    case "$ACTION" in
        install)       action_install ;;
        update-config) action_update_config ;;
        rollback)      action_rollback ;;
        uninstall)     action_uninstall ;;
        self-test)     action_self_test ;;
    esac

    commit_changes
    log_info "Finished."
}

# Allow the file to be sourced for testing without running main.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi