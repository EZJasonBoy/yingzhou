# TVBox 配置兼容性

> 逐字段说明引擎对 TVBox 配置的支持情况，对照的是 TVBoxOS / takagen99 Box 的行为。遇到"安卓版能用、这里不行"的订阅，先来这里查是不是已知缺口。
>
> ✅ 支持 · 🟡 读取了但只用了一部分 · ⬜ 读取了但没用上 / 不支持

## 1. 订阅地址与配置文件

| 写法 | 支持 | 说明 |
|---|---|---|
| `http(s)://…` | ✅ | |
| `clan://localhost/…`、`file://…` | ✅ | 引擎所在机器上的文件（桌面引擎）。相对路径从用户目录找 |
| 直接填本机路径（`C:\tv\a.json`、`/home/me/a.json`） | ✅ | 同上；文件里的 `./` 引用按文件所在目录解析 |
| `clan://<别的地址>/…` | ✅ | 另一台设备上的 TVBox 文件服务 |
| `地址;pk;密钥` | ✅ | AES-ECB |
| 图片里藏配置（`…**base64`） | ✅ | |
| `2423…` 开头的 AES-CBC | ✅ | |
| 不规范 JSON（注释、首尾有多余字符） | ✅ | 与安卓版同样用 Gson 宽松模式，只取第一个 `{` 到最后一个 `}` |
| 多仓 `{"urls": [{name, url}]}` | ✅ | 在「源」页选择子仓 |
| 多仓里套多仓 | ✅ | 选中的条目本身是多仓时，展开它并加载其中第一个能用的；它的条目随后出现在下拉里（缩进显示），最多套 3 层 |
| 多仓的第一个条目失效 | ✅ | 自动往后找能用的（只在不是用户亲手选的时候；用户选中的条目失效会直接报错） |
| 配置里引用的相对路径（`./xxx.js`） | ✅ | 相对订阅地址解析 |

### HTTPS 证书

与 TVBox 一样，引擎访问订阅里的地址时**不校验 HTTPS 证书**（过期、自签、域名不符都接受）。真实配置里大量站点、直播列表、节目单的证书是坏的，TVBox 能打开正是因为它不校验。代价是这些请求可能被网络中间人看到或篡改——与配置里大量使用的明文 http 相当。桌面引擎加 `--strict-tls` 可以恢复校验。

### GitHub 加速代理

订阅作者常把代理写死在 GitHub 地址前面（`https://gh-proxy.org/https://raw.githubusercontent.com/…`），因为他们所在的网络直连 GitHub 很慢。这类代理经常失效，一失效整个订阅就是 404。所以走不走代理由使用者决定，不由订阅决定：

- **关闭（默认）**：直连 GitHub，订阅里写的代理前缀被去掉。
- **打开**：GitHub 上的文件一律经你在「源」页填的代理获取（不管订阅里写的是哪个代理），代理失败时再直连。

对引擎发出的所有请求生效：配置、多仓条目、jar、JS 脚本、`ext`、直播列表、节目单，以及 jar 蜘蛛通过宿主发的请求。只认"代理域名后面紧跟 GitHub 域名"这一种写法；jsDelivr 之类换了地址格式的镜像不处理。

## 2. 顶层字段

| 字段 | 支持 | 说明 |
|---|---|---|
| `spider` | ✅ | 全局 jar。支持 `;md5;校验值`、`img+` 前缀、伪装成 `.png` 的 jar、`clan://`。缓存 7 天 |
| `sites` | ✅ | 见第 3 节 |
| `parses` | ✅ | 见第 4 节 |
| `flags` | ✅ | 这些播放标识走解析（VIP 解析） |
| `rules` | ✅ | 见第 5 节 |
| `lives` | 🟡 | 见第 6 节 |
| `wallpaper` | ⬜ | 引擎会返回地址，客户端还没用 |
| `hosts` | ⬜ | 域名重定向，未生效 |
| `doh` | ⬜ | 未生效，用系统 DNS |
| `headers` | ⬜ | 按域名加请求头，未读取 |
| `ads` | ⬜ | 嗅探时的广告域名黑名单，未生效 |
| `danmaku` | ⬜ | 弹幕未实现 |
| `ijk`、`logo`、`notice`、`warningText` 等 | ⬜ | 与安卓播放器内核或界面相关，忽略 |

## 3. 站点 `sites[]`

没有 `key`、`type` 或 `api` 的条目会被跳过（与安卓版一致）。

