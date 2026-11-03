# DSH 论文阅读环境 · 一键配置

把「六个插件 + 配置 + MinerU 后端」在任意一台 Windows 机器上重建出来。
配合 `paper-workflow.md`（读论文的完整流程）使用。

## 它装什么

| 包 | 作用 |
|---|---|
| `@ggboy123/dsh-paper-reader` | 论文伴读工作台（阅读器 UI、页码、划词、笔记、中文版） |
| `dsh-pdf-mineru` | 给 Agent 用的 MinerU 解析（公式/表格/扫描件、原页核对） |
| `dsh-paper-search` | 23 个学术源的免费检索（arXiv/OpenAlex/Crossref/S2/PubMed…） |
| `dsh-free-search` | 免 key 网页搜索 + 抓取（Bing/DuckDuckGo/SearXNG） |
| `dsh-deepread` | 证据化精读与多篇对比（五模式） |
| `dsh-pdf-reader` | 内容感知视觉版：图表区域高清渲染（需 Python + pymupdf） |

## 用法

```powershell
# 1. 复制这个文件夹到新机器
# 2. 首次配置（会装插件、写配置、问你要 MinerU token）
.\bootstrap.ps1 -MineruToken "sk-你的token"

# 已经有配置，只想检查
.\bootstrap.ps1 -VerifyOnly

# 装到别的 profile（Linux/web 宿主常用 web）
.\bootstrap.ps1 -Profile web
```

脚本可重复运行：已经装过的包会跳过，配置块已存在不会重复追加。

## 它不改什么

- **不碰** `~/.dsh/.credentials.yaml` 以外的密钥文件；token 只写进
  `~/.dsh/.dsh-paper-reader/mineru.json` 和凭据服务（0600 语义）——**不要把这个文件夹提交到公开仓库时带上 token**。
- **不碰** 论文库（`~/.dsh-paper-reader/data`），那是你的数据，单独备份/同步。

## 换机器还差什么

1. **论文库**：把 `~/.dsh-paper-reader/data` 整个拷过去（笔记、学习档案、转录缓存都在里面）。
2. **凭据**：`~/.dsh/.credentials.yaml` 里的 `MINERU_API_KEY` 和 LLM 网关的 key（环境变量名见
   配置里的 `apiKeyEnv`），拷过去或重填。
3. **翻译/嵌入端点**：在论文伴读的设置面板里重填一次（不是文件，存在插件设置里）。
4. **Python**（视觉版需要）：任何 3.9+ 的 Python，`pip install pymupdf`，且必须在 PATH 上——
   插件只探测 PATH 里的 `python`，不认 DSH 自带的 3.12。
5. **翻译引擎**（点「中」会用到）：插件自带的安装流程要连 GitHub，国内常超时。
   直接跑 `tools\install-babeldoc.ps1` 绕开它，再跑 `tools\apply-babeldoc-env-fix.ps1`。
6. **LLM 模型目录**（可选）：`llm-catalog.local.json` 不在仓库里（内含校内端点和型号清单），
   从 `llm-catalog.example.json` 复制一份填好，再跑 `python tools\fill_llm_models.py`。
7. **git 钩子**：`tools\install-git-hooks.ps1` 装一下，防止以后把密钥提交进来。

## 文件

```
bootstrap.ps1                     # 主脚本
cordis.patch.snippet.yml          # 追加到 profile cordis.patch.yml 的配置块（脚本会自动合并）
paper-workflow.md                 # 读论文的完整流程
zotero_sync.py                    # Zotero → 论文库的镜像脚本
llm-catalog.example.json          # LLM 路由目录模板（真实值放 llm-catalog.local.json，不入库）
docs/troubleshooting.md           # 踩过的坑：症状 → 根因 → 处理
tools/install-babeldoc.ps1        # 装翻译引擎（绕开 GitHub 下载）
tools/apply-babeldoc-env-fix.ps1  # 修 NO_PROXY 里 [::1] 让 httpx 崩溃的问题
tools/sitecustomize.py            # 上面那个修复的实际内容
tools/fill_llm_models.py          # 按目录 JSON 生成模型配置（含图片能力声明）
tools/install-git-hooks.ps1       # 装 pre-commit 密钥拦截钩子
tools/git-hooks/pre-commit        # 钩子本体
```

## 这个仓库能公开吗

能，里面**没有任何真实密钥**：token 一律走命令行参数或凭据文件，文档里出现的 `sk-xxx` 全是占位符。
提交前还有一道 `pre-commit` 钩子拦明文密钥（`sk-…`、`ghp_…`、私钥块、JWT 等）。

不入库的东西：`llm-catalog.local.json`（校内端点+型号）、`mineru.json`、`.credentials.yaml`。
公开之后 GitHub 的 secret scanning 会免费帮你盯住新提交；但**历史不会重写**——
万一哪天误提交了真密钥，光删文件没用，必须去平台上换掉（rotate）。

## 遇到问题先查

[docs/troubleshooting.md](docs/troubleshooting.md) —— 每条都是真踩过的，带症状关键词，方便 Ctrl+F。

## 关于执行策略

Windows PowerShell 默认禁止运行 .ps1。首次跑如果被拦：

```powershell
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1 -MineruToken "sk-xxx"
```

脚本存成了带 BOM 的 UTF-8 —— 不带 BOM 的话 Windows PowerShell 5.1 会把中文读成乱码并解析失败。
