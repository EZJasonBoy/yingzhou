# tvbox-next 架构设计

> 工作名，正式名称以后再定。许可证：AGPL-3.0（会移植 TVBoxOS / Box 的 Java 实现，同为 AGPL-3.0；参考 Win-box 的部分为 MIT，保留其版权声明）。

> 相关文档：[需求](requirements.md) · [进度](status.md) · [协议](protocol.md) · [开发指南](development.md) · [配置兼容性](compatibility.md)。本文描述的是目标架构；标了"已实现"的小节与代码一致，其余是计划。

## 1. 目标

- **完全兼容 TVBox 配置与蜘蛛协议**：订阅链接、加密配置、多仓、type 0/1/3/4 站点、jar / js / py 蜘蛛、解析接口、直播源。目标是"安卓能播的，这里也能播"。
- **全平台**：Windows、macOS、Linux、Android 手机 / 平板 / 电视、iOS / iPadOS。
- **现代界面、友好交互**：单窗口、流式聚合搜索、自动换线换源、跨设备续播。
- **播放性能好、弹幕完整**：每个平台用最强的播放内核，弹幕由引擎统一抓取匹配。

## 2. 总体架构：一个引擎 + 一个客户端 + 一套协议

```
┌──────────── 引擎 tvbox-engine（Kotlin/JVM，一份代码）────────────┐
│ 订阅/配置 · 站点分发 · jar/js/py 运行时 · 解析/嗅探 · 聚合搜索    │
│ 直播/EPG · 弹幕抓取与匹配 · /proxy（兼容 9978）· 历史/收藏/进度   │
└──────────────────────────────────────────────────────────────────┘
 部署：NAS/Linux Docker │ Windows/macOS 桌面版内置 │ 安卓 App 内置 │ 云（可选）
                 ▲ HTTP + SSE + WebSocket · 局域网 mDNS 发现 · 扫码配对 + 令牌
 客户端（Flutter，一份代码）：Windows · macOS · Linux · 安卓手机/平板/TV · iOS/iPadOS
```

- **引擎**是唯一理解 TVBox 协议的地方。客户端只消费规整后的数据（不解析 `$$$`、`#`、`$` 这类拼接串）。
- **客户端**只负责界面、播放、弹幕渲染、本地偏好。客户端连"本机引擎"和"远程引擎"走的是同一套协议，没有区别。
- **协议**见 [protocol.md](protocol.md)。

### 2.1 各平台形态

| 平台 | 客户端 | 引擎 | jar 蜘蛛 |
|---|---|---|---|
| Android 手机/TV | Flutter | **同进程内置**（Kotlin 直接打进 APK，Ktor 监听 127.0.0.1） | `DexClassLoader` 原生加载，含带 `.so` 的加固 jar |
| Windows / macOS / Linux | Flutter | 内置引擎（精简 JRE 子进程，可关闭）或连 NAS | dex 转换 + 安卓桩类；加固 jar 计划走 unidbg（未实现） |
| NAS / 服务器 | — | Docker 镜像（amd64 / arm64） | 同桌面 |
| iOS / iPadOS | Flutter | **无**，连局域网引擎；外出用 Tailscale 等连回家 | 由远程引擎负责 |

最兼容的引擎是一台安卓设备（盒子、旧手机）：ART 原生运行所有 jar。

### 2.2 Android 内置引擎（已实现）

- `client/android` 通过 Gradle 复合构建（`includeBuild("../../engine")`）直接编译引擎源码，不复制代码。
- `TvboxApplication` 启动时在 127.0.0.1:9978 拉起引擎（Ktor CIO），数据在 `files/engine`，并恢复上次的订阅；客户端默认地址就是它。
- jar 运行时：`DexSpiderRuntime` 只负责用 `DexClassLoader` 把 jar 变成类加载器（文件只读以满足 Android 14），其余逻辑在与桌面共用的 `JarSpiderRuntime`（见 2.3）。
- 网页嗅探：`WebViewSniffer`，有可见 Activity 时 1×1 透明挂在窗口上（部分播放器不在窗口里不加载），否则不挂窗口运行。
- `proguard-rules.pro` 保留宿主类和 OkHttp / Gson / Jsoup。
- 引擎代码不用 `java.util.Base64`（Android 8.0 才有），统一走 `Base64Compat`，最低支持 Android 7.0（API 24）。
- 开发用演示 jar：`engine/server/demo-jar/build.sh`（javac + d8），演示引擎在 `/demo/spider.jar` 提供，演示站的链接按请求的 Host 生成，模拟器通过 10.0.2.2 访问。

和桌面引擎的对照（`EmbeddedEngine.kt` 对 `engine/server/.../Main.kt`）：

| 功能 | 桌面 / NAS | 安卓内置引擎 |
|---|---|---|
| 采集站、JS、jar 蜘蛛、嗅探、解析、直播、回看、数据缓存、字幕、弹幕、网盘 | 有 | 有（同一套路由；网盘没有"本机文件夹"） |
| 播放缓存（`StreamCache`） | 数据目录，默认 2 GB | 应用缓存目录 `cache/stream`，默认 1 GB，并给磁盘留 500 MB（见下） |
| 离线下载（`DownloadManager`） | 和播放缓存同一个库，导出到「下载」文件夹 | 应用在共享存储上的目录，导出交给系统（见下） |
| 局域网共享、配对、令牌、签名地址 | `LanSharing`（JmDNS） | `AndroidLan`（同一个 `LanListeners`，`NsdManager` 通告） |
| Python 蜘蛛 | 有 | 没有：不注册 Python 运行时，`capabilities.py=false`，也没有 `/python` 接口 |
| `/file/` 本机文件、`--check` 体检、CDP 嗅探 | 有 | 没有（安卓用 WebView 嗅探） |

代码在 `client/android/app/src/main/kotlin/tvbox/next/tvbox_client/engine/`：

- **播放缓存**（`AndroidStorage.streamCache`）：`StreamStore` 带 `reserveBytes = 500 MB`。它算容量时还看磁盘剩余：快放不下时先删自己最旧的文件（不到上限也删）；删光了剩余也不够时 `lowOnSpace()`，`StreamCache` 不再缓存新分片、不预读，播放器要的分片 302 到片源。放在 `cacheDir` 里，系统清理缓存时删掉的文件，`StreamStore.file` 会发现并当作没缓存。这一版之前安卓没有播放缓存，所以第一次启动时把设置里没人改过的 2048 MB 改成 1024 MB（`files/engine/.android-cache-default` 标记只做一次）。
- **离线下载**（`AndroidStorage.downloads`）：下载库在 `getExternalFilesDir(null)/downloads`（`Android/data/<应用>/files/downloads`，不要权限，卸载时一起删），和播放缓存分开（缓存目录会被系统清理）。没有能随便填的路径，所以 `DownloadManager` 的 `locations` 列出各个存储卷上应用自己的目录（内部存储、SD 卡、U 盘，`getExternalFilesDirs`），客户端给下拉框。导出不给路径时走 `publish`：`AndroidExports` 在 Android 10 起用 MediaStore 写进 `Download/映舟/`（`IS_PENDING` 写完再公开，重名时用系统给的名字），更早的版本写进 `Android/data/<应用>/files/Download/` 并用 `FileProvider`（`${applicationId}.exports`）给出 `content://` 地址；返回的 `uri` 由客户端经 `yingzhou/android` 通道交给分享面板（`AndroidChannel`）。连的是别的设备上的引擎时，`saveExport` 由原生代码直接把 `/dl/<id>/export` 流进 MediaStore，不经过临时文件。
- **前台服务**（`EngineKeeper` + `EngineService`）：安卓会杀后台进程。`EngineKeeper` 盯着两件事——有排队或正在下的下载（`DownloadManager.changes`）、局域网共享开着（`LanListeners` 的 `onSharing`）——有活时启动前台服务，没活时服务自己停掉。服务类型：下载 `dataSync`，共享 `connectedDevice`（Android 14 要求声明类型和对应的 `FOREGROUND_SERVICE_*` 权限；`connectedDevice` 还要 `CHANGE_NETWORK_STATE`）。通知：下载进度条、速度，「暂停 / 取消」（多集时「全部暂停 / 全部取消」，取消会删掉没下完的文件）；共享时「局域网共享中」、地址、配对码（`VISIBILITY_PRIVATE`，锁屏上不显示内容）和「停止共享」。通知最多每秒更新一次。服务运行期间持有 `PARTIAL_WAKE_LOCK` 和 Wi-Fi 锁，息屏后下载和其他设备的请求不断。Android 13+ 第一次需要服务时（第一次下载或第一次打开共享）在当前 Activity 上请求 `POST_NOTIFICATIONS`，只问一次；不给权限服务照样运行，只是看不到通知。Android 12+ 不允许后台启动前台服务（例如 App 不在前台时配对设备远程加了下载）：这时只记一行日志，进程活着就照常下载。Android 15 的 `dataSync` 每天 6 小时上限到了（`onTimeout`）时，只剩共享就改成只有 `connectedDevice`，否则停掉服务。后台播放不在此列。
- **局域网共享**（`AndroidLan`）：`AccessControl(supported = true)` 加上 `LanListeners`（与桌面共用，`engine/api/.../access/LanListeners.kt`）：打开后在每个局域网 IPv4 地址上各起一个 CIO 监听（端口 9978，路由相同），关闭就全部停掉，`127.0.0.1` 上的监听不受影响。地址只取 Wi-Fi 和以太网（`ConnectivityManager`），手机不会在移动数据网络上监听。网络变化（`registerDefaultNetworkCallback`）和每 15 秒重新检查地址。mDNS 用系统的 `NsdManager`（`NsdAnnouncer`：`_tvbox-engine._tcp`，TXT `protocol=1`、`name`；一个注册覆盖所有接口，地址变了重新注册，失败了下一轮再试）。名字是"映舟 · 设备名"（`Settings.Global.DEVICE_NAME`，没有就用型号）。共享开关保存在引擎数据里，App 下次启动时照样打开。

