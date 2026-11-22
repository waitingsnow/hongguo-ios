# 0.1.32 build 43 滚动与互动回归

- `scripts/test-playback-continuity.sh`：用可计数的视频源模拟连续经过 5 个目标。滚动阶段与旧系统防抖两条路径都没有打开中间视频源。取消滑动保留原播放器并恢复声音，退出页面不会被迟到任务重新开播。2× 自然切集两次没有暂停或重复开源。
- Nuke 离线缓存探针：同路径换签名后命中磁盘、再次显示命中内存。连续同步移动预取窗口 100 次，只提交最终 9 张；每个列表最多 2 个并发请求。离开窗口不会取消其他列表仍需要的共享传输。此项测请求调度，不是设备帧率。
- iOS 18.4 模拟器实网 UI：`testImmersiveHomeControlsPagingAndFirstEpisode`、`testEpisodeCommentsAndDanmakuPreference`、`testPlayerMoreDanmakuSettingsPersist` 均通过，未跳过。覆盖推荐翻页及返回、评论和暂停中的弹幕、字号和滚速重启保留。
- 官网公开分集样本中，两个样本均有 15 条可轮播评论，评论总数分别为 863、12,149，全剧收藏总数分别为 1,026,483、897,435。三种数值独立解析，不是本机计数。线上数字会变化。
