# 引擎协议 v1（草案）

客户端与引擎之间的唯一接口。本机内置引擎和远程引擎使用同一套协议。

> 标了 **（未实现）** 的是已定下形状但还没写的接口：`/events`。其余都已实现并有测试。

## 约定

- 基础路径：`/api/v1`。JSON 使用 UTF-8，字段名 camelCase。
- 鉴权：`Authorization: Bearer <token>`，令牌由配对得到（见下面"鉴权与配对"）。本机的调用方不需要令牌。
- 错误：HTTP 状态码 + `{"error": {"code": "SITE_TIMEOUT", "message": "…"}}`。
- 流式结果用 **SSE**（`text/event-stream`）；引擎主动推送的事件用 **WebSocket** `/api/v1/events` **（未实现）**。遥控（见"遥控"）的两条 WebSocket 已实现。
- 版本：`GET /api/v1/info` 返回 `protocol` 版本号，不兼容的改动升主版本。

## 引擎信息与配对

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/info` | `{name, version, protocol, platform, capabilities: {jar, js, py, sniff}}`，无需令牌。`py` 是"现在能运行 Python 蜘蛛"：引擎有 Python 运行时、并且找到了 Python 3.8+，用户装好 Python 后会由 false 变 true，客户端要重新问 |
| POST | `/pair` | `{code, name}` → `{token, deviceId, name}`，无需令牌；`name` 是设备给自己起的名字 |

局域网发现：开启局域网共享时，引擎在每个局域网地址上用 mDNS 通告服务 `_tvbox-engine._tcp`，TXT 记录含 `protocol` 与 `name`。

### 鉴权与配对

**谁算本机**：对方地址是回环地址（127.0.0.1、::1），**并且**请求的 `Host` 是 `127.0.0.1` / `localhost` / `[::1]`（带不带端口都行）。后一半挡住本机浏览器里借 DNS 重绑定用自己的域名访问 127.0.0.1 的网页，和 `/file/` 的规则一样。本机调用方什么都不需要；经反向代理把 `Host` 改成 127.0.0.1 转发进来的请求也会被当成本机，不要这样配置。

**检查顺序**（一个拦截器挡在所有路由前面，之后新加的路由自动受保护，默认拒绝）：

1. 公开：`GET /api/v1/info`、`POST /api/v1/pair`、网页遥控器的静态文件 `/remote/`（见"遥控"）；演示引擎（`--demo`）的 `/demo/` 也公开，因为它代表的是第三方站点，别的引擎（模拟器里的安卓引擎）要不带令牌地取它。
2. 本机 → 放行。
3. GET / HEAD、路径不在 `/api/` 下、带有效的 `tvsig` 签名 → 只放行这一个地址（见下面"签名地址"）。
4. 局域网共享关闭 → `403 LAN_SHARING_OFF`（带令牌也一样）。
5. 有效的 `Authorization: Bearer <token>` → 放行（`/api/v1/lan` 除外，它只认本机）。遥控的两条 WebSocket 路由还接受放在子协议里的令牌，并且在第 1 步之前先检查 `Origin`（见"遥控"）。
6. 其余 → `401 UNAUTHORIZED`，响应头 `WWW-Authenticate: Bearer`。客户端收到 401 就回到配对。

**配对码**：6 位数字，一次有效，10 分钟过期。没有界面的引擎把它打印在标准输出里；本机的应用经 `GET /api/v1/lan` 读取。`POST /pair` 带空的 `code` 不算一次尝试：没有有效的码时引擎会生成一个（并打印），回答 `400 PAIR_CODE_REQUIRED`——客户端打开配对窗口时就发这个请求。

| 回答 | 含义 |
|---|---|
| `200 {token, deviceId, name}` | 配对成功，码作废 |
| `400 PAIR_CODE_REQUIRED` | 没填码；引擎上现在有一个 |
| `403 PAIR_CODE_WRONG` | 码不对或已过期，消息里有剩余次数 |
| `429 PAIR_LOCKED` + `Retry-After` | 连错 5 次：码作废，所有人的配对锁定 1 分钟，再错翻倍，最长 15 分钟；锁定期间正确的码也不行 |
| `403 LAN_SHARING_OFF` | 局域网共享没开 |

**令牌**：`<设备 id>.<32 字节随机数的 base64url>`。引擎只保存随机部分的 SHA-256（`access.json`，在引擎数据目录里），比较用恒定时间。每台设备一个令牌，可单独撤销；撤销后它的令牌和它拿到的签名地址立即失效。

**签名地址**：播放器（libmpv、ExoPlayer）带不上我们的请求头，而播放器会把 `PlayInfo.headers` 发给每个地址（包括 CDN），所以令牌绝不能放进播放器的请求头。引擎改为在交给客户端的引擎地址上加签名参数：

```
tvsig=<过期时间，秒，36 进制>.<设备 id 或 local>.<HMAC-SHA256 前 16 字节，base64url>
```

- HMAC 的内容是 `tvsig1\n<主体>\n<过期>\n<规范形式>`。规范形式：路径的每一段与每个查询参数先百分号解码成字节，再严格编码（只有 `A-Z a-z 0-9 - . _ ~` 原样保留），去掉 `tvsig`，参数按名字稳定排序（同名参数保持原顺序）。所以改值、换路径、追加参数（例如给 `/proxy` 多塞一个 `siteKey`）都会让签名失效，参数换顺序不影响。
- 密钥：设备签名用该设备令牌的哈希；`local` 签名用引擎每次启动随机生成的内存密钥，且只认来自回环地址的请求（本机播放器有时会带着 CDN 的 `Host` 头来请求引擎地址，靠它通过）。
- 只用于 GET / HEAD，路径第一段不能是 `api`（不分大小写），不能含 `.` / `..` 段。设备签名还要求局域网共享开着、设备没被撤销。
- 有效期：`/play/resolve` 返回的 24 小时；直播列表里的 30 天（客户端整次运行都用同一份列表）；经签名地址取到的播放列表里的地址继承那个签名的过期时间。
- 签名发生在响应出去之前（Ktor 发送管道）：`PlayInfo.url`、`sniff.pageUrl`、`subtitles[].url`、直播列表里的频道地址，以及 HLS 播放列表正文里的地址。被签的是指向引擎自己的地址：`http://127.0.0.1:<端口>/`、`http://localhost:<端口>/`、`http://<请求的 Host>/`。HLS 正文里请求的 `Host` 可能来自播放器（可能是 CDN 的名字），所以那里按 `Host` 只签 `/m3u8?` 和 `/proxy?`。
- 签名发生在响应出去之前（Ktor 发送管道）：`PlayInfo.url`、`sniff.pageUrl`、`subtitles[].url`、直播列表里的频道地址，以及 HLS 播放列表正文里的地址。被签的是指向引擎自己的地址：`http://127.0.0.1:<端口>/`、`http://localhost:<端口>/`、`http://<请求的 Host>/`。HLS 正文里请求的 `Host` 可能来自播放器（可能是 CDN 的名字），所以那里按 `Host` 只签 `/m3u8?`、`/proxy?`、`/hls/` 和 `/dl/`（下载的离线副本）。
- 新加返回引擎地址的接口：返回 `PlayInfo` / `LiveList` 会自动签名；别的形状要自己调用 `AccessControl.sign(url, call.accessGrant.subject, 过期时间)`。

### 局域网共享（只限本机）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/lan` | `{supported, enabled, forced, listening, name, port, addresses, discoverable, error, code, codeExpiresAt, lockedUntil, devices: [{id, name, createdAt, lastSeenAt, lastAddress}]}`；共享开着时总有一个有效的 `code` |
| PUT | `/lan` | `{enabled}`：打开或关闭，立即生效并保存，返回同上 |
| POST | `/lan/code` | 换一个配对码 |
| DELETE | `/lan/devices/{id}` | 撤销一台设备 |

这四个接口每次都在处理函数里再检查一次"本机"，不是本机一律 `403 LOCAL_ONLY`，带令牌也不行。`supported=false`：这个引擎不能共享（体检模式、旧版安卓引擎），或者是没有网络监听能力的测试环境。`forced=true`：以 `--lan` 启动，开关不起作用。安卓引擎和桌面引擎一样：打开后在每个局域网地址上另起监听（端口同为 9978），用系统的 NSD（`NsdManager`）通告 `_tvbox-engine._tcp`，共享期间在前台服务里运行。

