"""启动时清理 NO_PROXY 里的方括号 IPv6 条目。

背景：DSH 的代理策略（app.asar 里 `LOOPBACK_NO_PROXY`）固定写入
    localhost,127.0.0.1,::1,[::1]
其中 `[::1]` 是给 undici 的匹配器用的（它把裸 `::1` 读成 host=":" port="1"）。
但 Python 的 httpx 会把这个条目拼成 `all://[[::1]]`，解析端口得到 ":1]"，
直接抛 httpx.InvalidURL —— babeldoc 一构造 HTTP 客户端就崩。

这里在解释器启动、任何库 import 之前把条目去掉，对整个 venv 生效，
不依赖具体版本的 httpx。venv 被完全重建时才会丢失。
"""

import os

_BAD_PREFIX = "["


def _clean(value: str) -> str:
    parts = [p.strip() for p in value.split(",")]
    kept = [p for p in parts if p and not p.startswith(_BAD_PREFIX)]
    return ",".join(kept)


for _name in ("NO_PROXY", "no_proxy"):
    _value = os.environ.get(_name)
    if _value and _BAD_PREFIX in _value:
        os.environ[_name] = _clean(_value)
