# vibetaking · 语音输入

一款基于 SwiftUI 的 iOS 速记应用，主打"打开即写"的全屏输入体验，并把 AI 处理、标签管理、本地网络同步等能力收敛到一条可自定义的 Workflow 流水线中。所有记录以 Markdown 文件形式存储，并可通过 iCloud Drive 在设备间自动同步。

## 演示

![应用演示](docs/demo.png)

## 功能特性

- **极速捕捉**：应用启动后自动聚焦输入框、唤起键盘，无需额外点击即可开始记录；草稿实时保存，关闭应用也不丢失。
- **AI 文本处理**：接入兼容 OpenAI `responses` 接口的网关，可对当前文本执行润色、改写、总结等自定义提示词处理。
- **智能标签推荐**：结合候选标签与历史打标样例，基于文本相似度与时间衰减为当前内容推荐最相关的标签。
- **可视化 Workflow**：将"AI 处理 → 复制 → HTTP 发送 → 保存记录"等节点自由编排为一条流水线，一键执行。
- **AutoPaste 局域网同步**：开启后，草稿会实时同步到局域网内的 AutoPaste 目标主机，并接收回调以清空草稿。
- **历史记录与搜索**：记录按 Markdown 文件归档，支持全文搜索、按标签筛选、导入与导出。
- **iCloud 存储**：记录优先写入 iCloud Drive 容器，跨设备自动同步；无 iCloud 时回落到本地沙盒。
- **配置导入导出**：AI 配置与 Workflow 可打包为 JSON 文件，便于备份与迁移。
- **安全的密钥存储**：AI 密钥保存在系统 Keychain 中，不写入 `UserDefaults`。

## 技术栈

- **SwiftUI** + `@Observable`（Observation 框架）
- **Network.framework**（`NWListener` / `NWConnection`，用于 AutoPaste 控制服务）
- **Keychain**（密钥安全存储）
- **iCloud Drive / CloudDocuments**（Markdown 记录同步）
- **iOS 26.0+**

## 架构概览

应用以单例形式组织核心服务，UI 层通过 `@Observable` 订阅状态变化：

| 模块 | 职责 |
| --- | --- |
| `VibetakingApp` / `AutoPasteSyncManager` | 应用入口；监听场景生命周期，驱动 AutoPaste 草稿同步与控制服务 |
| `ContentView` | 全屏输入主界面、底部工具栏与 Workflow 触发逻辑 |
| `WorkflowManager` | Workflow 与节点的增删改查、持久化，以及流水线执行 |
| `AIService` | 模型列表拉取、文本处理与标签推荐 |
| `HistoryManager` | 草稿与历史记录的读写，iCloud / 本地存储解析 |
| `TagManager` | 标签缓存与最近使用标签管理 |
| `SettingsManager` | AI 网关地址、模型、密钥配置 |
| `AppConfigurationManager` | 配置打包导入 / 导出 |

### Workflow 节点类型

`WorkflowManager` 执行时会按顺序处理启用的节点：

- `ai_process` — 以配置的提示词调用 AI 处理当前文本
- `copy` — 将当前文本复制到剪贴板
- `http_post` — 将文本以 `text/plain` POST 到指定主机和端口
- `save` — 将结果保存为历史记录

Workflow 分为两类：可执行的 `manual`（手动流水线）与开关型的 `autoPasteSync`（AutoPaste 同步）。

## 开发

使用 Xcode 打开 `vibetaking.xcodeproj` 即可开始开发。

也可以直接用 `make` 编译、安装，并在已连接的真机上自动打开 App：

```bash
make install
```

如果连接了多台设备，可以显式指定设备名：

```bash
make install DEVICE_NAME="KAI"
```

查看当前可用真机列表：

```bash
make devices
```

## 配置说明

### AI 服务

在应用「设置」中填写以下信息：

- **API 密钥**：访问令牌，安全存储于 Keychain。
- **网关地址**：默认 `https://api.infingrow.asia/v1`，地址会自动规范化为以 `/v1` 结尾。
- **模型**：默认 `gpt-5.5`，可从网关返回的模型列表中选择。

> AI 文本处理走兼容 OpenAI 的 `responses` 接口，模型列表走 `models` 接口。

### AutoPaste 局域网同步

- 在 Workflow 配置中填写 AutoPaste **主机地址**与**端口**（默认 `7788`）。
- 开启同步后，草稿会在应用处于前台时实时推送到目标主机的 `/draft`。
- 应用会在本地 `7789` 端口启动控制服务，接收目标主机的 `/draft/clear` 回调以清空当前草稿。
- 该功能需要本地网络权限（已在 `Info.plist` 中声明 `NSLocalNetworkUsageDescription`）。

### 存储

- 记录以 `.md` 文件存储，文件名基于创建时间生成；草稿固定为 `_draft.md`。
- 优先使用 iCloud 容器 `iCloud.cn.1pointech.vibetaking` 的 Documents 目录；未登录 iCloud 时回落到本地沙盒。
- 支持以系统文档浏览器在原位打开 Markdown 文档（`LSSupportsOpeningDocumentsInPlace`）。

## 许可证

MIT License
