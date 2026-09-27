# Dogear 0.3.0

发布日期 / Release date: 2026-09-27

## 中文

- Ask 现在默认使用确定性的本地 BM25 检索，无需下载模型。
- 证据会在同一页、同一文本块内组合最多 3 个相邻句子，提供更完整的上下文，同时保持引用与高亮位置可追溯。
- 英文论文仍可选用本地“语义检索 — Small EN（实验性）”；模型由用户手动导入，Dogear 不会自动下载。
- 当 PDF 文本和分块规则未变化时，Dogear 会复用可重建的本地检索缓存，减少重复提取、分块和向量计算，且不会修改原始 PDF。

需要 macOS 14.0 或更高版本。云 AI 为可选功能，需自行配置兼容服务；当前发行包已使用开发者账户签名。

## English

- Ask now uses deterministic local BM25 retrieval by default and needs no model download.
- Evidence combines up to three adjacent sentences from the same page and text block for fuller context while keeping citations and highlight locations traceable.
- English papers can still use the optional local “Semantic — Small EN (Experimental)” mode; users import the model manually and Dogear never downloads it automatically.
- When PDF text and segmentation rules are unchanged, Dogear reuses rebuildable local retrieval caches to reduce repeated extraction, segmentation and vector calculation without modifying the original PDF.

Requires macOS 14.0 or later. Cloud AI is optional and requires a compatible service configuration. The current distribution package is signed with the developer account.
