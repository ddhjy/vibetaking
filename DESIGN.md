# 随心记 iOS 设计规范

## 体验

打开即写。主页保留空白编辑器、自动键盘和一键工作流；整理、回顾和配置使用系统导航及表单。界面服务于记录内容。

## 颜色和材质

- 强调色：`UIColor.systemIndigo`，沿用靛蓝识别，支持系统深浅色及高对比度。
- 编辑和会话背景：`systemBackground`；列表：`systemGroupedBackground`、`secondarySystemGroupedBackground`。
- 正文：`Color.primary` / `UIColor.label`；说明：`Color.secondary` / `secondaryLabel`。
- 删除和失败使用系统 red，并同时提供名称、符号或文字状态。
- Liquid Glass 限于底部操作区域；表单和消息使用内容层背景。降低透明度时，操作区域使用不透明系统背景。

## 字体和尺寸

- 正文使用 `.body`，说明使用 `.subheadline` / `.footnote`，日期等元数据使用 `.caption`。
- UIKit 编辑器使用 `UIFont.preferredFont(forTextStyle: .body)` 和 Dynamic Type。
- 自定义操作热区至少 44 × 44 pt；图标选择单元随字体缩放。
- 正文不限制辅助功能字号。紧凑工具栏的符号保持 20 pt，以避免图标侵占正文；最大字号下工作流转为系统菜单。
- 长表单、权限详情支持滚动。统计日历在辅助功能字号或不足 308 pt 的内容宽度下采用日期列表。
- 主编辑器和 AI 会话的阅读宽度上限为 720 pt。

## 控件与状态

- 导航：NavigationStack；工作流在常规宽度沿用 NavigationSplitView。
- 列表：iPhone 使用 insetGrouped，保留系统分隔、重排、侧滑与选择惯例。
- 多选：勾号表示全部选中，减号表示部分选中；读屏名称同时包含状态。
- 表单：字段名称常驻；AI 密钥关闭自动大写与纠错；主机和端口在保存前校验。
- 有编辑项的弹窗提供“取消／保存”；只读详情提供“完成”；不可逆删除与配置覆盖使用明确确认。
- 清除草稿显示恢复入口；复制和执行结果提供文字或辅助功能反馈。
- 系统减少动态效果设置禁用自定义动画。优先采用系统按钮和原生弹窗的可访问行为。

逐页修改清单与实测范围见 [HIG 审视记录](docs/ios-hig-audit.md)。