## 订阅与配置

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/subscriptions` | 订阅列表：`[{id, name, url, usedAt}]`。`name` 没改过时就是地址；`usedAt` 是最后一次作为当前订阅加载的时间（毫秒，0 表示还没用过，老引擎没有这个字段） |
| POST | `/subscriptions` | `{name?, url}`，`url` 支持 http(s)、`clan://`、`file://`、引擎所在机器上的路径、`;pk;` 密钥后缀 |
| PUT | `/subscriptions/{id}` | `{name}` 重命名，空字符串恢复成地址；返回改后的订阅 |
| DELETE | `/subscriptions/{id}` | 删除 |
| POST | `/subscriptions/{id}/activate` | 切换当前订阅；多仓订阅可带 `{repo}` 选择子仓（见下） |
| POST | `/config/reload` | 重新下载当前配置，返回新的摘要。下载失败时报错（`CONFIG_LOAD_FAILED`），正在用的配置保持不变，原因记在摘要的 `refreshError` 里 |
| GET | `/config` | 当前配置摘要：站点数、解析数、直播数、spider、壁纸，以及下面的"新旧"字段 |
| GET | `/cache` | 数据缓存的大小：`{bytes, entries, areas: {config｜site｜ext｜live: {bytes, entries}}}` |
| DELETE | `/cache` | 清空数据缓存，返回清空后的大小。正在用的配置不受影响 |

配置的新旧（`/config`、`activate`、`/config/reload` 返回的摘要里）：

| 字段 | 说明 |
|---|---|
| `fetchedAt` | 正在用的配置是什么时候下载的（毫秒时间戳，0 表示不知道） |
| `stored` | `true`：引擎启动时用的是上次下载后保存的副本，网络上的还没核对过（或核对失败） |
| `refreshing` | `true`：正在后台核对副本。客户端隔一两秒再取一次 `/config`，直到它变成 `false`；这期间配置可能被换成新的（`fetchedAt`、站点数会变） |
| `refreshError` | 最近一次下载失败的原因；没失败为空 |

引擎启动时先用保存的副本激活上次的订阅（不等网络），再在后台下载：内容没变就只更新 `fetchedAt` 并把 `stored` 置回 `false`；变了就换成新的；下载失败就继续用副本并写明 `refreshError`。没有副本时（第一次、或缓存被清空）和以前一样等下载完成。

设置：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/settings` | `{githubProxy, githubProxyPrefix, httpProxy, proxyScopes, doh, streamCache, streamCacheMaxMB, danmakuConfigApi, danmakuApi}` |
| PUT | `/settings` | 同样的对象，**可以只带要改的字段**，没带的保持原值；保存并立即生效，返回规整后的完整对象。改 GitHub 代理后当前配置不会自动重新加载，客户端随后重新 `activate` |
| GET | `/network` | 当前配置的网络项和 DNS 选择，见下 |
| GET | `/github-proxy` | 可选的 GitHub 加速代理：`{presets: [{name, prefix}], probeUrl}` |
| POST | `/github-proxy/probe` | 测速：body `{prefixes: [...]}`（可省略或为空，表示全部 `presets`），返回 `{url, results: [{prefix, ok, ms, error}]}` |

`doh` 是所选 DNS-over-HTTPS 服务器的地址，空串（默认）表示用系统 DNS；不是 http(s) 地址的值会被存成空串。改了之后从下一个请求起生效。

`/network`：

```json
{
  "doh": "",                       // 同 settings.doh
  "dohOptions": [{"name": "阿里", "url": "https://dns.alidns.com/dns-query", "ips": [], "source": "builtin"}],
  "dohStatus": "",                 // 还没用过为空；之后是 "ok" 或 "failed: <原因>"（此时由系统 DNS 应答）
  "hosts": {"a.example": "1.2.3.4"},
  "headerHosts": ["media.example"],
  "ads": ["ads.example"]
}
```

`dohOptions` 的 `source`：`builtin` 引擎内置，`config` 当前配置的 `doh` 提供，`saved` 之前选的、现在两边都不再列出。`hosts` / `headerHosts` / `ads` 是当前配置里被采用的条目（写错的条目不在其中），语义见 [compatibility.md](compatibility.md) 第 2 节。

`danmakuConfigApi`（默认 `false`）：是否向当前配置顶层的 `danmaku` 接口要弹幕——它会收到所播内容的片名和集数，所以由使用者打开。`danmakuApi`（默认空）：使用者自己的弹幕服务，只接受 http(s) 地址，别的值存成空串。见下面"弹幕"。

`streamCache`（默认 `true`）和 `streamCacheMaxMB`（默认 2048，引擎会限制在 200 到 1048576 之间）控制播放缓存，见下面"播放缓存"一节；改它们不需要重新加载配置。

`githubProxy` 为 `false`（默认）时，GitHub 上的文件（`raw.githubusercontent.com`、`github.com` 等）直接向 GitHub 取，地址前面被订阅写上的代理（`https://<代理>/https://raw.githubusercontent.com/…`，带不带内层的 `https://` 都认）会被去掉。开启后，公开下载优先经 `githubProxyPrefix` 取，失败再直连。`/config` 的 `url` 始终是订阅里写的原样，`fetchedUrl` 是优先使用的地址。

`httpProxy` 是引擎所在设备可达的 HTTP 代理，格式为 `主机:端口` 或 `[IPv6]:端口`。`proxyScopes` 可多选 `config`（订阅、多仓、站点扩展配置和直播列表）、`modules`（蜘蛛脚本、JAR、Python 运行时和 pip 依赖）以及 `playback`（播放地址解析请求和网页嗅探）。默认地址为空，范围为 `[]`。引擎按用途选择 HTTP 代理，回环和常用局域网地址直连。播放器自行发送的媒体数据与引擎发送的解析请求是两条独立链路。本机更新的选择由客户端保存，引擎和客户端都能同时使用 GitHub 加速和所选的 HTTP 代理。

`/github-proxy` 的 `presets` 是引擎内置的公共加速代理（`prefix` 以 `/` 结尾，GitHub 地址直接接在后面），`githubProxyPrefix` 可以是其中之一，也可以是别的。`/github-proxy/probe` 同时取 `probeUrl`（本项目公开仓库里固定提交下的一个约 100 字节的文件）：先直连 GitHub（结果里 `prefix` 为空串、排第一），再经每个前缀各一次，不受 `githubProxy` 设置影响、不会改道，除这一个 GET 外不发送任何东西。前缀会被规整（补 `https://` 和结尾的 `/`）、去重，最多 20 个；每个最多等 8 秒，所以整个请求最长约 8 秒。`ok` 表示取回的内容确实是那个文件（有的代理对任何地址都回答 200 和一个自己的页面，算作失败）；`ms` 是从发出到读完（或失败）的毫秒数；`error` 是失败原因，如 `HTTP 503 from <host>`、`timeout talking to <host>`、`answered, but not with the file`。旧引擎没有这两个接口（404），客户端这时只显示开关和地址输入框。

多仓：`/config` 与 `activate` 返回的 `repos` 是 `[{name, url, parent, group, depth}]`。条目本身是多仓时，`activate` 它会把它展开：它变成 `group: true`，它的条目紧跟其后（`parent` 是它的 `url`，`depth` 加一），并加载其中第一个能用的，返回的 `url` 是实际加载的那个。不带 `repo`（或选的是一个多仓）时，失效的条目会被跳过；带 `repo` 指定的具体条目失效则报错，当前配置保持不变。

