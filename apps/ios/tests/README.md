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

## 标签推荐与下拉转场回归

运行 `./apps/ios/tests/run-tag-recommendation-checks.sh`，直接编译生产代码 `AIService.swift`，沿用项目的 MainActor 默认隔离配置。

用 200 条长记录检查推荐计算期间主线程能继续处理任务、取消能中断计算，以及历史样例上限、候选标签清理和推荐结果过滤保持一致。请求由本地 URLProtocol 接管，不读取应用配置或密钥，也不访问网络。

界面回归还应覆盖：AI 推荐进行中下拉关闭、下拉后取消关闭、点击“完成”，以及从草稿和记录页打开标签选择后保存更改。

## 首页浮动工具栏导航回归

先安装当前代码，再通过独立的 XCTest UI runner 检查手机上的应用：

```sh
make ios-install DEVICE_NAME=KAI
./apps/ios/tests/run-navigation-toolbar-checks.sh 'platform=iOS,name=KAI'
```

需要 Xcode、可用的开发签名及 Ruby `xcodeproj` gem。测试工程在临时目录生成，终端打印的 `.xcresult` 路径包含截图和断言结果。脚本只测试已安装的应用，运行前请先完成安装。

覆盖连续三次进出 AI 助手、助手输入框唤起键盘后返回、侧滑返回和记录页返回。检查首页按钮的可点击状态及其位置是否恢复，避免第三方输入法未暴露标准键盘辅助功能节点时误判。测试不发送 AI 消息、不执行工作流，也不修改草稿或记录。
