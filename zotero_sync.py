#!/usr/bin/env python3
"""把 Zotero 文献库里的 PDF 同步成 dsh-paper-reader 的文献库结构。

Zotero 结构：  <zotero>/storage/<附件itemKey>/<文件名>.pdf
paper-reader： <dest>/<专题名>/<文件名>.pdf

默认用硬链接（同盘时不占额外空间，Zotero 原文件保持不动），跨盘自动退回复制。
台账文件 <dest>/.zotero-sync.json 记录每条映射，重复跑只补新增/变更。

用法：
    python zotero_sync.py --dry-run
    python zotero_sync.py
    python zotero_sync.py --dest "D:/papers" --copy
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime
from pathlib import Path

DEFAULT_ZOTERO = Path(os.environ.get("USERPROFILE", "~")) / "Zotero"
DEFAULT_DEST = Path(os.environ.get("USERPROFILE", "~")) / ".dsh-paper-reader" / "data"
UNCATEGORIZED = "_未分类"

INVALID = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
# Zotero 里这类“标题”毫无信息量，宁可用文件名
JUNK = {"pdf", "所有文件", "论文", "untitled", "document", "latest", "full text pdf", "paper", "新论文"}


def pick_name(title: str | None, stem: str) -> str:
    """在 Zotero 标题与 PDF 文件名之间挑更有信息量的那个。"""
    cands = [c.strip() for c in (title or "", stem) if c and c.strip()]
    useful = [c for c in cands if c.lower() not in JUNK and len(c) > 3]
    if useful:
        return max(useful, key=len)
    return cands[0] if cands else "untitled"


def sanitize(name: str, limit: int = 120) -> str:
    name = INVALID.sub("_", name).strip().rstrip(".")
    name = re.sub(r"\s+", " ", name)
    return (name[:limit] or "untitled").strip()


def snapshot(db: Path, tmpdir: Path) -> Path:
    """复制一份 zotero.sqlite（含 WAL），避免和正在运行的 Zotero 抢锁。"""
    dst = tmpdir / "zotero.sqlite"
    for suffix in ("", "-wal", "-shm"):
        src = Path(str(db) + suffix)
        if src.exists():
            shutil.copy2(src, Path(str(dst) + suffix))
    return dst


def load_rows(db_copy: Path):
    con = sqlite3.connect(str(db_copy))
    con.row_factory = sqlite3.Row
    cur = con.cursor()

    # 专题（集合）名，取叶子名；重名用父级前缀区分
    cur.execute("SELECT collectionID, collectionName, parentCollectionID FROM collections")
    cols = {r["collectionID"]: r for r in cur.fetchall()}

    def topic_of(cid: int) -> str:
        row = cols.get(cid)
        if not row:
            return UNCATEGORIZED
        name = sanitize(row["collectionName"])
        seen = set()
        pid = row["parentCollectionID"]
        while pid and pid in cols and pid not in seen:
            seen.add(pid)
            parent = sanitize(cols[pid]["collectionName"])
            if parent and parent != name:
                name = f"{parent}-{name}"
            pid = cols[pid]["parentCollectionID"]
        return name

    cur.execute(
        """
        SELECT ci.collectionID, ci.itemID
        FROM collectionItems ci
        """
    )
    item_collections: dict[int, list[int]] = {}
    for r in cur.fetchall():
        item_collections.setdefault(r["itemID"], []).append(r["collectionID"])

    # 标题
    cur.execute(
        """
        SELECT d.itemID AS itemID, v.value AS title
        FROM itemData d
        JOIN fields f ON f.fieldID = d.fieldID AND f.fieldName = 'title'
        JOIN itemDataValues v ON v.valueID = d.valueID
        """
    )
    titles = {r["itemID"]: r["title"] for r in cur.fetchall()}

    # PDF 附件：path 形如 storage:xxx.pdf 或绝对路径
    cur.execute(
        """
        SELECT a.itemID AS attID, a.parentItemID AS parentID, a.path AS path,
               i.key AS attKey
        FROM itemAttachments a
        JOIN items i ON i.itemID = a.itemID
        WHERE a.contentType = 'application/pdf'
        """
    )
    rows = cur.fetchall()
    con.close()
    return rows, titles, item_collections, topic_of


def build_plan(rows, titles, item_collections, topic_of, zotero_root: Path):
    plan = []
    for r in rows:
        raw = r["path"] or ""
        if raw.startswith("storage:"):
            fname = raw[len("storage:"):]
            src = zotero_root / "storage" / r["attKey"] / fname
        elif raw:
            src = Path(raw)
        else:
            continue
        if not src.exists():
            continue

        parent = r["parentID"]
        title = titles.get(parent) or titles.get(r["attID"])
        name = pick_name(title, src.stem)
        topics = [topic_of(c) for c in item_collections.get(parent, [])]
        if not topics:
            topics = [UNCATEGORIZED]

        plan.append(
            {
                "src": str(src),
                "topics": topics,
                "title": sanitize(name),
                "key": r["attKey"],
                "size": src.stat().st_size,
            }
        )
    return plan


def link_or_copy(src: Path, dst: Path, force_copy: bool) -> str:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst.unlink()
    if not force_copy:
        try:
            if src.stat().st_dev == dst.parent.stat().st_dev:
                os.link(src, dst)
                return "hardlink"
        except OSError:
            pass
    shutil.copy2(src, dst)
    return "copy"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zotero", default=str(DEFAULT_ZOTERO), help="Zotero 数据目录（含 zotero.sqlite）")
    ap.add_argument("--dest", default=str(DEFAULT_DEST), help="paper-reader 文献库目录")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--copy", action="store_true", help="强制复制而不建硬链接")
    ap.add_argument("--report", default="", help="把清单写成 Markdown")
    args = ap.parse_args()

    zotero_root = Path(args.zotero)
    dest = Path(args.dest)
    db = zotero_root / "zotero.sqlite"
    if not db.exists():
        print(f"[x] 找不到 {db}")
        return 2

    with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as td:
        copy = snapshot(db, Path(td))
        rows, titles, item_collections, topic_of = load_rows(copy)

    plan = build_plan(rows, titles, item_collections, topic_of, zotero_root)
    print(f"Zotero: {zotero_root}")
    print(f"目标库: {dest}")
    print(f"可同步 PDF: {len(plan)}")

    created = skipped = failed = 0
    results = []
    claimed: dict[Path, str] = {}
    for p in plan:
        src = Path(p["src"])
        for topic in p["topics"]:
            topic_dir = dest / sanitize(topic)
            name = p["title"] + ".pdf"
            target = topic_dir / name
            if target in claimed and claimed[target] != str(src):
                # 同专题里两篇不同文献标题撞了：用附件 key 前 8 位区分，避免互相覆盖
                name = f"{p['title']} ({p['key'][:8]}).pdf"
                target = topic_dir / name
            claimed[target] = str(src)
            if target.exists() and target.stat().st_size == p["size"]:
                skipped += 1
                results.append((topic, name, "skip"))
                continue
            if args.dry_run:
                created += 1
                results.append((topic, name, "plan"))
                continue
            try:
                how = link_or_copy(src, target, args.copy)
                created += 1
                results.append((topic, name, how))
            except Exception as exc:  # noqa: BLE001
                failed += 1
                results.append((topic, name, f"FAIL {exc}"))

    topics = sorted({t for t, _, _ in results})
    print(f"专题 {len(topics)} 个：{', '.join(topics) if len(topics) <= 15 else ', '.join(topics[:15]) + ' …'}")
    print(f"新建 {created} · 跳过 {skipped} · 失败 {failed}" + ("（演练模式，未落盘）" if args.dry_run else ""))

    if args.report:
        lines = [f"# Zotero → paper-reader 同步清单", "", f"- 时间：{datetime.now():%Y-%m-%d %H:%M}", f"- 源：`{zotero_root}`", f"- 目标：`{dest}`", "", "| 专题 | 文件名 | 动作 |", "| --- | --- | --- |"]
        lines += [f"| {t} | {n} | {a} |" for t, n, a in sorted(results)]
        Path(args.report).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"清单写入 {args.report}")

    if not args.dry_run:
        ledger = dest / ".zotero-sync.json"
        ledger.parent.mkdir(parents=True, exist_ok=True)
        ledger.write_text(
            json.dumps({"syncedAt": datetime.now().isoformat(timespec="seconds"), "items": len(plan)}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