| 字段 | 支持 | 说明 |
|---|---|---|
| `key`、`name` | ✅ | |
| `type: 0` | ✅ | XML 采集站 |
| `type: 1` | ✅ | JSON 采集站 |
| `type: 3` | 🟡 | 蜘蛛，按 `api` 后缀分运行时，见下表 |
| `type: 4` | ✅ | HTTP 远程蜘蛛 |
| `api` | ✅ | |
| `ext` | ✅ | 字符串、对象、数组都接受；指向文件的会先取回 |
| `jar` | ✅ | 站点自己的 jar，写法同 `spider` |
| `searchable` | ✅ | 为 0 时不参与聚合搜索 |
| `quickSearch` | 🟡 | 会返回给客户端，客户端暂未区分 |
| `filterable` | ✅ | |
| `playUrl` | ✅ | 拼在播放地址前面的解析前缀 |
| `categories` | ✅ | 只保留并按此顺序显示分类 |
| `timeout` | ✅ | 该站请求超时（秒） |
| `click` | ⬜ | 站点级的嗅探点击脚本，未用（`rules` 里的 `script` 是支持的） |
| `style` | ⬜ | 海报比例等，客户端未用 |
| `changeable` | ⬜ | 换源未实现 |
| `playerType` | ⬜ | 桌面只有 libmpv 一个内核 |

### 蜘蛛运行时（`type: 3`）

| `api` 的样子 | 运行时 | Windows / macOS | Android | 说明 |
|---|---|---|---|---|
| `csp_Xxx` | jar | ✅ | ✅ | 桌面上把 dex 转成 JVM 字节码，配安卓桩类运行 |
| `csp_Xxx`，jar 带 native 壳（加固） | jar | ⬜ | ✅ | 桌面计划用 unidbg |
| `….js` | js | ✅ | ✅ | QuickJS，含 drpy 用到的宿主函数 |
| `….py` | py | ⬜ | ⬜ | 「源」页会标"运行时开发中" |

jar 蜘蛛在桌面上依赖的安卓类是桩类，覆盖了常见用法（`Context`、`SharedPreferences`、`Base64`、`Log`、`Looper`、`Bitmap` 等）。用到没有桩的类时会在引擎日志里列出来。

### 蜘蛛的本地代理

蜘蛛返回的 `proxy://…` 和 `http://127.0.0.1:9978/proxy?…` 都指向引擎的 `/proxy`：先交给对应站点的蜘蛛实例，再依次交给各个 jar 的静态 `Proxy.proxy`；`do=js` 交给 JS 蜘蛛。引擎端口不是 9978 时会把端口告诉 jar。

## 4. 解析 `parses[]`

| `type` | 支持 | 说明 |
|---|---|---|
| 0 嗅探 | ✅ | 引擎用无头 Edge / Chrome 打开解析页，抓视频地址 |
| 1 JSON | ✅ | 读 `url` / `data.url`、`header(s)`、`user-agent`、`referer`、`parse` |
| 2 JSON 扩展 | ✅ | 调 jar 里的 `parser.Json<url>` |
| 3 JSON 聚合 | ✅ | 调 jar 里的 `parser.Mix<url>` |
| 4 超级解析 | 🟡 | 并发尝试所有 type 1 的 JSON 解析接口，取最先成功的；不并发嗅探类解析 |
| `ext.header` | ✅ | 请求解析接口时带上 |
| `ext`（整体） | ✅ | JSON 解析接口带 `ext` 时，以 `cat_ext=<base64>` 拼进地址（同 TVBox） |

默认解析器取列表第一个（与 TVBox 一致）；它失败后再并发尝试所有 JSON 解析接口。客户端目前不能手动选解析器。

## 5. 规则 `rules[]`

| 写法 | 支持 | 用途 |
|---|---|---|
| `host` + `rule` | ✅ | 嗅探：该域名下匹配这些正则的请求才算视频 |
| `host` + `filter` | ✅ | 嗅探：排除 |
| `hosts` + `regex`（`#EXT…`、时长数字） | ✅ | m3u8 去广告：删掉匹配的片段 |
| `hosts` + `regex`（其他正则） | ✅ | 嗅探规则 |
| `hosts` + `script` | ✅ | 嗅探页面加载后执行的点击脚本 |
| `exclude` | ✅ | 嗅探排除 |

去广告在规则之外还有一个保守的启发式（去掉夹在 `#EXT-X-DISCONTINUITY` 之间、来自少数路径的分片）；要删的内容超过一半时放弃，保留原列表。

## 6. 直播 `lives[]`

