# 本机构建与安装

在 `Configuration/Release.json` 递增版本号和 build，填写本版变更。运行 `bash scripts/build-unsigned.sh` 会重新生成工程，用 iOS 27.1 或更新的 SDK 构建设备包，并校验架构、版本和资源。本机产物位于 `dist/`。

在已配置自动签名的维护者 Mac 上，连接并解锁 iPhone，运行 `bash local/install-iphone.sh --no-update` 安装当前工作树的版本。使用原有签名身份和 Bundle ID 覆盖安装，再从设备回读版本号和 build。

GitHub 仅用于源码。签名和未签名的 IPA 均保存在本地，GitHub Releases、全能签源和应用内更新清单已停止分发安装包。