## 站点与点播

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/sites` | `[{key, name, type, searchable, quickSearch, filterable, changeable, runtime: cms|js|jar|py|remote}]`；`changeable` 是配置里的 `changeable`（默认 1），客户端据此决定能不能自动换到 / 换离这个站点；旧引擎没有这个字段，客户端当作 true |
| GET | `/sites/{key}/home` | `{classes: [Class], filters: {typeId: [Filter]}, list: [VodCard]}` |
| GET | `/sites/{key}/category?tid=&pg=&f=` | `f` 为 URL 编码的 JSON 筛选值；返回 `Page<VodCard>` |
| GET | `/sites/{key}/detail?id=` | `VodDetail` |
| GET | `/sites/{key}/search?wd=&pg=` | `Page<VodCard>`（单站） |
| GET | `/search/stream?wd=&sites=` | **SSE** 聚合搜索，见下 |

`home`、`category`、`detail` 的回答会在引擎里保存一段时间（首页和分类 15 分钟，详情 1 小时）：没过期的直接返回；过期的也先返回旧的，同时在后台向站点要新的，下次就是新的了；站点连不上时旧的一直可用。加 `?refresh=1` 表示现在就向站点要（失败就报错，不拿旧的顶替）。空的回答不保存。保存的内容按"订阅 + 配置内容 + 站点"区分，换订阅、配置内容变了、换站点都不会串。`search` 和 `/play/resolve` 从不保存。

### 聚合搜索事件（SSE）

```
event: site      data: {"site":"a","status":"started"}
event: results   data: {"site":"a","items":[VodCard…]}
event: site      data: {"site":"a","status":"done","count":12,"ms":830}
event: site      data: {"site":"b","status":"error","code":"SITE_TIMEOUT"}
event: end       data: {"sites":40,"ms":9120}
```

客户端可按"片名 + 年份"合并不同站点的同一部片。

## 播放

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/play/resolve` | `{site, line, episodeId, direct?}` → `PlayInfo`。`direct: true`：播放器自己从片源取视频（见下面"直连片源"） |

`PlayInfo`：

```json
{
  "kind": "direct",              // direct | sniff
  "url": "https://…/index.m3u8",
  "headers": {"Referer": "…", "User-Agent": "…"},
  "format": "hls",               // 可选：hls | dash | mp4 | flv | …
  "subtitles": [                 // 站点给的外挂字幕（subt、subs），没有为空
    {"name": "简体中文", "lang": "zh", "format": "srt", "url": "http://127.0.0.1:9978/subtitle?url=…&h=…&f=srt&tvsig=…"}
  ],
  "danmaku": "",                 // 站点给的弹幕来自哪里（地址，或 "inline"）；没有为空。只用于显示，弹幕本身见下面 /danmaku
  "sniff": null,                 // kind=sniff 时：{"pageUrl", "headers", "clickSelector", "timeoutMs"}
  "cache": "84e291843de2b840",   // 非空：url 由引擎的播放缓存提供，值是查询缓存范围用的 key；空：引擎不缓存这个地址
  "download": ""                 // 非空：这一集已经下载好，url 是引擎磁盘上的离线副本（/dl/…），值是下载的 id
}
```

`subtitles[].url` 总是引擎的 `/subtitle` 地址（见"兼容端点"），播放器直接打开；`format` 是引擎交出的格式（`srt` | `ass` | `ssa` | `vtt`，TTML、LRC 等转成 `srt`），`lang` 照站点写的原样。局域网客户端拿到的同样是签过名的地址。

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/subtitle/convert` | 客户端本地的字幕文件：`{name, data}`（`data` 为文件内容的 base64，最大 32 MB）→ `{format, text}`，`text` 是 UTF-8、播放器能读的格式。编码和格式的识别同 `/subtitle`；`name` 的扩展名只在内容看不出格式时参考 |

网盘的视频，`subtitles` 填的是它旁边同名的字幕文件（见下面"网盘"）：`name` 是文件名，`lang` 是文件名里的语言标记（`film.zh.srt` 的 `zh`，没有为空），`url` 同样是引擎的 `/subtitle` 地址，引擎从网盘取文件（`/drive/…` 或 AList 的 `/d/…`）再转码。

这一集有**下载完成**的副本时（站点、线路、`episodeId` 都相同），`/play/resolve` 直接返回它，不向站点要地址、不联网：`url` 是 `/dl/<id>/index.m3u8`（HLS）或 `/dl/<id>/film.<扩展名>`（直链下载），`download` 是下载的 id，`headers` 为空，`cache` 为空。见下面"离线下载"。

引擎尽量自己走完解析链（直链 / JSON 解析接口 / `jx` / 网页嗅探）。网页嗅探：桌面与 NAS 引擎用无头 Edge/Chrome（CDP，浏览器装在非标准位置时设 `TVBOX_BROWSER`），Android 内置引擎用 WebView；判定规则同 TVBox（配置 `rules` 的 `host`/`rule`/`filter`，再加内置视频地址正则），返回的 `headers` 带上页面实际使用的 Referer / User-Agent / Cookie。配置的顶层 `headers` 里有播放地址所在域名的条目时，它的请求头也并进 `headers`（同名覆盖）；直播线路的 `headers` 同理。`/info` 的 `capabilities.sniff` 表示引擎能否嗅探；不能时才返回 `kind: "sniff"`，由客户端自行嗅探（或提示换线路）。

## 弹幕

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/danmaku?site=&line=&episodeId=&title=&episode=&refresh=` | 一集的弹幕，见下 |
| POST | `/danmaku/parse` | 客户端本地的弹幕文件：`{name, data}`（base64，最大 32 MB）→ 同样的列表，`source: "file"`，`from` 是文件名；认不出弹幕时 400 |
| GET | `/danmaku/services` | `{configApi, configApiEnabled, customApi}`：当前配置的 `danmaku` 接口（没有为空）、它是否打开（`settings.danmakuConfigApi`）、使用者自己的接口（`settings.danmakuApi`） |

`/danmaku` 的 `site` / `line` / `episodeId` 与 `/play/resolve` 的相同，`title` / `episode` 是片名和集名（给弹幕接口用）。按顺序找，第一个有弹幕的来源胜出：

1. `site`：这一集解析播放地址时站点给的 `danmaku`（地址或弹幕本身）。所以先 `/play/resolve` 再要弹幕；引擎重启后要重新解析才有。
2. `config`：配置的 `danmaku` 接口，仅当 `danmakuConfigApi` 为真。
3. `custom`：`danmakuApi`，非空时。

```json
{
  "source": "site",            // site | config | custom | file；没有任何来源时为空串，items 为空（不是错误）
  "from": "https://comment.bilibili.com/123.xml",   // 实际取自哪里
  "count": 2,
  "items": [                   // 按 time 排序
    {"time": 1500, "mode": "scroll", "color": 16777215, "size": 25, "text": "前方高能"},
    {"time": 3000, "mode": "top", "color": 16711680, "size": 36, "text": "顶部红字"}
  ]
}
```

`time` 是视频里的毫秒；`mode` 为 `scroll` | `top` | `bottom`；`color` 是 0xRRGGBB；`size` 用 B 站的字号（25 普通、18 小、36 大）。来源都有、但都没有弹幕时返回空列表；用到的来源全部出错时 `502 DANMAKU_FAILED`，消息里分别写明原因。结果按集在引擎内存里保留 30 分钟，`refresh=1` 重新获取。弹幕列表由客户端用令牌获取（普通 API），不经播放器，所以不需要签名地址。

接口的写法、各种弹幕格式见 [compatibility.md](compatibility.md) 第 7 节"弹幕"。

## 播放缓存