| 写法 | 支持 | 说明 |
|---|---|---|
| `{type: 0, url}`：TXT 列表 | ✅ | `分组,#genre#`、`频道,地址`、`地址#地址2`、`地址$线路名` |
| `{type: 0, url}`：M3U 列表 | ✅ | `group-title`、`tvg-logo`、`tvg-name`、`x-tvg-url`（多个地址依次尝试）、`#EXTVLCOPT` 与 `http-user-agent` / `http-referrer` 属性里的 UA / Referer |
| `{type: 0, url}`：JSON 列表 | ✅ | `[{"group"｜"name", "channels"｜"channel": [{"name", "urls"｜"url", "logo"}]}]` |
| `url` 写成 `http://127.0.0.1:9978/proxy?do=live&type=txt&ext=…` | ✅ | 等同 `proxy://do=live`，直接取它指向的列表 |
| `url` 或频道地址指向 `http://127.0.0.1:9978/proxy?…` | ✅ | 改指本引擎的 `/proxy`（由 jar 的代理处理）；没有蜘蛛应答时退而取 `url=` 参数里的列表 |
| `{group, channels: [{name, urls}]}` 内联 | ✅ | |
| `channels[].urls` 里是 `proxy://do=live&type=txt&ext=…` | ✅ | `ext` 是地址或其 base64 |
| 列表本身被包成配置格式（图片 base64、AES） | ✅ | |
| `epg`：带 `{name}` / `{date}` 的模板 | ✅ | 返回 `epg_data` 的那种接口 |
| `epg`：不带占位符的 DIYP 接口 | ✅ | 按 `?ch=&date=` 请求 |
| `epg`：XMLTV（`.xml` / `.xml.gz`） | ✅ | 也认 M3U 头里的 `x-tvg-url` |
| `logo`：带 `{name}` 的模板 | ✅ | |
| `ua`、`referer`、`header` | ✅ | 随线路下发给播放器 |
| `{type: 3, api, ext, jar, url}` 蜘蛛直播 | 🟡 | 列表由蜘蛛给出：jar 蜘蛛问 `liveContent(url)`，JS 蜘蛛问 `live(url)`（没写 `url` 时传脚本自己的地址，同 TVBox）。返回 TXT / M3U / JSON 文本都行，JS 也可以直接返回分组数组。蜘蛛没有返回、而 `url` 是个地址时，按普通列表下载它（TVBox 对这种写法也只是下载列表，蜘蛛只管频道的代理地址）。Python 蜘蛛直播不支持 |
| 蜘蛛列表里的 `proxy://…`、`http://127.0.0.1:9978/proxy?do=js&…` | ✅ | 指向本引擎的 `/proxy`，并补上这个直播源的蜘蛛的 `siteKey`，请求一定回到给出列表的那个蜘蛛。TVBox 是交给"最近用过的蜘蛛"；这里看直播的中途可以去点播别的站点，不带 `siteKey` 会串到别的脚本上 |
| `{type: 3}` 但没有 `api` | ⬜ | 「直播」页标"暂不支持" |
| `catchup` 回看 | ✅ | 见下面"回看" |
| `playerType`、`timeout`、`boot`、`pass` | ⬜ | 忽略 |

### 回看（catchup）

回看规则从这几处读，频道自己的优先：

| 写法 | 支持 | 说明 |
|---|---|---|
| M3U `#EXTINF` 的 `catchup`、`catchup-source`、`catchup-days`、`catchup-correction` | ✅ | `catchup-correction` 单位是小时（同 Kodi IPTV Simple），加到填进地址的开始 / 结束时间上 |
| M3U `#EXTM3U` 头上的同名属性 | ✅ | 作为所有频道的默认值，频道没写的项从这里取 |
| M3U `catchup-replace`、`timeshift="天数"`（SIPTV） | ✅ | 后者等于 `catchup="shift"` 加天数 |
| JSON 列表 / 配置内联频道的 `catchup`（对象，或类型字符串加 `catchup-source`） | ✅ | |
| `lives[].catchup` 对象：`type`、`source`、`replace`、`regex`（再加 `days`） | ✅ | 用于自己没有完整规则的频道；`regex` 不为空时，只有地址包含或匹配它的线路才能回看（TVBox） |
| 没有任何规则、地址里有 `/PLTV/` 的频道 | ✅ | 同 TVBox：`/PLTV/` 换成 `/TVOD/`，后面加 `?playseek=开始-结束` |

类型（`type` / `catchup`）：

