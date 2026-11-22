# 0.1.32 build 42 播放回归

- 先用既有签名安装 build 41。在 iPhone 16 Pro Max 的 8 秒镜像录像中，弹幕位置变化的最长间隔约 42 ms，未见超过 100 ms 的停顿。这个数字是镜像观察，不是设备显示器帧率。
- 同一部剧在 build 41 连播时产生 `EXC_BAD_ACCESS`。与安装包 UUID 完全匹配的 dSYM 将故障定位到 `ProgressiveSource.warm(bytes:from:)` 读取 `Pending`。build 42 用同步事务登记、取消和完成分块请求，网络和磁盘等待不占锁。
- build 42 在同一手机、同一部剧从第 3 集自然播到第 5 集，期间进程 PID 不变，设备没有新增该应用的崩溃报告。这是有限次回归，不代表所有剧都不会崩溃。
- `bash scripts/test-progressive.sh` 覆盖并发预读、取消、关闭、迟到响应和稀疏分块复用。优化构建启用 Thread Sanitizer 后通过 24 轮、1,536 次字节校验。
- `bash scripts/test-playback-continuity.sh <模拟器 UDID>` 验证推荐和剧集 A→B→A 的断点与已打开视频源复用，也验证 2× 下两次自然切集。`bash scripts/test-progressive-live.sh --live` 的实网样本下载约 10.4% 时已解出首帧。
- 底栏 UI 测试在 iPhone 16e 模拟器通过 5 项、0 跳过；真机账号收藏页和观看历史均显示了剧名和封面。`scripts/test-library.sh`、`scripts/test-account-rules.sh` 验证资料补全不会覆盖观看进度、改变顺序或恢复已删除记录。
