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

没做的：不是 HLS 的直链没有经引擎做分块缓存（那样才能跨次保留、多连接预读），目前只靠播放器的缓存文件；安卓内置引擎没有接流缓存（要先定小存储设备上的容量策略）。

### 2.6 直播与节目单（已实现，桌面优先）

- 引擎 `live` 包：`LiveSourceSpec` 解析 `lives` 的几种写法，`LivePlaylistParser` 解析 TXT / M3U，`Epg` 处理模板接口与 XMLTV 和频道名规整，`LiveService` 负责缓存（列表半小时、模板节目单半小时、XMLTV 6 小时）。不用 `java.time`，Android 7 也能跑。
- 客户端「直播」页：宽屏为 分组 | 频道（带当前节目和进度）| 播放器 + 节目单；窄屏上下堆叠。↑/↓ 换台（跨分组）、←/→ 换线路、PageUp/PageDown 换分组、F 或双击全屏（频道列表变成浮层）、M 静音、滚轮音量。线路报错或 15 秒没有画面就自动换下一条；记住上次看的频道；离开该页即停止播放，播放器在第一次打开该页时才创建。
- 蜘蛛直播（`type: 3` + `api`）：向 jar 蜘蛛要 `liveContent(url)`、向 JS 蜘蛛要 `live(url)`（`JsSpider.live`，没写 `url` 时传脚本地址），按同样的格式解析。列表也可以是 JSON。指向 TVBox 内置服务（`127.0.0.1:9978/proxy`）的地址改指本引擎；蜘蛛给出的列表里，这类地址由 `LiveService` 补上 `siteKey`（`live_<直播源名>`，蜘蛛就注册在这个 key 下），`/proxy` 才能把请求交回给出列表的那个蜘蛛，而不是 TVBox 那样交给"最近用过的"。
- 回看（`Catchup`）：解析时把每条线路的回看规则（M3U `catchup*` 属性，头上的作为默认；JSON 频道的 `catchup`；`lives[].catchup`）挂在 `LiveUrl.catchup` 上（不序列化，留在引擎），列表里每个频道只下发 `catchupDays`。`/live/{i}/catchup` 按规则和时间段拼出地址（类型 `default` / `append` / `shift` / `flussonic` / `xc`，TVBox 与 Kodi IPTV Simple 的占位符），先给所选线路，其余作为 `alternates`。时间用中国时间、`SimpleDateFormat`，不用 `java.time`。客户端在有回看的频道的节目单上方列出可回看的日期，点已结束的节目进入「回看」状态（进度条、`←/→` 快退快进），「回到直播」/ Esc / 换台回到直播；回看地址播不了时依次试 `alternates`。
- 尚未支持：Python 蜘蛛直播。

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
│  └─ runtime-py/           （M3，未创建）Python 蜘蛛
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

> 现状：单窗口外壳（首页、直播、搜索、我的、源）+ 详情页 + 播放页，桌面用 media_kit（libmpv），触控 / 鼠标模式。下面列的迷你播放器、画中画、遥控器焦点模式、`PlayerKernel` 抽象、弹幕都还是计划。

- **单窗口 + 路由**：首页、分类、搜索、详情、播放、直播、历史、收藏、设置。支持迷你播放器与画中画。
- **两种交互模式**：触控/鼠标模式；遥控器焦点模式（电视）。组件共用，布局与焦点逻辑分开。
- **播放内核抽象** `PlayerKernel`：
  - 桌面：libmpv（media_kit），硬解（d3d11va / videotoolbox / vaapi）。
  - Android：ExoPlayer（官方 video_player）为默认，libmpv 兜底冷门格式。
  - iOS：AVPlayer 为默认，libmpv 兜底 mkv / flv 等。
- **弹幕**：引擎下发统一格式；客户端两种渲染：
  1. Flutter 图层：文字预栅格化缓存、只绘制可见部分，兼容任何内核、可交互。
  2. 桌面 mpv 模式：转成 ASS 交给 libmpv 渲染，几乎零开销。

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