| 类型 | 地址怎么来 |
|---|---|
| `default`、`vod` | `source` 就是完整地址 |
| `append`、不写 | 直播地址（先按 `replace` 的 `正则,替换` 改）后面接 `source`；直播地址已有查询串时 `source` 里的 `?` 换成 `&`（TVBox） |
| `shift`、`timeshift` | 直播地址加 `?utc={utc}&lutc={lutc}`（已有查询串时用 `&`） |
| `flussonic`、`flussonic-hls`、`flussonic-ts`、`fs` | 由直播地址推出：先给归档播放列表 `<名>-{utc}-{duration}.m3u8`（mpegts 为 `archive-{utc}-{duration}.ts`，可拖动），再给 Kodi 的 `timeshift_rel-{offset:1}.m3u8` / `timeshift_abs-{utc}.ts` 作为备选 |
| `xc`（Xtream Codes） | `http://主机/timeshift/用户/密码/{duration:60}/{Y}-{m}-{d}:{H}-{M}/编号.ts`（直播是 `.m3u8` 时用 `.m3u8`） |

占位符：`{utc}` / `${start}` 开始，`{utcend}` / `${end}` 结束，`{lutc}` / `${now}` / `${timestamp}` 现在（都是秒级时间戳）；`{duration}` / `${duration}` 秒数，`{duration:N}` 以 N 秒为单位；`{offset:N}` 从开始到现在；`{Y}{m}{d}{H}{M}{S}` 开始时间的各个字段；`{utc:YmdHMS}`、`${end:Ymd-H-M}` 这样带格式的（Kodi 的字母，也认 `yyyyMMddHHmmss` 这种 Java 写法）；TVBox 的 `${(b)yyyyMMddHHmmss}` / `${(e)yyyyMMddHHmmss}`（开始 / 结束，格式写 `timestamp` 时为时间戳）。日期按中国时间写，和节目单一致。不认识的占位符原样保留。还在播的节目只回看到现在。

天数：`catchup-days` / `days`，没写时 7 天（TVBox 列一周的节目单）。`rtp://`、`udp://` 组播地址不能回看。

不支持：Kodi 的 `{catchup-id}`（XMLTV 节目的 `catchup-id`）、`tvg-rec`、`|` 后面的播放器参数。

节目单按频道名匹配，匹配前会规整名字：`CCTV-1 综合` → `CCTV1`，`CCTV-5+ 体育赛事` → `CCTV5+`，去掉"高清 / 超清 / HD / 4K / 频道"等后缀。规整后查不到再用原名。

## 7. 播放结果（蜘蛛 `playerContent` 的返回）

| 字段 | 支持 | 说明 |
|---|---|---|
| `url` | ✅ | |
| `parse: 0` | ✅ | 直接播 |
| `parse: 1` | ✅ | 交给嗅探 |
| `jx: 1` | ✅ | 走解析列表 |
| `header` / `headers` | ✅ | 对象或 JSON 字符串都行 |
| `flag` | ✅ | |
| `playUrl` | ✅ | |
| `subs` / `subt` 字幕 | ⬜ | |
| `danmaku` | ⬜ | |
| `format` | 🟡 | 引擎按地址和响应判断格式，不看这个字段 |

## 8. 拿真实订阅体检

`tools/check-configs.sh` 会像客户端一样加载订阅，逐个仓库、逐个站点走「首页 → 第一个分类 → 第一部影片的详情」（`PLAY=1` 时再解析第一集的播放地址），逐个直播源拉频道列表和节目单，把结果写到 `dist/check-report.md`：

```bash
tools/check-configs.sh                      # ../tvbox-ysc-config/output 里的配置
tools/check-configs.sh <订阅地址 | 文件 | 目录>
ONLY=cms,remote,live tools/check-configs.sh # 只查采集站、远程站和直播（引擎里不装蜘蛛运行时，不会加载任何 jar / js）
```

报告把失败分成四类：**引擎兼容**（引擎要修）、**不支持**（还没做的类型）、**网络**、**站点报错**（后两类多半是站点自己失效，在安卓 TVBox 上同样打不开）。它用打包后的精简 Java 运行时跑，所以运行时缺模块之类的问题也会在这里暴露。

> 体检会在本机运行订阅里的蜘蛛代码（jar / js），和你在应用里点开这些站点时做的事一样。只对你信得过的订阅运行。

## 9. 调研数据

对 `tvbox-ysc-config` 聚合的公开配置做过一次统计（2026-11），用来决定先做什么：

- 518 个站点里 406 个是 jar 蜘蛛，其余主要是 JS 蜘蛛和采集站，Python 只有 4 个。
- `rules` 绝大多数是 m3u8 去广告规则。
- `lives` 以 `type: 0` 的 TXT / M3U 和 `proxy://` 为主，少量 `type: 3`。