### 2.3 jar 蜘蛛（Android 与桌面共用，已实现）

- `engine/jar-host/java/com/github/catvod/`：jar 编译时依赖的 TVBox 宿主类（`crawler.Spider`、`SpiderApi`、`net.OkHttp`、`Proxy` 等），包名与签名必须保持一致；`tvbox.engine.jarhost.HostBridge` 给它们提供 Context 与端口。
- `JarSpiderRuntime`（`engine/jar-host/kotlin`）：全局 `spider` 或站点 `jar`（`JarRepository`：`img+`、`;md5;`、`clan://`，缓存 7 天），每个 jar 调一次 `Init.init(Context)`，类名 `com.github.catvod.spider.<api 去掉 csp_>`；`/proxy` 先给 `siteKey` 对应蜘蛛实例的 `proxy()`，再依次给站点 jar、最近使用的 jar、其他 jar 的静态 `Proxy.proxy(Map)`。
- 桌面 / NAS（`engine/runtime-jar`）：进程内 dex2jar 转换（按内容哈希缓存，多 dex，保留 assets 等资源），以父优先的 `URLClassLoader` 加载，父加载器提供安卓桩类（`src/main/java/android/**`，源自 Win-box，MIT）、宿主类、AOSP 版 org.json、androidx.collection。蜘蛛运行时再 `new DexClassLoader(...)` 加载的 dex 也走同一个转换器。
- dex2jar 产物修复（`ClassRepairs`）：`invoke-super` 被转成自递归 `invokespecial` 的改指父类；R8 删掉构造器后被误译成「`NEW` 祖先类」的实例化，按 dex 里的 `new-instance` 改回真实类型并补合成构造器。转换时会列出 jar 用到但桩类缺失的安卓类，方便补齐。
- 转换后的类不保证过 JVM 校验器（安卓也不校验），桌面引擎用 `-XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote` 启动。
- jar 里的解析器（`JarParsers`）：type 2 调 `com.github.catvod.parser.Json<url>.parse(jxs, url)`，type 3（「Json聚合」）调 `Mix<url>.parse(jxs, name, flag+"111", url)`，参数与 TVBox 一致（JSON 解析带 `ext` 时以 `cat_ext` 拼进地址）；先找最近用过的 jar，再找全局 `spider`。返回 `parse=1` 时交给嗅探。
- 伪装成图片的 jar（`img+` 前缀，或 `.png` 后面直接拼 jar）会被解包；`;md5;` 校验的是下载的原始文件。
- 尚未支持：加固 jar（native 壳，计划 unidbg）。

### 2.4 网页嗅探（已实现）

解析链遇到 type 0 解析或 `parse=1` 的页面时，由引擎自己嗅探（`Sniffer`），判定规则同 TVBox：`PlayRules` 解析配置 `rules`（`host`+`rule`/`filter` 正则、`hosts`+`regex` 里非广告的条目、`exclude`），再加内置视频地址正则；`hosts`+`script` 的点击脚本在页面加载后执行。桌面 / NAS 用无头 Edge/Chrome/Chromium（CDP，独立 profile，关闭站点隔离以便同一会话看到播放器 iframe 的请求；首次嗅探时启动，空闲 5 分钟、引擎退出、或上次被强杀时残留的都会关掉；`TVBOX_BROWSER` 可指定浏览器）。没有浏览器时 `capabilities.sniff=false`，返回 `kind=sniff` 给客户端。

### 2.5 解析与去广告（已实现）

- 默认解析器与 TVBox 一样取配置里的第一个（没有 jar 运行时就跳过 type 2/3）；它失败时再并发尝试所有 JSON 解析接口。
- HLS 经引擎的 `/m3u8` 播放：`M3u8Cleaner` 按配置 `rules` 里 `hosts`+`regex` 的广告规则去掉广告（`#EXT…` 正则删除匹配段；数字按 DISCONTINUITY 块的首段或总时长匹配，`-n` 匹配末段，规则来自 Box / TVBoxOS），再用保守的启发式去掉夹在 DISCONTINUITY 里、来自少数路径的分片；删除超过一半时放弃、保留原列表。
- 站点的 `categories` 只保留并按顺序排列这些分类。

#### 播放缓存：拖动进度条不再回片源（已实现）

问题：片源慢的 m3u8，播放器每拖一次进度条就要重新连片源、把落点所在的分片从头下载到落点。libmpv 自己只在内存里留前后各约 32 MB（2 Mbit/s 的片约两分钟），出了这个范围、或者看得久了被挤掉的部分，每次都要重新下载。

在本机用演示引擎的慢速片源实测（`client/integration_test/seek_test.dart`，真实的 Windows 应用；片源每个请求 400 ms 后才应答、新连接再多 300 ms、每个连接 500 kB/s；视频 2 Mbit/s、每段 6 秒；2026-11-19）：

| 操作 | 改动前 | 改动后 |
|---|---|---|
| 跳到预读过的位置（前方 24 秒） | 0.09 秒 | 0.09 秒，片源 0 请求 |
| 跳回看过的位置（后退 70 秒） | 0.06 秒 | 0.11 秒，片源 0 请求 |
| 跳到没缓存的位置（落在分片的 3/4 处） | 3.4 秒 | 1.6 秒 |
| 回到之前跳去看过的位置 | 0.10 秒 | 0.15 秒，片源 0 请求 |
| 两分钟、几次跳转之后回到开头 | 3.3 秒（已被挤出内存，重新下载） | 0.19 秒，片源 0 请求 |
| 按住进度条拖 2 秒再松手 | 播放器跳转 8 次，片源 6 个请求（4 个中途作废），松手后 3.1 秒 | 跳转 1 次，松手后 1.2 秒 |
| 应用内存（调试构建，提交量，跑完这一轮时） | 683 MB，其中 libmpv 缓存 64 MB | 651 MB，其中 libmpv 缓存 32 MB |
| 引擎内存（提交量） | 约 130 MB | 约 160 MB |

改动前"缓存内"的跳转本来就快，慢的是出了内存那一小段范围的所有情况；改动后凡是取过的都在磁盘上。

做法分两层：

- **引擎的流缓存**（`engine/core/.../cache`）。`HlsRewriter` 把点播的媒体播放列表改写成指向引擎的 `/hls/<播放列表>/<编号>.<扩展名>`（分片、密钥、初始化段；字节范围收进引擎一侧）；`StreamCache` 负责取和供；`StreamStore` 是磁盘上有容量上限的文件库。
  - 取过的文件直接从磁盘给，不再问片源。
  - 播放器连续往下要了两个分片之后（说明是在看，不是只探一下），引擎开始自己提前取后面的内容：先取 30 秒，播放器每再往下走一个分片多取 15 秒，最多约 3 分钟；跳转之后重新算。同一片源最多 4 个连接（强制 HTTP/1.1：慢的片源通常是按连接限速，HTTP/2 上并发的请求会共用一条连接的速度），连接留着复用。
  - 只被看了一眼的流不预读：多码率的主列表，播放器会把每一档的头两个分片都打开、读一点、再选定一档。没被选上的那几档，播放器一松手，没取到一半的下载就放弃（最初的实现里每一档都预读 3 分钟，一分钟的测试就存下了 274 MB）。
  - 播放器正等着的分片（跳转落点，以及落点之后它紧接着要的那几个）怎么取，看片源是哪一种慢。引擎边取边量两个数：一个连接单独在跑时每毫秒到多少字节，几个连接同时跑时各自到多少。
    - **慢在每个连接限速**（几个连接合起来比一个多，或者还不知道）：落点所在的分片按字节范围拆成几块，用全部连接并行取——片源情况未知时先单独取开头 256 KB（它的应答说明文件多大、支不支持 `Range`，它的速度就是"单独一个连接"的速度），再把剩下的拆开；已经知道片源支持 `Range`、也知道这个流的分片大概多大时直接全部拆开，最后一块取到文件结束为止。落点之后的分片：单个连接够快（超过视频码率的 1.5 倍）就和预读一样整个取、几个并行，总量最大，数据也连续不断（libmpv 要等手头那次读取返回才处理新的跳转，数据一断它就迟钝）；不够快就一次一个、按播放顺序、每个都拆开取，否则单连接下载一个分片比播放它还慢，刚跳过去就会卡。
    - **慢在线路本身**（几个连接合起来也不比一个多，比如用户自己的带宽是瓶颈）：拆开只会互相抢，所以播放器等的分片一律整个取、一次一个、按播放顺序。
    - 两种情况下，播放器等着某个分片时，这个流其他已经在下载的分片都停下不读（没人读，片源那头自然就不发了），最多让 6 秒；预读等播放器不再等了才继续。
  - 对播放器先应答、后取数据：ffmpeg 的 HLS 读取器在读当前分片之前会先把下一个分片的请求发出去并等它的应答头，直连慢片源时等于每次跳转多等一次建连和首字节；引擎立即应答就没有这一步。还在路上的文件边到边转发。
  - 缓存按"哪一集"归档（站点、线路、剧集的哈希，经 `/m3u8` 的 `k` 传递），文件按它在片源的路径命名，不带域名和查询串——下次解析出的地址换了 CDN 或 token 照样命中。同一路径只有查询串不同的播放列表（一个脚本吐所有分片）才把查询串算进名字。
  - 片源不给引擎（403、连不上）时让播放器自己去取（302）；一个流刚开始就连续两次失败，10 分钟内整个流不经缓存。
  - `StreamStore` 的约定：`<流>/<文件>` 是完整文件，`.part` 是没取完的（重启时清掉），最近使用时间记在文件的修改时间上，超过上限从最久没用的删起。被"钉住"的流不参与清理、不计入上限——以后做离线下载时，一个下载就是一个取全了并且钉住的流，播放时走同一条 `/hls` 路径。只用 `java.io`，Android 7 也能跑（Windows 上不能给打开着的文件改名，所以读者没关之前文件一直以 `.part` 的形式供应）。
