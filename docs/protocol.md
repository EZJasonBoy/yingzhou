# 引擎协议 v1（草案）

客户端与引擎之间的唯一接口。本机内置引擎和远程引擎使用同一套协议。

> 标了 **（未实现）** 的是已定下形状但还没写的接口：`/config/reload`、`/events`、`/danmaku`。其余都已实现并有测试。

## 约定

- 基础路径：`/api/v1`。JSON 使用 UTF-8，字段名 camelCase。
- 鉴权：`Authorization: Bearer <token>`，令牌由配对得到（见下面"鉴权与配对"）。本机的调用方不需要令牌。
- 错误：HTTP 状态码 + `{"error": {"code": "SITE_TIMEOUT", "message": "…"}}`。
- 流式结果用 **SSE**（`text/event-stream`）；引擎主动推送的事件用 **WebSocket** `/api/v1/events` **（未实现）**。
- 版本：`GET /api/v1/info` 返回 `protocol` 版本号，不兼容的改动升主版本。

## 引擎信息与配对

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/info` | `{name, version, protocol, platform, capabilities: {jar, js, py, sniff}}`，无需令牌 |
| POST | `/pair` | `{code, name}` → `{token, deviceId, name}`，无需令牌；`name` 是设备给自己起的名字 |

局域网发现：开启局域网共享时，引擎在每个局域网地址上用 mDNS 通告服务 `_tvbox-engine._tcp`，TXT 记录含 `protocol` 与 `name`。

### 鉴权与配对

**谁算本机**：对方地址是回环地址（127.0.0.1、::1），**并且**请求的 `Host` 是 `127.0.0.1` / `localhost` / `[::1]`（带不带端口都行）。后一半挡住本机浏览器里借 DNS 重绑定用自己的域名访问 127.0.0.1 的网页，和 `/file/` 的规则一样。本机调用方什么都不需要；经反向代理把 `Host` 改成 127.0.0.1 转发进来的请求也会被当成本机，不要这样配置。

**检查顺序**（一个拦截器挡在所有路由前面，之后新加的路由自动受保护，默认拒绝）：

1. 公开：`GET /api/v1/info`、`POST /api/v1/pair`；演示引擎（`--demo`）的 `/demo/` 也公开，因为它代表的是第三方站点，别的引擎（模拟器里的安卓引擎）要不带令牌地取它。
2. 本机 → 放行。
3. GET / HEAD、路径不在 `/api/` 下、带有效的 `tvsig` 签名 → 只放行这一个地址（见下面"签名地址"）。
4. 局域网共享关闭 → `403 LAN_SHARING_OFF`（带令牌也一样）。
5. 有效的 `Authorization: Bearer <token>` → 放行（`/api/v1/lan` 除外，它只认本机）。
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
- 签名发生在响应出去之前（Ktor 发送管道）：`PlayInfo.url`、`sniff.pageUrl`、直播列表里的频道地址，以及 HLS 播放列表正文里的地址。被签的是指向引擎自己的地址：`http://127.0.0.1:<端口>/`、`http://localhost:<端口>/`、`http://<请求的 Host>/`。HLS 正文里请求的 `Host` 可能来自播放器（可能是 CDN 的名字），所以那里按 `Host` 只签 `/m3u8?` 和 `/proxy?`。
- 新加返回引擎地址的接口：返回 `PlayInfo` / `LiveList` 会自动签名；别的形状要自己调用 `AccessControl.sign(url, call.accessGrant.subject, 过期时间)`。

### 局域网共享（只限本机）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/lan` | `{supported, enabled, forced, listening, name, port, addresses, discoverable, error, code, codeExpiresAt, lockedUntil, devices: [{id, name, createdAt, lastSeenAt, lastAddress}]}`；共享开着时总有一个有效的 `code` |
| PUT | `/lan` | `{enabled}`：打开或关闭，立即生效并保存，返回同上 |
| POST | `/lan/code` | 换一个配对码 |
| DELETE | `/lan/devices/{id}` | 撤销一台设备 |

