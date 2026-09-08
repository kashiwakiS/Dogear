# Dogear

[![Build](https://github.com/kashiwakiS/Dogear/actions/workflows/build.yml/badge.svg)](https://github.com/kashiwakiS/Dogear/actions/workflows/build.yml)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black.svg)](#requirements)

由PDF文件管理的痛点出发自建的PDF阅读管理工具 Dogear

特色：

- 原生PDFKit实现阅读功能
- PDF文件分组管理、页面整理功能
- 便捷的键盘交互
- 可选的统一 Ask：基于文档证据回答，并按需生成来源可追溯的 AI Highlights
- 可按请求分组显示、导航和导出 AI 批注
- 在页面右侧展示批注说明的 Margin Canvas

<p align="center">
  <img
    src="assets/screenshots/dogear-ai-highlights-hd.png"
    alt="Dogear 的 AI Highlights、Margin Canvas 与统一 Ask 侧边栏"
    width="100%"
  >
</p>

<p align="center">
  <sub>按请求分组的 AI Highlights、来源对应的页边说明与统一 Ask 工作流。</sub>
</p>

<p align="center">
  <img
    src="assets/screenshots/dogear-reading-workflow-hd.png"
    alt="Dogear 的 PDF 阅读工作区，显示文档位置导航与 Dog-ear"
    width="100%"
  >
</p>

<p align="center">
  <sub>文档位置导航、Dog-ear 与专注的 PDF 阅读工作区。</sub>
</p>

## 阅读体验

<p align="center">
  <img
    src="assets/screenshots/dogear-night-reading-hd.png"
    alt="Dogear 夜间阅读模式，显示全文搜索与文档导航"
    width="100%"
  >
</p>

<p align="center">
  <sub>夜间阅读、全文搜索与文档导航。</sub>
</p>

## 安装

你可以由右侧[GitHub Releases](https://github.com/kashiwakiS/Dogear/releases)下载最新构建。当前正式发行包已使用开发者账户签名。

## 自行编译

构建要求: macOS 14或更新版本， Xcode 16.0或更新版本。（由于作者没有较低版本的设备，此为理论下限）

```bash
git clone https://github.com/kashiwakiS/Dogear.git
cd Dogear
scripts/check-sensitive-info.sh
scripts/build.sh --debug
```

Debug 应用会输出到 `build/Debug/Dogear.app`，Release 应用会输出到
`build/Release/Dogear.app`。Xcode 的中间构建文件位于 `build/DerivedData/`；
如需指定其他最终输出目录，可使用 `--output-dir PATH`。
如需一次干净的通用 Release 构建：

```bash
scripts/build.sh --release --clean --universal
```

GitHub Actions 会在每次推送和 Pull Request 中运行相同的源码扫描、Debug 构建、通用 Release 构建和应用元数据检查。

### 可选的本地语义检索

Ask 默认使用无需模型的轻量词法检索。英文论文也可在设置中选择实验性的
“语义检索 — Small EN（实验性）”，并手动导入本地 BGE Small EN 模型包。Dogear
不会自动下载模型。高级用户可按 `scripts/prepare-bge-small-en.py` 顶部列出的
固定依赖，在隔离的 Python 环境中运行：

```bash
python3 scripts/prepare-bge-small-en.py --output /path/to/output
```

脚本会下载固定版本的上游模型、校验权重并生成 `SmallEN` 文件夹；随后在
Dogear 的 AI 设置中选择“导入本地模型…”导入该文件夹。词法检索始终可用，
无需执行这些步骤。

## 快捷键


| 操作                           | 快捷键                        |
| ------------------------------ | ----------------------------- |
| 高亮选中内容                   | `H`                           |
| 添加 FreeText 备注             | `T`                           |
| 添加/删除当前页的 Dog-ear      | `D`                           |
| 上一页 / 下一页                | `W` / `S`（也支持 `K` / `J`） |
| 打开 PDF                       | `⌘O`                         |
| 保存到原文件…                 | `⌘S`                         |
| 上一页 / 下一页                | `⌘↑` / `⌘↓`               |
| 第一页 / 最后一页              | `⌘⌥↑` / `⌘⌥↓`           |
| 放大 / 缩小                    | `⌘+` / `⌘−`                |
| 实际大小 / 适应页面 / 适应宽度 | `⌘0` / `⌘1` / `⌘2`         |
| 资料库导航器（左侧边栏）       | `⌘⌥L`                       |
| 批注与 AI 侧边栏（右侧边栏）   | `⌘⌥R`                       |
| 新建群组…                     | `⌘⇧N`                       |

当原生标签页组预览打开时，按未修饰的数字键 `1` 到 `9` 可打开对应文件。

## 隐私和文件安全

Dogear 没有遥测，也不需要账户。资料库数据只保存在你的 Mac 上。云 AI 为可选功能，默认关闭；Ask 只向你配置的提供商发送问题、选中的文字和工具按需读取的原生文本片段，不会附加 PDF 文件。每次发送都是独立问题，Dogear 不会在磁盘上保存对话历史。详见 [PRIVACY.md](PRIVACY.md)。

在正常编辑中，Dogear 绝不会覆盖原始 PDF。页面更改和批注会保存到应用管理的工作副本中。明确的“保存到原文件”命令需要确认，并使用原子写入。

## 贡献

Bug 报告和功能请求请提交到 [Issues](https://github.com/kashiwakiS/Dogear/issues)。欢迎通过 [pull requests](https://github.com/kashiwakiS/Dogear/pulls) 提交小型、聚焦于具体功能的改动；请先阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全问题请遵循 [SECURITY.md](SECURITY.md)。

Dogear 使用 [GNU General Public License v3.0](LICENSE) 许可。
