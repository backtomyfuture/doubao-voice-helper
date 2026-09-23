#!/usr/bin/env python3
"""Patch Logi Options+ MX Master 3S gesture button (c195) to emit mouse button 6.

Doubao only accepts a keyboard key. The companion daemon maps that extra
mouse button hold → left Ctrl tap (start) / release → left Ctrl tap (stop).
"""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import time
from datetime import datetime

SETTINGS_DB = os.path.expanduser(
    "~/Library/Application Support/LogiOptionsPlus/settings.db"
)
SLOT = "mx-master-3s-2b034_c195"
HID_USAGE = 6  # extra button; CGEvent button number is usually hidUsage-1 = 5

NEW_ASSIGNMENT = {
    "card": {
        "attribute": "MACRO_PLAYBACK",
        "icons": {
            "icons": ["Shortcut.png", "Shortcut.svg"],
            "uri": "pipeline://system_actions/",
        },
        "id": "card_global_presets_keyboard_shortcut",
        "macro": {
            "actionName": "MB6",
            "mouse": {"action": "BUTTON", "hidUsage": HID_USAGE},
            "type": "MOUSE",
        },
        "name": "ASSIGNMENT_NAME_KEYBOARD_SHORTCUT",
        "tags": [
            "PRESET_TAG_KEY_OR_BUTTON",
            "PRESET_TAG_MACROS_UNSUPPORTED",
            "PRESET_KEYBOARD_FUNCTIONS",
        ],
        "taskId": 73,
    },
    "cardId": "card_global_presets_keyboard_shortcut",
    "slotId": SLOT,
    "tags": ["UI_PAGE_BUTTONS"],
}

AGENT = (
    "/Library/Application Support/Logitech.localized/"
    "LogiOptionsPlus/logioptionsplus_agent.app"
)


def backup(db: str) -> str:
    ts = datetime.now().strftime("%Y%m%d-%H%M%S")
    dest = f"{db}.bak-doubao-{ts}"
    shutil.copy2(db, dest)
    return dest


def patch_blob(raw: str) -> tuple[str, int]:
    data = json.loads(raw)
    n = 0
    for key, val in data.items():
        if not isinstance(val, dict):
            continue
        assigns = val.get("assignments")
        if not isinstance(assigns, list):
            continue
        for i, a in enumerate(assigns):
            if a.get("slotId") == SLOT:
                assigns[i] = json.loads(json.dumps(NEW_ASSIGNMENT))
                n += 1
    if n == 0:
        raise SystemExit(f"no {SLOT} assignments found")
    return json.dumps(data, ensure_ascii=False, indent=2) + "\n", n


def restart_agent() -> None:
    subprocess.run(["killall", "logioptionsplus_agent"], check=False)
    time.sleep(1.2)
    subprocess.run(["open", AGENT], check=False)


def stop_agent() -> None:
    subprocess.run(
        ["osascript", "-e", 'tell application "logioptionsplus" to quit'],
        check=False,
        capture_output=True,
    )
    subprocess.run(["killall", "logioptionsplus_agent"], check=False)
    subprocess.run(["killall", "logioptionsplus"], check=False)
    time.sleep(2)


def main() -> None:
    if not os.path.exists(SETTINGS_DB):
        raise SystemExit(f"missing {SETTINGS_DB}")
    stop_agent()
    bak = backup(SETTINGS_DB)
    print(f"backup: {bak}")
    con = sqlite3.connect(SETTINGS_DB)
    row = con.execute("SELECT _id, file FROM data LIMIT 1").fetchone()
    if not row:
        raise SystemExit("empty settings.db")
    rid, blob = row
    text = blob.decode("utf-8") if isinstance(blob, bytes) else blob
    new_text, n = patch_blob(text)
    con.execute("UPDATE data SET file=? WHERE _id=?", (new_text, rid))
    con.commit()
    con.close()
    print(f"patched {n} profile assignment(s) {SLOT} → HID button {HID_USAGE}")
    restart_agent()
    print("logioptionsplus_agent restarted")


if __name__ == "__main__":
    main()
