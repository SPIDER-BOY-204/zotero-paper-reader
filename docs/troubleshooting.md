# 踩过的坑（按症状查）

每一条都写清：症状 → 根因 → 处理。更新时把新坑加在最上面。

---

## 1. 点「中」生成中文版，永远卡在「正在安装翻译引擎」

**症状**：翻译按钮点下去，进度条一直停在安装，几分钟后报
`babeldoc 自动安装失败: The operation was aborted due to timeout`。

**根因**：插件用 Node 的 `fetch` 直连 `api.github.com` 下载 `uv`，
**不走系统代理**。国内直连 GitHub 会被重置/超时（3 次 × 30 秒）。

**处理**：绕开下载，直接把引擎装到插件写死的查找位
`~/.dsh-paper-reader/.venv-pdf2zh`：

```powershell
python -m venv "$env:USERPROFILE\.dsh-paper-reader\.venv-pdf2zh"
& "$env:USERPROFILE\.dsh-paper-reader\.venv-pdf2zh\Scripts\python.exe" -m pip install `
    -i https://pypi.tuna.tsinghua.edu.cn/simple "babeldoc==0.6.4" "bitstring<5"
```

注意两点：版本**必须** 0.6.4（插件实测过的），`bitstring` **必须** `<5`
（5.0 删了 `BitStream`，babeldoc 还在用，装出来是残缺环境）。

---

## 2. 引擎装好了，翻译报 `httpx.InvalidURL: Invalid port: ':1]'`

**症状**：`babeldoc/translator/translator.py` 里 `httpx.Client(...)` 抛异常，
整个翻译立刻失败。

**根因（在 DSH 源码里，不是你的锅）**：DSH 的代理策略写死了
`LOOPBACK_NO_PROXY = ["localhost", "127.0.0.1", "::1", "[::1]"]`，
注释说明 `[::1]` 是给 undici 的匹配器用的（它把裸 `::1` 读成 `host=":" port="1"`）。
于是 `NO_PROXY` 里同时有 `::1` 和 `[::1]`。

Python 的 httpx 把条目拼成匹配模式：`[::1]` → `all://[[::1]]` → 解析端口得到 `:1]` → 崩。
**没有配置项能关掉这个**，那个列表是硬编码的「bypass 不是可选项」。

**处理**：往 venv 的 site-packages 放 `sitecustomize.py`，解释器启动时先清环境变量：

```powershell
.\tools\apply-babeldoc-env-fix.ps1
```

效果：venv 里 `NO_PROXY` 变成 `...,127.0.0.1,::1`（去掉方括号那条），httpx 正常。

**为什么用 sitecustomize 而不是改 httpx 源码**：
升级 httpx 不会失效，升级 DSH 也不影响；只有整个 venv 被删除重建才需要重跑一次。

---

## 3. MinerU 配了却不生效（两套配置）

**症状**：聊天里 `read_pdf` 能用 MinerU，但阅读器里「∑ 公式」还是灰的；或者反过来。

**根因**：MinerU 有**两套独立配置**，服务两个地方：

| 配置位置 | 管谁 |
|---|---|
| `~/.dsh/.credentials.yaml` 的 `MINERU_API_KEY` + `cordis.patch.yml` 的 `mp_official` | 聊天的 `read_pdf` / `async_parse_pdf` |
| `~/.dsh/.dsh-paper-reader/mineru.json` | 阅读器解析与「∑ 公式」面板 |

注意第二个路径在 `~/.dsh/` **里面**（`DSH_HOME` 下），不是 `~/.dsh-paper-reader/`。
放错位置的表现就是「配了但没生效」。

**处理**：`bootstrap.ps1 -MineruToken sk-xxx` 会自动写第二处；第一处靠凭据文件。

---

## 4. 脚本报「禁止运行脚本」

**症状**：`无法加载文件 bootstrap.ps1，因为在此系统上禁止运行脚本`。

