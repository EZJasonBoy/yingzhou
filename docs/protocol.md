# 引擎协议 v1（草案）

客户端与引擎之间的唯一接口。本机内置引擎和远程引擎使用同一套协议。

> 标了 **（未实现）** 的是已定下形状但还没写的接口：鉴权与 `/pair`、mDNS、`/events`、`/danmaku`。其余都已实现并有测试。

## 约定

- 基础路径：`/api/v1`。JSON 使用 UTF-8，字段名 camelCase。
- 鉴权 **（未实现）**：`Authorization: Bearer <token>`。本机回环地址上的内置客户端可免令牌。目前引擎不校验令牌，默认只监听 `127.0.0.1`。
- 错误：HTTP 状态码 + `{"error": {"code": "SITE_TIMEOUT", "message": "…"}}`。
- 流式结果用 **SSE**（`text/event-stream`）；引擎主动推送的事件用 **WebSocket** `/api/v1/events` **（未实现）**。
- 版本：`GET /api/v1/info` 返回 `protocol` 版本号，不兼容的改动升主版本。

## 引擎信息与配对

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/info` | `{name, version, protocol, platform, capabilities: {jar, js, py, sniff}}`，无需令牌 |
| POST | `/pair` | **（未实现）** `{code}` → `{token}`；配对码由引擎界面或日志显示 |

局域网发现 **（未实现）**：mDNS 服务类型 `_tvbox-engine._tcp`，TXT 记录含 `protocol` 与 `name`。

## 订阅与配置

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/subscriptions` | 订阅列表 |
| POST | `/subscriptions` | `{name?, url}`，`url` 支持 http(s)、`clan://`、`file://`、引擎所在机器上的路径、`;pk;` 密钥后缀 |
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
| GET | `/settings` | `{githubProxy, githubProxyPrefix, doh, streamCache, streamCacheMaxMB}` |
| PUT | `/settings` | 同样的对象，**可以只带要改的字段**，没带的保持原值；保存并立即生效，返回规整后的完整对象。改 GitHub 代理后当前配置不会自动重新加载，客户端随后重新 `activate` |
| GET | `/network` | 当前配置的网络项和 DNS 选择，见下 |

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

`streamCache`（默认 `true`）和 `streamCacheMaxMB`（默认 2048，引擎会限制在 200 到 1048576 之间）控制播放缓存，见下面"播放缓存"一节；改它们不需要重新加载配置。

`githubProxy` 为 `false`（默认）时，GitHub 上的文件（`raw.githubusercontent.com`、`github.com` 等）直接向 GitHub 取，地址前面被订阅写上的代理（`https://<代理>/https://raw.githubusercontent.com/…`，带不带内层的 `https://` 都认）会被去掉；为 `true` 时改经 `githubProxyPrefix` 取，失败再直连。`/config` 的 `url` 始终是订阅里写的原样，`fetchedUrl` 是实际访问的地址。

多仓：`/config` 与 `activate` 返回的 `repos` 是 `[{name, url, parent, group, depth}]`。条目本身是多仓时，`activate` 它会把它展开：它变成 `group: true`，它的条目紧跟其后（`parent` 是它的 `url`，`depth` 加一），并加载其中第一个能用的，返回的 `url` 是实际加载的那个。不带 `repo`（或选的是一个多仓）时，失效的条目会被跳过；带 `repo` 指定的具体条目失效则报错，当前配置保持不变。

