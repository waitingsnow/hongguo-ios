# 项目约定

- iOS 源码托管于 `waitingsnow/hongguo-ios`。Android 参考仓库为 `OOIUa/hongguo-android`。Git 作者和提交者统一使用 `OOIUa <79910828+OOIUa@users.noreply.github.com>`。
- IPA 仅在本地构建、校验和签名。不要将 IPA 加入 Git 或发布到 GitHub Releases，也不要同步在线安装源。维护者真机安装沿用已配置的自动签名流程，见 `RELEASING.md`。保留既有签名身份和 Bundle ID，不提交证书、描述文件、私钥或个人数据。
- `Configuration/Release.json` 维护版本、递增的 build、最低系统版本和更新说明。源码在 `Sources/`，最低 iOS 17。用 `scripts/generate_project.py` 生成工程，`scripts/build-unsigned.sh` 以关闭签名的方式生成设备包并调用 `scripts/verify-ipa.py` 校验。`build/`、`dist/` 与 `local/` 仅供本机使用。
- 兼容 iPhone Duo（外屏 466×678pt、内屏 669×951pt）。须用 `minimumBuildSDK` 指定的 iOS 27.1 或更新 SDK 构建，布局按宽度自适应。
- 品牌图标已同步 Android 0.7.8 / `69c1d5a`。原始 XML 与来源在 `Branding/`，用 `xcrun swift scripts/make-icon.swift` 同时生成 AppIcon、应用内 BrandLogo 与 `distribution/icon.png`。不要恢复旧“果”字图标。业务移植基线以 README 为准。
- 修改网络、媒体、账号、本机库或更新规则后，运行对应 `scripts/test-*.sh`。实网测试须显式传 `--live`。没有用户账号实测的登录、云写入不能宣称已验证。
- 从 0.1.3 起默认播放使用 `ProgressivePlayback`，按范围下载、CENC 按样本解密、分块校验缓存。完整文件准备仅用于可选下一集预加载及旧版缓存。涉及这条链路须运行 `scripts/test-progressive.sh`，实网验证用 `scripts/test-progressive-live.sh --live`。