点播的 HLS（有 `#EXT-X-ENDLIST` 的播放列表）由引擎代为获取并存在引擎的磁盘上：`/play/resolve` 返回的地址仍是 `/m3u8?…`，但播放列表里的分片、密钥、初始化段都指向引擎的 `/hls/…`（见"兼容端点"）。播放过和预读的部分因此不用再向片源要，连接同一个引擎的所有设备共用这份缓存。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/stream-cache` | `{available, enabled, bytes, files, streams, maxBytes, path, pinnedBytes, freeBytes, reserveBytes}`。`available: false` 表示这台引擎没有播放缓存（旧版引擎）；`streams` 是有缓存的视频数；`path` 是引擎所在机器上的目录；`pinnedBytes` 是放在同一目录里的下载（不算在 `bytes` 里，也不会因为超过容量被删）；`reserveBytes > 0` 表示缓存还看着磁盘剩余空间（安卓引擎：500 MB），`freeBytes` 是那块磁盘的剩余空间，其他引擎为 `-1` 和 `0` |
| DELETE | `/stream-cache` | 清空，返回清空后的同一个对象。正在播放、正被读取的文件会留到用完 |
| GET | `/stream-cache/coverage?key=` | `{durationMs, ranges: [[startMs, endMs], …]}`：`key` 是 `PlayInfo.cache`；`ranges` 是这部片已经在缓存里的时间段，按顺序、不重叠，给进度条画"已缓冲"用。没有这个 key 的播放列表时返回空 |

开关和容量在 `/settings` 里（`streamCache`、`streamCacheMaxMB`）。关掉后 `/play/resolve` 不再带 `cache`，播放列表里是片源自己的地址；已经发出去的播放列表里的 `/hls/…` 地址会 302 到片源。

**直连片源**（客户端在远处，比如经 Tailscale 连回家）：`/play/resolve` 带 `"direct": true` 时，点播的 HLS 仍经 `/m3u8`（引擎拉取播放列表、去广告），但地址带 `&d=1`、不带 `k`：播放列表里的分片是片源自己的地址，视频不经过引擎、不进播放缓存。这时 `relay` 是同一个视频经播放缓存的地址（`cache` 是它的缓存名），给直连失败时退回用（片源只认解析它的那个 IP、配置的 `hosts` 只在引擎里生效等）；播放缓存关着时 `relay` 为空。直链（mp4 等）、离线副本、`proxy://`、网盘文件不受影响。旧引擎不认识 `direct`，照常回答。

行为要点：

- 缓存按"哪一集"归档（站点 + 线路 + 剧集，即 `/m3u8` 的 `k` 参数），文件按它在片源上的路径命名，不含域名和查询串，所以下次解析出来的地址换了 CDN 域名或 token，仍然能用上次的缓存。
- 播放器连续往下请求了两个分片之后，引擎开始提前获取后面的内容：先 30 秒，播放器每再往下走一个分片多 15 秒，最多约 3 分钟；跳转之后重新算。同一个片源最多 4 个连接，连接会复用。只请求了开头就断开的流（多码率主列表里没被选中的那几档）不预读，没取到一半的下载也随即放弃。
- 播放器跳到没有缓存的分片时，优先取这个分片：片源按连接限速、又支持 `Range` 时把它按字节范围拆成几块并行获取，线路本身是瓶颈时整个取；在它到齐之前（最多 6 秒）这个流的其他下载都暂停。单个连接的速度跟不上视频码率时，播放器接着要的分片也这样一个一个按顺序取。
- 对播放器的请求立即应答，文件边到边转发；片源说了长度就带 `Content-Length`，否则分块传输。
- 片源拒绝引擎或一直连不上时：还没开始应答就 302 到片源；已经开始应答就断开连接，播放器重试时再 302。同一个视频刚打开就连续两次被拒，10 分钟内这个视频不再经缓存。
- 超过容量时删最久没用过的文件（不分是哪一部片）。下载（钉住的流）除外。
- 有 `reserveBytes` 时（安卓引擎），缓存还给磁盘留出这么多：快放不下时先删自己最旧的文件，删光了剩余空间也不够（只差不到 `reserveBytes` 的十分之一）就不再缓存新的分片、也不预读，播放器请求的分片 302 到片源；已经在缓存里的照常给。

## 离线下载

引擎替客户端下载剧集，下完不联网也能播。下载队列在引擎里（连着同一个引擎的所有设备看到同一份），保存在引擎数据目录的 `downloads.json`，引擎重启后没下完的接着下。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/downloads` | `{available, items: [DownloadItem]}`；`available: false` 表示这台引擎不能下载（0.2.0 之前的引擎），这时其他接口返回 `501 UNSUPPORTED_SITE` |
| POST | `/downloads` | `{items: [{site, line, episodeId, vodId?, title?, pic?, episodeName?, episodeIndex?}]}` → `{available, items}`：排队下载。前三项和 `/play/resolve` 一样；其余只是给列表显示的。同一集（站点 + 线路 + `episodeId`）已经在列表里就原样返回那一项，不会重复 |
| GET | `/downloads/events` | **SSE**：先发一次，之后列表有变化就再发（下载时最多每 0.4 秒一次），`event: downloads`，`data` 同 `GET /downloads`；空闲时每 15 秒一行 `: ping` |
| POST | `/downloads/{id}/pause` | 暂停（排队中的也可以），返回那一项 |
| POST | `/downloads/{id}/resume` | 继续暂停的；对失败的就是重试（重新解析地址）。返回那一项 |
| DELETE | `/downloads/{id}` | 停下并删掉它的文件，`204` |
| POST | `/downloads/{id}/export` | `{path?}` → `{path, bytes, format, uri}`：在**引擎所在的机器上**写一个文件。`path` 是文件夹（不存在就建）或者以视频扩展名结尾的文件名；不填就是默认的导出目录（桌面引擎：用户的「下载」文件夹）。同名文件已存在时文件名后加 ` (2)`。不能导出时 `501`，`message` 说明原因。**安卓引擎**不填 `path` 时交给系统：Android 10 起写进系统「下载」里的 `Download/映舟/`（MediaStore），更早的版本写进应用自己的 `Android/data/<应用>/files/Download/`；返回的 `path` 是给人看的位置，`uri` 是这个文件的 `content://` 地址，同一台设备上的 App 用它打开分享面板。其他引擎 `uri` 为空 |
| GET | `/downloads/settings` | `{available, dir, path, defaultPath, concurrency, maxConcurrency, freeBytes, reserveBytes, bytes, locations}` |
| PUT | `/downloads/settings` | `{dir?, concurrency?}`，只改带了的项。`dir` 是引擎所在机器上的完整路径，空串回到默认；不是完整路径或不能写入时 `400` |

`locations`：引擎所在设备上不能随便填文件夹时（安卓：应用只能写自己的目录），可选的下载位置 `[{name, dir, path, freeBytes, totalBytes, removable}]`。第一项是默认位置（内部存储，`dir` 为空串），后面是插着的 SD 卡、U 盘上应用自己的目录（`removable: true`：拔出期间那里的下载看不了）。客户端有 `locations` 时给一个下拉框，选中项的 `dir` 原样发给 `PUT`；没有（桌面、NAS 引擎）时让用户填路径。

`DownloadItem`：

```json
{
  "id": "6b81737673da",
  "site": "demo", "line": "慢速线路", "episodeId": "http://…/short/aes.m3u8",
  "vodId": "97", "title": "慢速源演示", "pic": "http://…/97.png", "episodeName": "短片加密", "episodeIndex": 6,
  "state": "running",        // queued | running | paused | done | failed
  "kind": "hls",             // 解析之前为空；hls | file（直链：mp4 / flv / mkv …）
  "bytes": 13000000,         // 已经在磁盘上的字节数
  "totalBytes": -1,          // 直链的文件大小、下完的总大小；HLS 下载中不知道（-1）
  "progress": 0.42,          // 0–1；HLS 按已下的时长算
  "speed": 1536000,          // 最近几秒每秒多少字节；不在下载时为 0
  "partsDone": 9, "parts": 21,   // HLS：分片、密钥、初始化段，已下 / 总数
  "durationMs": 120000,
  "error": "",               // failed 时的原因（给人看的中文），如"这是直播流（播放列表没有结尾），不能下载"
  "createdAt": 1795097507684, "finishedAt": 0
}
```

行为要点：