- **客户端**。进度条（`pages/seek_bar.dart`）松手才跳、只跳一次，拖动时显示落点时间，并画出已缓冲的范围（播放器自己持有的，加上向引擎问来的 `/stream-cache/coverage`）。`PlayerCache` 在每次打开视频前按来源配置 libmpv：经引擎缓存的流只在内存里留前 24 MB、后 8 MB（之前是各 32 MB）；其他网络视频（直链 mp4 / flv、引擎不缓存的流）在桌面上把缓存放进临时文件（`cache-on-disk` + `demuxer-cache-dir`；media_kit 默认开了 `cache-on-disk` 却没给目录，实际一直在用内存），读过的部分在这一集关闭之前都能跳回去，预读五分钟，文件超过 4 GB 就在原位置重新打开一次。

没做的：不是 HLS 的直链没有经引擎做分块缓存（那样才能跨次保留、多连接预读），目前只靠播放器的缓存文件。安卓内置引擎的容量策略见 2.2。

#### 离线下载（已实现）

下载在引擎里排队、由引擎下载（`engine/core/.../download/DownloadManager.kt`），所以 NAS 上的引擎替所有设备下载，下完哪台设备都能离线看。它建在播放缓存的文件库上，不另起一套：

- **一个下载 = 一个取全了并且钉住的流**。HLS 的分片、密钥、初始化段写进 `StreamStore`，文件夹名和文件名跟播放缓存给这一集起的完全一样（`k` + 播放列表路径的哈希；文件按片源路径命名）：看过、预读过的部分直接算进下载，下载中的那一集照常在线播放时和播放缓存共用文件；钉住的流不参与容量清理、不算进容量、"清空缓存"不删（`/stream-cache` 的 `pinnedBytes` 单独计数）。用户另选下载目录时，那个目录有自己的 `StreamStore`（全部钉住）；每个下载记住自己在哪个库里，换目录不搬旧的。
- 下载自己写文件，不经 `StreamCache` 的下载逻辑（那套是为"播放器正在等"设计的：抢占、让路、拆块）：每个文件先写到流目录里的工作文件 `_dl-<名字>.part`，取全后用 `StreamStore.adopt` 收进库里。播放器同时让播放缓存取同一个文件时两边各写各的临时文件，先完成的那份留下，不会互相截断。`.part` 工作文件在下次启动时被库清掉；直链下载的工作文件 `_dl-file.partial` 不以 `.part` 结尾，重启后保留，接着用 `Range` 往下下。
- **每次开始都重新解析**（`Engine.resolvePlay`，解析接口、嗅探与播放相同）：播放地址会过期，所以排队时只存"哪一集"（站点、线路、剧集 id），不存地址。`/play/resolve` 返回的 `/m3u8?url=&h=&k=` 被拆开：`url` 和 `h` 是要去取的播放列表和请求头，`k` 用来算播放缓存的文件夹名；广告按配置规则去掉（`Engine.cleanPlaylist`，和 `/m3u8` 同一个 `M3u8Cleaner`），然后 `HlsRewriter` 列出全部文件。没有 `#EXT-X-ENDLIST` 的拒绝（直播）。直链地址先取开头：是 `#EXTM3U` 就转去按 HLS 下载，否则按文件下载（类型看文件头：`ftyp`、`FLV`、EBML……）。
- **失败分两种**：断线、5xx 在原地重试几次（间隔 1、2、3 秒）；4xx、拿到的是网页（"地址已过期"页常是 200）、密钥不是 16 字节，算片源拒绝：整个下载重新解析一次再接着下，已下的保留；再拒绝才停下，原因写进 `error`。一个分片失败时同一下载的其他连接立即停下，不等超时。
- **离线播放**：`resolvePlay` 在问站点之前先问 `DownloadManager.offlinePlay`：同一集有完成的下载、文件都还在，就返回 `/dl/<id>/index.m3u8`（下载时把改写后的播放列表连同文件清单存在流目录的 `_download.json` 里，地址处是占位符，请求时换成请求者用的引擎地址）。`/dl/` 不在 `/api/` 下，和 `/hls/` 一样由 `AccessPlugin` 给局域网播放器签名。整个过程不碰网络，启动和拖动都只读磁盘。
- **队列**：`downloads.json`（引擎数据目录）存下载列表和设置，状态变化时立即写，下载中每 5 秒写一次进度；`--demo` 不带 `--data` 时只在内存里。引擎启动时，上次在下载的回到排队，等订阅恢复（`Engine.config()`）后再开始。最多同时 `concurrency` 个下载（默认 2），每个下载 4 个连接。进度和速度在内存里算，`/downloads/events`（SSE）在有变化时推送整张列表，客户端也可以轮询 `/downloads`。
- **导出**（`DownloadExport`）：按保存的播放列表把文件顺序拼起来——MPEG-TS 分片拼成 `.ts`（AES-128 用 `javax.crypto` 解密，IV 按 HLS 的规则），fMP4 拼成 `.mp4`（初始化段在前）。写之前先检查每个分片的开头（加密的只解第一个块），不是 0x47 就整个拒绝，不会写出半截文件。转成普通 mp4 要 ffmpeg，不附带、不安装。
- 安卓内置引擎也能下载，存储位置、导出和保活见 2.2。

没做的：多音轨 / 字幕轨单独成流的 HLS 只下视频那一档；直链没有多连接分块下载；下载之间没有优先级（按加入顺序）。

### 2.6 直播与节目单（已实现，桌面优先）

- 引擎 `live` 包：`LiveSourceSpec` 解析 `lives` 的几种写法，`LivePlaylistParser` 解析 TXT / M3U，`Epg` 处理模板接口与 XMLTV 和频道名规整，`LiveService` 负责缓存（列表半小时、模板节目单半小时、XMLTV 6 小时）。不用 `java.time`，Android 7 也能跑。
- 客户端「直播」页：宽屏为 分组 | 频道（带当前节目和进度）| 播放器 + 节目单；窄屏上下堆叠。↑/↓ 换台（跨分组）、←/→ 换线路、PageUp/PageDown 换分组、F 或双击全屏（频道列表变成浮层）、M 静音、滚轮音量。线路报错或 15 秒没有画面就自动换下一条；记住上次看的频道；离开该页即停止播放，播放器在第一次打开该页时才创建。
- 蜘蛛直播（`type: 3` + `api`）：向 jar 蜘蛛要 `liveContent(url)`、向 JS 蜘蛛要 `live(url)`（`JsSpider.live`，没写 `url` 时传脚本地址），按同样的格式解析。列表也可以是 JSON。指向 TVBox 内置服务（`127.0.0.1:9978/proxy`）的地址改指本引擎；蜘蛛给出的列表里，这类地址由 `LiveService` 补上 `siteKey`（`live_<直播源名>`，蜘蛛就注册在这个 key 下），`/proxy` 才能把请求交回给出列表的那个蜘蛛，而不是 TVBox 那样交给"最近用过的"。
- 回看（`Catchup`）：解析时把每条线路的回看规则（M3U `catchup*` 属性，头上的作为默认；JSON 频道的 `catchup`；`lives[].catchup`）挂在 `LiveUrl.catchup` 上（不序列化，留在引擎），列表里每个频道只下发 `catchupDays`。`/live/{i}/catchup` 按规则和时间段拼出地址（类型 `default` / `append` / `shift` / `flussonic` / `xc`，TVBox 与 Kodi IPTV Simple 的占位符），先给所选线路，其余作为 `alternates`。时间用中国时间、`SimpleDateFormat`，不用 `java.time`。客户端在有回看的频道的节目单上方列出可回看的日期，点已结束的节目进入「回看」状态（进度条、`←/→` 快退快进），「回到直播」/ Esc / 换台回到直播；回看地址播不了时依次试 `alternates`。
- Python 蜘蛛直播同 jar 蜘蛛，问 `liveContent(url)`（见 2.10）。

