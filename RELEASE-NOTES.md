# Dogear 0.1.3

发布日期：2026-08-20
版本：0.1.3（Build 4）

## 中文

### 主要内容

- 补全 Library 管理：可重命名、归档/恢复和删除 Group，也可只移除 Library 记录而保留原始 PDF 与应用工作副本。
- 同一 Group 的多个窗口现在使用独立会话，临时打开文件和当前选择不会再互相覆盖。
- 修复文件与文件夹拖放的接收结果，提升导入流程的稳定性。
- 修复强制英文界面仍出现“未分组”“第 N 页”或中文菜单的问题；菜单重建时不再短暂闪回系统语言。
- 右侧栏的 Full Text、Dog-ears、Annotations、Document Summary 和 Ask About Selection 现在支持带动画的折叠/展开，并在空间不足时自动收起较早展开的区域。
- 隐藏尚未定稿的 Library Info 面板，并将 Ask About Selection 的 Send 按钮移到输入框下方。

### 发布工程

- 正式打包现在强制使用 Developer ID 签名，并在压缩前后验证签名；标签工作流只验证已标记源码，避免自动生成未签名发行包。

### 要求与限制

- 运行要求：macOS 14.0 或更高版本。
- 最终发行包将使用作者个人 Apple Developer 账号签名；签名状态以最终包验证结果为准。
- AI 功能默认关闭，需要用户自行配置 OpenAI-compatible 提供商；PDF 上传范围以应用中的确认流程为准。
- 本版本不包含 OCR、表单填写、PDF 数字签名、云同步、账户/订阅或完整 PDF 内容编辑。
- 发布验证包含源码扫描、Debug 构建、通用 Release 构建、应用元数据、签名和校验和检查；原生 UI、多窗口和 macOS 14 运行时仍需人工烟测。

## English

### Highlights

- Complete Library management with Group rename, archive/restore, and delete actions, plus removal of Library records without deleting original PDFs or app-managed working copies.
- Independent window sessions for the same Group, so temporary files and current selection no longer overwrite one another across windows.
- More reliable file and folder imports through corrected drop acceptance handling.
- Correct forced-English rendering for Ungrouped, default Dog-ear page names, and rebuilt application menus without brief system-language flashes.
- Animated expand/collapse behavior for Full Text, Dog-ears, Annotations, Document Summary, and Ask About Selection, with automatic space-aware collapse of older sections.
- The unfinished Library Info panel is hidden, and the Ask About Selection Send button now sits below the input field.

### Release engineering

- Official packaging now requires a Developer ID signature and verifies it before and after archiving; the tag workflow verifies tagged source without producing an unsigned distribution archive.

### Requirements and limitations

- Requires macOS 14.0 or later.
- The final distribution package will be signed with the author's personal Apple Developer account; the final status will follow package verification.
- AI is opt-in and requires a user-configured OpenAI-compatible provider.
- OCR, form filling, PDF digital signatures, cloud sync, accounts/subscriptions, and full PDF content editing are outside this MVP.
- Release verification covers source scans, Debug and universal Release builds, app metadata, signing, and checksums. Native UI, multi-window behavior, and macOS 14 runtime smoke testing remain manual gates.
