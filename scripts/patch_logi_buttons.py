#!/usr/bin/env python3
"""Patch Logi Options+ database to emit raw mouse buttons for side buttons (forward/back).

By default on macOS, Logi Options+ converts forward/back clicks into macOS gesture navigation,
preventing apps (including DoubaoVoiceHelper and games) from receiving standard mouse events.

This script patches all mice in Logi Options+ settings.db:
- Back button (_c83) -> Mouse Button 4 (CGEvent button 3, hidUsage 4)
- Forward button (_c86) -> Mouse Button 5 (CGEvent button 4, hidUsage 5)
"""
from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime

SETTINGS_DB = os.path.expanduser(
    "~/Library/Application Support/LogiOptionsPlus/settings.db"
)

AGENT_PATH = (
    "/Library/Application Support/Logitech.localized/"
    "LogiOptionsPlus/logioptionsplus_agent.app"
)

def make_button_assignment(slot_id: str, hid_usage: int, action_name: str) -> dict:
    return {
        "card": {
            "attribute": "MACRO_PLAYBACK",
            "icons": {
                "icons": ["Shortcut.png", "Shortcut.svg"],
                "uri": "pipeline://system_actions/",
            },
            "id": "card_global_presets_keyboard_shortcut",
            "macro": {
                "actionName": action_name,
                "mouse": {"action": "BUTTON", "hidUsage": hid_usage},
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
        "slotId": slot_id,
        "tags": ["UI_PAGE_BUTTONS"],
    }

def backup_db(db_path: str) -> str:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    backup_path = f"{db_path}.bak-doubao-{timestamp}"
    shutil.copy2(db_path, backup_path)
    return backup_path

def stop_logi_processes():
    print("正在停止 Logi Options+ 进程...")
    subprocess.run(
        ["osascript", "-e", 'tell application "logioptionsplus" to quit'],
        check=False,
        capture_output=True,
    )
    subprocess.run(["killall", "logioptionsplus_agent"], check=False, capture_output=True)
    subprocess.run(["killall", "logioptionsplus"], check=False, capture_output=True)
    time.sleep(1.5)

def restart_logi_agent():
    print("正在重启 Logi Options+ 后台服务...")
    subprocess.run(["killall", "logioptionsplus_agent"], check=False, capture_output=True)
    time.sleep(0.5)
    if os.path.exists(AGENT_PATH):
        subprocess.run(["open", AGENT_PATH], check=False)
    print("Logi Options+ 服务已恢复。")

def patch_data(raw_json: str) -> tuple[str, int, list[str]]:
    data = json.loads(raw_json)
    patched_count = 0
    modified_slots = []

    for key, val in data.items():
        if not isinstance(val, dict):
            continue
        assignments = val.get("assignments")
        if not isinstance(assignments, list):
            continue

        for i, item in enumerate(assignments):
            slot_id = item.get("slotId", "")
            # c83 is Back (Mouse button 4), c86 is Forward (Mouse button 5)
            if slot_id.endswith("_c83"):
                assignments[i] = make_button_assignment(slot_id, 4, "MB4")
                patched_count += 1
                modified_slots.append(f"{slot_id} -> MB4 (后退)")
            elif slot_id.endswith("_c86"):
                assignments[i] = make_button_assignment(slot_id, 5, "MB5")
                patched_count += 1
                modified_slots.append(f"{slot_id} -> MB5 (前进)")

    new_json = json.dumps(data, ensure_ascii=False, indent=2) + "\n"
    return new_json, patched_count, modified_slots

def main():
    if not os.path.exists(SETTINGS_DB):
        print(f"未找到 Logi Options+ 配置文件：{SETTINGS_DB}")
        print("如果当前电脑未安装 Logi Options+，鼠标侧键默认即为系统原生键，无需修复。")
        sys.exit(1)

    stop_logi_processes()
    bak = backup_db(SETTINGS_DB)
    print(f"已备份原始配置到：{bak}")

    con = sqlite3.connect(SETTINGS_DB)
    try:
        row = con.execute("SELECT _id, file FROM data LIMIT 1").fetchone()
        if not row:
            print("错误：settings.db 数据为空")
            sys.exit(1)
        row_id, blob = row
        text = blob.decode("utf-8") if isinstance(blob, bytes) else blob
        new_text, count, slots = patch_data(text)

        if count == 0:
            print("未找到任何罗技鼠标侧键配置项（可能尚无鼠标连接记录）。")
            sys.exit(0)

        con.execute("UPDATE data SET file=? WHERE _id=?", (new_text, row_id))
        con.commit()
        print(f"\n成功修复 {count} 处按键配置：")
        for s in set(slots):
            print(f"  ✓ {s}")
    finally:
        con.close()

    restart_logi_agent()
    print("\n🎉 修复完成！现在你可以直接按鼠标前进键和后退键，系统与豆包语音助手均已原生支持！")

if __name__ == "__main__":
    main()