## 站点与点播

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/sites` | `[{key, name, type, searchable, quickSearch, filterable, runtime: cms|js|jar|py|remote}]` |
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
| POST | `/play/resolve` | `{site, line, episodeId}` → `PlayInfo` |
| GET | `/danmaku?site=&vodId=&title=&episode=` | **（未实现，M3）** 规整弹幕 |

`PlayInfo`：

```json
{
  "kind": "direct",              // direct | sniff
  "url": "https://…/index.m3u8",
  "headers": {"Referer": "…", "User-Agent": "…"},
  "format": "hls",               // 可选：hls | dash | mp4 | flv | …
  "subtitles": [],
  "danmaku": null,
  "sniff": null,                 // kind=sniff 时：{"pageUrl", "headers", "clickSelector", "timeoutMs"}
  "cache": "84e291843de2b840"    // 非空：url 由引擎的播放缓存提供，值是查询缓存范围用的 key；空：引擎不缓存这个地址
}
```

引擎尽量自己走完解析链（直链 / JSON 解析接口 / `jx` / 网页嗅探）。网页嗅探：桌面与 NAS 引擎用无头 Edge/Chrome（CDP，浏览器装在非标准位置时设 `TVBOX_BROWSER`），Android 内置引擎用 WebView；判定规则同 TVBox（配置 `rules` 的 `host`/`rule`/`filter`，再加内置视频地址正则），返回的 `headers` 带上页面实际使用的 Referer / User-Agent / Cookie。配置的顶层 `headers` 里有播放地址所在域名的条目时，它的请求头也并进 `headers`（同名覆盖）；直播线路的 `headers` 同理。`/info` 的 `capabilities.sniff` 表示引擎能否嗅探；不能时才返回 `kind: "sniff"`，由客户端自行嗅探（或提示换线路）。

## 播放缓存

点播的 HLS（有 `#EXT-X-ENDLIST` 的播放列表）由引擎代为获取并存在引擎的磁盘上：`/play/resolve` 返回的地址仍是 `/m3u8?…`，但播放列表里的分片、密钥、初始化段都指向引擎的 `/hls/…`（见"兼容端点"）。播放过和预读的部分因此不用再向片源要，连接同一个引擎的所有设备共用这份缓存。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/stream-cache` | `{available, enabled, bytes, files, streams, maxBytes, path}`。`available: false` 表示这台引擎没有播放缓存（如安卓 App 内置的引擎）；`streams` 是有缓存的视频数；`path` 是引擎所在机器上的目录 |
| DELETE | `/stream-cache` | 清空，返回清空后的同一个对象。正在播放、正被读取的文件会留到用完 |
| GET | `/stream-cache/coverage?key=` | `{durationMs, ranges: [[startMs, endMs], …]}`：`key` 是 `PlayInfo.cache`；`ranges` 是这部片已经在缓存里的时间段，按顺序、不重叠，给进度条画"已缓冲"用。没有这个 key 的播放列表时返回空 |

开关和容量在 `/settings` 里（`streamCache`、`streamCacheMaxMB`）。关掉后 `/play/resolve` 不再带 `cache`，播放列表里是片源自己的地址；已经发出去的播放列表里的 `/hls/…` 地址会 302 到片源。

行为要点：

- 缓存按"哪一集"归档（站点 + 线路 + 剧集，即 `/m3u8` 的 `k` 参数），文件按它在片源上的路径命名，不含域名和查询串，所以下次解析出来的地址换了 CDN 域名或 token，仍然能用上次的缓存。
- 播放器连续往下请求了两个分片之后，引擎开始提前获取后面的内容：先 30 秒，播放器每再往下走一个分片多 15 秒，最多约 3 分钟；跳转之后重新算。同一个片源最多 4 个连接，连接会复用。只请求了开头就断开的流（多码率主列表里没被选中的那几档）不预读，没取到一半的下载也随即放弃。
- 播放器跳到没有缓存的分片时，优先取这个分片：片源按连接限速、又支持 `Range` 时把它按字节范围拆成几块并行获取，线路本身是瓶颈时整个取；在它到齐之前（最多 6 秒）这个流的其他下载都暂停。单个连接的速度跟不上视频码率时，播放器接着要的分片也这样一个一个按顺序取。
- 对播放器的请求立即应答，文件边到边转发；片源说了长度就带 `Content-Length`，否则分块传输。
- 片源拒绝引擎或一直连不上时：还没开始应答就 302 到片源；已经开始应答就断开连接，播放器重试时再 302。同一个视频刚打开就连续两次被拒，10 分钟内这个视频不再经缓存。
- 超过容量时删最久没用过的文件（不分是哪一部片）。

## 直播

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/live` | `[{index, name, hasEpg, supported, spider}]`：配置 `lives` 里的每一项是一个直播源；`spider` 是给出列表的蜘蛛的种类（`jar` / `js` / `py`），普通列表为空 |
| GET | `/live/{index}?refresh=1` | `{source, name, groups: [{name, channels: [{name, logo, catchupDays, urls: [{url, label, headers}]}]}]}`，缓存半小时，列表取不到时返回上次取到的那份。`catchupDays`：能回看几天，0 为不能回看 |
| GET | `/live/{index}/epg?channel=&date=` | `{channel, date, programs: [{start, end, title}]}`，`date` 为 `yyyy-MM-dd`（中国时间，缺省今天；过去的日期也可以，回看用），时间为毫秒时间戳 |
| GET | `/live/{index}/catchup?channel=&group=&line=&start=&end=` | 回看：`{url, headers, line, alternates: [{url, headers, line}]}`。`start` / `end` 为毫秒时间戳；`group` 可选（频道名在不同分组里重复时用）；`line` 是想先用的线路（缺省 0）。`url` 是先试的地址，`alternates` 是它播不了时再试的：同一线路的其他写法，再是这个频道其他能回看的线路。频道不能回看、节目还没开始、参数不对时 400，频道不存在 404 |

`lives` 支持：`type: 0` 的 TXT（`分组,#genre#`、`频道,url#url2$线路名`）/ M3U（`group-title`、`tvg-logo`、`x-tvg-url`、`#EXTVLCOPT` 的 UA 与 Referer）播放列表；`proxy://do=live&ext=…` 里藏的列表地址；直接写在配置里的 `group`/`channels`；被包成配置格式（图片 base64、AES）的列表。`type: 3`（蜘蛛直播）由 `api` 指定的蜘蛛给出列表：jar 蜘蛛的 `liveContent(url)`、JS 蜘蛛的 `live(url)`；Python 蜘蛛和没写 `api` 的 `supported=false`，取列表时返回 501。频道里的 `proxy://` 指向引擎，局域网客户端拿到的地址按它访问引擎用的地址改写；蜘蛛给出的列表里，这类地址还会带上 `siteKey`（该直播源的蜘蛛），`/proxy` 据此把请求交回给同一个蜘蛛。

