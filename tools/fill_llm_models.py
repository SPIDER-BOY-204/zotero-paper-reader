#!/usr/bin/env python3
"""按 JSON 目录把自定义 LLM 路由写进 DSH 的 cordis.patch.yml。

为什么不把端点和型号写死在脚本里：这个仓库是公开的，学校的网关地址和型号清单
属于内部信息。真实值放在 llm-catalog.local.json（已被 .gitignore 排除），
仓库里只留 llm-catalog.example.json 这份占位模板。

用法：
    python tools/fill_llm_models.py --dry-run      # 只打印会写什么
    python tools/fill_llm_models.py                # 写入（自动备份 .bak-时间戳）
    python tools/fill_llm_models.py --catalog 路径 --patch 路径

目录 JSON 里 input 的 image 表示"允许 DSH 把图片发给它"。只声明上游真能处理的类型。
"""

from __future__ import annotations

import argparse
import io
import os
import re
import shutil
import sys
import time

BLOCK_HEAD = "- id: llm-pi-ai"


def render(cat: dict) -> str:
    """把目录 JSON 渲染成 cordis.patch.yml 里的一个 patch 条目。"""
    provider = cat["provider"]
    L = [
        BLOCK_HEAD,
        '  name: "@deepseek-ai/dsh-llm-pi-ai"',
        "  config:",
        "    providers:",
        f"      {provider}:",
        f"        displayName: {cat.get('displayName', provider)}",
        f"        apiKeyEnv: {cat['apiKeyEnv']}",
        f"        api: {cat.get('api', 'openai-completions')}",
        f"        baseURL: {cat['baseURL']}",
        "        # 由 tools/fill_llm_models.py 从本地目录生成，别手改这里",
        "        models:",
    ]
    for m in cat["models"]:
        L.append(f"          - id: {m['id']}")
        if m.get("name"):
            L.append(f"            name: {m['name']}")
        L.append("            input: [%s]" % ", ".join(m.get("input", ["text"])))
        if m.get("contextWindow"):
            L.append(f"            contextWindow: {int(m['contextWindow'])}")
        eff = m.get("reasoningEfforts")
        if isinstance(eff, dict) and eff:
            L.append("            reasoningEfforts:")
            for k, v in eff.items():
                L.append(f"              {k}: {v}" if v else f"              {k}:")
        elif eff is False:
            L.append("            reasoningEfforts: false")
    return "\n".join(L) + "\n"


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default="")
    ap.add_argument(
        "--patch",
        default=os.path.expanduser(r"~/.dsh/profiles/desktop/cordis.patch.yml"),
    )
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    cat_path = a.catalog
    if not cat_path:
        local = os.path.join(root, "llm-catalog.local.json")
        cat_path = local if os.path.exists(local) else os.path.join(root, "llm-catalog.example.json")
    if not os.path.exists(cat_path):
        print(f"找不到目录文件：{cat_path}", file=sys.stderr)
        return 2
    if "example" in os.path.basename(cat_path) and not a.dry_run:
        print("这是占位模板，写进去没意义。复制成 llm-catalog.local.json 再填真实值。", file=sys.stderr)
        return 2

    import json

    cat = json.load(io.open(cat_path, encoding="utf-8"))
    block = render(cat)
    print(f"目录：{cat_path}\n路由：{cat['provider']}  模型：{len(cat['models'])} 个\n")

    if a.dry_run:
        print(block)
        return 0

    if not os.path.exists(a.patch):
        print(f"配置文件不存在：{a.patch}", file=sys.stderr)
        return 2

    src = io.open(a.patch, encoding="utf-8").read()
    pat = re.compile(
        r"(?m)^" + re.escape(BLOCK_HEAD) + r"\b.*?(?=^- (?!id: llm-pi-ai)|\Z)", re.S
    )
    m = pat.search(src)
    if not m:
        print("配置文件里没有 llm-pi-ai 块，不敢乱插，请手工加。", file=sys.stderr)
        return 2

    backup = a.patch + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
    shutil.copyfile(a.patch, backup)
    out = (src[: m.start()] + block + src[m.end():]).rstrip("\n") + "\n"
    io.open(a.patch, "w", encoding="utf-8", newline="\n").write(out)
    print(f"备份：{backup}\n已写入：{a.patch}")

    try:
        import yaml
    except ImportError:
        print("（没装 pyyaml，跳过结构校验）")
        return 0
    doc = yaml.safe_load(io.open(a.patch, encoding="utf-8"))
    entry = [e for e in doc if isinstance(e, dict) and e.get("id") == "llm-pi-ai"]
    if not entry:
        print("！写入后解析不到 llm-pi-ai，请从备份回滚", file=sys.stderr)
        return 1
    models = entry[0]["config"]["providers"][cat["provider"]]["models"]
    print(f"校验通过：{len(models)} 个模型，顶层条目 {len(doc)} 个")
    for mm in models:
        print("   ", mm["id"], mm.get("input"), mm.get("contextWindow"))
    print("\n生效要完全退出 DSH 再打开。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