- **每次开始下载（含重试、引擎重启后继续）都重新走一遍 `/play/resolve` 的解析链**：直链、解析接口、嗅探都和播放一样。播放地址会过期；下到一半片源开始拒绝（4xx、返回网页而不是视频）时，引擎再解析一次接着下，已下好的保留；还不行才失败。5xx 和断线会先重试几次。
- **HLS**：主播放列表取码率最高的一档（音轨单独成流的档位只在没有别的选择时才用）；按配置的广告规则去掉广告，和播放时一样。分片、密钥（`#EXT-X-KEY`）、初始化段（`#EXT-X-MAP`）、字节范围都下下来，每集同时 4 个连接。**没有 `#EXT-X-ENDLIST` 的是直播，拒绝下载。**
- **直链**：带 `Range` 下载，暂停、重试、引擎重启后都从已下的位置接着下。片源不说文件多大（多半是直播流）时拒绝。
- 需要客户端嗅探的线路（`kind: "sniff"`）拒绝下载。
- 同时下载的集数是 `concurrency`（默认 2，1–5），其余排队，按加入的先后。
- **存在哪**：默认放进播放缓存的目录，作为"钉住"的流：文件名和播放缓存给这一集起的一样，所以看过的部分不用再下，下载中的那一集也可以照常在线播放（共用同一份文件），播放缓存的容量上限和"清空"都不碰它们。`dir` 设成别的目录后，新的下载放到那里，已有的留在原处。安卓引擎不这样：播放缓存在系统可能清理的缓存目录里，下载默认放在应用在共享存储上的目录（`Android/data/<应用>/files/downloads`），两者不共用文件。
- **空间**：磁盘剩余少于 `reserveBytes`（500 MB）时停下并失败；HLS 下了几段之后按已下的大小估算整集，放不下也提前停下；直链开始前就按文件大小检查。
- 下载完成后文件被删（用户清了目录）时，`/play/resolve` 发现后把它标成失败（"下载的文件不见了"），改走网络。

离线副本的地址（不在 `/api/v1` 下，见"兼容端点"）：`/dl/<id>/index.m3u8` 是下载时的播放列表，里面的分片、密钥、初始化段改成 `/dl/<id>/<编号>.<扩展名>`；直链下载是 `/dl/<id>/film.<扩展名>`。都支持 `Range`。和播放缓存的 `/hls/` 一样，局域网里的播放器拿到的这些地址都带 `tvsig` 签名（`/play/resolve` 的返回和播放列表正文都会签），不需要令牌。

**导出为一个文件**：

- HLS：分片按顺序拼接。都是 MPEG-TS 时得到 `.ts`，AES-128 加密的分片先用它的密钥解密（IV 用 `#EXT-X-KEY` 里写的，没写就用分片的序号）；分片是 fMP4（一个 `#EXT-X-MAP`）时得到 `.mp4`（初始化段 + 各个分片）。
- 直链下载原样复制。
- 做不到的情况：`SAMPLE-AES` 等其他加密、中途换了初始化段、分片不是标准 MPEG-TS（片源把分片伪装成图片等）。这些需要 ffmpeg 转封装，引擎**不附带也不安装 ffmpeg**，返回 `501` 并说明；这样的下载仍可离线播放。
- `GET /dl/<id>/export`：同样的文件由引擎边拼边发出（`Content-Disposition: attachment`，`filename*` 是 UTF-8 的"片名 集名.ts"），供另一台设备保存到它自己的磁盘；带令牌访问。

## 直播

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/live` | `[{index, name, hasEpg, supported, spider}]`：配置 `lives` 里的每一项是一个直播源；`spider` 是给出列表的蜘蛛的种类（`jar` / `js` / `py`），普通列表为空 |
| GET | `/live/{index}?refresh=1` | `{source, name, groups: [{name, channels: [{name, logo, catchupDays, urls: [{url, label, headers}]}]}]}`，缓存半小时，列表取不到时返回上次取到的那份。`catchupDays`：能回看几天，0 为不能回看 |
| GET | `/live/{index}/epg?channel=&date=` | `{channel, date, programs: [{start, end, title}]}`，`date` 为 `yyyy-MM-dd`（中国时间，缺省今天；过去的日期也可以，回看用），时间为毫秒时间戳 |
| GET | `/live/{index}/catchup?channel=&group=&line=&start=&end=` | 回看：`{url, headers, line, alternates: [{url, headers, line}]}`。`start` / `end` 为毫秒时间戳；`group` 可选（频道名在不同分组里重复时用）；`line` 是想先用的线路（缺省 0）。`url` 是先试的地址，`alternates` 是它播不了时再试的：同一线路的其他写法，再是这个频道其他能回看的线路。频道不能回看、节目还没开始、参数不对时 400，频道不存在 404 |

`lives` 支持：`type: 0` 的 TXT（`分组,#genre#`、`频道,url#url2$线路名`）/ M3U（`group-title`、`tvg-logo`、`x-tvg-url`、`#EXTVLCOPT` 的 UA 与 Referer）播放列表；`proxy://do=live&ext=…` 里藏的列表地址；直接写在配置里的 `group`/`channels`；被包成配置格式（图片 base64、AES）的列表。`type: 3`（蜘蛛直播）由 `api` 指定的蜘蛛给出列表：jar 和 Python 蜘蛛的 `liveContent(url)`、JS 蜘蛛的 `live(url)`；没写 `api` 的，和本机还没有 Python 时的 Python 蜘蛛 `supported=false`，取列表时返回 501。频道里的 `proxy://` 指向引擎，局域网客户端拿到的地址按它访问引擎用的地址改写；蜘蛛给出的列表里，这类地址还会带上 `siteKey`（该直播源的蜘蛛），`/proxy` 据此把请求交回给同一个蜘蛛。

回看规则（M3U 的 `catchup*` 属性、`lives[].catchup`、`/PLTV/` 地址）留在引擎里，不随列表下发；客户端只看 `catchupDays`，要播时问 `/catchup`。地址怎么拼见 [compatibility.md](compatibility.md) 第 6 节"回看"。

节目单：`epg` 为带 `{name}`/`{date}` 的模板（返回 `epg_data`），或不带占位符的同类接口（按 `?ch=&date=` 请求），或 XMLTV（`.xml` / `.xml.gz`，也可来自 M3U 的 `x-tvg-url`，缓存 6 小时）。频道名会先规整再查（`CCTV-1 综合` → `CCTV1`，去掉"高清""HD"等后缀），查不到再用原名。`logo` 模板的 `{name}` 同样用规整后的名字。

## 网盘

用户自己的视频：AList / OpenList、WebDAV、引擎所在机器上的文件夹（只有桌面和服务器引擎有，安卓内置引擎没有）。网盘列表连同账号、密码、令牌存在引擎里（数据目录的 `drives.json`）；**任何回答里都没有密码和令牌**，只说有没有。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/drives` | `[DriveInfo]` |
| POST | `/drives` | `DriveRequest` → `201 DriveInfo` |
| GET | `/drives/{id}` | `DriveInfo` |
| PUT | `/drives/{id}` | `DriveRequest`：没带的字段不变；`password` / `token` 为空串表示删除 → `DriveInfo` |
| DELETE | `/drives/{id}` | `204` |
| POST | `/drives/test` | `DriveRequest`，不保存，读一次它的根目录 → `{ok, message, entries}`。带 `id` 时，没填的字段（包括密码、令牌）用那个已保存的网盘的，编辑表单里没改密码也能测 |
| GET | `/drives/{id}/list?path=` | `{drive, path, entries: [DriveEntry]}`，`path` 缺省为 `/`。文件夹在前，再按名称（数字按大小："第2集"在"第10集"前） |
| POST | `/drives/{id}/unlock` | `{path, password}`：AList 文件夹的密码。AList 认了就由引擎记下（对这个文件夹和它下面的都有效），回答同 `list` |
| GET | `/drives/{id}/detail?path=` | 文件夹作为一部"片"：`VodDetail`，见下 |
| GET | `/drives/{id}/play?path=` | 一个文件的 `PlayInfo`（含 `subtitles`） |

```
DriveInfo    {id, name, kind: alist|webdav|local, url, username, hasPassword, hasToken, root, proxy,
              lockedFolders: [记着密码的 AList 文件夹], addedAt, site: "drive:<id>"}
