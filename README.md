# vibetaking · 随心记

“打开即写”的纯文本速记工具。iOS 端启动直接进入空白编辑页，自动聚焦、唤起键盘，草稿实时落盘，记录以 Markdown 文件存储并通过 iCloud Drive 同步；macOS 端是一个菜单栏伴侣应用，通过 HTTP 接收文本并粘贴到当前输入框。

![应用演示](docs/demo.png)

## 设计理念

很多笔记产品以回顾为中心，打开后首先看到列表；vibetaking 把入口放回记录本身：一张空白页、一个已经就绪的光标和键盘。空白页减少选择和干扰，也自然产生“把它填上”的输入动机。

这种“快”来自几个取舍：

- **入口快**：主页就是编辑页，不需要先新建、选择分类或进入某篇笔记。
- **启动快**：界面使用原生组件构建，优先保证启动、动画和交互的响应速度。
- **输入快**：纯文本记录，不区分标题和正文，不提供复杂排版。
- **整理快**：信息组织只有记录和标签两层；标签积累后，零散文本逐渐可分类、可检索、可回顾。

需要更快输入时，可以配合系统键盘听写，或借助豆包等语音转文字工具——语音不是内置能力，而是输入方式的延伸。

## 仓库结构

```
apps/
├── ios/     SwiftUI iOS 应用（主应用，App Store 发布物）
└── macos/   Swift + Cocoa 菜单栏伴侣应用
docs/        隐私政策、支持说明、演示图（App Store 登记的公开链接指向这里）
```

| 端 | 说明 | 文档 |
| --- | --- | --- |
| iOS | 打开即写主页、Workflow、标签、历史、iCloud 同步、AI 处理与 Agent | [apps/ios/README.md](apps/ios/README.md) |
| macOS | 菜单栏常驻，HTTP 接收文本并模拟按键粘贴到当前活跃输入框 | [apps/macos/README.md](apps/macos/README.md) |

两端原本是独立仓库，macOS 端已连同完整提交历史合并进本仓库，不再单独维护。iOS 的手动 Workflow 可以用 HTTP 发送节点把文本投到 Mac；macOS 端也接受任意来源的 `POST /`（纯文本或 `{"text": "..."}`），方便脚本或 AI 工具直接投递。

## 构建

仓库根目录的 `Makefile` 只做转发，`ios-` / `mac-` 前缀分别对应两端：

```bash
make help              # 列出转发规则
make ios-help          # iOS 端全部 target
make ios-install       # 构建并安装到第一台已配对真机
make mac-help          # macOS 端全部 target
make mac-install       # 构建并覆盖安装到 /Applications
```

也可以进入 `apps/ios/` 或 `apps/macos/` 直接用各自的 `Makefile`。

## 文档与许可证

- [隐私政策](docs/privacy-policy.md)
- [支持](docs/support.md)
- [App Store 发布清单](apps/ios/docs/app-store-release.md)
- [macOS 权限说明](apps/macos/docs/permissions.md)

GPL-3.0 License（见 [LICENSE](LICENSE)）。

本应用的 Agent 能力（多轮工具调用、Skills、持久记忆、日历/提醒/剪贴板设备集成）移植自 GPL-3.0 开源项目 [OpenMinis](https://github.com/OpenMinis/OpenMinis)，详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。因引入 GPL 代码，本项目整体按 GPL-3.0 授权；本仓库即完整对应源码。注意：向 App Store 公开分发含第三方 GPLv3 代码的应用存在合规争议，公开上架前需自行评估。