**处理**：

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -MineruToken "sk-xxx"
```

---

## 5. `.ps1` 在 Windows PowerShell 5.1 里满屏解析错误

**症状**：中文变乱码、`Unexpected token`、`字符串缺少终止符`。

**根因**：文件是**无 BOM 的 UTF-8**，5.1 按 ANSI 读，中文被拆坏，语法跟着崩。

**处理**：存成**带 BOM 的 UTF-8**。本仓库的 `.ps1` 已经是；自己改完记得别丢 BOM：

```powershell
$c = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($p, $c, (New-Object System.Text.UTF8Encoding($true)))
```

---

## 6. `paper_fulltext` 用不了

**症状**：`no pdf-to-markdown converter`。

**根因**：需要 `anydoc` 或 `markitdown` 之一，本机没有 npm/uv 装它。

**处理**：`pip install markitdown`（有了 uv 之后 `uv tool install markitdown` 也行）。

---

## 7. 视觉版 `pdf_read_page` 报找不到 pymupdf

**根因**：插件探测的是 **PATH 里的 python**，不认 DSH 自带运行时。

**处理**：`pip install pymupdf` 到 PATH 上那个 Python（`where python` 看是哪个）。

---

## 8. git 推不上去

**症状**：`Failed to connect to 127.0.0.1 port 7897`、`Recv failure: Connection was reset`、
或 `could not read Username`。

**根因**：三条完全不同的路，别混：

1. `Failed to connect ... port 7897` —— git 里写了代理，但那个端口没服务（代理软件换端口了）。
2. `Connection was reset` —— **没有**代理，git 直连 GitHub 被重置。
   **git 不读 Windows 系统代理**，浏览器能上不代表 git 能上。
3. `could not read Username` —— 网络通了，卡在认证。

**处理**：

- 情况 2 → 要么给 git 配代理，要么开代理软件的 **Tun 模式**（虚拟网卡，所有程序自动走，git 零配置）：
  ```powershell
  git config --global http.https://github.com.proxy http://127.0.0.1:12450
  ```
  端口写死，代理换端口时要跟着改 —— 所以更省心的是 Tun 模式。
- 情况 3 → GitHub 不能再用密码，用 Personal Access Token 当密码，或装 Git Credential Manager 走浏览器登录。

---

## 9. `read_image` 报 "does not declare image input"

**症状**：`pdf_read_page` 明明生成了 PNG，`read_image` 却说模型不支持图片。

**处理**：先分清两件事——**模型能不能看图**和**DSH 认为它能不能看图**。这两件事在不同层，
结论可以完全相反。

实测做法：拿同一张论文里的图（三面板示意图），直接对端点发 `image_url` 请求，
问它“几块并排、下方 epsilon 各是多少”，看它能不能答对。结果分三类：

| 表现 | 判定 | 说明 |
|---|---|---|
| 答对图里的内容 | ✅ 能看 | 多数对话/推理模型属于这类，别被名字骗了 |
| `400 Received multimodal data` | ❌ 明确不能看 | 端点自己声明的上限 |
| 请求成功但 `content` 空、`finish_reason: stop` | ⚠️ 判不了 | 保守当纯文本；同类模型往往拒绝多模态 |

**报错的真正来源是 DSH 的能力声明**（`llm.resolveModelInfo(...).inputModalities`）：
provider 配置里该模型的 `input` 没写 `image` 时，工具会在**发出请求之前**就拒掉，
请求根本没到模型。所以「报这个错」不等于「模型看不见」。

修法是给该模型补上 `input`（自定义路由的完整目录用 `tools/fill_llm_models.py` 生成，
型号和端点放在不入库的 `llm-catalog.local.json`）：

```yaml
- id: llm-pi-ai
  config:
    providers:
      myprovider:
        models:
          - id: some-chat-model
            input: [text, image]     # ← 关键
```

改完**重启 DSH 或刷新页面**才生效（能力信息是会话建立时解析的）。

**三个陷阱**：

- 别按“API 能收图”就断定 DSH 能发图，反过来也一样——两个判断来自不同层。
- `max_tokens` 给小了会得到 `content: null`（推理模型把 token 全花在 reasoning 上），
  看起来像“没看图”，其实它读了。排查时先看 `finish_reason` 和 `usage`。
- 生图模型（`mode: image_generation`）不要放进聊天路由，它只会让人误点。

**顺带一个判据**：`pdf_scan` 的 `rasterImages` 非空 = 图是位图，文本层里读不到内容，
必须走视觉；`hasTextLayer: true` 只说明**正文**能读，不代表图能读。

