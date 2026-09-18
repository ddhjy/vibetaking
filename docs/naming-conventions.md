# 命名规范

## 范围

产品中文名为“随心记”；仓库及发布身份保持现状。本规范针对本项目自有 Swift 代码及当前开发文档，不要求重写上游协议或历史审计记录。

## 领域术语

| 概念 | 用户文案 | Swift 术语 |
| --- | --- | --- |
| 单条记录 | 记录 | Note |
| 当前输入 | 草稿 | draft / currentDraft |
| 打开即写页面 | 主页 | QuickCaptureView |
| 已保存记录的浏览入口 | 记录 | NoteLibraryView |
| 记录状态和持久化 | 不直接暴露 | NoteStore |
| 标签聚合与计数 | 标签 | TagIndex |
| AI 设置状态 | AI 设置 | AISettingsStore |
| 配置导入导出 | 配置迁移 | AppConfigurationTransfer |
| 工作流与节点 | 工作流、步骤 | Workflow / WorkflowNode |
| 助手执行系统 | AI 助手 | Agent |
| Mac 远程输入接收 | 沿用现有文案 | RemoteInputHTTPServer |

## 基本规则

类型采用 UpperCamelCase，成员采用 lowerCamelCase。自有名称中的缩写统一为 ID、URL、API，例如 selectedWorkflowID、baseURLString、hasAPIKey。布尔值表达状态或能力，例如 isRunning、isNoteLibraryPresented、hasSavedItems；动作函数采用动词，例如 openNoteLibrary。

集合名须体现实际元素：Set<UUID> 的选中集合使用 selectedNoteIDs，而不是让人误以为保存实体的 selectedItems。类型上下文已明确时不重复堆叠领域前缀，例如 AISettingsStore.apiKey 而不是 AISettingsStore.aiApiToken。

Store 表示状态与持久化入口，Index 表示派生索引，Transfer 表示数据传输职责。Manager 不是禁用词；对象确实同时承担配置管理、状态协调与执行时，可以保留 WorkflowManager。

## 文件命名

文件随其主要类型命名。本轮沿用既有文件边界，不要求拆开所有辅助类型；Note、TagIndex 暂与 NoteStore 同文件，AISettingsStore 暂与 SettingsView 同文件。后续拆分必须保持职责与初始化顺序，不引入重复定义。

文件改名时同步声明、全部引用、Preview、测试替身、当前架构文档和显式工程引用。不得以复制新文件但留下旧文件的方式实施重命名。

## 兼容性边界

Swift 标识符不等于持久化键或外部协议名。修改 Codable 属性时显式保留原 CodingKeys：

```swift
case apiKey = "apiToken"
case selectedWorkflowID = "selectedWorkflowId"
```

保留 Bundle ID、iCloud container、UserDefaults/Keychain 键、Markdown front matter、草稿与缓存文件名、配置 schema 版本、Workflow raw value、工具名、HTTP 路径和可访问性标识。

具体包括 apiToken、selectedWorkflowId、aiApiToken、aiBaseURLString、aiModelID、workflows_v2、_draft.md、history-snapshot.json、draft-history.json、/send；不得通过全局替换擅自改变它们。

## 保留项

Mac 的 DraftHistoryEntry / DraftHistoryStore 确实表示草稿操作历史，继续使用 History。OpenAIResponsesAgentProvider.modelId 及其参数标签按既有 Agent 接口保留；NativeOffloads 的导出符号和第三方工具协议不参与本轮统一。

保留历史审计文档和日志中的当时名称；当前 README、设计规范和实现说明必须跟随新名称。

## 变更验收

重命名 PR 不混入算法、线程模型、默认值、界面文案或存储位置变化。必须验证旧配置解码、新配置回写的旧字段名、旧读者兼容、记录/草稿恢复、演示数据切换、导航回归、Mac 粘贴及 /send 提交。源代码扫描不能以“所有旧字符串都消失”为标准，应区分旧 Swift 符号与必须保留的数据键。
