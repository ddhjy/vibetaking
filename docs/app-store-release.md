# 随心记 App Store 发布清单

更新日期：2026-06-10

## App 参数

- App 名称：VibeTaking 随心记
- App Store Connect App ID：`6778762693`
- Bundle ID：`cn.1pointech.vibetaking`
- SKU：`cn.1pointech.vibetaking`
- Platform：iOS
- Version：`1.0`
- Build：`1`
- Team ID：`6KH2T566FP`
- Primary locale：`zh-Hans`

## 本地已完成

- Release archive 已生成：`.asc/artifacts/vibetaking.xcarchive`
- App Store export options 已生成：`.asc/ExportOptions-AppStore.plist`
- 中文 App Store 元数据已生成并通过离线校验：`metadata/`
- 隐私政策和支持文档草稿已生成：`docs/privacy-policy.md`、`docs/support.md`
- App Store 候选截图已生成：`screenshots/appstore/zh-Hans/`

## 当前阻塞

1. `asc` 没有 App Store Connect API Key 登录。
2. App Store Connect 中还没有 `cn.1pointech.vibetaking` 的 app 记录。
3. 需要确认隐私政策和支持链接已公开可访问。
4. 需要在 App Store Connect 填写 App Privacy、年龄分级、内容版权、价格/可用地区、审核联系人等审核项。
5. 当前模拟器截图自动化卡在 CoreSimulator 启动/安装，已用 `docs/demo.png` 生成候选截图；正式提交前建议补一组真实 iPad 截图。

## 继续发布命令

登录 `asc`：

```bash
asc auth login \
  --name "vibetaking" \
  --key-id "KEY_ID" \
  --issuer-id "ISSUER_ID" \
  --private-key "/path/to/AuthKey_KEY_ID.p8" \
  --network
```

确认 App Store Connect app id：

```bash
asc apps list --bundle-id "cn.1pointech.vibetaking" --output table
```

重新导出 IPA：

```bash
asc xcode export \
  --archive-path ".asc/artifacts/vibetaking.xcarchive" \
  --export-options ".asc/ExportOptions-AppStore.plist" \
  --ipa-path ".asc/artifacts/vibetaking.ipa" \
  --overwrite \
  --xcodebuild-flag=-allowProvisioningUpdates \
  --output json --pretty
```

上传并等待处理：

```bash
asc builds upload --app "APP_ID" --ipa ".asc/artifacts/vibetaking.ipa" --wait
```

上传元数据前预览：

```bash
asc metadata push --app "APP_ID" --version "1.0" --platform IOS --dir "./metadata" --dry-run --output table
```

提交前检查：

```bash
asc validate --app "APP_ID" --version "1.0" --platform IOS --output table
```
