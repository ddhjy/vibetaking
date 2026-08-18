# 随心记 iOS 端 (vibetaking)

基于 SwiftUI 的 iOS 速记应用，主打“打开即写”：启动直接进入空白编辑页，自动聚焦、唤起键盘。草稿实时落盘，记录以 Markdown 文件存储，通过 iCloud Drive 在设备间同步。设计理念见[仓库根 README](../../README.md)，macOS 伴侣端见 [apps/macos/README.md](../macos/README.md)。

![应用演示](../../docs/demo.png)

## 功能

- **记录**：进入主页自动聚焦全屏输入框；草稿实时写入 `_draft.md`，退出或切走应用不丢；清空后可一键恢复。
- **Workflow**：把 AI 处理、复制、HTTP 发送、保存记录组合成一键触发的流水线。
- **标签**：为草稿和历史记录打标；基于候选标签、历史打标样例、文本相似度和时间衰减做 AI 推荐。
- **历史**：全文搜索、多标签筛选、随机浏览（工具栏按钮或摇一摇）、批量复制、批量打标、统计、导入导出。
- **配置迁移**：AI 配置与 Workflow 可导出为 JSON，在另一台设备导入覆盖。

## Workflow

Workflow 显示为主页底部工具栏的按钮，可新建、复制、排序，并按“打开/收起”控制是否出现在主页。

点按触发：读取当前草稿，按从上到下的顺序执行所有启用节点。执行成功后，含 `save` 节点则把最终文本存为历史记录，否则仅清空草稿。

| 节点 | 行为 |
| --- | --- |
| `ai_process` | 用节点内提示词调用 AI，返回结果成为后续节点输入 |
| `copy` | 将当前文本写入系统剪贴板 |
| `http_post` | 以 `text/plain; charset=utf-8` POST 到 `http://host:port`；草稿为空时点按同一 Workflow 会向各已启用 HTTP 节点的 `http://host:port/send` 发送回车指令（配合 macOS 端粘贴后一键发送） |
| `save` | 将最终文本保存为历史记录，并继承当前草稿标签 |

### 隐藏调试入口

在主页输入以「打开调试模式」开头的内容，再点按任意手动流水线按钮，会清空草稿并打开调试页（当前页面为空）。

## 存储

记录文件是普通 Markdown，带 front matter：

```markdown
---
created: 2026-06-07-1530-00
description: "记录摘要"
tags:
  - "标签"
---

正文内容
```

- 历史记录文件名基于创建时间生成，格式为 `yyyy-MM-dd-HHmm-ss.md`；当前草稿固定保存为 `_draft.md`。
- 默认存储位置是 iCloud 容器 `iCloud.cn.1pointech.vibetaking` 的 `Documents` 目录；iCloud 不可用时回落到应用沙盒 `Documents/Records`。
- 导入支持 `.md`、`.markdown`、文件夹和 `.zip`，按正文内容去重，创建时间取自文件名或 front matter；导出会把全部记录打包为 ZIP。

## 配置

在应用「设置」中配置 AI 网关，网关需兼容 OpenAI 的 `/v1/responses` 与 `/v1/models` 接口：

| 配置项 | 默认值 / 行为 |
| --- | --- |
| API Key | 保存在系统 Keychain（历史配置会自动从 `UserDefaults` 迁移） |
| API 前缀 | `https://api.infingrow.asia/v1`，未以 `/v1` 结尾时自动补齐 |
| 模型 | `gpt-5.5`，也可从 `/v1/models` 拉取列表选择（过滤图片模型） |

「配置迁移」可把 AI 配置与全部 Workflow 导出为单个 JSON 文件，导入后覆盖当前配置。注意：导出文件包含明文 API Key，请勿随意分发。

## 开发

要求：

- 能构建 iOS 26.0 的 Xcode
- 已配置可用的 Apple Developer Team
- 如需 iCloud 同步，账号需具备 `iCloud.cn.1pointech.vibetaking` 容器权限

打开工程：

```bash
open apps/ios/vibetaking.xcodeproj
```

常用 Makefile 命令（在 `apps/ios/` 下执行；在仓库根目录加 `ios-` 前缀等价，如 `make ios-install`）：

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

App Store 发布流程见 [docs/app-store-release.md](docs/app-store-release.md)。

## 架构

| 路径 | 职责 |
| --- | --- |
| `vibetaking/VibetakingApp.swift` | App 入口 |
| `vibetaking/ContentView.swift` | 打开即写主页、底部工具栏、Workflow 触发、`UITextView` 桥接输入 |
| `vibetaking/WorkflowManager.swift` | Workflow 数据模型、持久化与迁移、手动流水线执行 |
| `vibetaking/WorkflowConfigView.swift` | Workflow 列表、节点编辑和图标选择 |
| `vibetaking/AIService.swift` | 模型列表、AI 文本处理、AI 标签推荐（含历史样例筛选） |
| `vibetaking/HistoryManager.swift` | 草稿与历史记录的 Markdown 读写、导入导出；内含 `TagManager` 与手写 ZIP 解析器 |
| `vibetaking/HistoryView.swift` | 历史列表、搜索、筛选、随机浏览、批量操作、统计 |
| `vibetaking/TagPickerView.swift` | 标签选择、创建、重命名、AI 推荐展示、批量打标 |
| `vibetaking/SettingsView.swift` | AI 设置、模型刷新、配置导入导出；内含 `SettingsManager` |
| `vibetaking/AppConfigurationManager.swift` | 配置包 JSON 的编码、解码与应用 |
| `vibetaking/KeychainHelper.swift` | Keychain 读写封装 |
| `vibetaking/Design.swift` | 全局颜色定义 |
| `vibetaking/AppToolbarIdentity.swift` | 顶栏“更多”按钮的共享标识与加载态 label |
| `vibetaking/DebugView.swift` | 隐藏调试页（当前为空） |
| `vibetaking/Info.plist` | 本地网络说明、文档浏览器、Markdown 文档类型、iCloud 容器声明 |
| `vibetaking/vibetaking.entitlements` | iCloud Documents 权限 |

技术栈：

- SwiftUI + Observation（`@Observable`）
- UIKit bridge（`UITextView`）用于稳定的全屏输入体验
- URLSession 用于 AI 请求与 Workflow 的 HTTP 发送
- Keychain Services 用于密钥存储
- iCloud Drive / CloudDocuments 用于 Markdown 文件同步
- zlib 用于 ZIP 导入解析
