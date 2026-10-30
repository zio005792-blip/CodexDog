#!/usr/bin/env python3
"""
清理 Codex 会话文件里内嵌的图片，阻止每轮对话重复上传历史图片。

做的事：
  1. 退出 Codex / ChatGPT 桌面版（运行中改文件会被覆盖或损坏）
  2. 扫描 ~/.codex/sessions 和 ~/.codex/archived_sessions 下所有 .jsonl
  3. 把内嵌的 base64 图片换成 1x1 透明 PNG（结构不变，对话仍可继续）
  4. 改过的行末尾补空格，保持每行字节数不变——Codex 在 thread_history_1.sqlite
     里按字节位置记录每轮对话，文件变短会导致聊天记录打不开
  5. 保留文件修改时间（侧边栏排序不乱），打印清理结果

用法：python3 clean_images.py
注意：不做备份，清理后模型看不到旧图片，无法恢复。文件大小不会变小。
旧版清理导致记录打不开的，运行 repair_history.py 修复。
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
SCAN_DIRS = [CODEX_HOME / "sessions", CODEX_HOME / "archived_sessions"]

TINY_PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
    "YPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
)
TINY_PNG_URL = "data:image/png;base64," + TINY_PNG_B64

DATA_URL_MIN = 1000        # 超过这个长度的 data:image 字符串才清理
RAW_B64_MIN = 50_000       # 超过这个长度的纯 base64 字符串视为图片
B64_RE = re.compile(r"[A-Za-z0-9+/=\r\n]+")
APPS = ["Codex", "ChatGPT"]
PROCS = ["Codex", "ChatGPT", "codex"]


def running():
    return [p for p in PROCS
            if subprocess.run(["pgrep", "-x", p], capture_output=True).returncode == 0]


def quit_apps():
    if not running():
        return
    print("正在退出 Codex / ChatGPT ...")
    for app in APPS:
        subprocess.run(["osascript", "-e", f'quit app "{app}"'], capture_output=True)
    for _ in range(20):
        if not running():
            return
        time.sleep(0.5)
    for p in running():
        subprocess.run(["pkill", "-x", p], capture_output=True)
    time.sleep(1)
    left = running()
    if left:
        sys.exit(f"无法退出进程 {left}，请手动关闭后重试。")


def scrub(obj, stats):
    """递归替换图片数据，返回新对象。"""
    if isinstance(obj, dict):
        return {k: scrub(v, stats) for k, v in obj.items()}
    if isinstance(obj, list):
        return [scrub(v, stats) for v in obj]
    if isinstance(obj, str):
        n = len(obj)
        if obj.startswith("data:image/") and n > DATA_URL_MIN:
            stats["images"] += 1
            return TINY_PNG_URL
        if n > RAW_B64_MIN and B64_RE.fullmatch(obj):
            stats["images"] += 1
            return TINY_PNG_B64
    return obj


def needs_parse(line):
    return "data:image/" in line or len(line) > RAW_B64_MIN


def utf8_len(s):
    return len(s.encode("utf-8", "surrogateescape"))


def clean_file(path, stats):
    st = path.stat()
    blanked0 = stats["blanked"]
    tmp = path.with_suffix(path.suffix + ".tmp")
    changed = False
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as src, \
         open(tmp, "w", encoding="utf-8", errors="surrogateescape") as dst:
        for line in src:
            if needs_parse(line):
                body = line.rstrip("\n")
                try:
                    data = json.loads(body)
                except json.JSONDecodeError:
                    dst.write(line)
                    continue
                n0 = stats["images"]
                new = scrub(data, stats)
                if stats["images"] != n0:
                    out = json.dumps(new, ensure_ascii=False, separators=(",", ":"))
                    pad = utf8_len(body) - utf8_len(out)
                    if pad < 0:
                        stats["images"] = n0
                        dst.write(line)
                        continue
                    changed = True
                    stats["blanked"] += pad
                    dst.write(out + " " * pad)
                    dst.write("\n" if line.endswith("\n") else "")
                    continue
            dst.write(line)
    if changed:
        os.replace(tmp, path)
        os.utime(path, (st.st_atime, st.st_mtime))
        stats["files"] += 1
        print(f"  {path.name}: 清掉 {(stats['blanked'] - blanked0)/1e6:.1f} MB 图片")
    else:
        tmp.unlink()


def main():
    dirs = [d for d in SCAN_DIRS if d.is_dir()]
    if not dirs:
        sys.exit(f"没找到会话目录：{CODEX_HOME}/sessions")
    quit_apps()
    stats = {"files": 0, "images": 0, "blanked": 0}
    files = [p for d in dirs for p in d.rglob("*.jsonl")]
    print(f"扫描 {len(files)} 个会话文件 ...")
    for p in files:
        try:
            clean_file(p, stats)
        except Exception as e:
            print(f"  跳过 {p.name}：{e}")
    print(f"\n完成：清理 {stats['images']} 张图片，涉及 {stats['files']} 个文件，"
          f"去掉 {stats['blanked']/1e6:.1f} MB 图片数据。")
    print("现在可以重新打开 Codex。")


if __name__ == "__main__":
    main()