DriveRequest {name?, kind?, url?, username?, password?, token?, root?, proxy?, id?}
DriveEntry   {name, path, dir, size, modified, type: folder|video|subtitle|other}
```

- `url`：AList 的网页地址；WebDAV 的 DAV 目录地址；本机文件夹的完整路径。地址里写了 `user:pass@` 时，账号被移到 `username` / `password`，地址里只留主机。`root` 是网盘从服务器上哪个文件夹开始（网盘的 `/` 就是它），本机文件夹没有。`proxy: true` 表示文件一律经引擎转给播放器。
- 路径都是网盘里的路径，以 `/` 开头。含 `..`、反斜杠的路径一律 400；本机文件夹的路径还不能含 `:`。
- 视频按扩展名认（mp4、mkv、avi、mov、wmv、flv、webm、ts、m2ts、mpg、rmvb 等），字幕是 `srt` / `ass` / `ssa` / `vtt`。
- 只有本机的调用方能添加本机文件夹、或把网盘改成指向另一个本机文件夹（`403 LOCAL_ONLY`）；配对过的设备可以浏览、播放已有的。没有界面的引擎用启动参数 `--drive-folder <路径>` 添加。
- 错误码：`DRIVE_PASSWORD`（403，AList 文件夹要密码或密码不对，客户端据此弹出密码框）、`DRIVE_AUTH`（403，网盘不认账号；不用 401，401 留给"引擎令牌无效"）、`DRIVE_PATH`（403，本机文件夹以外）、`DRIVE_UNREACHABLE`（502，连不上或回答看不懂）、`NOT_FOUND`、`BAD_REQUEST`。

**文件夹即"片"**：网盘的文件夹在引擎的其他接口里是站点 `drive:<id>` 的一部片，片 id 是文件夹路径，只有一条线路（名字是网盘名），剧集是文件夹里的视频（按名称排，`id` 是文件路径，`name` 是去掉扩展名的文件名）。所以：

- `GET /sites/drive:<id>/detail?id=<文件夹>` 和 `/drives/{id}/detail` 一样；
- `POST /play/resolve` 带 `{site: "drive:<id>", episodeId: <文件路径>}` 和 `/drives/{id}/play` 一样；
- 观看历史照常用 `PUT /history/drive:<id>/<文件夹路径>` 记录（`episodeId` 是文件路径），续播、"继续播放"和站点的片一样。`drive:` 开头的站点键是保留的。

**播放器从哪里取**：能自己取的就给网盘自己的地址——AList 是 `/d/<路径>?sign=<签名>`（AList 的下载路由，它再转到存储），没有账号的 WebDAV 是文件的 WebDAV 地址，`headers` 为空。否则给引擎的 `http://127.0.0.1:<端口>/drive/<id>/<路径>`（见"兼容端点"），由引擎带上账号去取：带账号的 WebDAV、本机文件夹、`proxy: true` 的网盘，以及网盘地址是回环地址（`127.0.0.1` / `localhost`）而播放器在别的设备上时。局域网设备拿到的这类地址按它访问引擎用的地址改写并签名，字幕地址也一样。

## 历史、收藏、进度

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/history?limit=` | 最近观看 |
| PUT | `/history/{site}/{vodId}` | `{title, pic, line, episodeId, episodeName, positionMs, durationMs, subtitle, audio}` |
| DELETE | `/history/{site}/{vodId}` | |
| GET / PUT / DELETE | `/favorites[/{site}/{vodId}]` | 同上 |

数据存在引擎里，因此连接同一个引擎的所有设备自动同步进度。

`subtitle` / `audio` 是给这部片选的字幕和音轨，客户端写、客户端读，引擎不解释：`off`（关闭字幕）、`lang:<语言>`、`name:<轨道名>`，空为播放器默认。

## Python 蜘蛛

只有桌面 / NAS 的独立引擎有这组接口（安卓内置引擎没有 Python，返回 404，客户端据此不显示「Python 蜘蛛」设置）。谁能用引擎谁就能看；改动只接受本机的请求（403 `LOCAL_ONLY`），因为 Python 的位置是引擎要运行的程序，安装是往那台机器上放软件。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/python?refresh=1` | 状态（见下）；`refresh=1` 重新查找 Python |
| PUT | `/python` | `{path?, indexUrl?, downloadMirror?}`：Python 的位置（空 = 自动查找）、PyPI 镜像（空 = pip 自己的设置）、Python 下载镜像（空 = python.org，目录结构相同）。没写的字段不变。返回状态 |
| POST | `/python/download` | 开始下载 CPython 免安装版（只有 Windows），返回状态；已经在下载或安装时 409 `PYTHON_BUSY`，不是 Windows 时 400 |
| DELETE | `/python/download` | 删除下载的 CPython 和给它装的包 |
| POST | `/python/packages` | `{packages: [...]}`，空 = 常用的包；包名只能是名字加可选的版本条件（`pywasm==0.4.8`），选项和路径一律 400。返回状态 |

状态：

```json
{
  "supported": true, "available": true,
  "python": {"path": "C:\\…\\python.exe", "version": "3.14.10", "source": "downloaded", "pip": false},
  "problem": "",
  "settings": {"path": "", "indexUrl": "", "downloadMirror": ""},
  "packagesDir": "C:\\Users\\…\\.tvbox-next\\engine\\python\\packages\\cp314-win_amd64",
  "packages": [{"name": "requests", "module": "requests", "installed": true, "where": "engine"}],
  "missing": [{"module": "lxml", "packageName": "lxml", "site": "某站", "at": 1795097938765}],
  "download": {"version": "3.14.10", "url": "https://www.python.org/ftp/python/3.14.10/python-3.14.10-embed-amd64.zip",
               "sizeBytes": 12619664, "sha256": "9090…", "dir": "…\\python\\runtime", "installed": true},
  "task": {"kind": "install", "state": "running", "message": "…", "progress": -1, "log": ["$ pip install lxml", "…"]},
  "worker": {"running": true, "pid": 1234, "starts": 1, "spiders": 3}
}
```

- `source`：`custom`（用户填的）、`env`（`TVBOX_PYTHON`）、`system`（本机找到的）、`downloaded`。`problem`：没有 Python 的原因，或者用户填的位置有什么问题。
- `packages`：TVBox 的 Python 版自带的那几个包，这个 Python（加上引擎给它装的）能否导入。`where`：`engine` 在引擎的目录里，`python` 是 Python 自己环境里的。
- `missing`：蜘蛛导入了但没有的模块（最近的在前），装上之后自动消失。`packageName` 是提供它的包。
- `download`：可以下载的 CPython；不是 Windows 时没有这个字段。下载与安装在后台进行，`task` 是正在进行的或上一次的（`state`：`running` / `done` / `failed`），客户端每秒问一次直到结束。

Python 站点调用失败时的错误码：`PY_UNAVAILABLE`（没有可用的 Python）、`PY_MODULE_MISSING`（缺包，消息里有包名）、`PY_CRASHED`（Python 进程退出了，下次调用会重启它）；蜘蛛自己抛的异常是 `SITE_ERROR`，加载时就出错是 `SPIDER_LOAD_FAILED`。

## 遥控

让手机驱动一个映舟客户端：接在电视上的电脑（Windows / macOS / Linux）、电视盒子、没有键盘的旧安卓设备。**引擎是中枢**：允许被遥控的客户端向它正在用的引擎登记为一块**屏幕**，保持一条 WebSocket；配对过的手机（**遥控端**）列出屏幕，向其中一块开一条控制 WebSocket。引擎只转发：屏幕的状态里有什么、有哪些命令，是客户端和遥控端之间的事，引擎不解释（以后加字段、加命令不用动引擎）。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/remote/screens` | `[{id, name, platform, form, version, title, controllers, connectedAt}]`：现在能遥控的屏幕。`form` 是屏幕的界面形态：`desktop` / `tv` / `phone` / `tablet`；`title` 取自屏幕最近一次状态的 `title`；`controllers` 是正连着它的遥控端个数 |
| WS | `/remote/screen` | 屏幕端：先说 `hello`，然后发状态、收命令 |
| WS | `/remote/control?screen=<id>` | 遥控端：立即收到那块屏幕最近的状态，之后每次变化都收到；发命令 |

网页遥控器和控制台在 `/remote/`（不在 `/api/v1` 下）：`index.html`、`remote.css`、`remote.js`、`icon.svg`、`manifest.webmanifest` 五个静态文件，加上控制台各页第一次打开时才加载的 `pages/sources.js`、`pages/data.js`、`pages/logs.js`、`pages/settings.js`（固定的清单，`/remote/` 下别的路径都是 404），没有依赖也没有构建步骤，**不需要令牌**（它自己经 `POST /pair` 配对，令牌存在手机浏览器的 localStorage 里）。宽度 900 像素以上是左侧导航（遥控与播放、订阅与站点、数据、日志与崩溃、设置），更窄是底栏（遥控、播放、更多）。地址后面可以带 `#code=<配对码>`，网页拿它直接配对后从地址里去掉；`#page=<页>` 打开某一页（`remote`、`playing`、`sources`、`data`、`logs`、`settings`，手机上还有 `more`），可以和 `#code=` 一起用（`#page=logs&code=123456`）；`#tab=play` 和 `#page=playing` 一样。响应带 `Content-Security-Policy`（只运行自己的脚本）：屏幕报上来的片名、集名来自第三方站点，网页只把它们当文字显示。

