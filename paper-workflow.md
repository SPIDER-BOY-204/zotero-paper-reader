# 读一篇论文的完整流程（六插件协作）

先建立一个心智模型：**三个入口，一件事**。

| 入口 | 在哪 | 适合 |
|---|---|---|
| 阅读器界面 | 侧栏「📚 论文伴读」 | 真的要“读”：划词、看页码、做笔记、看中文版 |
| 聊天 | 就是现在这个对话 | 让 Agent 帮你检索、比对、读图表、写综述 |
| Zotero | 你原来的文献库 | 收集与元数据；PDF 由脚本镜像进论文库 |

下面按“找 → 入库 → 读 → 啃硬骨头 → 看图 → 比 → 产出”七步走。

---

## 阶段 1 · 找文献（`dsh-paper-search`）

比通用搜索准得多，因为打的是 arXiv / OpenAlex / Crossref / Semantic Scholar 的官方接口。

```
paper_search("graph neural network protein", sources="arxiv,openalex,semantic", min_sitasi=50, urutkan="sitasi")
```

三个常用玩法：

- **按影响力筛**：`min_sitasi=50` 把经典文献顶上来；`urutkan="terbaru"` 看最新进展。
- **滚雪球**：找到一篇关键论文后，用 `paper_citations` 看谁引用了它（`arah="pengutip"`）或它引用了谁（`arah="rujukan"`）。比关键词搜索更容易找到真正的源头。
- **要免费全文**：`paper_oa` 给 DOI 查有没有合法开放版本；`paper_fulltext` 能把 OA 的 PDF 抓下来转 Markdown 读全文（**注意：这台机器还没装转换器，见文末坑 6**）。

看到想要的，就加进 Zotero（浏览器插件一键保存最快）。

## 阶段 2 · 入库（同步脚本）

```powershell
python D:\workspace\zotero-sync\zotero_sync.py
```

- Zotero 的集合 → 论文库的“专题”，父子层级压平成 `父-子`
- PDF 用**硬链接**放进 `~/.dsh-paper-reader/data/<专题>/`，不占额外空间，Zotero 原目录不动
- 可重复执行：已有的跳过，新加的补进去
- 硬链接的副作用：你在阅读器里给论文加笔记/转录，产物（`.txt` `.notes.json` `.study.json`）写在论文库那边，不会污染 Zotero

不想用 Zotero 也行：直接把 PDF 丢进 `~/.dsh-paper-reader/data/<专题>/` 即可。

## 阶段 3 · 首读（`dsh-paper-reader`）

侧栏点「📚 论文伴读」→ 选专题 → 点论文。然后：

1. **选一段字** → 弹出「选中即问」→ 提问。回答里每个页码都是可点的，点了跳回原文并高亮。
2. **想找某句话**：`Ctrl+F`，防抖搜索、支持跨行断词（`dis-tributed` 也能中）。
3. **做笔记**：选中 → 气泡里点「笔记」，文字下方出现蓝色波浪线；顶栏「笔记」看全部、按页排序。
4. **中文版**：顶栏「中」→ 生成 `-zh.pdf` / `-dual.pdf`（首次要装 babeldoc + 填翻译端点，几分钟）。之后可切「对照」或「分屏」，两列同步滚动。
5. **教练式带读**（可选）：会话的 preset 选「论文伴读」，它会出 3–6 步计划、提问、检查你的回答，答好才推进。学习档案存在 `<论文>.study.json`，跨会话累积。

聊天侧等价操作（不用开界面）：

```
transcribe_pdf(topic="火灾疏散文献", name="某篇论文")   # 转录，带页码索引
search_paper(topic=..., name=..., query="locality")     # 按页返回片段
```

## 阶段 4 · 啃硬骨头：扫描件与公式（MinerU）

**这里有个最容易搞混的点：MinerU 有两套配置，服务两个地方。**

| 配置在哪 | 管谁 | 现状 |
|---|---|---|
| 凭据 `MINERU_API_KEY` + `cordis.patch.yml` 的 `mp_official` | 聊天的 `read_pdf` / `async_parse_pdf` | ✅ 已配好 |
| `~/.dsh/.dsh-paper-reader/mineru.json` | 阅读器里的解析与「∑ 公式」面板 | ✅ 已配好 |

什么时候需要它：

- **扫描版 PDF**（没有文本层）——pdf.js 读不出字，必须 OCR
- **要引用公式**——公式在文本层里是乱码，MinerU 识别成 LaTeX 后可以点、可以搜

