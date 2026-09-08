# Dogear 0.2.2

发布日期：2026-09-08
版本：0.2.2

## 中文

### 本版更新

- 统一 Ask 现在会基于按需读取的文档证据给出回答，并可在同一次请求中生成来源可追溯的可选高亮。
- 新增“允许高亮”控制。关闭时请求只生成文字回答；明确要求不标注时也会阻止写入批注。
- 每次发送都是独立问题，并提供分阶段进度和取消操作；同时兼容支持响应游标和无状态的 OpenAI Responses API 实现。
- 最终回答会针对本次读取的有限证据再进行一次核验；核验有助于发现缺少支持或相互矛盾的表述，但结果仍受 PDF 原生文本、检索范围和所选模型能力限制。
- 新增可选的实验性 BGE Small EN 本地语义检索。轻量词法检索仍为默认模式，模型需由用户手动准备和导入，应用不会自动下载。
- 修复适应宽度阅读时 PDF 滚动条与右侧边栏宽度调节区域冲突的问题。

AI Highlights 继续使用标准 PDF 批注并写入应用管理的工作副本；原始 PDF 不会在正常编辑中被覆盖。

### 使用要求

- 运行要求：macOS 14.0 或更高版本。
- 当前发行包已使用开发者账户签名。

## English

### What's new

- Unified Ask now returns an answer grounded in document evidence read on demand, with optional source-linked highlights from the same request.
- Added an Allow highlights control. Turn it off for a text-only answer; explicit no-annotation requests are also enforced.
- Each Send starts an independent question with staged progress and cancellation, across both response-cursor and stateless OpenAI Responses API implementations.
- A final review checks the proposed answer against the bounded evidence read for that request. It can catch unsupported or contradictory claims, but remains limited by native PDF text, retrieval coverage, and the selected model.
- Added optional experimental local semantic retrieval with BGE Small EN. Lightweight lexical retrieval remains the default; the model is prepared and imported manually, with no automatic model download by the app.
- Fixed a conflict between the PDF scrollbar and sidebar resizing while reading in Fit Width mode.

AI Highlights remain standard PDF annotations in the app-managed working copy; normal editing leaves the original PDF unchanged.

### Requirements

- Requires macOS 14.0 or later.
- The current distribution package is signed with the developer account.
