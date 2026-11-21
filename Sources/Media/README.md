# 渐进播放

`PlayerSession` 和首页试看都通过 `EpisodeStream` 打开 `ProgressivePlayback`。整个播放会话复用一个 `AVPlayer`，换集只替换 item，小窗因此可在后台连播。下一集在当前集播放几秒后预先取址、读索引并预读开头（`warm`）；「整集预加载」打开时继续分段预读整集。`MediaPreparer` 只保留给旧版整集缓存的容量统计与清理。

- `MediaLocator` 复用上次重定向到的 CDN 地址；失败后回到原地址重试，仍失败或返回 4xx 时用同一清晰度重新取址，只接受加密密钥相同的新地址，并发失败共用一次续签。
- 预读窗口从 1 块起，随顺序读取增长到 6 MB，每次最多合并 4 块为一个 Range、同时 2 个；跳转后从小窗口重新开始，首帧和跳播不必等多余数据。
- `MediaRangeHTTP` 共用一个 URLSession（每主机 6 个连接），减少每段重新握手。

KTVHTTPCache 等本地 HTTP 代理缓存只能缓存原始加密字节，无法完成 CENC 按样本解密与 moov 修复，播放仍须走 AVAssetResourceLoader，因此未引入，而在自有链路上实现连接复用、预读、分块缓存和预加载。

1. `MediaRangeHTTP` 只接受受信视频域的 HTTPS，发送有界 Range 请求，核对 HTTP 206、Content-Range、总长度和实际响应长度。拒绝忽略 Range 的整文件响应，不把上游地址、身份或密钥带入错误文案。
2. `ProgressiveSource` 跳过 mdat 读取顶层 box 与 moov 索引；moov 位于尾部时直接读取尾部范围。索引、文件、样本数量和大小均有上限。
3. `MP4Processor.streamPlan` 复用完整解密路径的验证器，保留全部文件偏移，将加密信令等长修复。读取某范围时补齐与之相交的完整加密样本，按该样本 IV 解密，再返回请求的切片；支持 8/16 字节 IV。
4. `ProgressivePlayback` 把虚拟明文 MP4 暴露给 AVPlayer，按请求的当前偏移逐块回复，直到该请求的实际范围满足后才 finish。拖动可直接补齐目标位置，无需补齐之前的媒体。
5. `ProgressiveCache` 保存已完成且带 SHA-256 的加密块。索引、文件长度、加密信息与首块共同参与缓存标识；损坏块重新获取。内存原始块约 4 MB，明文样本缓存通常不超过 8 MB（单个大样本除外），文件及磁盘缓存各限制 512 MB。

暂停和进入后台时不发起新的读取；已有有界请求可完成。切集/退出关闭所属资源加载器并取消在途请求。已完成分块保留，未完成响应不提交缓存。清理缓存保护正在播放的目录，关闭后可清除。

目前覆盖普通、非碎片化 MP4 和全样本 AES-CTR CENC。碎片化封装、子样本/模式加密和不支持分段读取的服务器暂不支持。下载地址刷新仍由现有播放重试逻辑重新取链。

## 验证

`bash scripts/test-progressive.sh` 在本地生成真实 H.264 视频并按 CENC 加密，以完整解密结果作为独立对照。验证首帧先于整集完成、真实 AVPlayer 起播和跳播、跨块/跨样本读取、IV 宽度、缓存复用与损坏、暂停/取消、HTTP 范围响应边界。无需访问外部网络。

`bash scripts/test-progressive-live.sh --live` 使用真实匿名内容接口和视频 CDN，记录首帧的网络字节数并验证音视频解码；不输出实际视频地址、身份或密钥。

Apple 接口约定：

- [AVAssetResourceLoadingDataRequest](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingdatarequest)：允许增量回复，按 currentOffset 继续，不能提前结束请求。
- [requestsAllDataToEndOfResource](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingdatarequest/requestsalldatatoendofresource)：为 true 时忽略 requestedLength，持续回复到实际末尾或取消。
- [contentInformationRequest](https://developer.apple.com/documentation/avfoundation/avassetresourceloadingcontentinformationrequest)：声明 MP4 UTI、实际总长度和字节范围能力。
