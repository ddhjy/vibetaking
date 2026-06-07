# vibetaking · 随心记

一款基于 SwiftUI 的 iOS 速记应用，主打“打开即写”：启动后自动聚焦输入区、唤起键盘，适合键盘输入和系统听写。草稿实时保存，记录以 Markdown 文件落盘，并可通过 iCloud Drive 在设备间同步。

应用把 AI 处理、标签管理、剪贴板、HTTP 发送、保存记录和 AutoPaste 局域网同步收敛到可配置的 Workflow 中，让一段临时输入可以一键变成“润色后的文本”“发往局域网的草稿”或“带标签的历史记录”。

## 演示

![应用演示](docs/demo.png)

## 核心能力

- **打开即写**：进入主页后自动聚焦全屏输入框；草稿写入 `_draft.md`，退出或切走应用也不会丢。
- **Workflow 流水线**：手动 Workflow 可按顺序组合 AI 处理、复制、HTTP 发送、保存记录等节点。
- **AutoPaste 同步**：开关型 Workflow 可把当前草稿实时推送到局域网目标，并接收远端清空回调。
- **AI 处理**：接入兼容 OpenAI `/v1/responses` 与 `/v1/models` 的网关，支持自定义提示词和模型选择。
- **标签推荐**：基于候选标签、历史打标样例、文本相似度和时间衰减为当前内容推荐标签。
- **历史管理**：支持全文搜索、多标签筛选、随机浏览、批量复制、批量打标、统计、导入和导出。
- **Markdown 存储**：记录带 front matter，优先写入 iCloud Drive 容器，无 iCloud 时回落到本地沙盒。
- **配置迁移**：AI 配置与 Workflow 可导出为 JSON，也可导入覆盖当前配置。
- **密钥保护**：AI API Key 保存在系统 Keychain，历史配置会从 `UserDefaults` 迁移到 Keychain。

## Workflow

Workflow 分为两类：

| 类型 | 用途 |
| --- | --- |
| `manual` | 主页按钮触发，按节点顺序处理当前草稿 |
| `autoPasteSync` | 主页按钮切换开关，负责 AutoPaste 实时同步 |

手动 Workflow 支持的节点：

| 节点 | 行为 |
| --- | --- |
| `ai_process` | 用节点内提示词调用 AI，返回结果成为后续节点输入 |
| `copy` | 将当前文本写入系统剪贴板 |
| `http_post` | 以 `text/plain; charset=utf-8` POST 到 `http://host:port` |
| `save` | 将最终文本保存为历史记录，并继承当前草稿标签 |

AutoPaste 同步使用单独协议：开启后，应用在前台会向 `http://host:port/draft` 发送 JSON：

```json
{
  "text": "当前草稿",
  "callbackPort": 7789
}
```

应用同时在本机 `7789` 端口启动控制服务，接收 `POST /draft/clear` 后清空当前草稿。同一时间只允许一个 AutoPaste Workflow 处于开启状态。

## 存储

记录文件是普通 Markdown：

```markdown
---
created: 2026-06-07-1530-00
description: "记录摘要"
tags:
  - "标签"
---

正文内容
```

- 历史记录文件名基于创建时间生成，格式为 `yyyy-MM-dd-HHmm-ss.md`。
- 当前草稿固定保存为 `_draft.md`。
- 默认存储位置是 iCloud 容器 `iCloud.cn.1pointech.vibetaking` 的 `Documents` 目录。
- iCloud 不可用时，记录写入应用沙盒 `Documents/Records`。
- 导入支持 `.md`、`.markdown`、文件夹和 `.zip`；导出会打包为 ZIP。

## AI 配置

在应用「设置」中配置：

| 配置项 | 默认值 / 行为 |
| --- | --- |
| API Key | 写入 Keychain |
| API 前缀 | `https://api.infingrow.asia/v1`，会自动补齐 `/v1` |
| 模型 | `gpt-5.5`，也可从 `/v1/models` 拉取并选择 |

模型列表会过滤图片模型；文本处理调用 `/v1/responses`，请求包含 `instructions`、`input`、`temperature` 和 `max_output_tokens`。

## 开发

要求：

- 支持 iOS 26.0+ 的 Xcode
- 已配置可用的 Apple Developer Team
- 如需 iCloud 同步，账号需具备 `iCloud.cn.1pointech.vibetaking` 容器权限

打开工程：

```bash
open vibetaking.xcodeproj
```

常用 Makefile 命令：

```bash
make help
make build
make install
make install DEVICE_NAME="KAI"
make devices
make simulators
make install-simulator
make install-simulator SIMULATOR_NAME="iPhone 17"
make clean
```

`make install` 会构建、安装并启动到第一台已配对真机；`make install-simulator` 会优先使用指定模拟器、已启动模拟器或第一台可用 iPhone 模拟器。

## 代码结构

| 路径 | 职责 |
| --- | --- |
| `vibetaking/VibetakingApp.swift` | App 入口、场景生命周期、AutoPaste 同步管理与本地控制服务 |
| `vibetaking/ContentView.swift` | 打开即写主页、底部工具栏、Workflow 触发和草稿交互 |
| `vibetaking/WorkflowManager.swift` | Workflow 数据模型、持久化、迁移、节点执行 |
| `vibetaking/WorkflowConfigView.swift` | Workflow 列表、节点编辑、图标选择、AutoPaste 配置 |
| `vibetaking/AIService.swift` | 模型列表、AI 文本处理、AI 标签推荐 |
| `vibetaking/HistoryManager.swift` | Markdown 草稿和历史记录的读写、导入、导出、标签更新 |
| `vibetaking/HistoryView.swift` | 历史列表、搜索、筛选、统计、批量操作 |
| `vibetaking/TagPickerView.swift` | 标签选择、创建、重命名和 AI 推荐展示 |
| `vibetaking/SettingsView.swift` | AI 设置、模型刷新、配置导入导出，内含 `SettingsManager` |
| `vibetaking/AppConfigurationManager.swift` | JSON 配置包的编码、解码与应用 |
| `vibetaking/KeychainHelper.swift` | Keychain 读写封装 |
| `vibetaking/Info.plist` | 本地网络、文档浏览器、Markdown 文档类型、iCloud 容器声明 |
| `vibetaking/vibetaking.entitlements` | iCloud Documents 权限 |

## 技术栈

- SwiftUI + Observation (`@Observable`)
- UIKit bridge (`UITextView`) 用于稳定的全屏输入体验
- Network.framework (`NWListener` / `NWConnection`) 用于本地控制服务
- URLSession 用于 AI 和局域网 HTTP 请求
- Keychain Services 用于密钥存储
- iCloud Drive / CloudDocuments 用于 Markdown 文件同步
- zlib 用于 ZIP 导入解析

## 许可证

MIT License
