# 权限交互回归

在装有 Xcode 26 的 Mac 上运行：

```sh
./apps/ios/tests/run-permission-checks.sh
```

脚本直接编译生产代码 `OffloadPermissionManager.swift` 与 `CommandLine.swift`，用独立临时 UserDefaults 和空日志器隔离应用配置。它不访问系统日历、提醒事项或剪贴板。

共 9 项检查：允许及同会话复用、拒绝、等待期间取消、展示前取消、并发队列、重复请求复用、排队请求取消、带引号参数与负数日期解析，以及超过 30 秒仍保留授权面板的状态。最后一项包含 31 秒等待，以复现此前的自动关闭问题。

这些检查验证权限状态与异步任务完成行为；完整的 VoiceOver、Switch Control 和真实设备权限交互需在设备上验证。

## 用户错误反馈回归

运行 `./apps/ios/tests/run-copy-checks.sh`，直接编译生产代码 `UserFacingError.swift`。

13 项检查覆盖密钥、地址示例、模型、限流、内容过长、服务故障、流式错误、未知错误代码、断网、安全连接、取消、文件访问、空间不足和自定义工作流错误保留。无需 AI 密钥或网络连接。
