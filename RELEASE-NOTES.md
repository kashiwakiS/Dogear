# Dogear 0.1.2

发布日期：2026-08-19  
版本：0.1.2（Build 3）

## 中文

### 主要内容

- 完成 macOS 原生 PDF 阅读工作流：PDFKit 阅读、页面导航、缩放和多种阅读布局。
- 支持标准 PDF 高亮、FreeText 备注、批注搜索、批注导航和 Markdown 导出。
- 提供本地资料库、群组、原生标签页预览、工作副本和安全的页面整理/导出流程。
- 增加 Dog-ear 页面标记、文档大纲导航、夜间显示和安静链接展示。
- 提供英文和简体中文界面，以及可选的 OpenAI-compatible 阅读助手；未配置 AI 时仍可使用确定性本地功能。
- 修复发布构建输出位置：默认应用位于 `build/Debug/Dogear.app` 或 `build/Release/Dogear.app`，中间文件位于 `build/DerivedData/`。
- 发布流程现在生成通用 `x86_64`/`arm64` 应用包、源码包和 SHA-256 校验文件。

### 要求与限制

- 运行要求：macOS 14.0 或更高版本。
- 应用包为未签名、未公证构建；首次打开时可能需要在 macOS 中确认。
- AI 功能默认关闭，需要用户自行配置 OpenAI-compatible 提供商；PDF 上传范围以应用中的确认流程为准。
- 本版本不包含 OCR、表单填写、签名、云同步、账户/订阅或完整 PDF 内容编辑。
- 发布验证包含源码扫描、Debug 构建、通用 Release 构建、应用元数据和校验和检查；原生 UI、多窗口和 macOS 14 运行时仍需人工烟测。

## English

### Highlights

- Native macOS PDF reading with PDFKit, page navigation, zoom, and multiple reading layouts.
- Standard PDF highlights, FreeText notes, annotation search/navigation, and Markdown export.
- Local Library and Groups, native tab previews, app-managed working copies, and safe page organization/export flows.
- Dog-ear page markers, document-outline navigation, night display, and quiet link presentation.
- English and Simplified Chinese interfaces, plus an optional OpenAI-compatible reading assistant with deterministic local behavior when no provider is configured.
- Predictable build output: `build/Debug/Dogear.app` and `build/Release/Dogear.app`; intermediate files live under `build/DerivedData/`.
- Universal `x86_64`/`arm64` application archive, source archive, and SHA-256 checksums.

### Requirements and limitations

- Requires macOS 14.0 or later.
- The distributed app is unsigned and not notarized; macOS may require confirmation on first launch.
- AI is opt-in and requires a user-configured OpenAI-compatible provider.
- OCR, form filling, signatures, cloud sync, accounts/subscriptions, and full PDF content editing are outside this MVP.
- Release verification covers source scans, Debug and universal Release builds, app metadata, and checksums. Native UI, multi-window behavior, and macOS 14 runtime smoke testing remain manual gates.
