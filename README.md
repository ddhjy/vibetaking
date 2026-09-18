# 随心记

打开即写的纯文本速记工具。

启动直达空白编辑页——自动聚焦、键盘就绪、草稿实时落盘，以 Markdown 存储并通过 iCloud Drive 同步。

## 下载

已上架 App Store：

[![Download on the App Store](https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/zh-cn?size=250x83)](https://apps.apple.com/cn/app/id6778762693)

[随心记 - 打开即写](https://apps.apple.com/cn/app/id6778762693)

![应用演示](docs/demo.png)

## 设计理念

多数笔记产品打开先看列表，以回顾为中心。随心记把入口放回记录本身：一张空白页，一个就绪的光标。空白减少选择和干扰，也自然产生"把它填上"的动机。

这种"快"来自几处取舍：

- **入口快**：主页即编辑页，无需新建、选分类或找笔记。
- **启动快**：原生组件构建，优先保证启动和交互响应。
- **输入快**：纯文本，不区分标题正文，不提供复杂排版。
- **整理快**：只有记录和标签两层；标签积累后，零散文本可分类、可检索、可回顾。

需要更快输入时，配合系统听写或豆包等语音转文字工具即可。

## 构建

```bash
make help              # 列出全部 target
make install           # 构建并安装到第一台已配对真机
```

详见 [apps/ios/README.md](apps/ios/README.md)。

## 文档

- [App Store 下载](https://apps.apple.com/cn/app/id6778762693)
- [隐私政策](docs/privacy-policy.md)
- [支持](docs/support.md)
- [App Store 发布清单](apps/ios/docs/app-store-release.md)
- [命名规范](docs/naming-conventions.md)

## 许可证

GPL-3.0（见 [LICENSE](LICENSE)）。

Agent 能力（多轮工具调用、Skills、持久记忆、日历/提醒/剪贴板设备集成）移植自 GPL-3.0 开源项目 [OpenMinis](https://github.com/OpenMinis/OpenMinis)，详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)。因引入 GPL 代码，本项目整体按 GPL-3.0 授权，本仓库即完整对应源码。

> 向 App Store 公开分发含第三方 GPLv3 代码的应用存在合规争议，上架前请自行评估。