### 2.7 配置体检（已实现）

`tvbox-engine --check <订阅…>`（`tools/check-configs.sh`）用同一个引擎把订阅里的每个仓库、站点、直播源走一遍并出报告，失败按"引擎兼容 / 不支持 / 网络 / 站点报错"归类。`--demo --check --strict` 是自检：打包脚本在裁剪完 Java 运行时后用它跑一遍演示配置（采集站、JS、jar、嗅探、直播），不通过就不出包——精简运行时缺模块（曾经漏了 `jdk.zipfs`，导致所有 jar 蜘蛛失败）会在这里被拦下。

HTTPS 与 TVBox 一致，不校验证书（`LenientTls`），`--strict-tls` 恢复校验。

### 2.8 配置的网络项与 DNS（已实现）

`core/net/ConfigNetwork` 持有当前配置的 `hosts` / `headers` / `doh` / `ads` 和使用者选的 DoH 服务器，并把三样东西装到引擎唯一的 OkHttp 客户端上（`install`）：一个 `Dns`（先按 `hosts` 换名字，目标是 IP 就直接用；选了 DoH 就问它，问不到退回系统 DNS）、一个网络拦截器（按域名加 `headers`，重定向后的请求也经过）、一个自己的连接池（规则一变就清掉空闲连接，新规则不必等旧连接过期）。引擎里所有发请求的地方——`ConfigLoader`、`SiteHttp`、`JsHttp`、`JsModules`、`JarRepository`——都从这个客户端派生，所以不用逐处接。jar 蜘蛛的宿主类 `com.github.catvod.net.OkHttp` 通过 `HostBridge.baseClient` 也从它派生（保留 TVBox 的 30 秒超时，用单独的 `Dispatcher`，免得蜘蛛 `cancelAll()` 连带取消引擎的请求），`OkDns` 先查蜘蛛自己加的表，再问引擎的 `Dns`。

`Engine.activate` 在新配置生效的同一处调用 `onConfig`；DoH 的选择是 `EngineSettings.doh`，引擎启动时在取任何东西之前就应用。交给播放器的请求头（`PlayInfo.headers`、直播线路）在 `Engine` 里按媒体地址的域名补上。`CdpSniffer` 把 `hosts` 作为 `--host-resolver-rules` 传给浏览器（规则变了就重启浏览器），`ads` 用 `Network.setBlockedURLs` 屏蔽。

播放器自己发的请求不经过引擎，所以 `hosts` 和 DoH 管不到媒体流；要管到，需要让媒体经引擎转发（或给 mpv 配一个由引擎提供的 HTTP 代理），还没做。

### 2.9 数据缓存（已实现）

目的：打开就能用，源慢或断网时还能翻看过的内容。三层，各管各的：

- **配置副本**（引擎，`core/cache/DataCache` 的 `config` 区）：`ConfigLoader` 每次下载并解析成功后，把原始文本按订阅地址存一份（多仓的每一层、最终的配置各一份）。`Engine.restore` 先在"只读副本"模式下走一遍和平时完全相同的激活流程（`LoadTrace(stored = true)` 作为协程上下文带着走，`load` 据此决定读副本还是走网络），所以多仓、嵌套多仓不需要另写一套；然后在后台把这次用到的每个地址重新下载，文本的哈希都没变就只更新时间，有变就正常 `activate` 一次换掉，失败就留着副本并把原因放进摘要。副本缺失或解析不了时退回原来的"等下载"。
- **站点数据**（引擎，`core/cache/SiteDataCache`，`site` 区）：`home` / `category` / `detail` 的规整结果序列化后保存，键是"配置指纹 | 站点 | 调用 | 参数"。配置指纹由订阅、选中的条目和这次加载到的所有文本的哈希算出，所以换订阅、订阅内容变了都自然失效，不需要显式清理。过期的先返回、后台刷新（同一个键同时只刷新一次）。直播列表（`live` 区）和 `ext` 文件（`ext` 区）是另一种策略：先走网络，失败才用保存的。
- **海报**（客户端，`ui/poster_cache*.dart`）：自己写的一个按地址存文件的 `ImageProvider`，没有用第三方缓存库（它们在 Windows 上要带 sqlite）。同一张图同时只下载一次，写临时文件再改名；超过上限时按最近使用时间删到八成。

`DataCache` 是"一条一个文件 + 内存里留最近用过的"，没有索引文件，崩溃不会留下不一致的状态；每个区有大小上限和最长保存时间，`config` 区除外（一个订阅一个小文件，启动要靠它）。演示模式（没有数据目录）只在内存里；`--check` 完全不带缓存。

### 2.10 网盘（已实现）

用户自己的视频，三种来源，代码在 `engine/core/.../drive/`：

- `DriveService`：网盘列表（`EngineStore.loadDrives/saveDrives`，JSON 存储里是 `drives.json`），增删改、测试连接、列目录、AList 文件夹密码、播放。对客户端只给 `DriveInfo`（有没有密码 / 令牌，不给值）。安卓内置引擎也有它，只是 `localFolders = false`。
- 三个 `DriveBackend`：`AListBackend`（AList v3 / OpenList 的 `/api/fs/list`、`/api/fs/get`，令牌或登录换来的令牌放在 `Authorization`，登录过期自动重登；文件夹密码按最近的上级文件夹取；播放地址是 AList 的 `/d/<路径>?sign=`）、`WebDavBackend`（`PROPFIND Depth: 1`，按本地名匹配元素，解析思路移植自 MisaTV；Basic 认证）、`LocalBackend`（只用于桌面 / 服务器）。
- 本机文件夹的路径安全：路径先规整，含 `..`、反斜杠、冒号的段直接拒绝；再逐段拼到文件夹的真实路径下，`toRealPath()`（跟随符号链接、联接点）之后必须仍在文件夹的真实路径里，否则 403；列目录时指向外面的链接不列出。添加本机文件夹只认本机的调用方，否则配对过的设备就能借此打开这台机器的任何目录。
- **文件夹即"片"**：站点键 `drive:<网盘 id>`、片 id 是文件夹路径、剧集是其中的视频（按名称、数字按大小排）。`EngineModule` 里 `/sites/{site}/detail` 和 `/play/resolve` 先问 `DriveService`（`driveDetail` / `drivePlay`，不是 `drive:` 站点时返回 null），其余照旧。于是播放页、选集、上下集、观看历史、续播、"我的"里的详情页不用为网盘改一行。
- **播放地址**：播放器能自己取的就给网盘的地址（AList 的 `/d/`、无账号 WebDAV 的文件地址）；要账号的、本机文件夹、设了"经引擎转发"的，以及网盘在回环地址而播放器在别的设备上时，给引擎的 `/drive/<id>/<路径>`。这条路由按单段 `Range` 读本机文件（`RandomAccessFile`），或把 `Range` 转给网盘并原样转回 `206`/`Content-Range`。它和别的引擎地址一样受鉴权拦截器保护，交给局域网设备时由 `forClient` 改写主机、由发送管道签名（`PlayInfo.subtitles` 的地址也在其中）。
- **字幕**：播放时列出视频所在的文件夹，同名（可再带语言标记，如 `第1集.zh.ass`）的 `srt/ass/ssa/vtt` 放进 `PlayInfo.subtitles`，地址的给法和视频相同。
- **演示**：`--demo` 时 `DemoDrive` 用 `DemoVideo` 现做几段几秒长的 TS 视频（每集从不同的分片开始，画面能看出是哪一集）加字幕，挂成一个演示 WebDAV（引擎自己的 `/demo/dav/`，账号 `demo` / `demo`）和一个写在临时目录里的演示本机文件夹。

没做的：网盘里的 m3u8 文件（相对地址的分片不会被签名，局域网设备会被拒）；搜索网盘；上传、删除等写操作；TVBox 配置里 `csp_AList` 站点 `ext` 的 `drives` 列表（那是 jar 蜘蛛自己的配置，由蜘蛛处理，见 compatibility.md）；不经 AList 直接登录阿里云盘、夸克、115 等。

### 2.11 Python 蜘蛛（已实现，桌面 / NAS）

TVBox 的安卓分支用 Chaquopy 把 CPython 嵌进 App；JVM 上没有对应物，所以引擎**另起一个 Python 进程**，用一行一个 JSON 的协议和它说话。应用不自带 Python：用本机的，或者用户点按钮下载的。

