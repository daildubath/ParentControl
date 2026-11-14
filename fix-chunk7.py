#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path

p = Path("install-parentcontrol.sh")
text = p.read_text(encoding="utf-8")

replacements = [
    (
        'readonly PC_POLKIT_RULE="/etc/polkit-1/rules.d/49-parentcontrol.rules"',
        'PC_POLKIT_RULE="${PC_POLKIT_RULE:-/etc/polkit-1/rules.d/49-parentcontrol.rules}"',
    ),
    (
        'readonly PC_PUBLIC_INFO="/etc/parentcontrol/public-info.json"',
        'PC_PUBLIC_INFO="${PC_PUBLIC_INFO:-/etc/parentcontrol/public-info.json}"',
    ),
    (
        'readonly PC_FEED_CACHE="${PC_VAR_DIR}/feed-blocklist.txt"',
        'PC_FEED_CACHE="${PC_FEED_CACHE:-${PC_VAR_DIR}/feed-blocklist.txt}"',
    ),
    (
        'readonly PC_HOSTS_FILE="/etc/hosts"',
        'PC_HOSTS_FILE="${PC_HOSTS_FILE:-/etc/hosts}"',
    ),
    (
        'readonly PC_HOSTS_BEGIN="# BEGIN PARENTCONTROL MANAGED BLOCKS"',
        'PC_HOSTS_BEGIN="${PC_HOSTS_BEGIN:-# BEGIN PARENTCONTROL MANAGED BLOCKS}"',
    ),
    (
        'readonly PC_HOSTS_END="# END PARENTCONTROL MANAGED BLOCKS"',
        'PC_HOSTS_END="${PC_HOSTS_END:-# END PARENTCONTROL MANAGED BLOCKS}"',
    ),
    (
        '    chown root:root "$PC_POLKIT_RULE"\n    chmod 0644 "$PC_POLKIT_RULE"\n}',
        '    chown root:root "$PC_POLKIT_RULE"\n    chmod 0644 "$PC_POLKIT_RULE"\n    systemctl restart polkit >/dev/null 2>&1 || true\n}',
    ),
    (
        '''    "restricted_user": cfg.get("restricted_user", ""),
    "default_browse_dir": f"/home/{cfg.get(\\"restricted_user\\", \\"\\")}",''',
        '''    "restricted_user": cfg.get("restricted_user", ""),
    "default_browse_dir": "/home/" + cfg.get("restricted_user", ""),''',
    ),
]

for old, new in replacements:
    if old not in text:
        print(f"[WARN] Pattern not found (may already be patched): {old[:55]}...")
    else:
        text = text.replace(old, new)

p.write_text(text, encoding="utf-8")
subprocess.run(["bash", "-n", str(p)], check=True)
print("[OK] install-parentcontrol.sh patched and syntax-verified.")
