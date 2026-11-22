# 肥猫订阅的 Go 兼容引擎

这个本机服务读取原始 TVBox 订阅，将有适配器的站点导出为映舟可导入的 Type 4 订阅。游戏直播、急救、酷狗、兔小贝等站点直接通过 Go 访问各自的官网。Windows x64 还可以在独立的 AppContainer 内调用提前编译的原蜘蛛，运行时无需为这些蜘蛛安装 Java。Flutter 客户端仍连接映舟引擎。

## iOS / iPadOS

iOS 15 及以上的实验版默认使用内置 Go。打开「源 → 引擎」选择「本机 Go」或「远程引擎」。在极简模式从「设置 → 内容」进入。选择本机 Go 后直接添加原始订阅地址，例如 `http://肥猫.net`。选择远程引擎时填写桌面、安卓或 NAS 的映舟引擎地址并按提示配对。订阅、收藏和播放进度保存在各自的引擎，切回来会恢复。

本机 Go 支持单份 HTTP(S) JSON 订阅、已适配站点的分类、搜索、详情和直连播放。此次用相同 Go 服务在 Windows 读取肥猫得到 13 个入口，其中 12 个是纯 Go 站点，干饭提供目录。搜索《人工呼吸法》解出 1280 × 720 视频帧，酷狗《慌啥子嘛》解出 44.1 kHz 音频帧。依赖原始 JAR、JS、Python 或网页嗅探的线路可以选择有对应能力的远程引擎。下文的 32 个入口是 Windows x64 原生蜘蛛宿主的覆盖范围。

在 macOS 安装 Xcode、Flutter 3.50.0、CocoaPods 和 Go，在仓库根目录执行以下命令。

```sh
cd client
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign
flutter build ios --simulator --debug
flutter test -d <模拟器设备ID> integration_test/ios_go_engine_test.dart
```