```
引擎（JVM）                                    Python 进程（worker.py）
PyRuntime ── SpiderRuntime(kind=py)            stdin  ← {"id","op":"load|init|call|proxy|destroy|net|setup",…}
  PySpider ── Spider（每个站点 / 直播源一个）   stdout → {"id","ok","result"|"error"}   （只走协议，ASCII）
  PyWorker ── 进程、按 id 配对的请求、超时        stderr → 引擎日志（蜘蛛的 print、Python 的报错）
PythonManager ── 找 Python、下载 CPython、pip 装包     base/spider.py（TVBox 的基类）、base/_host.py（引擎给的网络规则、HTTP、缓存）
```

- **模块**：`engine/runtime-py`（`tvbox.engine.py`）。Python 一侧的文件在 `src/main/resources/tvbox/py/`：`worker.py`（协议、线程池、把蜘蛛结果转成 JSON 文本、`localProxy` 的返回转成状态码 / 类型 / 响应头 / base64 正文）、`probe.py`（报告版本、pip、能导入哪些模块，不导入任何包）、`base/`（`spider.py` 基类、`_host.py`、`localProxy.py`、移植自 TVBoxOS 的 `htmlParser.py`）。引擎启动时把它们按内容哈希写到 `<数据目录>/python/bridge/<哈希>/`。路由在 `engine/server/.../PythonRoutes.kt`，演示用的三个脚本在 `engine/server/src/main/resources/demo/py/`。
- **一个进程，多个线程**：每个引擎一个 Python 进程，所有 Python 站点和直播源共用（TVBox 也是一个解释器跑全部），请求在 32 个线程的池里并发执行，回答按 id 对上。每个站点在进程里有自己的一份模块（同一个脚本被两个站点使用也互不影响，TVBox 基类"一个类一个实例"的约定照旧）。比起每个蜘蛛一个进程，省下的是内存（导入 requests + lxml 后一个进程约 30 MB）和启动时间（首次调用约 0.5 秒）；代价是一个蜘蛛弄崩进程会连累正在进行的其他调用——它们报 `PY_CRASHED`，下一次调用起新进程，`PySpider` 发现进程换了就把自己重新加载、初始化一遍。
- **进程的生命**：第一次用到 Python 蜘蛛时才启动（参数 `-E -X utf8 -u`：忽略 `PYTHON*` 环境变量、UTF-8 模式、不缓冲）。退出有三重保险：`PyRuntime.close` / JVM 关闭钩子 / 服务器的 `ChildProcesses` 杀掉它；引擎被强杀时管道断开，worker 读到 EOF 立即 `os._exit`。卡住的调用（超时后 Python 线程还在跑）超过 8 个就换进程；一分钟内启动 5 次还在崩就暂停并报错。worker 一开始就复制出真正的 stdin / stdout 给协议用，把文件描述符 0、1 指向空设备和 stderr，所以蜘蛛和原生库打印的东西都进不了协议。
- **网络规则**：引擎在每次调用前比较当前的规则（配置 `hosts` 和 `headers`——取自 `ConfigNetwork.hostRules()` / `headerRules()`——、GitHub 加速代理的开关和前缀、`--strict-tls`），变了就发一条 `net`。worker 里 `socket.getaddrinfo` 按 `hosts` 换名字（一步，同 TVBox，`*` 通配），`requests.Session.request` 被包一层：按域名加 `headers`、GitHub 地址按设置走代理（代理失败再直连）或去掉写死的代理前缀、没指定 `verify` 时不检查证书。基类的 `fetch` / `post` 在没装 `requests` 时用标准库实现同样的规则。DoH 不经过。
- **找 Python**（`PythonLocator`）：用户填的位置 → `TVBOX_PYTHON` → 本机（Windows 先 `py -3`，再 `PATH` 上的 `python3` / `python`，再 python.org 的默认安装目录，微软商店的占位 `python.exe` 放最后；macOS 加上 Homebrew 和 python.org 的目录，因为从访达启动的应用拿不到 shell 的 `PATH`，苹果自带的 `/usr/bin/python3` 只在装了开发者工具时才碰，否则一运行就弹安装窗口）→ 下载的 CPython。每个候选跑一遍 `probe.py`，第一个 3.8+ 的胜出；`py -3` 和 scoop 的 shim 换成它报告的真实路径。引擎启动时在后台找，`available`（也就是 `capabilities.py`）最多等它 5 秒。
- **下载 CPython**（只有 Windows）：固定版本 3.14.10 的官方免安装版（amd64 / arm64），大小和 SHA-256 取自 python.org 的发布页并写在代码里，所以换成镜像也安全。下到 `python/download.part`，边下边算哈希，大小或哈希不对就删掉；解压（防路径穿越）到 `runtime.new` 再改名成 `runtime`。没有用户在设置里确认就不会发出任何请求。
- **装包**（`pip install --target python/packages/<解释器标签> --upgrade --only-binary=:all: --no-input --cache-dir python/pip-cache -- <包>`）：每种解释器（`cp314-win_amd64` 之类）一个目录，换了 Python 不会加载到不兼容的二进制包；worker 把这个目录放在 `sys.path` 的最前面（免安装版的 `._pth` 不认 `PYTHONPATH`，所以由 worker 自己插）。只装 wheel，安装时不运行任何包的 `setup.py`。Python 没有 pip 时（免安装版就没有）先从同一个源的 simple 页面找到最新的、这个 Python 能用的 pip wheel，校验 SHA-256 后存到 `python/pip/`，用 `python pip.whl/pip install …` 运行。一次装多个失败时逐个重试，装好的留着，装不上的列出来。装完换一个 worker 进程，新包立即可用。包名只接受"名字 + 可选的版本条件"，挡掉 `--index-url` 之类的参数注入。
- **错误**：`SpiderLoadException` 多了 `code`，`Engine.describe` 原样交给 API：`PY_UNAVAILABLE`、`PY_MODULE_MISSING`（Python 一侧的 `ModuleNotFoundError.name`，以及 `from base.spider import *` 时代留下的 `requests` / `etree` 的 `NameError`）、`PY_CRASHED`。蜘蛛方法里抛的异常是 `PySpiderException`，归为站点报错。缺的模块记在 `PyRuntime` 里，经 `/python` 交给设置页。
- **能力随时变化**：`SpiderRuntime.available`（默认 true）表示"现在能运行"；`Engine.info` 改成每次现算，`capabilities.py = 有 py 运行时 && available`。聚合搜索跳过 `available=false` 的蜘蛛站点，直播源的 `supported` 也看它（`LiveService(moreSpiderKinds)`）。
- **安卓**：内置引擎不注册 Python 运行时，`capabilities.py` 永远是 false，没有 `/python` 接口；代码不需要改。
- **Docker 镜像**里没有 Python，NAS 上 Python 站点暂时打不开（要在 `engine/Dockerfile` 里装 `python3` 和常用的包，还没做）。

## 3. 仓库结构

```
tvbox-next/
├─ docs/                    设计文档
├─ engine/                  Kotlin/JVM（Gradle 多模块）
│  ├─ core/                 纯 JVM、可在 Android 上运行：模型、配置、站点分发、采集站、搜索聚合
│  ├─ api/                  协议 v1 的 Ktor 路由，独立进程与 Android 内置引擎共用
│  ├─ server/               独立进程入口（桌面内置 / Docker），Ktor CIO
│  ├─ runtime-js/           QuickJS 宿主：移植 TVBox 的 Global/Req/Crypto/HtmlParser 等宿主函数
│  ├─ jar-host/            TVBox 宿主类与 jar 运行时，Android 与桌面共用（源码目录，被两边编译）
│  ├─ runtime-jar/         桌面/服务器 jar 运行时：dex2jar 转换与修复、安卓桩类
│  └─ runtime-py/           Python 蜘蛛：在一个 Python 子进程里运行（桌面 / NAS，见 2.10）
├─ client/                  Flutter 客户端
│  └─ android/              Android 宿主工程，以 Gradle 复合构建引入 engine/core + runtime-*
└─ tools/                   打包脚本
```

### 3.1 引擎技术选型

| 关注点 | 选择 | 理由 |
|---|---|---|
| 语言 | Kotlin，字节码目标 JVM 17 | 同一份代码跑在 HotSpot 和 Android ART 上 |
| HTTP 服务 | Ktor（CIO 引擎） | 纯 Kotlin，JVM 与 Android 都能跑 |
| HTTP 客户端 | OkHttp 4.x | 与 TVBox 和 jar 蜘蛛使用的一致；4.x 仍保留 3.x 的 Java 签名 |
| HTML | Jsoup | `pdfh/pdfa` 与安卓版同一个实现，行为一致 |
| TVBox JSON | Gson（宽松模式） | 与安卓版解析行为一致（配置里常见不规范 JSON） |
| 我们自己的 API | kotlinx.serialization | 类型安全 |
| JS | QuickJS（JNI），全平台同一个引擎 | 与安卓版一致；可缓存字节码 |
| 存储 | `EngineStore` 接口；目前是 JSON 文件（`JsonFileStore`），数据量大了再换 SQLite | 历史、收藏、进度、订阅 |