**谁能被遥控**：屏幕都是自己连上来的。客户端里的「允许手机遥控」默认关闭，关着的时候它根本不连 `/remote/screen`，不在列表里，也就没有任何办法遥控它；打开后登记，关掉即断开。能遥控的是能通过引擎鉴权的调用方：本机，或局域网共享开着时配对过的设备。配对过的设备可以遥控登记在这台引擎上的任何屏幕（它本来也能用这台引擎的全部接口）。

### 鉴权

和其他接口同一套（见"鉴权与配对"），没有第二套令牌。两点不同：

- **令牌可以放在 `Sec-WebSocket-Protocol` 里**。浏览器不能给 WebSocket 设置请求头，只能指定子协议，所以这两条 WebSocket 路由除了 `Authorization: Bearer` 之外，还接受一个名为 `yingzhou.token.<令牌>` 的子协议。网页打开连接时写 `new WebSocket(url, ['yingzhou.remote.v1', 'yingzhou.token.' + token])`；引擎回答里选中的子协议永远是 `yingzhou.remote.v1`，不会把令牌回显出来。不带子协议也能连（脚本、其他客户端用请求头）。这个子协议只在这两条路由上有效，别的接口不认。
- **检查 `Origin`**。WebSocket 没有同源策略：本机浏览器里任何网站的网页都能连 `ws://127.0.0.1:9978/…`，而且会被当成本机（不需要令牌）。所以这两条路由在所有检查之前先看 `Origin`：有 `Origin`（是浏览器）就必须等于 `http(s)://<请求的 Host>`，也就是引擎自己发出去的网页，否则 `403 BAD_ORIGIN`；没有 `Origin`（不是浏览器）不受影响。

握手被拒绝时是普通的 HTTP 回答（`401 UNAUTHORIZED`、`403 LAN_SHARING_OFF`、`403 BAD_ORIGIN`），浏览器的 WebSocket 读不到状态码，所以网页连不上时会用 `GET /remote/screens` 再问一次原因。连接建立之后引擎每 3 秒复查一次：设备被撤销或局域网共享关掉，连接以 4401 关闭。

### 消息

都是 JSON 文本帧，带 `type`。引擎每 15 秒发一次 WebSocket ping，20 秒没有回应就断开（屏幕掉线后从列表里拿掉）；浏览器发不了 ping 帧，遥控端可以发 `{"type":"ping"}`，引擎回 `{"type":"pong"}`。屏幕发来的消息最长 512 KB，遥控端的 32 KB，超过即断开。

| 方向 | 消息 | 说明 |
|---|---|---|
| 屏幕 → 引擎 | `{"type":"hello","id","name","platform","form","version"}` | 第一条消息，10 秒内必须到。`id` 是屏幕自己保存的固定标识（`[A-Za-z0-9._-]`，最长 64），`name` 最长 40 字 |
| 引擎 → 屏幕 | `{"type":"welcome","id","controllers":0}` | 登记成功 |
| 屏幕 → 引擎 | `{"type":"state","state":{…}}` | 屏幕现在的状态（见下）。引擎留着最近的一份，并转给所有遥控端 |
| 引擎 → 屏幕 | `{"type":"controllers","count","names":[…]}` | 遥控端来了或走了；`names` 是它们配对时的设备名（本机是"本机"） |
| 引擎 → 屏幕 | `{"type":"command","from","id","name","args":{…}}` | 一个遥控端的命令。`from` 是那个遥控端在引擎里的会话号，`id` 是遥控端自己给的（可以没有） |
| 屏幕 → 引擎 | `{"type":"result","to","id","ok","message"}` | 命令的结果，`to` 填命令的 `from`。做不了时 `ok=false`，`message` 是给拿着手机的人看的原因 |
| 遥控端 → 引擎 | `{"type":"command","id","name","args":{…}}` | 转给屏幕 |
| 引擎 → 遥控端 | `{"type":"screen","screen":{id,name,platform,form,version}}` | 连上后的第一条 |
| 引擎 → 遥控端 | `{"type":"state","state":{…}}` | 连上后立即一条（屏幕已经报过状态的话），之后每次变化一条 |
| 引擎 → 遥控端 | `{"type":"result","id","ok","message"}` | 自己发的那条命令的结果（只发给发命令的那个遥控端） |
| 引擎 → 遥控端 | `{"type":"gone"}` | 屏幕断开了；随后连接以 4410 关闭 |

关闭码：

| 码 | 含义 |
|---|---|
| 4400 | 消息不对（屏幕的第一条不是合法的 `hello`） |
| 4401 | 不再允许：设备被撤销，或局域网共享关了 |
| 4404 | 没有这块屏幕（没登记，或已经断开）。遥控端应回到屏幕列表，等它出现再连 |
| 4409 | 同一个 `id` 的屏幕又连了一次，旧连接被顶替（客户端重连得比引擎发现断线还快）；它的遥控端收到 `gone` 后重新连接 |
| 4410 | 屏幕断开了 |
| 4429 | 太多了：一台引擎最多 32 块屏幕，一块屏幕最多 8 个遥控端 |

### 状态

屏幕在状态变化时发送（80 毫秒内的多次变化合并成一次；内容没变不发）。播放位置不是每秒都发：遥控端按 `position`、`speed`、`paused`、`buffering` 自己往前推，屏幕只在跳转、暂停、换集等变化时发，另外在有遥控端连着时每 5 秒发一次校正，有新的遥控端连上时也发一次。

```
{
  "title":  "星河往事 第二季",        // 一句话说明现在在看什么，空串表示没在播放；屏幕列表里显示
  "page":   "browse" | "player" | "live",
  "form":   "tv" | "desktop" | "phone" | "tablet",
  "canTv":  true,                     // 这块屏幕能不能切换界面模式（命令 uiMode）
  "text":   null | {"value", "hint", "secret", "multiline"},   // 屏幕上有输入框得到焦点时；密码框的 value 永远是空串
  "player": null | {
    "kind": "vod" | "live",
    "title": "星河往事 第二季",        // 点播是片名，直播是频道名
    "subtitle": "第3集 · 线路一",      // 点播：集名 · 线路；直播：分组 · 正在播出的节目，回看时是节目名
    "position": 754000, "duration": 2712000,     // 毫秒；直播（不是回看）时都是 0
    "seekable": true,
    "paused": false, "buffering": false,
    "error": "",                      // 播放失败时的说明（这时遥控端可以发 retry）
    "speed": 1.0, "speeds": [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0],   // 直播 speeds 为空
    "volume": 80, "muted": false,     // 播放器的音量 0–100，不是系统音量
    "fullscreen": true, "canFullscreen": true,
    "lines": ["线路一", "线路二"], "line": 0,
    "episodes": ["第1集", …], "episode": 2,        // 直播：正在浏览的分组里的频道，episode 是正在播的那个（不在这个分组时 -1）
    "groups": ["央视", …], "group": 0,             // 只有直播有：频道分组，group 是正在浏览的分组
    "subtitles": [{"id": "off", "name": "关闭"}, {"id", "name"}, …], "subtitleId": "…",   // 只有点播有；没有字幕时是空数组
    "audios": [{"id", "name"}, …], "audioId": "…",
    "danmaku": true                   // 只有点播有：弹幕开关
  }
}
```

### 命令

`name` 和 `args`。前五个由客户端的外壳处理，其余交给正在播放的页面（点播播放页或直播页）；没有在播放时回答 `ok=false`「屏幕上现在没有在播放」。