GitHub Actions 为本分支构建设备 IPA 和模拟器 App。模拟器测试在设备内提供一个示例订阅，经 Flutter 调用 Go 取得播放地址，检查播放器播放本地音频，并在重启后读取原订阅。真机安装需要用自己的 Apple 开发身份签名。下载构建产物可前往 [iOS Go engine 构建记录](https://github.com/Sa1koro/yingzhou/actions/workflows/ios-lab.yml?query=branch%3Alab%2Fengine-go)。

在其他开发机上，可以从本目录运行 `go run . -mobile-data ./state.local -listen 127.0.0.1:9980` 启动相同的移动端 API。在映舟的「引擎地址」填写 `http://127.0.0.1:9980`，再在订阅框输入原始源地址。

## 直接导入原始地址

在 `lab/engine-go` 目录运行以下命令。Go 启动时读取订阅并选择本机支持的站点，搜索、详情和播放在请求时执行。

```powershell
go run . -source 'http://肥猫.net' -listen 127.0.0.1:9980
```

2026-11-22 在 Windows x64 实测，原始地址用 Go 引擎的请求头返回 40 个站点。上面的命令导出 13 个，其中 12 个使用 Go 适配器，干饭只提供目录。加上匹配的 `-spider-native` 后，导出 32 个，其中 12 个走纯 Go，20 个走编译后的原蜘蛛。逐站播放结果见后文。

发行版映舟可在「订阅」里添加 `http://127.0.0.1:9980/config.json`。要在普通订阅框直接输入原始地址，使用本分支构建的桌面引擎，在启动映舟的终端设置下面两个变量。如果 Go 监听 `9987`，第二个变量也填 `9987`。

```powershell
$env:YINGZHOU_LAB_GO_SOURCE = 'http://肥猫.net'
$env:YINGZHOU_LAB_GO_PORT = '9980'
```

用本分支的 `:server:installDist` 构建桌面引擎，从这个终端启动使用该引擎的映舟，然后添加 `http://肥猫.net`。订阅保留原地址，站点和解析器的相对路径指向已配对端口的 Go 服务。请在映舟引擎所在的电脑运行相应订阅的 Go 服务，并在使用期间保持它运行。上游站点配置变化后，重启 Go 服务并在映舟刷新订阅。其他订阅继续按各自原有方式导入。

实测向桌面客户端使用的添加订阅接口提交原始中文地址，然后激活并刷新。两次均得到 32 个 Type 4 站点。通过这份订阅搜索「人工呼吸」并打开《人工呼吸法》，FFmpeg 解出 1280 × 720 首帧。搜索酷狗《慌啥子嘛》后解出 44.1 kHz 音频帧。

GitHub Actions 适合对脱敏样例运行兼容性测试。把 `/config.json` 上传到 GitHub 会让其中的 `./t4/…` 指向 GitHub。这些接口需要本机适配器在用户点播时获取线路和时效地址。

## 运行在线版

本目录的 Go 程序需要 Go 1.22 或以上版本。Windows 原生宿主的构建需要 PowerShell 7.2+、GraalVM JDK 21、Visual Studio 2022 的 x64 C++ 工具、Windows SDK、已按[开发说明](../../docs/development.md)构建的映舟引擎，以及这版订阅提供的原蜘蛛文件。脚本校验原包摘要后才转换 DEX 和编译可执行文件。将 `GRAALVM_HOME` 和 `GANFAN_SPIDER` 分别设为本机工具目录和原包路径，然后在 `lab/engine-go` 运行以下命令。

```powershell
$out = Join-Path $env:LOCALAPPDATA 'Yingzhou/feimao-native'
$engineLib = (Resolve-Path '../../engine/server/build/install/tvbox-engine/lib').Path
& ./native-host/Build-GanFan.ps1 -Spider $env:GANFAN_SPIDER -GraalHome $env:GRAALVM_HOME -EngineLib $engineLib -OutputDirectory $out
$source = 'http://肥猫.net/'
go run . -source $source -spider-native (Join-Path $out 'ganfan-sandbox.exe') -listen 127.0.0.1:9987
```

在同一台电脑的映舟添加 `http://127.0.0.1:9987/config.json`。可以从「游戏直播 → 虎牙 → 英雄联盟」选一个直播间，或到「酷狗」搜索《慌啥子嘛》。`/status` 列出全部入口及执行方式。Go 在启动时核对原生宿主支持的类、站名和包版本，按原订阅的全局或单站包指纹匹配。每次调用带上真实的站点标识和该站的配置。订阅更换蜘蛛包后，需要用对应版本重建和验证。原单站宿主仍可用 `-drama2-native` 接入干饭。

此版本复用映舟的 Android 兼容类和 DEX 转换器，保留原蜘蛛的 v5 请求与解析逻辑。构建脚本为 GraalVM 调整了一处同步块的异常处理表，并省略 Android 专用的可选 `GoProxy` 辅助程序。依赖这个辅助程序的线路需要单独适配。

只运行 `go run . -source $source` 也可以使用纯 Go 站点以及干饭的实时分类和筛选，默认端口为 `9980`。

## Windows x64 逐站验证

本期肥猫有 40 个入口。上期导出 19 个，本期新增 13 个，共 32 个。其中 12 个走纯 Go，20 个调用 Windows x64 提前编译的原蜘蛛。实测使用独立的映舟桌面引擎导入 Go 订阅，从分类或搜索进入详情，再按映舟返回的播放信息用 FFmpeg 解码。直播间、线路和片单会随时间变化。

| 本轮新增入口 | 实测结果 |
| --- | --- |
| 游戏直播 | 保留虎牙、斗鱼和哔哩的分区、房间 ID 及 `folder` 标记。虎牙 6 个分区，英雄联盟 120 个房间。哔哩 115 个分区，英雄联盟 30 个房间。各打开一个房间，虎牙 HLS 与哔哩 FLV 均解出 1280 × 720 首帧。斗鱼显示 6 个分区，首分区 8 个房间，交给映舟的官网播放页本次解析返回 502。 |
| 急救 | 保留原站 8 个分类，「急救技能」19 项。目录中的《人工呼吸》对应官网影片《人工呼吸法》。定向搜索「人工呼吸」返回 4 部视频。从目录进入《人工呼吸法》、从搜索进入《什么是人工呼吸》均解出 1280 × 720 首帧。 |
| 酷狗 | 全球榜、热门榜、特色榜支持进入榜单和歌曲。官网搜索《慌啥子嘛》返回 299 项，首项是赵本山的录音。从搜索及「热门榜 → TOP500」进入这首歌，映舟均解出 44.1 kHz 音频帧。每次播放从官网重新获取试听地址。 |
| 荐片 | 首页 7 类、10 条推荐，电影第二页 15 项。搜索《方子传》精确命中，22 条线路中第 22 线解出 1280 × 720 首帧。前两条线路本次 DNS 失败。 |
| 咕噜 | 首页 12 类、21 条推荐。《重生2》搜索 23 项并精确命中。详情 6 条线路，第 4 线解出 1920 × 1080 首帧。 |
| 瓜子影视、豆瓣预告 | 瓜子影视首页 5 类、128 条推荐，电影《峡湾》第一条线路解出 1920 × 1080 首帧。豆瓣预告首页 1 类、13 条推荐，《沙丘》预告解出 864 × 486 首帧。 |
| 瓜子体育、看球直播 | 瓜子体育首页 4 类，热门赛程 20 场。「国王 vs 凯尔特人」通过映舟解出 1920 × 1080 首帧。看球直播保留 4 个分类，兼容原「全部直播」的空分类标识。实测全部赛程 62 场，进行中赛事的详情能列出 16 个播放选项。抽测的播放页需要嗅探，映舟本次在嗅探时超时。 |
| 一起 | 6 个分类，电影第 2 页有 90 项。搜索《空枪》精确命中，详情有 18 条可选线路。映舟通过第 6 线解出 1920 × 1080 首帧。原蜘蛛有时用约 33 秒返回清晰度与地址。Go 向映舟传递完整清晰度列表，该站缺省超时设为 50 秒，显式配置优先。桌面引擎同步按单站超时读取响应。 |
| 韩圈、金牌、火火 | 韩圈《背着善宰跑》和金牌《迷失许愿井路》能搜索并打开详情，本次抽测的播放请求返回 502。火火能搜索《山竹刀》，原蜘蛛解析该片详情时报数组越界。 |

余下 8 个入口在 `/status` 标为 `unsupported`。配置中心和网盘应用依赖 Android 交互。闪电和蜡笔共用 `Duopan`，原版测试在创建 Gson 数据对象时失败，搜索没有条目。米搜在初始化 Android 日志类时失败，盘搜缺少 Android 界面类。潮流原版首页为空，两次搜索返回 502。动漫巴士的隔离 JVM 基准遇到网络权限限制，Windows 原生宿主的首页和两次搜索均返回空列表。

上期的逐站记录如下。

| 站点 | 映舟客户端与媒体结果 |
| --- | --- |
| 行动 | 8 个分类，电影第二页 21 项。按片名搜索《石湖》精确命中，详情有 4 条线路。FFmpeg 从第一条解出 1280 × 720 首帧。 |
| 再来、干饭 | 各有 11 个分类、90 条推荐。电影第二页各 21 项，《与父与子》的搜索与详情对上原版，两个站均解出 1280 × 534 首帧。 |
| 儿童启蒙（兔小贝） | 4 个分类、24 条推荐，儿歌第二页 30 项。《洗白白》解出 1280 × 720 首帧。肥猫当时的 drpy 加载器和规则地址均返回 404，Go 按已识别的兔小贝规则从官网读取数据。《洗白白》《萤火虫》的搜索均精确命中。订阅保留原站的聚合搜索开关。 |
| 360 影视 | 4 个分类、30 条推荐，电影第二页 35 项。《寒战1994》搜索返回 5 项，详情有 6 条线路。第一条是要求解析的官方影片页，已打开该页。 |
| 一碗 | 本次入口返回 HTTP 451，原版与 Go 均得到空首页。 |
| 蔬菜、方舟、番薯、肥猫、光盘 | 对应 `AppGet` 或 `AppQi`。同一时段原版和 Go 均返回空分类、空推荐，本次没有节目可验。 |

Go 保留 CatVod 的筛选默认值、选集标识、播放请求头及 `parse`、`jx`。原订阅的两个 HTTP Type 1 JSON 解析器以本机地址提供，原解析器地址和配置头保存在本机进程。用本地测试解析器联测时，映舟按 360 返回的 `parse=1`、`jx=1` 调用了正确端点，拿到了测试用 MP4 地址和媒体请求头。两个 Type 3 混合解析插件需要另行适配。这次实机平台为 Windows x64。

本期肥猫订阅有 1 个 drpy 入口，显式 Python 入口为 0。另用依赖 `requests` 的社区 Python 蜘蛛做了对照。原 Python 的匿名详情请求收到 HTTP 412。在 Python 3.12.14 上回放公开存档的详情响应，与 Go 实时返回的 10 个分集逐项核对，分集名称、CID 和顺序全部相同。Python 展示合辑标题，Go 直接用 BV 号查详情时会在缺少搜索元数据的情况下显示第一集名称。[Python 插件固定版本](https://github.com/UndCover/PyramidStore/blob/94d6422dbe094779f7c70539e4cb948e84046594/plugin/py_bilibili.py) · [公开响应样本](https://github.com/minisheeep/bilibili-API-collect/blob/bae574a1a944554956e627026bd5107d2e8a3d13/docs/video/info.md#L944)

## 迁移几个真实条目

原生宿主也可以为 `-category` 提供片单和选集。也支持使用一个单独的、已激活原订阅的映舟 JVM 引擎作为迁移端。以下命令演示后一种方式，使用已经构建的 Windows 启动器。在未设置 `YINGZHOU_LAB_GO_SOURCE` 的终端运行，让迁移端直接加载原始蜘蛛。该实例监听 `127.0.0.1:9979`，客户端常用的引擎留作导入 Go 订阅。在同一实例中激活新订阅会切走原站。

```powershell
$source = 'http://肥猫.net/'
& ../../engine/server/build/install/tvbox-engine/bin/tvbox-engine.bat --port 9979 --data "$env:TEMP/yingzhou-ganfan-host" --subscribe $source
```

在另一个终端从电影分类第一页取两部，每条线路保留第一集。导入 Go 服务的订阅后，原蜘蛛进程即可退出。要浏览原站最新的整页片单，可以省略 `-category`，并保持原引擎在线。

```powershell
$source = 'http://肥猫.net/'
go run . -source $source -drama2-host http://127.0.0.1:9979 -category 1 -limit 2
```

取样默认保存在内存。`-page` 选择原站页码，`-item` 指定这页中的某个原站 ID，`-episodes` 决定每条线路保留多少个分集或频道。需要在重启后打开同一份样本时，使用 `-export-sample` 写入一个新文件，再用 `-sample` 启动。样本含有原 CDN 的临时地址，到期后需重新取样。央视直播应优先用在线版，在点播时向原站获取当前地址。

```powershell
go run . -source $source -drama2-host http://127.0.0.1:9979 -category 1 -limit 2 -export-sample ./film.local.json
go run . -sample ./film.local.json
```

## 2026-11-21 本机实测

原订阅有 40 个入口。干饭返回 11 个分类、90 部首页推荐和 5 组电影筛选。原生在线版在原 JVM 蜘蛛进程关闭后读取电影第 2 页，共 21 部。映舟的 Type 4 客户端通过这套服务找到了《一些往事》，读取 2 条线路并成功解析播放。FFmpeg 通过相同的 Go 订阅从影片及直播的实际媒体解出了首帧。

| 原站条目 | 获取方式 | 首帧 |
| --- | --- | --- |
| 一些往事 | 原生在线版，分类第二页 | 1280 × 544 |
| CCTV直播，原站频道「1」 | 原生在线版，播放时获取当前地址 | 1920 × 1080 |
| 四渡 | JVM 原蜘蛛取样后关闭，Go 独立提供订阅 | 1280 × 534，与原版首帧 SHA-256 一致 |
| 峡湾 | JVM 原蜘蛛取样后关闭，Go 独立提供订阅 | 1280 × 720，与原版首帧 SHA-256 一致 |

快照下的搜索只覆盖已迁移的条目。电影快照保留了《四渡》的 10 条线路和《峡湾》的 4 条线路，各抽测 1 条。直播快照保留了 31 个频道，其中抽测的地址随后到期。切换到在线版并重新选择频道「1」后恢复播放。此处的平台验证仅覆盖 Windows x64。

```powershell
go test ./...
$env:GANFAN_TEST_SUBSCRIPTION = 'http://肥猫.net/'
go test -count=1 -run TestGanFanLiveCatalog -v
$env:GANFAN_TEST_NATIVE = Join-Path $out 'ganfan-sandbox.exe'
$env:APPDRAMA2_TEST_SITES = '干饭,行动,再来'
go test -count=1 -run TestAppDrama2LiveSites -v
$env:YINGZHOU_TEST_DRPY_LIVE = '1'
go test -count=1 -run TestDrpyLiveOfficialSite -v
$env:YINGZHOU_TEST_FIRSTAID_LIVE = '1'
$env:YINGZHOU_TEST_KUGOU_LIVE = '1'
go test -count=1 -run 'TestFirstAidLiveOfficialSite|TestKugouLiveSearchAudio' -v
```

订阅入口暂时返回 HTTP 522 时，`-source` 和 `GANFAN_TEST_SUBSCRIPTION` 也接受已保存的原始订阅文件。文件只提供站点配置，分类、搜索、详情和播放仍在线请求。