### 3.2 引擎核心模块（engine/core）

- `config`：订阅拉取与解密（`FindResult` 的三种格式：图片藏 base64 `**`、`2423` AES-CBC、`;pk;` AES-ECB）、`clan://` 与 `file://` 路径、多仓 `urls`、`sites / parses / lives / hosts / rules / doh / flags / ads / spider / wallpaper / danmaku` 字段。
- `site`：`SiteSource` 接口，四种实现：
  - `CmsXmlSource`（type 0）、`CmsJsonSource`（type 1）：`ac=videolist / detail`。
  - `SpiderSource`（type 3）：按 api 后缀分发到 js / py / jar 运行时。
  - `RemoteSpiderSource`（type 4）：HTTP 远程蜘蛛。
- `model`：规整后的影片、分类、筛选、线路、剧集；`TvboxCompat` 负责与 TVBox JSON 互转。
- `search`：聚合搜索调度（并发上限、每源超时、按片名+年份合并）。
- `live`：直播源与节目单（见 2.6）。
- `drive`：网盘（AList / OpenList、WebDAV、本机文件夹，见 2.10）。
- `play`：播放解析链（直链 / 解析接口 type 0–4 / `jx` / VIP flags）；需要嗅探的页面交给平台的 `Sniffer`（见 2.4），没有时转交客户端。
- HTTP 路由在独立的 `engine/api` 模块，见 protocol.md。

## 4. 客户端（Flutter）

> 现状：单窗口外壳（首页、直播、搜索、我的、源）+ 详情页 + 播放页，桌面用 media_kit（libmpv），触控 / 鼠标模式；点播有字幕、音轨和弹幕（Flutter 图层）。安卓电视上有遥控器焦点模式（见下面"电视与遥控器"）。下面列的迷你播放器、桌面的画中画、`PlayerKernel` 抽象、弹幕的 mpv/ASS 渲染方式都还是计划。

- **单窗口 + 路由**：首页、分类、搜索、详情、播放、直播、历史、收藏、设置。支持迷你播放器与画中画。
- **两种交互模式**：触控/鼠标模式；遥控器焦点模式（电视）。组件共用，布局与焦点逻辑分开。
- **播放内核抽象** `PlayerKernel`：
  - 桌面：libmpv（media_kit），硬解（d3d11va / videotoolbox / vaapi）。
  - Android：ExoPlayer（官方 video_player）为默认，libmpv 兜底冷门格式。
  - iOS：AVPlayer 为默认，libmpv 兜底 mkv / flv 等。
- **字幕与音轨（已实现）**：引擎把站点给的 `subt` / `subs`（`core/play/Subtitles.kt`）变成自己的 `/subtitle?url=&h=` 地址，取的时候识别编码（`core/util/TextDecoding.kt`：BOM、UTF-16、UTF-8，否则 GB18030 / Big5 按常用字打分；gzip / deflate 按内容解压）并把 TTML、LRC、B 站 JSON 字幕转成 SRT（`SubtitleConverter`）；本地文件经 `POST /subtitle/convert` 走同一条路，所以客户端不需要任何编码库。桌面播放器开 libass（`PlayerConfiguration(libass: true)`），字幕由 libmpv 画进视频纹理，ASS 样式原样保留；大小、位置、时间偏移是 libmpv 的 `sub-scale`、`sub-pos`、`sub-delay`（`pages/player_tracks.dart` 的 `PlayerTracks`）。站点的字幕在选中时才 `sub-add`，之后按轨道 id 切换。选的字幕语言和音轨写进观看历史（`HistoryEntry.subtitle` / `audio`）。安卓不开 libass，由 media_kit 画纯文本。
- **弹幕**：引擎下发统一格式；客户端两种渲染：
  1. Flutter 图层（已实现）：文字预栅格化缓存、只绘制可见部分，兼容任何内核、可交互。
  2. 桌面 mpv 模式：转成 ASS 交给 libmpv 渲染，几乎零开销（未做，Flutter 图层已经够快，见下）。

#### 手机与平板（已实现）

- **设备形态**：用和电视共用的 `ui/device_form.dart`（`DeviceFormScope.of(context)` → `phone` / `tablet` / `tv` / `desktop`，规则和用户的"界面模式"见电视那一节）。手机和平板按**窗口**的短边分，小于 600 dp 是手机，所以分屏里的平板拿到手机布局。新加的触控行为只认 `isTouch(context)`（手机或平板），电视和桌面不受影响；播放页和直播页在第一次 `didChangeDependencies` 时决定要不要触控那一套。组件测试把要测的形态用 `DeviceFormScope.fixed(...)` 包在应用外面；`test/flutter_test_config.dart` 让没有包的测试按桌面跑（`DeviceFormScope.debugFormWithoutScope`，flutter_test 把平台报成安卓）。
- **外壳**：手机竖着时底部导航栏，平板和横着的手机用侧边导航栏（高度不够时可滚动、去掉顶上的图标）；状态栏和导航栏透明，图标颜色随主题；手机和平板跟随系统的浅色 / 深色，桌面和电视仍是深色。手机和平板上系统的"返回"在别的页签先回首页，在首页才退出（电视的返回由 `TvShell` 自己处理）。
- **页面**：海报墙 `PosterGridDelegate` 宽度不足 560 dp 时三列铺满（桌面的最小窗口也到不了这个宽度，桌面不变）。详情页窄屏时小海报和标题并排、按钮在下面，选集按钮按宽度铺满一行（至少三列）。订阅和引擎地址弹出网址键盘，搜索结果一滚动就收起键盘。
- **点播播放页**（`pages/player_page.dart` 加 `player_mobile.dart`、`touch_gestures.dart`）：
  - 布局：手机或平板竖着（且不全屏）时，16:9 的画面在顶上，下面是 `PlayerPhoneInfo`：片名、倍速 / 弹幕 / 字幕 / 小窗、线路、选集（52 dp 高的按钮，正在放的那集滚到眼前）；字幕和弹幕面板也在下面这块打开，不压在小画面上。横着或全屏时与桌面同一套层叠，控制条换成 `TouchPlayerBars`（48 dp 按钮，放不下的按钮横向滚动），左边多一个锁。画面和控制条挂在一个 `GlobalKey` 下，竖屏 / 全屏 / 画中画之间切换时视频组件不重建。
  - 手势（`TouchGestureLayer`，是控制条的兄弟层而不是父层，按钮不用等双击判定）：单击显示 / 隐藏控制条（桌面的"单击暂停"在触屏上不用）；双击左三分之一快退 10 秒、右三分之一快进 10 秒、中间暂停 / 继续，连续双击累加；左右拖动预览目标时间，松手才跳一次，划过整个画面宽度是三分钟（片子更短就是整片）；左半边上下拖是本窗口亮度，右半边是系统媒体音量（拖过画面高度的 80% 从无到满）；长按 2 倍速，松手恢复；锁住时只有单击（叫出锁）有用，返回手势也被拦下并提示。从屏幕边缘系统手势区开始的拖动留给系统（返回、通知栏）。
  - 全屏与转屏（`MobilePlayback`）：手机上横屏就是全屏——把手机横过来自动全屏（隐藏系统栏，`immersiveSticky`），全屏按钮把屏幕转成横向（竖的视频转成竖向），退出全屏转回竖向并锁住竖向到离开这一页，免得手机还横着就又转回全屏；平板全屏只隐藏系统栏并转横，退出后恢复自由旋转。系统返回依次：解锁提示 → 关面板 → 退出全屏 → 离开页面。离开页面时恢复系统栏、所有方向和系统亮度。
  - 常亮与后台：播放中保持屏幕常亮（`FLAG_KEEP_SCREEN_ON`），暂停或离开就取消；没进画中画就切到后台（应用被隐藏）时暂停。
  - 画中画：播放中离开应用（上滑回桌面、最近任务）自动缩成小窗，只剩画面（控制条、锁、提示、弹幕都不画）；小窗里有一个播放 / 暂停按钮；小窗被关掉时应用随即被隐藏，于是按上一条暂停。安卓 12 起用 `setAutoEnterEnabled`，8–11 在 `onUserLeaveHint` 里 `enterPictureInPictureMode`；控制条和竖屏操作区里也有"小窗"按钮（设备支持时才显示）。宽高比跟着视频。