回看规则（M3U 的 `catchup*` 属性、`lives[].catchup`、`/PLTV/` 地址）留在引擎里，不随列表下发；客户端只看 `catchupDays`，要播时问 `/catchup`。地址怎么拼见 [compatibility.md](compatibility.md) 第 6 节"回看"。

节目单：`epg` 为带 `{name}`/`{date}` 的模板（返回 `epg_data`），或不带占位符的同类接口（按 `?ch=&date=` 请求），或 XMLTV（`.xml` / `.xml.gz`，也可来自 M3U 的 `x-tvg-url`，缓存 6 小时）。频道名会先规整再查（`CCTV-1 综合` → `CCTV1`，去掉"高清""HD"等后缀），查不到再用原名。`logo` 模板的 `{name}` 同样用规整后的名字。

## 历史、收藏、进度

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/history?limit=` | 最近观看 |
| PUT | `/history/{site}/{vodId}` | `{title, pic, line, episodeId, episodeName, positionMs, durationMs}` |
| DELETE | `/history/{site}/{vodId}` | |
| GET / PUT / DELETE | `/favorites[/{site}/{vodId}]` | 同上 |

数据存在引擎里，因此连接同一个引擎的所有设备自动同步进度。

## 兼容端点（不在 `/api/v1` 下）

| 路径 | 说明 |
|---|---|
| `/proxy?…` | 兼容 TVBox 9978：先给 `siteKey` 对应的蜘蛛，再给 jar 的 `Proxy.proxy`；`do=js` 给 JS 蜘蛛；`do=ck` 返回 `ok` |
| `/file/<路径>` | 仅桌面引擎、仅本机访问：本机文件，供 `clan://localhost/`、`file://` 和本机路径的订阅及其 `./` 引用使用 |
| `/m3u8?url=&h=&k=` | HLS 播放列表：引擎拉取播放列表（`h` 为请求头 JSON 的 URL 安全 base64），把相对地址改成绝对地址，按配置 `rules` 的广告规则和保守的分片路径启发式去掉广告片段；主播放列表的各码率也指回这里（带着同一个 `k`）。点播的媒体播放列表在播放缓存开着时再改写一遍：分片、`#EXT-X-KEY`、`#EXT-X-MAP` 的地址换成 `/hls/…`，`#EXT-X-BYTERANGE` 去掉（范围由引擎向片源请求）。`k` 是 `/play/resolve` 给这一集起的缓存名，可以不带（那就按播放列表地址归档）。直播列表（没有 `#EXT-X-ENDLIST`）不改写、不缓存。拉取失败时 302 到原地址 |
| `/hls/<播放列表>/<编号>.<扩展名>` | `/m3u8` 改写出来的地址：播放缓存里的分片（`.ts` / `.m4s` 等，片源的扩展名不像媒体文件时一律 `.ts`）、密钥（`.key`）、初始化段（`.mp4`）。支持 `Range`。引擎取不到时 302 到片源（按字节范围切的分片无法这样退回，返回 502） |

`/play/resolve` 返回的 HLS 地址默认包成 `/m3u8?…`（`headers` 照样返回；经播放缓存时播放器用不上它们，引擎会带着去请求片源，没写 User-Agent 时用播放器自己的）。引擎为自己生成的地址（`/m3u8`、`/hls`、蜘蛛 `/proxy`）用 `127.0.0.1`；局域网里的其他设备请求时，按它访问引擎用的地址（请求的 `Host`）改写，所以电视连 NAS 引擎也能直接播。

## 数据模型

```
VodCard   {site, id, name, pic, remarks}
Class     {id, name}
Filter    {key, name, values: [{name, value}]}
Page<T>   {page, pageCount, total, list: [T]}
VodDetail {site, id, name, pic, year, area, type, actor, director, content, remarks,
           lines: [{name, episodes: [{id, name}]}]}
```

`lines` 由 TVBox 的 `vod_play_from`（`$$$` 分隔）与 `vod_play_url`（线路 `$$$`、剧集 `#`、名称与地址 `$`）规整而来。`episodeId` 对客户端是不透明字符串，原样传回 `/play/resolve`。
