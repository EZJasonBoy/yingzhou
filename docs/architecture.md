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

### 2.6 直播与节目单（已实现，桌面优先）

- 引擎 `live` 包：`LiveSourceSpec` 解析 `lives` 的几种写法，`LivePlaylistParser` 解析 TXT / M3U，`Epg` 处理模板接口与 XMLTV 和频道名规整，`LiveService` 负责缓存（列表半小时、模板节目单半小时、XMLTV 6 小时）。不用 `java.time`，Android 7 也能跑。
- 客户端「直播」页：宽屏为 分组 | 频道（带当前节目和进度）| 播放器 + 节目单；窄屏上下堆叠。↑/↓ 换台（跨分组）、←/→ 换线路、PageUp/PageDown 换分组、F 或双击全屏（频道列表变成浮层）、M 静音、滚轮音量。线路报错或 15 秒没有画面就自动换下一条；记住上次看的频道；离开该页即停止播放，播放器在第一次打开该页时才创建。
- 蜘蛛直播（`type: 3` + `api`）：向 jar 蜘蛛要 `liveContent(url)`，按同样的格式解析。列表也可以是 JSON。指向 TVBox 内置服务（`127.0.0.1:9978/proxy`）的地址改指本引擎。
- 尚未支持：JS / Python 蜘蛛直播、回看（`catchup`）、`hosts` / `headers` 配置项。

### 2.7 配置体检（已实现）

`tvbox-engine --check <订阅…>`（`tools/check-configs.sh`）用同一个引擎把订阅里的每个仓库、站点、直播源走一遍并出报告，失败按"引擎兼容 / 不支持 / 网络 / 站点报错"归类。`--demo --check --strict` 是自检：打包脚本在裁剪完 Java 运行时后用它跑一遍演示配置（采集站、JS、jar、嗅探、直播），不通过就不出包——精简运行时缺模块（曾经漏了 `jdk.zipfs`，导致所有 jar 蜘蛛失败）会在这里被拦下。

HTTPS 与 TVBox 一致，不校验证书（`LenientTls`），`--strict-tls` 恢复校验。

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
- 网盘 Cookie 等凭据只存在引擎所在设备。
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