注意两条规则：

- 已经转录过的论文**不会自动重录**。要公式可搜，得在「∑ 公式」面板对那篇显式点一次「用 MinerU 重新转录」。
- `paper_fulltext` 和 deepread 都**不做 OCR**，扫描件必须先过 MinerU。

## 阶段 5 · 看图：架构图、流程图、复杂表格（`dsh-pdf-reader` 视觉版）

正文走文本、图走渲染，避免整页压成 800×800 把图例压糊。

```
pdf_scan(pdf_path="...")                      # 先看每页有什么：分栏、图区、表格、公式风险
pdf_read_page(pdf_path="...", page=3, mode="mixed")
      # 一次拿到：整页低清预览 + 该页文本 + 每个图/表区域的高清 PNG（给出路径，不进上下文）
pdf_render_region(pdf_path="...", page=3, region=[72,120,500,380], dpi=200)
      # 某个公式/表格角落还是看不清，按 bbox 精确放大
```

得到的 PNG 直接在会话里读出来看（支持图片的模型才能看）。

## 阶段 6 · 深读与对比（`dsh-deepread`）

五种模式，按需要选：

| 场景 | 模式 |
|---|---|
| 只想快速抓要点 | `quick` |
| 要论证结构、证据、置信度四档 | `deep` |
| 要知识地图（观点—证据—数据—关系） | `map` |
| 想被追问着学（费曼） | `feynman` |
| 整本书 | `book` |

大文件先预算预检，不烧钱：

```
deepread(path="...", depth="deep", estimate=true)     # 只估算，不调模型
deepread(path="...", depth="map")
deepread(batch=[{path:"a.pdf"},{path:"b.pdf"}])       # 2–10 篇跨篇对比
```

产出可导出 `md` / `mm`（FreeMind，XMind 可导入）/ `html`。

**它不做 OCR**：扫描件先过阶段 4。

## 阶段 7 · 产出

- 阅读器里的笔记 → `<论文>.notes.json`，跟着论文走，换机器也带着
- deepread 报告 → 导出 Markdown 后放进你的综述草稿
- 想把结论写进论文：把 deepread 的“证据 + 页码”直接当引文锚点，比凭记忆引用可靠

---

## 一页决策表

| 我遇到的情况 | 用哪个 |
|---|---|
| 想找某方向的论文 | `paper_search` |
| 找到一篇关键论文，想顺藤摸瓜 | `paper_citations` |
| 想知道有没有免费全文 | `paper_oa` → `paper_fulltext`（需 anydoc） |
| 正常文字版 PDF，读+提问 | 侧栏「论文伴读」 |
| 扫描件、老论文、书章 | MinerU（两套配置都已就绪） |
| 公式要能点、能搜 | MinerU（同上） |
| “这张图画了什么” | 视觉版 `pdf_scan` → `pdf_read_page` |
| 要写综述、比 5 篇以上 | `deepread` + `batch` |
| 只要一句话的答案 | 直接问，别动用重武器 |

## 七个坑（都踩过）

1. **两套 MinerU 配置**——聊天能用不代表阅读器里能用，反之亦然。
2. **旧论文不会自动重录**——想要公式引用，得手动重录一次。
3. **扫描件喂给 deepread 等于喂空**——先 OCR。
4. **视觉版只认 PATH 里的 Python**——DSH 自带的 3.12 不算；`pip install pymupdf` 到系统 Python 才算数。
5. **`web_search` 曾经接管失败**——热加载时插件抢不到 provider，重启一次就好。
6. **`paper_fulltext` 缺转换器**——需要 `npm i -g @firecrawl/anydoc` 或 `uv tool install markitdown`；本机没 npm。
7. **翻译端点要单独填**——中文版和划词翻译共用一份，存在插件设置里（不是凭据文件），换机器要重填。

## 一次真实的最小闭环

```
1. paper_search("meta reinforcement learning", urutkan="sitasi")     → 找到综述
2. Zotero 里加进去（或直接丢 data/火灾疏散文献/）
3. python zotero_sync.py                                              → 进库
4. 侧栏打开 → 选字问「MAML 和 RL2 的区别」→ 点页码回原文核对
5. search_paper(query="meta-learning algorithm")                      → 第 7 页命中 MAML 定义
6. deepread(depth="map") → 导出 md，粘进综述草稿
```

这套流程里，唯一会持续花钱的是 MinerU 按页计费，其余都是你本来就在用的模型 token。