- **直播页**：手机竖着时画面在上，下面是正在播放的节目、频道 / 节目单两个页签（源、分组、频道在第一个页签）；横过来自动全屏，全屏时单击叫出左侧频道列表（带分组）和右上角的小窗、退出全屏按钮。手势：单击显示控制、双击暂停、左右滑动换上一个 / 下一个频道（回看时改为拖动跳转、长按倍速）、上下拖动亮度 / 音量。画中画、常亮、切后台（直播是停下，回来时重新调台）同点播。
- **原生一侧**：`MainActivity` 在 `configureFlutterEngine` 里多注册一个通道、转发 `onUserLeaveHint` 和 `onPictureInPictureModeChanged`；`PlaybackChannel.kt`（`yingzhou/playback`：启动时的 `info`（是不是模拟器）、本窗口亮度 `screenBrightness`、`STREAM_MUSIC` 音量（不弹系统音量条）、常亮、画中画参数、小窗按钮用本应用内的广播 `RECEIVER_NOT_EXPORTED`）。没有新增依赖。
- **安卓上的播放**（`player_backend.dart`）：media_kit 在安卓上默认 `vo=gpu`（libmpv 的 OpenGL ES 画进 Flutter 纹理）、`hwdec=auto-safe`（解码器支持的流走 MediaCodec，不支持的退回软解，所以 libmpv 能读的流都有画面，字幕和弹幕在所有设备上画法一样），并且在模拟器上强制软解。真机保持这个默认。模拟器（`-gpu swiftshader_indirect`）的 OpenGL 不接受 libmpv 要的上下文（logcat：`eglCreateContext: EGL_BAD_ATTRIBUTE`），画面一直是黑的、只有声音；所以**只在模拟器上**（`PlaybackHost.isAndroidEmulator`，启动时问 `PlaybackChannel`）改用 `vo=mediacodec_embed` + `hwdec=mediacodec`，由 MediaCodec 直接把画面送进视频的 Surface，不经过 libmpv 的 OpenGL（模拟器的 `c2.goldfish.h264.decoder`）。这样在模拟器上播放、跳转、转屏、画中画都有画面。
  - 没在真机上验证的：真机上 `auto-safe` 实际选的是 `mediacodec`（零拷贝）还是 `mediacodec-copy`、发热和掉帧，10 bit HEVC、杜比视界这类流，弱 GPU 的盒子上 `vo=gpu` 的开销（`mediacodec_embed` 更省但没有软解兜底，换不了解码器的流就没画面），以及刘海屏、折叠屏、各家系统对画中画和亮度的处理。

#### 弹幕（已实现）

- **引擎**（`core/danmaku/`）：`DanmakuParser` 把 B 站 XML、各种 JSON、弹幕 ASS 读成一种格式（毫秒、`scroll`/`top`/`bottom`、0xRRGGBB、B 站字号、文字），解压和编码识别与字幕共用 `TextDecoding`。`DanmakuService` 按顺序找一集的弹幕：播放结果里的 `danmaku`（`Engine.resolvePlay` 时按"站点 + 线路 + 剧集"记下）、配置的 `danmaku` 接口（`EngineSettings.danmakuConfigApi` 打开时）、使用者自己的接口（`danmakuApi`），结果在内存里按集保留 30 分钟。接口不内置任何第三方地址，两个开关默认都关。客户端经 `GET /api/v1/danmaku`（带令牌）取，所以局域网客户端不需要签名地址。
- **客户端**（`pages/danmaku_layer.dart`）：`DanmakuScheduler` 是纯计算（可单测）：滚动弹幕在视频时间里用 9 秒（除以速度设置）从右到左走完一屏，越长越快；一条轨道只在前一条完全进场、并且新的追不上旧的时才接新的，大字号占两条轨道；顶部 / 底部弹幕停 4 秒；没有轨道就丢掉（密集时保持可读）；跳转后把最近 9 秒内开始的弹幕放回它们此刻应在的位置。`DanmakuOverlay` 用帧时间戳（应用里是垂直同步时间，组件测试里是测试时钟）推算播放位置：播放器报的位置和推算差 120 ms 以上才校正、1.5 秒以上算跳转；暂停、缓冲时冻结，倍速按视频时间走。每条弹幕上屏时用 `TextPainter` 画一次（带描边）并 `toImageSync` 成纹理，之后每帧只是 `drawImageRect`；只有在播放且有弹幕时 `Ticker` 才运行，暂停时不重绘；整层 `RepaintBoundary` + `IgnorePointer`，在画面之上、控制条之下。屏蔽类型和屏蔽词在上屏时过滤，改了设置时把已在屏上的被屏蔽弹幕立即拿掉。
- **实测**（`client/integration_test/desktop_play_test.dart`，真实 Windows 应用，调试构建，演示引擎的《弹幕演示》：三分钟 3000 条，2026-11-19；窗口 1346×823 逻辑像素 = 2356×1441 物理像素，显示器约 144 Hz，帧由引擎按刷新率出）：

  | 20 秒内 | 帧数 | 构建 p50 / p90 / p99 / 最大 | 光栅化 p50 / p90 / p99 / 最大 | 超过 16.7 ms 的帧 | 屏上弹幕（平均 / 最多） |
  |---|---|---|---|---|---|
  | 弹幕开，窗口 | 2877 | 0.60 / 1.14 / 1.52 / 10.32 ms | 1.31 / 1.56 / 2.04 / 2.82 ms | 0 | 125 / 151 |
  | 弹幕开，全屏 3601×2252（10 秒） | 1454 | 0.50 / 1.06 / 1.74 / 12.12 ms | 1.22 / 1.51 / 2.15 / 3.14 ms | 0 | 103 / 141 |
  | 弹幕关（10 秒，对照） | 1220 | 0.21 / 0.69 / 1.33 / 14.96 ms | 0.31 / 0.56 / 0.75 / 1.47 ms | 0 | — |

  即同屏一百多条时每帧多出约 0.4 ms 构建、1 ms 光栅化。20 秒里上屏 388 条、因没有轨道丢掉 8 条。这是调试构建；发布构建只会更快。CPU 占用没有单独测。

#### 电视与遥控器（已实现）

电视上只有方向键、OK、返回和菜单键（有时还有数字、频道和媒体键）。组件和桌面、手机共用，电视只在几处换布局、加按键处理。

