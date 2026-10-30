#!/usr/bin/env python3
"""
修复旧版 clean_images.py 清理后 Codex 聊天记录打不开的问题。

原因：Codex 在 thread_history_1.sqlite 里按“字节位置”记录每轮对话在会话文件里的起止，
旧版清理把图片换小后文件变短，这些位置全部错位，Codex 就读不出历史。

修复：在被清理过的行末尾补空格（JSON 允许尾随空白），把每段长度补回数据库记录的值，
不删除、不改动数据库。

用法：python3 repair_history.py          # 修复（会先退出 Codex）
      python3 repair_history.py --dry   # 只检查不修改
"""
import os
import re
import sqlite3
import sys
from pathlib import Path

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
TINY = b"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk"
ORD_RE = re.compile(rb'"ordinal":(\d+)')


def anchors_for(h, tid):
    """数据库记录的 {行号: 该行起始的逻辑字节位置}。"""
    a = {}
    for o, b, eo, eb in h.execute(
            "select rollout_ordinal, rollout_byte_offset, rollout_end_ordinal,"
            " rollout_end_byte_offset from thread_turns where thread_id=?", (tid,)):
        if b is not None:
            a[o] = b
        if eo is not None and eb is not None:
            a[eo + 1] = eb
    row = h.execute("select next_rollout_ordinal, next_rollout_byte_offset"
                    " from thread_history_projection_state where thread_id=?", (tid,)).fetchone()
    if row:
        a[row[0]] = row[1]
    return a


def scan(path):
    """返回 [(行号, 起始位置, 是否被清理过)] 和文件大小。"""
    lines, pos = [], 0
    with open(path, "rb") as f:
        for line in f:
            m = ORD_RE.search(line[:300])
            if not m:
                return None, pos
            lines.append((int(m.group(1)), pos, TINY in line))
            pos += len(line)
    return lines, pos


def plan(lines, size, anchors):
    """算出每个被清理行要补多少空格。返回 {行号: 补的字节数}，对不上返回字符串原因。"""
    if not lines:
        return {}
    first, last = lines[0][0], lines[-1][0]
    starts = {o: p for o, p, _ in lines}
    starts[last + 1] = size
    pts = sorted((o, off) for o, off in anchors.items() if first <= o <= last + 1)
    if not pts:
        return {}
    cleaned = [o for o, _, c in lines if c]
    o0, off0 = pts[0]
    if any(c < o0 for c in cleaned):
        # 第一个锚点前有被清理的行：只有文件从第 0 行开始时才知道它的起点是 0
        if first != 0:
            return "第一个锚点前就有被清理的行"
        pts.insert(0, (0, 0))
        o0, off0 = 0, 0
    # 前面分段（已压缩的旧文件）的总长度
    base = off0 - starts[o0]
    pad, added = {}, 0
    for o, off in pts[1:]:
        deficit = (off - base) - (starts[o] + added)
        if deficit < 0:
            prev = max(p for p, _ in pts if p < o)
            if not any(prev <= c < o for c in cleaned):
                return "SKIP"
            return f"行 {o} 比记录还长"
        if deficit:
            prev = max(p for p, _ in pts if p < o)
            cand = [c for c in cleaned if prev <= c < o and c not in pad]
            if not cand:
                return f"行 {prev}-{o} 缺 {deficit} 字节但没有被清理的行"
            pad[cand[0]] = deficit
            added += deficit
    return pad


def apply(path, pad):
    st = path.stat()
    tmp = path.with_suffix(path.suffix + ".tmp")
    with open(path, "rb") as src, open(tmp, "wb") as dst:
        for line in src:
            m = ORD_RE.search(line[:300])
            n = pad.get(int(m.group(1))) if m else None
            if n:
                nl = line.endswith(b"\n")
                line = line.rstrip(b"\n") + b" " * n + (b"\n" if nl else b"")
            dst.write(line)
    os.replace(tmp, path)
    os.utime(path, (st.st_atime, st.st_mtime))


def main():
    dry = "--dry" in sys.argv
    if not dry:
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from clean_images import quit_apps
        quit_apps()
    s = sqlite3.connect(f"file:{CODEX_HOME/'state_5.sqlite'}?mode=ro", uri=True)
    h = sqlite3.connect(f"file:{CODEX_HOME/'thread_history_1.sqlite'}?mode=ro", uri=True)
    fixed = failed = 0
    for tid, rp, title in s.execute("select id, rollout_path, title from threads"):
        path = Path(rp)
        if not path.is_file():
            continue
        lines, size = scan(path)
        if lines is None or not any(c for _, _, c in lines):
            continue
        p = plan(lines, size, anchors_for(h, tid))
        name = (title or tid).splitlines()[0][:30] if title else tid
        if p == "SKIP":
            # 位置本来就对不上（不是清理造成的，Codex 自己的分段文件），不动
            continue
        if isinstance(p, str):
            failed += 1
            print(f"  无法修复 {name}：{p}")
            continue
        if not p:
            continue
        fixed += 1
        print(f"  {'将修复' if dry else '已修复'} {name}：补回 {sum(p.values())/1e6:.1f} MB")
        if not dry:
            apply(path, p)
    print(f"\n{'检查' if dry else '完成'}：{fixed} 个对话{'需要' if dry else '已'}修复，{failed} 个无法修复。")


if __name__ == "__main__":
    main()
