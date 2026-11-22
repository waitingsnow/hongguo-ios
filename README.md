<div align="center">

<img src="distribution/icon.png" width="112" alt="红果独立版 logo">

# 红果独立版 iOS

**在 iPhone 上发现好剧，随时接着看。**

基于 SwiftUI 与 AVFoundation 构建的原生 iOS 短剧客户端。<br>请求签名、媒体解密、缓存与播放均在本机完成，无需部署服务器或配置 API key。

[![iOS](https://img.shields.io/badge/iOS-17.0%2B-000000?logo=apple&logoColor=white)](#源码构建) [![UI](https://img.shields.io/badge/UI-SwiftUI-F05138?logo=swift&logoColor=white)](#功能一览) [![License](https://img.shields.io/badge/License-GPL--3.0--only-blue)](LICENSE)

[功能一览](#功能一览) · [源码构建](#源码构建) · [反馈问题](https://github.com/waitingsnow/hongguo-ios/issues)

</div>

仓库提供源码。安装时请在本机完成构建与签名。覆盖安装旧版时，使用相同的 Bundle ID 和兼容的签名配置，以保留本机数据。

## 功能一览

| 功能 | 说明 |
| --- | --- |
| 首页与推荐 | 全屏推荐支持上下滑换剧，左滑或点剧名看详情。底部「看全集」显示总集数，点开后从预览位置继续播放。开启自动连播时，第 1 集播完进入第 2 集。卡片首页也可查看最近观看、热度、最新短剧与榜单。 |
| 发现与搜索 | 浏览短剧、漫剧、AI 剧，按上游提供的条件筛选；按剧名或关键词搜索 |
| 剧集详情 | 简介、选集、相关作品（其他季与同 IP 作品，待上线作品可预约） |
| 边下边播 | 读取视频索引后即可起播，不等整集下完；随播放进度逐步预读、复用连接，地址失效自动换新；拖动时按需补齐目标片段，已校验的分块缓存复用 |
| 播放手势 | 在画面上左滑打开当前剧详情，右滑返回。横屏右滑先退出全屏。上下滑切集，双击暂停或继续，轻点切换控件，双指外拉清屏。长按临时 2×，保持按住并左右拖动调进度，或纵向滑入锁定区保持 2×。 |
| 播放控制 | 点底部「选集」查看全集和当前集。右上角「更多」可调整六档倍速、720P / 1080P 清晰度、开启清屏，或设定播完本集、15、30、60 分钟后停止播放。倍速与清晰度会记为默认值。 |
| 播放互动 | 评论气泡优先显示官网评论总数，缺少总数时显示已读到的预览数。「弹」显示本集可轮播的公开评论条数，五角星显示官网返回的全剧收藏数，点星仍只更改本机收藏。不可读取的数量不按零显示。「更多」可调弹幕字号和滚动速度，重新打开仍保留。弹幕随暂停停住，滚动速度独立于视频倍速。官网预览无分页，也不提供原生弹幕的播放时间戳。 |
| 全屏与小窗 | 播放器解锁时跟随系统方向，横竖屏均可上滑看下一集、下滑看上一集。横屏右侧锁键可锁住方向和手势。横屏片源也可点「全屏观看」。播放时离开应用可自动转为画中画并继续连播，回到应用自动恢复全屏。 |
| 片单与历史 | 本机收藏与播放历史，退出后恢复集数和位置；登录后可查看账号收藏、最近历史与预约 |
| 红果账号 | 扫码、手机号或官网登录；账号收藏写入后回读核对；观看进度默认上报，打开剧集时取本机与账号中较新的进度 |
| 界面风格 | 暖白精修、沉浸暗场、内容卡片三种布局，浅色、深色或跟随系统 |
| iPhone Duo | 用 iOS 27.1 以上 SDK 构建，展开后按内屏尺寸运行；海报网格随屏幕宽度增加列数 |

## 快速上手

1. 从「首页」「发现」或搜索选剧，进入详情后选择集数开始播放。
2. 播放中轻点画面呼出控件，双击任意位置暂停；长按临时 2 倍速，长按后左右拖动调整进度。
3. 退出播放器后，在首页或「我的 → 播放历史」继续上次的集数与位置。
4. 「我的 → 设置」切换主题样式、浅色或深色，调整自动连播、下一集整集预加载、默认清晰度与倍速。
5. 「我的」顶部的账号卡片进入红果账号登录。官网会话和手机业务身份分别验证，云账号确认后才开放账号收藏、历史与预约。

## 当前版本边界

- 支持 HTTP 分段读取的普通 MP4 与全样本 CENC 视频，按需下载并解密；索引位于文件尾部也能先读索引再起播。碎片化 MP4、子样本或模式加密暂不支持。
- 推荐页连续滑动时不为经过的每一部都创建播放器。停稳后播放落点，按最近的滑动方向准备邻近剧目；回划可复用刚看过的视频源。预读以当前播放缓冲够用为前提，临近片尾会优先准备当前剧第 2 集。开启「下一集整集预加载」后，剩余部分在这些开头准备好后分段下载。
- 首页各频道与发现页（未筛选）列表、剧集详情在本机保留 7 天，30 分钟内直接显示，较旧时先显示再后台刷新；封面由 Nuke 做内存与 300 MB 磁盘缓存。
- 前台或小窗播放。三种风格按 iOS 原生控件适配，共用同一个播放器。
- 本机收藏与历史各最多 200 部，与账号数据分开管理。账号历史读取最近 50 部，预约读取 20 部，收藏展示已读取的批次；不提供完整的云端备份。
- 推荐会在本机记住最近 540 部已推荐作品，刷新或重开应用后继续去重；匿名与不同账号分别保存，不上传推荐浏览记录。超过窗口的旧作品仍可能再次出现。
- 本机片单读取失败时保留原文件并暂停写入，可在片单页面重试读取，避免空记录覆盖原数据。
- 账号收藏响应不确定时保留「待核对」状态，不会自动重发收藏请求。
- 云进度上报默认开启（可在账号菜单关闭），只上报此后实际观看的内容，待发送记录按账号隔离并加密保存。

## 源码构建

需要完整 Xcode 及 **iOS 27.1 或更新的 SDK**（`Configuration/Release.json` 的 `minimumBuildSDK`），旧 SDK 构建的包在 iPhone Duo 展开后会按普通 iPhone 尺寸加黑边显示，构建脚本会直接拒绝。部署最低版本 iOS 17.0。唯一的外部 Swift Package 是 [Nuke](https://github.com/kean/Nuke) 13.2.3（固定版本，首次构建需联网解析）。

```sh
bash scripts/build-unsigned.sh
```

脚本会生成 Xcode 工程、编译 Release 设备目标（关闭代码签名）、打包标准 `Payload/Hongguo.app` 结构，并把 IPA 和 SHA-256 输出到 `dist/`。

在 Xcode 中开发：

```sh
python3 scripts/generate_project.py
open Hongguo.xcodeproj
```

版本号、build、最低系统与更新说明统一在 `Configuration/Release.json` 维护，工程由脚本从中生成。

## 验证

离线测试：

```sh
bash scripts/test-account-rules.sh
bash scripts/test-library.sh
bash scripts/test-network.sh
bash scripts/test-media.sh
bash scripts/test-progressive.sh
bash scripts/test-updates.sh
python3 scripts/test-feeds.py
```

实网测试会访问内容源并下载视频，需要显式加 `--live`：

```sh
bash scripts/test-network-live.sh --live
bash scripts/test-media-live.sh --live
bash scripts/test-progressive-live.sh --live
```

测试不需要本人账号，也不会打印设备身份、Cookie、媒体密钥或完整媒体 URL。各版本的验证记录与尚未验证的部分见 [VALIDATION.md](VALIDATION.md)。

在未设置 `playback.commentDanmaku` 的 QA 安装上，运行 `testEpisodeCommentsAndDanmakuPreference` 时传入 `TEST_RUNNER_HONGGUO_QA_MODE=--live` 和 `TEST_RUNNER_HONGGUO_QA_FRESH_COMMENT_DANMAKU=1`，可验证默认开启、手动关闭和重启后保留关闭状态。

本机签名和真机安装流程见 [RELEASING.md](RELEASING.md)。

## 开源与来源

最初移植自 [OOIUa/hongguo-android](https://github.com/OOIUa/hongguo-android) 0.7.5（`72d5531`），此后随 Android 版本同步功能。应用图标与应用内标识来自 Android 0.7.8（`69c1d5a`）的矢量素材，重新生成方式见 [Branding/README.md](Branding/README.md)。

项目按 GPL-3.0-only 分发，许可证和原作者通知保留在 `Resources/`。签名算法来自 `jackotom/hongguo-drama` 的开源实现，在本机由 JavaScriptCore 执行；设备注册、账号与媒体处理参考 Android 版及其列出的 GPL / MIT 来源。详见 `Resources/ThirdPartyNotices.txt`、`Sources/Networking/PureSign.js` 与各源文件注释。分发安装包时应同时提供对应源码及构建脚本，每个 Release 都附有源码 ZIP。

## Star History

<a href="https://www.star-history.com/#waitingsnow/hongguo-ios&Date">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=waitingsnow/hongguo-ios&type=Date&theme=dark" />
    <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=waitingsnow/hongguo-ios&type=Date" />
    <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=waitingsnow/hongguo-ios&type=Date" />
  </picture>
</a>