| 命令 | 参数 | 作用 |
|---|---|---|
| `key` | `{key, action}` | 按键。`key`：`up` `down` `left` `right` `ok` `back` `menu`、`playpause` `next` `previous` `fastforward` `rewind`、`channelup` `channeldown`、`0`–`9`。`action`：`press`（默认，按下再松开）、`down`、`repeat`、`up`。按住不放时遥控端先发 `down`，约 0.4 秒后每 0.1 秒发一次 `repeat`，松手发 `up`；`down` 之后 1.5 秒没有 `repeat` 或 `up`（手机断线了），屏幕自己松开这个键 |
| `home` | — | 关掉所有打开的页面，回到首页 |
| `text` | `{value}` | 把得到焦点的输入框的内容换成 `value`（和在屏幕上打字一样触发它的 `onChanged`） |
| `submit` | — | 输入框的回车（搜索、连接、完成） |
| `uiMode` | `{mode: "tv" \| "auto"}` | 切到电视模式，或回到这台设备本来的界面 |
| `toggle` / `play` / `pause` | — | 播放 / 暂停 |
| `seek` | `{position}` | 跳到这个位置（毫秒）。直播只有回看时可以 |
| `seekBy` | `{delta}` | 往前或往后跳（毫秒，可为负） |
| `speed` | `{value}` | 倍速，必须是 `speeds` 里的一个 |
| `volume` / `volumeBy` | `{value}` / `{delta}` | 播放器音量 |
| `mute` | `{on?}` | 静音；不带 `on` 是切换 |
| `fullscreen` | `{on?}` | 全屏；不带 `on` 是切换。电脑的电视模式本来就一直全屏，不能切 |
| `line` | `{index}` | 换线路（`lines` 的下标） |
| `episode` | `{index}` | 点播：换集；直播：播放正在浏览的分组里的这个频道（也可以带 `group`） |
| `next` / `previous` | — | 下一集 / 上一集；直播是下一个 / 上一个频道 |
| `group` | `{index}` | 直播：浏览另一个分组（`episodes` 随之换成它的频道，不换台） |
| `subtitle` / `audio` | `{id}` | 点播：选字幕（`off` 关闭）/ 音轨 |
| `danmaku` | `{on?}` | 点播：弹幕开关 |
| `retry` | — | 出错后重试 |
| `stop` | — | 点播：退出播放页；直播：退出全屏 |

**按键是真的按键**：客户端把 `key` 合成为 Flutter 的按键事件（方向键、`select`、`goBack`、`contextMenu`、媒体键），走和电视盒子遥控器完全相同的路径，所以焦点移动、每个页面自己的按键处理都不用为遥控另写。`back` 没有任何页面处理时，客户端像安卓的系统返回键那样关掉最上面的页面。不提供、也不打算提供的：控制操作系统的鼠标键盘、系统音量、唤醒和关机。

## 兼容端点（不在 `/api/v1` 下）

| 路径 | 说明 |
|---|---|
| `/proxy?…` | 兼容 TVBox 9978：先给 `siteKey` 对应的蜘蛛，再给 jar 的 `Proxy.proxy`；`do=js` 给 JS 蜘蛛；`do=py` 只给 Python 蜘蛛的 `localProxy`（`siteKey` 指名的，没有就是最近用过的）；`do=ck` 返回 `ok` |
| `/file/<路径>` | 仅桌面引擎、仅本机访问：本机文件，供 `clan://localhost/`、`file://` 和本机路径的订阅及其 `./` 引用使用 |
| `/m3u8?url=&h=&k=&d=` | HLS 播放列表：引擎拉取播放列表（`h` 为请求头 JSON 的 URL 安全 base64），把相对地址改成绝对地址，按配置 `rules` 的广告规则和保守的分片路径启发式去掉广告片段；主播放列表的各码率也指回这里（带着同一个 `k`）。点播的媒体播放列表在播放缓存开着时再改写一遍：分片、`#EXT-X-KEY`、`#EXT-X-MAP` 的地址换成 `/hls/…`，`#EXT-X-BYTERANGE` 去掉（范围由引擎向片源请求）。`k` 是 `/play/resolve` 给这一集起的缓存名，可以不带（那就按播放列表地址归档）。直播列表（没有 `#EXT-X-ENDLIST`）不改写、不缓存。`d=1`：播放器直连片源，媒体播放列表只去广告、不改写成 `/hls/…`，主播放列表的各码率也带上 `d=1`。拉取失败时 302 到原地址 |
| `/subtitle?url=&h=&f=` | `PlayInfo.subtitles` 指向这里：引擎带着请求头（`h`，同 `/m3u8`）取 `url` 上的字幕，识别编码（BOM、UTF-16、UTF-8，否则在 GB18030 与 Big5 中按常用字多少选，不信服务器声明的）和格式，交出 UTF-8 的 SRT / ASS / WebVTT（TTML、LRC、B 站 JSON 字幕转成 SRT）。`f` 是站点声明的格式，内容看不出时才用。取不到时 502 |
| `/drive/<网盘 id>/<路径>` | 网盘里的一个文件，由引擎取来给播放器（见"网盘"）：本机文件夹直接读文件，WebDAV / AList 由引擎带上账号向网盘要。支持 `GET` / `HEAD` 和单段 `Range`（`bytes=a-b`、`a-`、`-n`；范围不对时 416）；网盘的回答按原样转发状态码和 `Content-Range`，`Content-Type` 是 `application/octet-stream` 时按扩展名改成视频类型。本机文件夹之外的路径 403，`..` 400 |
| `/hls/<播放列表>/<编号>.<扩展名>` | `/m3u8` 改写出来的地址：播放缓存里的分片（`.ts` / `.m4s` 等，片源的扩展名不像媒体文件时一律 `.ts`）、密钥（`.key`）、初始化段（`.mp4`）。支持 `Range`。引擎取不到时 302 到片源（按字节范围切的分片无法这样退回，返回 502） |
| `/dl/<下载 id>/index.m3u8`、`/dl/<下载 id>/<编号>.<扩展名>`、`/dl/<下载 id>/film.<扩展名>` | 下载完成的剧集（见"离线下载"）：播放列表和它的分片、密钥、初始化段，或者直链下载的整个文件。只读磁盘，从不联网。支持 `Range`。没有这个下载或文件时 404 |
| `/dl/<下载 id>/export` | 下载的剧集拼成一个文件发出（见"离线下载"） |

`/play/resolve` 返回的 HLS 地址默认包成 `/m3u8?…`（`headers` 照样返回；经播放缓存时播放器用不上它们，引擎会带着去请求片源，没写 User-Agent 时用播放器自己的）。引擎为自己生成的地址（`/m3u8`、`/hls`、蜘蛛 `/proxy`）用 `127.0.0.1`；局域网里的其他设备请求时，按它访问引擎用的地址（请求的 `Host`）改写，所以电视连 NAS 引擎也能直接播。这些地址都带 `tvsig` 签名（见"鉴权与配对"），播放器不需要令牌。

这些兼容端点和 API 一样受鉴权保护：其他设备要么带令牌，要么用引擎签过名的地址。jar 蜘蛛在引擎进程里访问 `127.0.0.1` 上的 `/proxy`，属于本机，不受影响。

## 数据模型

```
VodCard   {site, id, name, pic, remarks, tag}
Class     {id, name}
Filter    {key, name, values: [{name, value}]}
Page<T>   {page, pageCount, total, list: [T]}
VodDetail {site, id, name, pic, year, area, type, actor, director, content, remarks,
           lines: [{name, episodes: [{id, name}]}]}
```

`tag` 是站点的 `vod_tag`（原样，没有时为空）：`folder` 和 `cover` 表示文件夹，客户端用 `/sites/{key}/category?tid=<卡片 id>` 打开它的下一层，而不是请求详情。

`lines` 由 TVBox 的 `vod_play_from`（`$$$` 分隔）与 `vod_play_url`（线路 `$$$`、剧集 `#`、名称与地址 `$`）规整而来。`episodeId` 对客户端是不透明字符串，原样传回 `/play/resolve`。