这四个接口每次都在处理函数里再检查一次"本机"，不是本机一律 `403 LOCAL_ONLY`，带令牌也不行。`supported=false`：这个引擎不能共享（安卓内置引擎），或者是没有网络监听能力的测试环境。`forced=true`：以 `--lan` 启动，开关不起作用。

## 订阅与配置

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/subscriptions` | 订阅列表 |
| POST | `/subscriptions` | `{name?, url}`，`url` 支持 http(s)、`clan://`、`file://`、引擎所在机器上的路径、`;pk;` 密钥后缀 |
| DELETE | `/subscriptions/{id}` | 删除 |
| POST | `/subscriptions/{id}/activate` | 切换当前订阅；多仓订阅可带 `{repo}` 选择子仓（见下） |
| POST | `/config/reload` | **（未实现）** 重新拉取（忽略缓存）；目前重新 `activate` 即可 |
| GET | `/config` | 当前配置摘要：站点数、解析数、直播数、spider、壁纸 |

设置：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/settings` | `{githubProxy, githubProxyPrefix}` |
| PUT | `/settings` | 同样的对象；保存并立即生效，返回规整后的值。当前配置不会自动重新加载，客户端随后重新 `activate` |

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
  "sniff": null                  // kind=sniff 时：{"pageUrl", "headers", "clickSelector", "timeoutMs"}
}
```

引擎尽量自己走完解析链（直链 / JSON 解析接口 / `jx` / 网页嗅探）。网页嗅探：桌面与 NAS 引擎用无头 Edge/Chrome（CDP，浏览器装在非标准位置时设 `TVBOX_BROWSER`），Android 内置引擎用 WebView；判定规则同 TVBox（配置 `rules` 的 `host`/`rule`/`filter`，再加内置视频地址正则），返回的 `headers` 带上页面实际使用的 Referer / User-Agent / Cookie。`/info` 的 `capabilities.sniff` 表示引擎能否嗅探；不能时才返回 `kind: "sniff"`，由客户端自行嗅探（或提示换线路）。

## 直播

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/live` | `[{index, name, hasEpg, supported}]`：配置 `lives` 里的每一项是一个直播源 |
| GET | `/live/{index}?refresh=1` | `{source, name, groups: [{name, channels: [{name, logo, urls: [{url, label, headers}]}]}]}`，缓存半小时 |
| GET | `/live/{index}/epg?channel=&date=` | `{channel, date, programs: [{start, end, title}]}`，`date` 为 `yyyy-MM-dd`（中国时间，缺省今天），时间为毫秒时间戳 |

`lives` 支持：`type: 0` 的 TXT（`分组,#genre#`、`频道,url#url2$线路名`）/ M3U（`group-title`、`tvg-logo`、`x-tvg-url`、`#EXTVLCOPT` 的 UA 与 Referer）播放列表；`proxy://do=live&ext=…` 里藏的列表地址；直接写在配置里的 `group`/`channels`；被包成配置格式（图片 base64、AES）的列表。`type: 3`（蜘蛛直播）暂不支持，`supported=false`。频道里的 `proxy://` 指向引擎，局域网客户端拿到的地址按它访问引擎用的地址改写。

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
| `/m3u8?url=&h=` | HLS 去广告：引擎拉取播放列表（`h` 为请求头 JSON 的 URL 安全 base64），把相对地址改成绝对地址，按配置 `rules` 的广告规则和保守的分片路径启发式去掉广告片段；主播放列表的各码率也指回这里。拉取失败时 302 到原地址 |

`/play/resolve` 返回的 HLS 地址默认包成 `/m3u8?…`（`headers` 照样返回，播放器拿去请求分片）。引擎为自己生成的地址（`/m3u8`、蜘蛛 `/proxy`）用 `127.0.0.1`；局域网里的其他设备请求时，按它访问引擎用的地址（请求的 `Host`）改写，所以电视连 NAS 引擎也能直接播。这些地址都带 `tvsig` 签名（见"鉴权与配对"），播放器不需要令牌。

这些兼容端点和 API 一样受鉴权保护：其他设备要么带令牌，要么用引擎签过名的地址。jar 蜘蛛在引擎进程里访问 `127.0.0.1` 上的 `/proxy`，属于本机，不受影响。

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