- **是不是电视**（`ui/device_form.dart`，和手机 / 平板会话共用）：`DeviceFormScope.of(context)` 给出 `desktop` / `phone` / `tablet` / `tv`。安卓经 `yingzhou/device` 通道（`DeviceChannel.kt`）问一次 `UiModeManager` 是不是 `UI_MODE_TYPE_TELEVISION`、有没有 `android.software.leanback` 和触摸屏；电视模式或"leanback 且没有触摸屏"算电视。「源 → 界面模式」（`pages/ui_mode_settings.dart`，设置项 `ui.form`）可以强制电视或触屏。桌面平台恒为 `desktop`。手机和平板按较短边 600 区分。
- **整个应用的外框**（`ui/tv/tv_app.dart` 的 `TvAppFrame`，`main.dart` 把它放在导航器外面）：电视上给 `MediaQuery.padding` 加约 5% 的过扫描边距（所有 `SafeArea` 自动避开，视频仍然铺满）、字放大 10%、`navigationMode: directional`（滑块只用 ←/→，↑/↓ 能离开）；BACK 映射成 `DismissIntent`（关菜单、对话框，和桌面的 Esc 一样），↑/↓ 映射成不忽略输入框的方向意图（单行输入框不然会吃掉 ↑/↓，焦点出不来）。非电视时这些部件都在但什么都不做，结构不变，切换模式不会重建导航器和页面。
- **焦点看得见**（`ui/tv/tv_focus.dart`）：`TvFocusRing` 在最上层画一圈品牌色（船身的珊瑚色描边 + 水波的黄色光晕）跟着当前焦点，适用于任何可聚焦的组件（按钮、标签、列表行、对话框、菜单），在绘制阶段读焦点组件的位置，所以滚动、动画中也贴着；切换焦点时滑过去。整屏大小的焦点（页面自己的按键处理节点）不画。`TvFocusable` 是海报、频道行这类"格子"：OK 激活、按住 OK / 菜单键另作处理、获得焦点时放大并自己画描边、在所在列表里滚到中间。`TvAutofocus` 让页面内容出来后焦点落到主要按钮上（详情页的播放、错误时的重试）。主题（`tvTheme`）把按钮、列表行的焦点底色换成更明显的珊瑚色。
- **方向键怎么走**：`TvTraversalPolicy` 改了 ↑/↓：先找那个方向上最近的一行，再在这一行里取水平方向最近的一个，像电视桌面那样；Flutter 自带的算法优先找和当前组件同一列的，所以从页面右侧的按钮往下会跳过从左边开始的一整行。↑ 之后再 ↓ 回到原来那个。←/→ 用 Flutter 的。焦点掉到空的作用域上（获得焦点的按钮被移走、输入框提交后放弃焦点）时，`TvFocusRing` 把它放回这个作用域里上次的组件或第一个组件。
- **输入框**（`ui/tv/tv_text_input.dart`）：Flutter 在输入框获得焦点时就弹出输入法，电视上焦点只是经过也会弹出来并占住方向键。电视上装一个什么都不做的 `TextInputControl`，平台输入法仍然连接但收到的类型是 `TextInputType.none`（安卓于是不显示键盘，实体键盘照样能打字）；在输入框上按 OK 时换回平台输入法，并让输入框重新连接一次，这次带真正的类型，键盘弹出来；焦点离开就换回去。
- **BACK 只算一次**：安卓在 BACK 抬起时、应用没处理这个键的情况下执行"返回"。关对话框、关面板的处理在按下时就完成了，抬起没人处理，Flutter 把它交还给安卓，安卓又返回一次（对话框关了，后面的页面也跟着退）。`TvAppFrame` 最外层的 `_BackKeyGuard`：按下传到它这里（说明应用里没人处理）时让抬起照常交给安卓，否则把抬起留下。手机、平板上同样生效。
- **主界面**（`ui/tv/tv_shell.dart`，`ui/shell.dart` 在电视上换成它）：左边一列大入口，焦点在页面里时只显示图标、焦点回到这一列时展开并盖在页面上（页面不重排）。这一列和页面各是一个 `FocusScope`，方向键碰到边时由 `_EdgeAwareDirectionalFocusAction` 在两者之间切换；进入页面时回到它上次的焦点（每页记一个），没有就取页面里第一个格子。BACK：页面 → 入口 → 首页 → 询问退出（`PopScope`）。焦点落到外壳的容器上（启动时外壳自己的 autofocus、页面里获得焦点的组件被换掉）时放回入口或页面。
- **页面**：海报可聚焦（桌面上只像悬停一样提示键盘焦点）；`TabBar` 的标签停留 350 ms 就切换（`tvTabFollowsFocus`，和 TVBox 的分类栏一样）；下拉菜单换成列表对话框（`showTvChoiceDialog`）；搜索页左边是字母数字键盘（`ui/tv/tv_keyboard.dart`）和输入法按钮，最近搜索存在客户端设置 `search.recent`；"我的"里的小删除按钮换成按住 OK / 菜单键。
- **播放页**（`pages/player_tv.dart`，`player_page.dart` 的 part）：页面的按键处理在电视上先交给 `_onTvKey`。画面有焦点时：OK 暂停、←/→ 快退快进（按住时目标越走越快，松开才 `seek` 一次——引擎的播放缓存和播放器都更喜欢一次跳转）、↑ 选集面板、↓ 控制栏（焦点在播放按钮）、菜单键设置面板（倍速、线路、字幕与音轨、弹幕、选集）、频道键 / 上下曲换集；焦点在控制栏或面板里时方向键交给焦点系统。侧面板打开时焦点进去（`PlayerSidePanel` 里的 `TvAutofocus`）。
- **直播页**（`pages/live_tv.dart`，`live_page.dart` 的 part）：电视上开始播放就进全屏；↑/↓ 和频道键换台，数字键按列表里的序号换台，OK 打开分组 + 频道列表（焦点所在的分组决定右边列哪个分组的频道），←/→ 换线路（只有一条线路时打开列表 / 节目单），菜单键节目单（可回看的频道能选前几天、OK 回看）。退出全屏是电视版的三栏（分组 | 频道 | 小画面 + 节目单）。行高固定，列表一打开就滚到正在播的频道。
- **启动器**：`AndroidManifest.xml` 已有 `LEANBACK_LAUNCHER` 和"不需要触摸屏"；横幅 `res/drawable-xhdpi/banner.png`（320×180）和 `drawable-xxhdpi`（480×270）由 `tools/brand/render-banner.mjs` 从 `docs/brand/yingzhou-banner.svg` 画出来。`DeviceChannel` 还关掉了安卓给获得焦点的视图画的默认高亮（整个 Flutter 视图外面一圈彩色框）。
- **测试**：`test/tv_focus_test.dart`（主界面、首页、详情、搜索、输入框、BACK）、`test/tv_player_test.dart`（播放页、直播页），用方向键、OK、BACK、菜单键驱动，检查每一步之后焦点在哪；各有一个桌面用例确认桌面按键没变。在模拟器上的看法见 [development.md](development.md) 第 13 节。

## 5. 安全

> 现状：局域网共享、配对码配对、令牌、签名媒体地址、mDNS 发现已实现（扫码配对还没有，输入 6 位配对码）。细节见 [protocol.md](protocol.md)"鉴权与配对"。

- **默认只有本机**。本机 = 对方是回环地址且 `Host` 是回环名（挡 DNS 重绑定）。安卓内置引擎永远只监听 127.0.0.1，也用同一套检查（`supported=false`，其他来源一律拒绝）。
- **局域网共享**是引擎里保存的开关（`access.json`），桌面应用在「源 → 局域网」里切换；`--lan` 强制打开并监听 0.0.0.0（NAS / Docker）。开关打开时，独立引擎（`engine/server/.../lan/LanSharing.kt`）在本机每个 IPv4 局域网地址上**另起一个监听**（同一套路由），127.0.0.1 上的监听始终不动，所以开关切换不会打断正在用引擎的应用，关闭时网络上什么都不监听（Windows 防火墙只在用户打开共享时才询问）。网络地址每 30 秒重新检查一次。
- **一个拦截器**（`engine/api/.../access/AccessPlugin.kt`，装在 `EngineModule` 的路由前面）决定每个请求：公开接口 → 本机 → 签名地址 → 共享关闭则 403 → 令牌 → 401。路由块本身不改，以后加的路由默认受保护。
- **配对**：6 位一次性配对码（10 分钟），连错 5 次锁定所有人的配对，时长翻倍到 15 分钟。令牌按设备命名、可撤销，引擎只存哈希。
- **播放器带不上请求头**：引擎把交给客户端的引擎地址（`/m3u8`、`/proxy`，HLS 主列表里的子列表）加上 HMAC 签名参数 `tvsig`，绑定路径、全部参数、设备和过期时间；撤销设备或关闭共享即失效。令牌从不进播放器的请求头（播放器会把请求头发给 CDN）。
- **发现**：引擎用 JmDNS 在每个局域网地址上通告 `_tvbox-engine._tcp`；客户端用 bonsoir（调用系统自带的 mDNS 服务：Windows DNS-SD、macOS Bonjour、安卓 NSD）。
- 客户端按引擎地址（scheme://host:port）在本地偏好里保存令牌，每个 API 请求带上；图片加载器只对来自该引擎的图片带令牌。收到 401 就回到配对窗口。
- 网盘 Cookie 等凭据只存在引擎所在设备。网盘（2.10）的账号、密码、令牌、文件夹密码存在引擎的 `drives.json` 里，API 只回答"有没有"；需要账号才能取的文件由引擎带上账号代取，账号不进播放器的地址和请求头，也不写进日志。本机文件夹只能由本机的调用方添加或改路径。
- 已知局限：请求经反向代理且代理把 `Host` 改成 127.0.0.1 时会被当成本机；Docker 桥接网络里所有请求都来自网关地址（不是本机），mDNS 也过不了桥接（用 host 网络或手填地址）；配对锁定可以被同网段的人故意触发（拒绝服务，不会泄露）。

## 6. 里程碑

当前状态见 [status.md](status.md)：M1 完成，M2 大部分完成。

| 阶段 | 内容 |
|---|---|
| **M1 能看**（Windows + Android） | 引擎：配置拉取/解密/多仓、type 0/1/4、JS 蜘蛛（QuickJS + 完整宿主函数）、规整模型、流式聚合搜索、播放解析（直链 + JSON 解析接口）、历史/收藏。客户端：首页、分类、详情、搜索、播放（media_kit / ExoPlayer）、订阅管理。Android 内置引擎，Windows 内置引擎子进程。 |
| **M2 兼容** | jar：Android `DexClassLoader`；桌面 dex 转换 + 安卓桩类（参考 Win-box `stubs-src`，MIT）。`/proxy` 与 `/proxyM3u8`、网页嗅探、直播 + EPG + 回看、电视焦点模式。 |
| **M3 好用** | 弹幕、字幕、Python 蜘蛛、DLNA、扫码配对与 mDNS、Docker 镜像、网盘（WebDAV / AList）、自动换线换源。 |
| **M4 全平台** | macOS、Linux、iOS / iPadOS 客户端；加固 jar 的 unidbg 支持。 |

**优先级（2026-11 起）：桌面优先。** Android 上已有原版 TVBox / 影视仓，本项目主要补桌面端：先 Windows，再 macOS。Android 构建保持可用，但不再单独为它做功能。macOS 的工程、签名配置和打包脚本已就绪（`tools/package-desktop.sh` 在 Mac 上出 DMG，或用 `.github/workflows/desktop.yml` 在 CI 上出 Apple Silicon / Intel 两个包），尚未在真机上验证。

## 7. 参考资料（不在本仓库内）

- `../TVBoxOS`（q215613905，AGPL-3.0）：协议行为的主要参照。
- `../Box`（takagen99，AGPL-3.0）：网盘、播放器等扩展。
- `../Win-box`（yagami-hue，MIT）：桌面 jar 运行的踩坑记录、安卓桩类、测试用例。
- `../MisaTV`（GPL-3.0）：Win-box 作者的 Flutter 重写，只参考思路，不搬代码。
- `../tvbox-ysc-config`：聚合的公开配置，用来统计真实配置里各种写法的占比（约 8 成站点是 jar 蜘蛛，`rules` 多为 m3u8 去广告）。
