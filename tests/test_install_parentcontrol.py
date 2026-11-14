#!/usr/bin/env python3
"""Isolated integration tests for install-parentcontrol.sh."""

import json
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
INSTALLER = REPOSITORY / "install-parentcontrol.sh"


class InstallerSyntaxTests(unittest.TestCase):
    def test_installer_has_valid_bash_syntax(self):
        result = subprocess.run(
            ["bash", "-n", str(INSTALLER)],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


class InstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        syntax_check = subprocess.run(
            ["bash", "-n", str(INSTALLER)],
            text=True,
            capture_output=True,
            check=False,
        )
        if syntax_check.returncode != 0:
            raise unittest.SkipTest(
                "Installer runtime tests need valid Bash syntax: "
                + syntax_check.stderr.strip()
            )

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory(prefix="parentcontrol-test-")
        self.addCleanup(self.temp_dir.cleanup)
        self.root = Path(self.temp_dir.name)
        self.etc_dir = self.root / "etc"
        self.etc_dir.mkdir()
        (self.etc_dir / "os-release").write_text(
            'ID=linuxmint\nVERSION_ID="22.3"\n', encoding="utf-8"
        )
        self.installer = self.root / "install-parentcontrol.sh"
        self.installer.write_text(self._stage_installer(), encoding="utf-8")
        self.installer.chmod(0o755)

    def _stage_installer(self):
        source = INSTALLER.read_text(encoding="utf-8")
        for system_path in (
            "/var/lib/parentcontrol",
            "/var/log/parentcontrol",
            "/etc/parentcontrol",
            "/opt/parentcontrol",
            "/etc/os-release",
        ):
            source = source.replace(system_path, str(self.root / system_path.lstrip("/")))

        # Keep tests unprivileged while retaining the installer flow and modes.
        source = source.replace(" -o root -g root", "")
        source = re.sub(r"(?m)^\s*chown root:root .*?$", ":", source)
        source = source.replace(
            'if [[ "${EUID}" -ne 0 ]]; then',
            "if false; then",
            1,
        )
        source = source.replace(
            "        pc_require_root\n",
            "        :\n",
        )
        return source

    def run_installer(self, *args):
        return subprocess.run(
            ["bash", str(self.installer), *args],
            text=True,
            capture_output=True,
            check=False,
        )

    def install(self, *args):
        result = self.run_installer("--skip-test", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def run_bash(self, script, *args):
        return subprocess.run(
            ["bash", "-c", script, "test-shell", *map(str, args)],
            text=True,
            capture_output=True,
            check=False,
        )

    @property
    def common_library(self):
        return self.root / "opt/parentcontrol/lib/common.sh"

    @property
    def config_file(self):
        return self.root / "etc/parentcontrol/config.json"

    def test_help_and_unknown_option(self):
        help_result = self.run_installer("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("ParentControl Bootstrap Installer v0.1.0", help_result.stdout)
        self.assertIn("--skip-test", help_result.stdout)

        unknown_result = self.run_installer("--not-a-real-option")
        self.assertEqual(unknown_result.returncode, 2)
        self.assertIn("Unknown option: --not-a-real-option", unknown_result.stderr)
        self.assertFalse((self.root / "opt/parentcontrol").exists())

    def test_installer_flags_are_parsed(self):
        source_without_main = self.installer.read_text(encoding="utf-8").replace(
            '\nmain "$@"\n', "\n"
        )
        definitions = self.root / "installer-functions.sh"
        definitions.write_text(source_without_main, encoding="utf-8")
        result = self.run_bash(
            'source "$1"; parse_args --verbose --force-os --skip-test; '
            'printf "%s %s %s\\n" "$VERBOSE" "$FORCE_OS" "$SKIP_TEST"',
            definitions,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "1 1 1")

    def test_deploys_expected_directories_files_and_modes(self):
        result = self.install("--verbose")
        self.assertIn("Pre-flight checks passed.", result.stdout)
        self.assertIn("self-test skipped", result.stdout)

        expected_modes = {
            "opt/parentcontrol": 0o755,
            "opt/parentcontrol/bin": 0o755,
            "opt/parentcontrol/lib": 0o755,
            "etc/parentcontrol": 0o750,
            "var/lib/parentcontrol": 0o750,
            "var/lib/parentcontrol/backup": 0o700,
            "var/lib/parentcontrol/queue": 0o751,
            "var/lib/parentcontrol/queue/pending": 0o1733,
            "var/lib/parentcontrol/queue/approved": 0o750,
            "var/lib/parentcontrol/queue/archive": 0o750,
            "var/log/parentcontrol": 0o750,
            "opt/parentcontrol/lib/defaults.conf": 0o644,
            "opt/parentcontrol/lib/common.sh": 0o644,
        }
        for relative_path, expected_mode in expected_modes.items():
            path = self.root / relative_path
            with self.subTest(path=relative_path):
                self.assertTrue(path.exists())
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), expected_mode)

        defaults = (self.root / "opt/parentcontrol/lib/defaults.conf").read_text(
            encoding="utf-8"
        )
        self.assertIn('readonly PC_ADMIN_USER="pcadmin"', defaults)
        self.assertIn('readonly PC_HOSTS_BEGIN_MARKER=', defaults)

    def test_rejects_unsupported_os_before_creating_installation(self):
        (self.etc_dir / "os-release").write_text(
            'ID=debian\nVERSION_ID="13"\n', encoding="utf-8"
        )
        result = self.run_installer("--skip-test")
        self.assertEqual(result.returncode, 4)
        self.assertIn("Target OS is Linux Mint 22.3", result.stderr)
        self.assertFalse((self.root / "opt/parentcontrol").exists())

    def test_force_os_override_allows_installation(self):
        (self.etc_dir / "os-release").write_text(
            'ID=debian\nVERSION_ID="13"\n', encoding="utf-8"
        )
        result = self.install("--force-os")
        self.assertTrue((self.root / "opt/parentcontrol/lib/common.sh").is_file())

    def test_config_creation_json_get_and_nested_set(self):
        self.install()
        result = self.run_bash(
            'source "$1"; '
            'pc_json_get maintenance.auto_updates; '
            'pc_json_set maintenance.trash_retention_days 14; '
            'pc_json_set new_section.enabled true; '
            'pc_json_get maintenance.trash_retention_days; '
            'pc_json_get new_section.enabled',
            self.common_library,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["true", "14", "true"])

        config = json.loads(self.config_file.read_text(encoding="utf-8"))
        self.assertEqual(config["admin_user"], "pcadmin")
        self.assertEqual(config["maintenance"]["trash_retention_days"], 14)
        self.assertIs(config["new_section"]["enabled"], True)
        self.assertEqual(stat.S_IMODE(self.config_file.stat().st_mode), 0o640)

    def test_invalid_json_update_rolls_back_configuration(self):
        self.install()
        initial = self.config_file.read_text(encoding="utf-8")
        result = self.run_bash(
            'source "$1"; pc_json_set maintenance.auto_updates "{"',
            self.common_library,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Changes rolled back", result.stderr)
        self.assertEqual(self.config_file.read_text(encoding="utf-8"), initial)

    def test_transaction_rollback_restores_and_removes_files(self):
        self.install()
        existing = self.root / "existing.txt"
        created = self.root / "created.txt"
        existing.write_text("before\n", encoding="utf-8")
        result = self.run_bash(
            'source "$1"; '
            'pc_init_transaction; '
            'pc_backup_file "$2"; printf "after\\n" > "$2"; '
            'pc_backup_file "$3"; printf "new\\n" > "$3"; '
            'pc_rollback; '
            'printf "%s %s\\n" "$PC_TX_ACTIVE" "${#PC_TX_MANIFEST[@]}"',
            self.common_library,
            existing,
            created,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(existing.read_text(encoding="utf-8"), "before\n")
        self.assertFalse(created.exists())
        self.assertEqual(result.stdout.strip(), "0 0")

    def test_transaction_commit_keeps_changes_and_cleans_backup(self):
        self.install()
        created = self.root / "committed.txt"
        result = self.run_bash(
            'source "$1"; '
            'pc_init_transaction; pc_backup_file "$2"; '
            'printf "kept\\n" > "$2"; tx_dir="$PC_TX_DIR"; '
            'pc_commit_transaction; '
            'printf "%s %s\\n" "$PC_TX_ACTIVE" "$PC_TX_DIR"; '
            'test ! -e "$tx_dir"',
            self.common_library,
            created,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "0 ")
        self.assertEqual(created.read_text(encoding="utf-8"), "kept\n")

    def test_json_result_contains_module_action_message_and_data(self):
        self.install()
        result = self.run_bash(
            'source "$1"; PC_MODULE_NAME="test-module"; '
            'PC_CURRENT_ACTION="verify"; PC_JSON_OUTPUT=1; '
            'pc_emit_result "ready" \'{"ok":true}\'',
            self.common_library,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(
            payload,
            {
                "status": "ok",
                "module": "test-module",
                "action": "verify",
                "message": "ready",
                "data": {"ok": True},
            },
        )

    def test_self_test_runs_with_staged_mint_environment(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(result.stdout)
        self.assertEqual(payload["status"], "ok")
        self.assertEqual(payload["module"], "selftest")
        self.assertEqual(payload["action"], "verify")
        self.assertEqual(payload["data"], {"mint_verified": True})


if __name__ == "__main__":
    unittest.main()
