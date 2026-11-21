# 开发指南

## 1. 环境

| 工具 | 版本 | 用途 |
|---|---|---|
| JDK | 21（Temurin） | 引擎；打包时用它的 `jlink` 裁出精简 JRE |
| Flutter | 3.50+ | 客户端 |
| Visual Studio | "使用 C++ 的桌面开发"工作负载 | Windows 客户端；还需要打开系统的**开发者模式**（插件要建符号链接） |
| Xcode | — | macOS 客户端 |
| Linux 构建依赖 | Ubuntu 24.04 或更新：`clang cmake ninja-build pkg-config libgtk-3-dev libx11-dev libxi-dev liblzma-dev libmpv-dev`，打 deb 还要 `dpkg-dev` | Linux 客户端（见第 6 节"Linux"） |
| Android SDK | platforms;android-36、build-tools;36.0.0 | 只在构建 Android 客户端或重建演示 jar 时需要 |
| Python | 3.8+，可选 | Python 蜘蛛的引擎测试和演示站要用；找不到时这些测试跳过。用 `TVBOX_PYTHON` 指定 |

Windows 上用 scoop 装的话，新开的终端里要有这些环境变量（Git Bash）：

```bash
export JAVA_HOME="$HOME/scoop/apps/temurin21-jdk/current"
export ANDROID_HOME="$HOME/scoop/apps/android-clt/current"
export FLUTTER_ROOT="$HOME/scoop/apps/flutter/current"
export PATH="$JAVA_HOME/bin:$FLUTTER_ROOT/bin:$ANDROID_HOME/platform-tools:$HOME/scoop/shims:$PATH"
```

## 2. 仓库怎么分

```
engine/          Kotlin/JVM，Gradle 多模块
  core/          协议逻辑，纯 JVM，Android 上也跑：config / site / search / play / live / cache（播放缓存）/ download（离线下载）
  api/           HTTP 路由（Ktor），独立进程和 Android 内置引擎共用
  server/        独立进程入口；演示站（--demo）；CDP 嗅探
  runtime-js/    QuickJS 宿主
  jar-host/      TVBox 宿主类 + jar 运行时公共部分（只有源码目录，被 runtime-jar 和 Android 工程各自编译）
  runtime-jar/   桌面 jar 运行时：dex2jar、字节码修复、安卓桩类
client/          Flutter
  lib/engine/    引擎协议的客户端和数据模型；桌面上启动内置引擎
  lib/pages/     首页、详情、搜索、播放、直播、我的、源
  lib/ui/        外壳（导航）、主题、通用组件
  lib/desktop/   窗口：全屏、记住大小位置
  android/       Android 宿主工程，复合构建引入 engine
  macos/ windows/ linux/
tools/           打包脚本
docs/            文档
```

## 3. 日常命令

```bash
# 引擎
cd engine
./gradlew test                              # 全部引擎测试
./gradlew :server:installDist               # 产出 server/build/install/tvbox-engine，客户端开发模式会用它
./gradlew :server:run --args="--port 9978"  # 单独跑引擎

# 客户端
cd client
flutter test                                # 单元 / 组件测试（用 test/fake_engine.dart，不需要引擎）
flutter run -d windows                      # 没有引擎在 9978 上时会自己拉起上面 installDist 的引擎（macOS、Linux 换成 -d macos / -d linux）
```

`flutter test` 里唯一要真引擎的是 `test/engine_crash_test.dart`：用应用自己的启动代码（`engine/local_engine_io.dart`）在空闲端口上起演示引擎（`--demo`，数据在内存里），从外面结束进程、占住它的端口让它起不来，检查 `engine.log` 和崩溃记录留下了原因。没有 `installDist` 的产物或找不到 Java（`JAVA_HOME`，或 PATH 上的 `java`）时这几个用例跳过。诊断的其他测试：`diagnostics_redact_test.dart`（遮掉什么）、`diagnostics_store_test.dart`（轮换和上限）、`diagnostics_hooks_test.dart`（组件里抛的错、没人接的异步错误都留下记录）、`diagnostics_page_test.dart`（桌面和电视上的卡片与页面）、`diagnostics_feedback_test.dart`（新问题页面的网址与 `.github/ISSUE_TEMPLATE/bug_report.yml` 的字段对得上）。

引擎参数：`--port`、`--lan`（监听 0.0.0.0，局域网共享始终开启，配对码打印在标准输出）、`--name <名字>`（局域网里显示的名字，默认"映舟 · 计算机名"）、`--data <目录>`（默认 `~/.tvbox-next/engine`）、`--subscribe <地址>`、`--drive-folder <目录>`（把这台机器上的文件夹加成网盘，可以写多次，已有的不重复加）、`--demo`、`--dev-cors`、`--exit-with-stdin`。

### 局域网共享与鉴权

- 代码：`engine/api/src/main/kotlin/tvbox/engine/api/access/`（`AccessControl` 配对码、令牌、签名；`AccessPlugin` 拦截器、`/pair`、`/lan`、给响应里的引擎地址签名；`LanListeners` 按地址另起监听、地址变化、通告——桌面和安卓共用），`engine/server/.../lan/LanSharing.kt`（桌面：CIO + JmDNS），安卓 `client/android/.../engine/AndroidLan.kt`（CIO + `NsdManager`，见 architecture.md 2.2）。客户端：`client/lib/engine/lan.dart`、`discovery*.dart`、`lib/ui/pairing_dialog.dart`、`lib/pages/lan_section.dart`。协议见 [protocol.md](protocol.md)"鉴权与配对"。
- `EngineModuleOptions(access = …)` 不传时是"只有本机"。新加的路由不用做任何事就受保护；返回引擎地址的新接口，返回 `PlayInfo` / `LiveList` 会自动签名，其他形状自己调 `AccessControl.sign`。
- 测试：`engine/api/src/test/.../LanListenersTest.kt`（开关、地址变化、监听失败、`--lan`；最后一个用例在本机局域网地址上起真实监听，经 `PUT /api/v1/lan` 打开后配对）。
- 测试：`engine/api/src/test/.../AccessTest.kt`。测试宿主的请求来自回环地址，"别的设备"用外来的 `Host` 头模拟；有一个用例在本机的局域网地址上起真实的 CIO 监听，从非回环地址访问。这些都还是同一台机器，**没有跨真实网络测过**；mDNS 通告只确认了注册不报错，没有用另一台设备搜到过。客户端用 `test/fake_lan_engine.dart` 模拟要令牌的远程引擎。
- 手动试：`--demo --port 19984` 启动后 `curl -X PUT -H 'Content-Type: application/json' -d '{"enabled":true}' http://127.0.0.1:19984/api/v1/lan`，返回里有地址和配对码；用局域网地址访问 `/api/v1/sites` 应得 401。试完记得关掉（`{"enabled":false}`）或停掉引擎。
- Git Bash 传给 Java 的中文参数会乱码（`--name 测试引擎`），测试时用英文名。

### 手机遥控

设计见 [architecture.md](architecture.md) 第 4 节"手机遥控"，协议见 [protocol.md](protocol.md)"遥控"。代码：引擎 `engine/api/.../remote/`（`RemoteHub` 中枢、`RemoteRoutes` 路由和静态文件）与 `access/AccessPlugin.kt` 里那两条 WebSocket 路由的规则；网页遥控器 `engine/api/src/main/resources/remote/`；客户端 `client/lib/remote/`（屏幕一侧：`remote_agent.dart` 连接、`remote_screen.dart` 状态与命令、`remote_keys.dart` 合成按键、`remote_text.dart` 输入框、`remote_settings.dart` 开关和二维码；遥控一侧：`remote_controller.dart`、`remote_page.dart`）、`lib/pages/player_remote.dart`、`live_remote.dart`。

- **引擎测试**：`./gradlew :api:test --tests "tvbox.engine.api.RemoteTest"`。测试宿主的 WebSocket 客户端被拒绝时只知道握手失败，所以拒绝的情形用普通请求读状态码和错误码，再挑几个用 WebSocket 客户端确认真的连不上（测试宿主里每次失败的握手要等 1 秒）。
- **客户端测试**：`flutter test test/remote_test.dart test/remote_page_test.dart`（后一个是手机上的「遥控另一台映舟」）。整个应用的测试经 `RemoteScreen.debugConnector` 把到引擎的 WebSocket 换成 `test/fake_remote_hub.dart`，测试自己扮演中枢和手机。
- **改网页**：引擎从 jar 里读这几个文件并缓存，改一次要重新 `installDist`。开发时给引擎加 `-Dtvbox.remote.dir=<仓库>/engine/api/src/main/resources/remote`，就直接读这个目录、每次请求重读，改完刷新浏览器即可。CSP 不允许内联脚本和 `style=""` 属性（用 JS 设 `el.style` 可以），外部资源一律不许。
- **没有应用也能看网页**：`node tools/remote/fake-screen.mjs http://127.0.0.1:19990` 向引擎登记一块假屏幕"演示屏幕"，报告一部正在播放的片，打印收到的每条命令，并对暂停、跳转、倍速、音量、换集等作出反应（`--idle` 没在播放，`--live` 直播，`--text` 有输入框）。然后在浏览器里打开 `http://127.0.0.1:19990/remote/`（本机不用配对）。
- **截图**：`node tools/remote/screenshots.mjs http://127.0.0.1:19990 <目录>` 用无头 Edge / Chrome 按手机尺寸（390×844，3 倍）截「遥控」和「播放」两页，存成 `web-remote-remote.png`、`web-remote-play.png`（引擎和假屏幕要先开着，而且只有这一块屏幕，否则网页先让你选屏幕）。
- **在真实应用里**：`flutter test integration_test/remote_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19990 --dart-define=SHOT_DIR=<目录>`（演示引擎先在 19990 上开着）。应用以电视模式启动（**测试期间窗口会全屏**），测试经引擎的 `/api/v1/remote/control` 发按键和命令，检查焦点移动、暂停、跳转、换集（用《慢速源演示》，不需要外网）。
- **手动走一遍配对**：演示引擎 `curl -X PUT -H 'Content-Type: application/json' -d '{"enabled":true}' http://127.0.0.1:19990/api/v1/lan` 打开共享，回答里有局域网地址和配对码；用那个地址在浏览器里打开 `/remote/#code=<配对码>`（同一台机器的局域网地址不算本机，要配对）。试完关掉共享。
- **没有验证过的**：真手机（iOS Safari、安卓 Chrome、微信内置浏览器）上的触摸、按住连发、震动、添加到主屏幕、锁屏后的重连；跨真实网络的连接（都是同一台机器）；macOS / Linux 上的电视模式全屏；安卓内置引擎里的 WebSocket 路由（代码和桌面共用，但没有在设备或模拟器上跑过）。

## 4. 演示引擎

`--demo` 会在引擎里起一个假的站点并订阅它，开发和测试都用它，不依赖任何真实订阅：

```bash
cd engine && ./gradlew :server:run --args="--demo --dev-cors --port 19978"
```

它提供：一个采集站、一个 JS 蜘蛛站、一个 jar 蜘蛛站、一个需要嗅探的站；JSON 解析、jar 聚合解析、嗅探解析各一个；一条去广告规则；一个带节目单的直播源（含一个第一条线路是死链的频道，用来测自动换线）；「演示直播」里的「回看演示台」能回看 3 天（`catchup="default"`，回看地址是 `/demo/catchup.m3u8?start=&end=&utc=`，时间填对了就 302 到点播测试流，填错或不是过去的时间返回 400）；一个由 JS 蜘蛛给出列表的直播源「演示JS直播」（`/demo/live.js`，三个频道的地址分别是直链、脚本自己的代理地址和 `proxy://`，后两个要请求回到这个脚本才播得出来）；Python 蜘蛛的「演示Python站」（`/demo/py/demo_vod.py`，只用标准库：浏览、搜索，每部片两条线路"直连"和"代理"，后者经蜘蛛的 `localProxy` 取播放列表）、「演示Python依赖站」（`demo_pkg.py`，导入 lxml：没装时用来看缺包提示和安装按钮）和直播源「演示Python直播」（`demo_live.py`，频道写法同「演示JS直播」），脚本在 `engine/server/src/main/resources/demo/py/`，见下面"Python 蜘蛛"。点播里《白昼迷踪 第二季》（首页第二个）的第一条线路"失效线路"也是死链，用来测点播的自动换线路。演示模式的数据默认只在内存里。

演示 jar 的源码在 `engine/server/demo-jar/`，改了之后跑 `build.sh`（javac + d8）重新生成。

### 演示网盘

演示引擎启动时加两个网盘（`DemoDrive.kt`），内容相同：`演示剧集/第1集.ts`（旁边有 `第1集.srt`）、`第2集.ts`（旁边有 `第2集.zh.vtt`）、`第10集.ts`（测按数字排序），根目录的 `短片.ts` 和一个 `说明.txt`。视频由 `DemoVideo` 现做（每集 18 秒、约 1.2 MB，各集从不同的分片开始，画面上的分片号能看出是哪一集），仓库里没有视频文件。

- 「演示 WebDAV」：引擎自己的 `/demo/dav/`（`PROPFIND`、`GET`、`HEAD`、`Range`，Basic 认证，账号 `demo` / `demo`）。因为有账号，播放器拿到的是引擎的 `/drive/<id>/…`。
- 「演示本机文件夹」：上面的文件写到引擎临时目录的 `demo-drive`（`%TEMP%/tvbox-next-engine-<端口>/demo-drive`；带 `--data` 时在数据目录下），每次启动重写。

带 `--data` 启动时网盘会存下来，再启动不会重复添加。

试网盘的接口（Git Bash 会把以 `/` 开头的参数改成 Windows 路径，中文路径要先编码）：

```bash
curl -s http://127.0.0.1:19987/api/v1/drives
curl -s "http://127.0.0.1:19987/api/v1/drives/<id>/list?path=%2F%E6%BC%94%E7%A4%BA%E5%89%A7%E9%9B%86"
```

测试：`engine/core/src/test/.../drive/`（`FakeDriveServers.kt` 里有测试用的 AList 和 WebDAV 服务器；本机文件夹的路径安全，包括指出文件夹的符号链接——Windows 上要开开发者模式才能建符号链接，建不了时这一段跳过）、`engine/api/src/test/.../DriveRoutesTest.kt`（HTTP 层：回答里没有密码和令牌、`Range`、局域网设备拿到签名地址）。客户端：`test/drives_page_test.dart`（`test/fake_drive_engine.dart` 在 `fake_engine.dart` 之上加了网盘接口）、`integration_test/drive_test.dart`（真实应用里浏览两个演示网盘并播放，见第 5 节）。

### 慢速片源

首页最后一个《慢速源演示》是一个故意又慢又限速的 HLS 片源（`/demo/slow`，`DemoSlowSource.kt`），用来测拖动进度条和播放缓存。视频是引擎里现算出来的（`DemoVideo.kt`：手写的 H.264 + MPEG-TS，40 分钟、每段 6 秒、约 2 Mbit/s），不需要编码器，仓库里也没有视频文件；画面上是分片序号和时间，截图就能看出跳到了哪。五集是同一段视频的五种写法：普通播放列表、主播放列表、AES-128 加密、字节范围（所有分片在一个文件里）、直链（整个文件，不是 HLS）。

- `GET /demo/slow/set?delayMs=&connectMs=&kBps=&totalKBps=&reset=1`：每个请求先等多久、新连接多等多久、每个连接限速多少 kB/s、所有连接合计限速多少（0 不限）；`reset=1` 清空请求记录。默认 400 / 300 / 300 / 0。
- 还有两个制造故障的参数：`cutAfter=<字节数>` 让每个分片应答发到这么多就断开连接，`refuse=<状态码>` 让分片和密钥一律返回这个状态码（都是 0 关闭）。用来看片源出问题时引擎和播放器各自怎么收场。
- `GET /demo/slow/log`：当前参数和收到的每个请求（哪个分片、字节范围、发了多少、是否中途断开、是不是新连接）。

它的地址写成 `localhost` 而不是 `127.0.0.1`：引擎不会把自己地址上的 m3u8 再包一层 `/m3u8`，换个名字它才和普通站点一样经过播放列表接口和播放缓存。

《慢速源演示》后面四集是给离线下载用的（`DemoDownloads.kt`）：「短片」「短片加密」「短片直链」是同一段视频的前两分钟（20 个分片，约 30 MB），分别是普通播放列表、AES-128 加密、直链文件，演示时几秒到几十秒就能下完；「直播」是一个随时间滑动、没有结尾的播放列表，下载会拒绝它。上面的 `set` 参数对它们同样有效：`kBps` 调慢能看清进度和速度，`refuse=503` 相当于片源下线（播放列表照常给，分片和密钥都拒绝），用来演示下载中途失败、重试，以及片源下线后离线播放。

### 字幕、音轨与弹幕演示

首页最后两个是《字幕演示》和《弹幕演示》（`DemoMedia.kt`），视频同样是现算出来的（三分钟），不需要外网。字幕和弹幕只在「演示JS站」里有：JS 蜘蛛的 `play` 遇到 `/demo/av/` 的地址时，把 `/demo/extras?url=` 返回的整个播放结果交出去；在「演示站」（采集站）里打开就只有视频。

- 《字幕演示》：`/demo/av/master.m3u8`，主列表里有两条 `#EXT-X-MEDIA` 音轨（国语单声道、English 立体声，MPEG-1 Layer II，手写的静音帧，没有编码器所以听不出区别，只能看音轨列表）；`subs` 给三条字幕：`/demo/subs/gbk.srt`（GBK 编码、CRLF、不声明编码）、`/demo/subs/styled.ass`（带样式、顶部提示、UTF-8 BOM）、`/demo/subs/private.srt`（没有 `Referer: …/demo/` 就 403，播放结果的 `header` 里给了）。
- 《弹幕演示》：`/demo/av/video.m3u8`，蜘蛛给出 `danmaku: /demo/danmaku/dense.xml`：三分钟 3000 条 B 站 XML（固定随机种子，85% 滚动、8% 顶部、7% 底部），像 B 站一样用不带头的 deflate 压缩并声明 `Content-Encoding: deflate`。
- 演示配置有顶层 `danmaku`：`/demo/danmaku/api?name={name}&episode={episode}`，对任何片名都回答 `{"url": …/demo/danmaku/comments.json?…}`，后者是 80 条弹幕接口常见的 JSON（`comments[].p` = 时间,模式,颜色,用户）。引擎只在「设置 → 弹幕」里打开"订阅的弹幕接口"之后才会问它。

### 离线下载

代码：`engine/core/.../download/`（`DownloadManager` 队列与下载、`DownloadExport` 导出），`engine/api/.../DownloadRoutes.kt`（`/api/v1/downloads`、`/dl/…`），`StreamStore` 的 `adopt` / `workFile` / `remove`。客户端：`client/lib/engine/downloads.dart`（接口、轮询的 `DownloadsWatcher`）、`download_files*.dart`（把导出存到本机、在文件管理器里显示），`lib/pages/download_sheet.dart`（详情页的下载按钮、选集、每集的状态）、`downloads_tab.dart`（「我的 → 下载」）、`download_settings.dart`（「设置 → 离线下载」）。协议见 [protocol.md](protocol.md)"离线下载"，设计见 [architecture.md](architecture.md)"离线下载"。

- 测试：`DownloadManagerTest`（核心：并发上限、重启后继续、钉住与缓存上限、密钥和初始化段、直链断点续传、导出、地址过期、直播、空间不足）、`DownloadRoutesTest`（经 HTTP：片源关掉后离线播放、局域网签名、事件、设置）；客户端 `test/downloads_test.dart`。
- 手动试：`--demo --port 19988 --data <临时目录>` 启动（带 `--data` 才能试"重启后接着下"），在详情页下载「短片」，或者 `curl -X POST -H 'Content-Type: application/json' -d '{"items":[{"site":"demo","line":"慢速线路","episodeId":"http://localhost:19988/demo/slow/short/index.m3u8"}]}' http://127.0.0.1:19988/api/v1/downloads`。Git Bash 里 curl 发出去的中文会变成问号，片名在列表里就是一串 `?`，从客户端发的不会。
- **试导出时一定给 `path`**：不给就写进用户真正的「下载」文件夹（桌面引擎的默认导出目录）。

### Python 蜘蛛

设计见 [architecture.md](architecture.md) 2.11。代码在 `engine/runtime-py`：Kotlin 一侧 `PyRuntime`（`SpiderRuntime`）、`PySpider`、`PyWorker`（进程与协议）、`PythonManager`（找 Python、下载、装包）、`PythonLocator`、`PyScripts`；Python 一侧在 `src/main/resources/tvbox/py/`。路由 `engine/server/.../PythonRoutes.kt`；客户端 `client/lib/engine/python.dart`、`lib/pages/python_settings.dart`。

- **用哪个 Python**：引擎启动时在后台找（顺序见 compatibility.md "Python 蜘蛛"），日志里打印一行 `python: using …`。开发时想换一个，设 `TVBOX_PYTHON=<python 路径>` 再启动引擎；或者在应用「设置 → Python 蜘蛛」里填。`--demo` 不带 `--data` 时，下载的运行时和装的包都在系统临时目录的 `tvbox-next-engine-<端口>/python` 里。
- **演示站**：「演示Python站」只用标准库，有 Python 就能跑；「演示Python依赖站」要 lxml，可以在设置里点安装，也可以拿它看缺包时的样子。改了 `demo/py/*.py` 要重新 `installDist`。
- **测试**：`./gradlew :runtime-py:test`。`PyRuntimeTest` 用真的 Python 跑 `src/test/resources/py/` 里的测试蜘蛛（浏览、搜索、播放、代理、直播、依赖、崩溃、卡死、缺包、网络规则），`PyLanTest` 测配对设备打开 Python 蜘蛛的代理地址，`PythonManagerTest` 用本地的假服务器测下载 CPython（含校验失败）和 pip 装包（含没有 pip 时先取 pip 的 wheel）。全部只连本机。没有 Python 时这些测试跳过（`Assumptions`）；用到 `requests` 的那一个在 Python 没装 requests 时跳过——要跑它，建一个装了 requests 的虚拟环境并设 `TVBOX_PYTHON`：

  ```bash
  python -m venv <临时目录>/venv && <临时目录>/venv/Scripts/python -m pip install requests lxml
  TVBOX_PYTHON=<临时目录>/venv/Scripts/python.exe ./gradlew :runtime-py:test --rerun-tasks
  ```

  CI（`.github/workflows/desktop.yml` 的 Windows 任务）用 `actions/setup-python` 装 Python，所以这些测试在 CI 上会跑。
- **单独看 worker**：`python -E -X utf8 -u <bridge>/worker.py --home <目录>` 后在标准输入里逐行敲 JSON（`{"id":1,"op":"setup","proxy":"http://127.0.0.1:9978/proxy"}`、`{"id":2,"op":"load","key":"k","path":"x.py"}`、`{"id":3,"op":"init","key":"k","ext":""}`、`{"id":4,"op":"call","key":"k","method":"homeContent","args":[true]}`），第一行输出是 `{"id":0,…,"hello":1}`。bridge 目录在 `<数据目录>/python/bridge/<哈希>/`。
- **集成测试**：`client/integration_test/python_test.dart` 在真实应用里打开「演示Python站」、播放经蜘蛛代理的线路、搜索、看依赖站的缺包提示、播放「演示Python直播」的代理频道（跑法同下面第 5 节，引擎所在的机器要有 Python）。

## 5. 在真实 Windows 应用里跑集成测试

单元测试覆盖不到播放器、窗口和全屏。`client/integration_test/` 里的测试会启动真正的应用，连演示引擎，一步步操作：

```bash
# 先在另一个终端启动演示引擎（见上），然后：
cd client
flutter test integration_test/desktop_play_test.dart -d windows --dart-define=SHOT_DIR=<截图目录>
flutter test integration_test/live_test.dart -d windows --dart-define=SHOT_DIR=<截图目录>
flutter test integration_test/drive_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19978 --dart-define=SHOT_DIR=<截图目录>
```

`drive_test.dart` 打开「网盘」，进「演示 WebDAV」的 `演示剧集`，检查排序和"有字幕"，播放第 1 集、按 N 播第 2 集、返回后看"上次看到"，再到「演示本机文件夹」播放 `短片.ts`。

每一步会打印 `MARK:<步骤>`，给了 `SHOT_DIR` 就在那一步存一张截图（应用内截图，包含视频画面；从外部截测试窗口是黑的）。

macOS、Linux 上把 `-d windows` 换成 `-d macos` / `-d linux`。没有桌面的 Linux（服务器、CI）在虚拟屏幕上跑，而且要有窗口管理器，全屏是它的事，没有它全屏那一步过不了：

```bash
sudo apt install xvfb openbox libgl1-mesa-dri fonts-noto-cjk
Xvfb :99 -screen 0 1600x900x24 & export DISPLAY=:99; openbox &
flutter test integration_test/desktop_play_test.dart -d linux --dart-define=SHOT_DIR=<截图目录>
```

`desktop_play_test.dart` 的"subtitles, audio tracks and danmaku"一步要用「演示JS站」的《字幕演示》《弹幕演示》（见第 4 节），开始前会删掉这两部片在引擎里的观看历史（否则会按上次选的字幕和进度继续）。弹幕部分把帧策略切到 `fullyLive`，按引擎实际出的每一帧统计构建 / 光栅化耗时，打印三行 `DANMAKU_FRAMES:{…}`（弹幕开、全屏、弹幕关），结果记在 [architecture.md](architecture.md) 第 4 节。按键偶尔没有送到播放页时，前面一行 `KEYS:` 会打印当时按住的键和焦点在哪。

`integration_test/seek_test.dart` 量的是拖动进度条的耗时：在《慢速源演示》上播一分钟，然后点进度条——跳到预读的位置、看过的位置、两处没缓存的位置、回到其中一处、回到开头，中间还按住拖两秒。每次跳转打印一行 `SEEK:{…}`：从点击到出第一帧（`firstPictureMs`）、到重新播起来（`playingMs`）各多少毫秒，播放器收到几次跳转，片源收到哪些请求；另外打印应用和引擎的内存（`MEMORY:{…}`）。第二个用例播"直链"那一集，检查播放器自己的缓存文件。缓存命中的跳转要求一秒内恢复、不向片源请求落点所在的分片，拖动只算一次跳转。

```bash
flutter test integration_test/seek_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19978 --dart-define=SHOT_DIR=<目录>
# 片源多慢可以调：--dart-define=SLOW_KBPS=300 --dart-define=SLOW_DELAY_MS=800 --dart-define=SLOW_TOTAL_KBPS=600
# 只量不判（比如量一个没有播放缓存的旧版本）：--dart-define=SEEK_STRICT=false
```

结果也写到 `SHOT_DIR/seek-results.json`。引擎不带 `--data` 时播放缓存在系统临时目录的 `tvbox-next-engine-<端口>/cache/stream`，每次启动清空；测试开始时也会清一次。

`integration_test/download_test.dart` 是离线下载：在详情页下载「短片」，看着选集按钮下的状态从排队到百分比再到"已下载"；然后让慢速片源拒绝一切分片和密钥（`refuse=503`），播放这一集，拖到快结尾、再拖回开头，要求片源一个请求都没收到，播放页写着"离线播放"；再在片源关着的时候下载「短片加密」，它失败并在「我的 → 下载」里写明原因，打开片源后点重试下完。开始前和结束时都删掉引擎里的下载。

```bash
flutter test integration_test/download_test.dart -d windows --dart-define=ENGINE_URL=http://127.0.0.1:19988 --dart-define=SHOT_DIR=<目录>
```

## 5a. 在安卓模拟器上跑和测内置引擎

内置引擎的安卓部分（前台服务、通知、MediaStore 导出、`NsdManager`、只在 Wi-Fi / 有线网络上监听）只能在设备或模拟器上看。别用存着自己真实订阅的那个 AVD，另建一个：

```bash
# Windows 上 avdmanager 是 .bat
echo no | avdmanager.bat create avd -n yz-test -k "system-images;android-34;google_apis;x86_64" -d pixel_6
emulator -avd yz-test -port 5560 -no-window -gpu swiftshader_indirect -no-snapshot-save -no-boot-anim -no-audio
adb -s emulator-5560 wait-for-device
cd client && flutter build apk --debug && adb -s emulator-5560 install -r build/app/outputs/flutter-apk/app-debug.apk
```

- **演示引擎在电脑上**：`--demo --port 19992`（别用 9978，模拟器里的 App 自己占着 9978），模拟器里用 `http://10.0.2.2:19992/demo/config.json` 订阅。演示站的地址按请求的 Host 生成，所以都是 `10.0.2.2`。`adb shell input text` 打英文网址时会被输入法自动纠正，订阅更省事的办法是走接口（见下）。
- **从电脑访问模拟器里的引擎**：`adb -s emulator-5560 forward tcp:29978 tcp:9978`（先确认电脑上这个端口空着：别的会话、别的引擎可能占着相邻的端口），然后 `curl http://127.0.0.1:29978/api/v1/info`。经 `adb forward` 进来的请求来自模拟器的回环地址，引擎当它是"本机"，不用配对；要模拟局域网里的另一台设备，加一个不是回环的 `Host` 头（`-H "Host: 10.0.2.18:9978"`），这时 `/api/v1/sites` 得 401，`POST /api/v1/pair` 带上配对码换到令牌后得 200。Git Bash 里 curl 的 `-d '{"line":"慢…"}'` 会被改坏，JSON 写进文件用 `--data-binary @文件`。
- **局域网监听本身**：模拟器的 `wlan0`（如 `10.0.2.18`）是 Wi-Fi，`eth0`（`10.0.2.15`）是模拟的移动网络。打开共享后引擎只在 `wlan0` 上监听；电脑连不到 `wlan0`（模拟器的 `redir` 只通 `eth0`），要从非回环地址访问就在模拟器里用 `nc`：把一段 `printf 'GET /api/v1/sites HTTP/1.1\r\nHost: …\r\n…' | nc -w 5 10.0.2.18 9978` 写成脚本 `adb push` 进去再 `adb shell sh` 运行（直接写在 `adb shell` 命令行里转义会乱）。
- **mDNS**：两个模拟器各有各的虚拟网络，互相发现不了，也连不上。能做的是在同一个模拟器的 App 里「源 → 局域网里的引擎 → 搜索」，应该能找到自己（"映舟 · sdk_gphone64_x86_64"），说明 `NsdManager` 的注册、类型和 TXT 都对。
- **前台服务和通知**：`adb shell dumpsys activity services io.github.sa1koro.yingzhou` 看 `isForeground=true` 和 `types=`（`1` = dataSync 下载，`10` = connectedDevice 共享，`11` = 两者）；`adb shell cmd statusbar expand-notifications` 拉下通知栏再截图（`adb exec-out screencap -p > x.png`），`cmd statusbar collapse` 收起；`adb shell uiautomator dump /sdcard/ui.xml` 后读出来能拿到通知按钮的坐标（Git Bash 里先 `export MSYS_NO_PATHCONV=1`，否则 `/sdcard/…` 会被改成 Windows 路径）。后台时进程的状态：`dumpsys activity processes <包名>` 里 `curProcState=4` 就是前台服务。
- **日志**：`adb logcat -s EmbeddedEngine EngineLan EngineKeeper EngineStorage EngineService`。
- **数据在哪**：引擎数据 `/data/user/0/io.github.sa1koro.yingzhou/files/engine`，播放缓存 `…/cache/stream`，下载 `/storage/emulated/0/Android/data/io.github.sa1koro.yingzhou/files/downloads`，导出到 `Download/映舟/`。
- **已知问题**：本机上用 `-gpu swiftshader_indirect` 时，模拟器进程会不定时崩溃（退出码 139，没有日志），播放视频时几乎必然：播放器一开始就崩。所以视频播放在模拟器上测不了，下载后的离线播放只在接口层面看（`/play/resolve` 给出 `/dl/…`、播放列表和分片能取到），播放器那一步靠桌面的 `integration_test/download_test.dart`。

## 6. 打包

```bash
tools/package-desktop.sh
```

- Windows（Git Bash）：`dist/yingzhou-windows-x64.zip`，解压后运行 `yingzhou.exe`。未压缩的目录在 `client/build/windows/x64/runner/Release`。
- Windows 安装程序：`dist/yingzhou-windows-x64-setup.exe`，机器上有 Inno Setup（6.3 以上，`scoop install inno-setup`）时在 zip 之后生成，没有就跳过。脚本是 `tools/installer/windows.iss`，说明见下面"Windows 安装程序"。
- macOS：`dist/yingzhou-macos-<arm64|x86_64>.dmg`（应用是 `Yingzhou.app`，显示名"映舟"）。JRE 跟构建机的 CPU 走；默认临时签名，设 `SIGN_IDENTITY` 用开发者证书。
- Linux：`dist/yingzhou-linux-x64.tar.gz` 和 `dist/yingzhou-linux-x64.deb`，见下面"Linux"。
- 没有 Mac 或 Linux：推到 GitHub 后手动触发或打 `v*` 标签，`.github/workflows/desktop.yml` 出全部的包。

包里有：Flutter 应用、`engine/lib`（引擎 jar）、`engine/jre`（jlink 裁出的运行时）。用户不用装 Java。

包在生成前会自检：用裁剪好的运行时跑一遍演示配置里的采集站、JS 蜘蛛、jar 蜘蛛、嗅探和直播（`--demo --check --play --strict`），任何一项失败就中止。精简运行时用的是整个 Java SE 加几个 JDK 模块（见脚本里的 `modules`），因为蜘蛛 jar 是别人的代码，用到什么模块没法靠 `jdeps` 预知。

### Windows 安装程序

`tools/installer/windows.iss`（Inno Setup）把 Release 目录整个装进去，版本号取自 `yingzhou.exe`（即 `client/pubspec.yaml` 的 `version`）。打包脚本会自动调用；Release 目录备好后也可以单独运行 `iscc tools\installer\windows.iss`，编译输出在 `dist/installer.log`。

- **每用户安装**，不要管理员权限，默认装到 `%LOCALAPPDATA%\Programs\Yingzhou`；命令行加 `/ALLUSERS` 才装到 Program Files。
- **`AppId` 不能改**：升级和卸载靠它找到已装的那一份。
- **运行中不能装也不能卸**：应用启动时创建命名互斥量 `Yingzhou.App.Running`（`client/windows/runner/main.cpp`），安装和卸载程序看到它就提示先关闭。引擎是应用的子进程，晚一点才退出，所以换文件、删文件之前还会等 `engine\jre\bin\javaw.exe` 解除占用（最多 10 秒）。
- **升级先删 `engine` 和 `data` 两个目录**再装新的：引擎的类路径是 `engine\lib\*`，旧版留下的 jar 会和新版的一起被加载。
- **卸载只删装进去的文件**；订阅、历史、收藏（`%USERPROFILE%\.tvbox-next`）和界面设置（`%APPDATA%\Yingzhou`）默认保留，交互卸载时询问，静默卸载从不删。
- 向导右上角的 logo 是 `tools/installer/wizard-*.bmp`（每种显示缩放一张），和应用图标一样由 `node tools/brand/render-icons.mjs` 生成。
- 界面语言跟系统走：简体中文或英文。
- 没有签名。要签名的话用 Inno Setup 的 `SignTool` 配置，脚本里还没接。

改了脚本之后至少手动过一遍：静默安装（`/VERYSILENT`）→ 启动 → 再装一次（升级）→ 卸载，确认目录、开始菜单和「应用和功能」里的条目都干净。

### Linux

在 Ubuntu 24.04 或更新的系统上装好第 1 节的构建依赖，运行 `tools/package-desktop.sh`。包跟着构建机走：CPU（x64 / arm64）、glibc 和 libmpv 的版本都是构建机的，所以在 24.04 上打的包只能装在 24.04、Debian 13 及更新的系统上。CI 用的就是 `ubuntu-24.04`。

- **Flutter 部分**：`flutter build linux --release` 出 `client/build/linux/x64/release/bundle`。可执行文件 `yingzhou`，GTK 应用 ID `io.github.sa1koro.yingzhou`（`client/linux/CMakeLists.txt`），窗口标题"映舟"和窗口图标在 `client/linux/runner/my_application.cc`。CMake 安装步骤顺带把 `client/linux/icons/`（hicolor 图标，`render-icons.mjs` 生成）和 `client/linux/io.github.sa1koro.yingzhou.desktop` 放进 bundle 的 `share/`。
- **mimalloc**：按 media_kit 的建议，可执行文件静态链接 mimalloc 代替 glibc 的 malloc（libmpv 下 glibc 的堆只涨不缩）。目标文件由 media_kit_libs_linux 构建时从 GitHub 下载 mimalloc 源码编出（校验 MD5）。
- **tar.gz**：bundle 加上 `engine/lib`、`engine/jre`、许可证和 `install-desktop-entry.sh`（源文件 `tools/installer/linux-desktop-entry.sh`，给当前用户加菜单项，`Exec` 指向解压目录）。客户端在可执行文件旁边找 `engine/`（`local_engine_io.dart`，用的是解析过符号链接的真实路径）。
- **deb**：整个 bundle 放在 `/opt/yingzhou`，`/usr/bin/yingzhou` 是指向它的链接，`.desktop` 和图标装到 `/usr/share`。图标缓存和菜单由 dpkg 的触发器刷新，包里没有维护脚本。`Depends` 由 `dpkg-shlibdeps` 从 bundle 里所有 ELF 文件（包括 JRE 的）算出来；`Recommends: fonts-noto-cjk`；浏览器和 `avahi-daemon` 只放在 `Suggests`（装不装由用户定）。版本号取 `client/pubspec.yaml` 的 `version`（去掉 `+` 后面的构建号）。
- 打包前检查 `ldd yingzhou` 没有 "not found"；机器上没有 `dpkg-deb` / `dpkg-shlibdeps`（非 Debian 系）时只出 tar.gz。

查看一个 deb：`dpkg-deb --info dist/yingzhou-linux-x64.deb`、`dpkg-deb --contents …`。

CI 的 `linux` 作业打完包后：用 apt 装上 deb（检验依赖能解析），在 Xvfb + Openbox 的虚拟屏幕上以一个全新的 `HOME` 启动 `yingzhou`，检查窗口标题、应用拉起的是包里的 Java、`~/.local/share/io.github.sa1koro.yingzhou/shared_preferences.json` 里记下了挪动后的窗口、关掉应用后引擎也退出，再连着启动两次，窗口都回到原来的位置和大小（用 `xwininfo` 量，误差 3 像素以内）；然后用包里的 Java 跑演示引擎，跑 `integration_test/desktop_play_test.dart` 的三个用例。两步都过了才上传包。截图和日志作为 `linux-smoke` 工件上传（打标签时不传，否则会被发布出去）：`gh run download <run id> -n linux-smoke`。虚拟屏幕是软件渲染（Mesa llvmpipe），没有声卡。

### 更新通道

应用的「检查更新」（`client/lib/update/`）读的是滚动预发布版 `channel` 上的 `latest.json`：`https://github.com/Sa1koro/yingzhou/releases/download/channel/latest.json`。它是普通的下载地址，不走 GitHub API（没有频率限制，加速代理也能转发），也不依赖 `/releases/latest`（所有版本都是预发布版，那个地址找不到它们）。

- `desktop.yml` 的 release 任务在发布 `v*` 之后生成它：`version`（标签去掉 `v`）、`tag`、`date`、`notes`（`CHANGELOG.md` 里 `## v<版本>` 那一节）、`page`、`download`（这个版本安装包所在的目录地址）和 `assets`（按平台：`windows-x64` 安装程序、`windows-x64-zip`、`macos-arm64`、`android-arm64-v8a` / `armeabi-v7a` / `x86_64`，Linux 包以 `linux` 开头，各带 `name` 和 `size`），用 `gh release upload channel latest.json --clobber` 覆盖。`channel` 不存在时先建（预发布版，标签指向这次的提交）。
- **版本号要一致**：`client/pubspec.yaml` 的 `version`（不含 `+构建号`）必须等于标签去掉 `v`，否则这一步报错、`latest.json` 不动——不然装了这一版的人会一直被提示"更新"到它自己。应用里的版本号是 `lib/update/release_info.dart` 的 `appVersion`，`test/update_test.dart` 检查它和 pubspec 一致，所以改版本号时两处一起改。
- 重新跑一个旧标签的 release 任务不会把通道退回旧版本（已公布的版本更新时跳过）。
- 某个平台的构建失败时 `assets` 里就没有它，那个平台的用户会看到"这次没有适合这台设备的安装包"；补跑成功后 release 任务重跑，`latest.json` 会补上。
- 想在本机试"有新版本"：`flutter run --dart-define=APP_VERSION=0.1.0` 让应用以为自己是旧版本。

测试：`test/update_test.dart`（本机假服务器分别充当 GitHub、加速代理和 HTTP 代理：新 / 同 / 旧版本、连不上、格式不对、经前缀回退、经代理、下载）、`test/update_settings_test.dart`（「更新」卡片、更新窗口、电视上用方向键、自动检查只提示一次）、`test/github_proxy_settings_test.dart`（加速代理列表与测速）；引擎侧 `GithubProxyTest`（测速经假代理、不受设置改道）和 `GithubProxyRoutesTest`。真实的 `latest.json` 要等第一次带这个任务的发布之后才能验证。

## 7. 拿真实订阅体检

```bash
tools/check-configs.sh                              # ../tvbox-ysc-config/output 里的配置
tools/check-configs.sh <订阅地址 | 文件 | 目录>...
ONLY=cms,remote,live tools/check-configs.sh         # 只查不需要蜘蛛的部分
PLAY=1 MAX_SITES=20 tools/check-configs.sh          # 加上播放解析；每个配置最多 20 个站点
```

`ONLY` 里没有 `jar` / `js` 时，这次体检的引擎里不注册对应的运行时，所以不只是跳过蜘蛛站点——经蜘蛛代理取的直播列表、jar 解析器也都不会加载任何 jar。

报告在 `dist/check-report.md`（同名 `.json` 给程序读），每查完一个配置就更新一次，中途停掉也有结果。相同站点的镜像配置只查一次。引擎用一个空闲端口、内存数据，不会碰你平时用的订阅和历史。分类规则和注意事项见 [compatibility.md](compatibility.md) 第 8 节。

## 8. 排查问题

- **崩溃记录与引擎日志**（`client/lib/diagnostics/`，界面在「源 → 诊断与反馈」）：`main.dart` 经 `Diagnostics.runGuarded` 启动应用，挂上 `FlutterError.onError`、`PlatformDispatcher.instance.onError` 和一个包住整个 `main` 的 guarded zone（`ensureInitialized` 和 `runApp` 在同一个 zone 里），出错写成 `<支持目录>/diagnostics/crash-<时间>-dart.txt`；桌面内置引擎的标准输出和标准错误写进同一目录的 `engine.log`（每次启动轮换，保留 3 个），引擎不是被 `stop()` 停掉而退出时再记一条 `-engine.txt`；安卓上 `CrashRecorder.kt`（`TvboxApplication` 里装上）在进程死之前写 `-android.txt`，格式和 Dart 的一样，下次启动列出来。安卓的系统日志经 `yingzhou/diagnostics` 通道（`DiagnosticsChannel.kt`：`info`、`logcat`、`openUrl`）读。要显示、复制的东西都先过 `diagnostics/redact.dart`。测试里不要碰真实目录：`Diagnostics(store: MemoryDiagnosticsStore())` 或 `DiagnosticsStore.files(() async => <临时目录>)`，打开网址换掉 `Diagnostics.openUrl`（`flutter test` 下桌面的打开命令本身也不会运行）。
- **内置引擎没起来**：启动失败时界面上的错误提示带着引擎最后几行输出，完整的在 `engine.log`（上一条）。也可以手动跑 `engine/jre/bin/java -cp "engine/lib/*" tvbox.engine.server.MainKt` 看报错。
- **9978 被占**：已有引擎在跑时客户端直接用它，不会再启动一个。
- **嗅探不可用**：引擎启动时会打印找到的浏览器；装在非标准位置时设环境变量 `TVBOX_BROWSER`。
- **jar 蜘蛛报缺类**：转换时会列出 jar 用到但桩类里没有的安卓类，在 `engine/runtime-jar/src/main/java/android/**` 补。
- **Python 站点打不开**：`GET /api/v1/python` 里的 `problem` 说明为什么没有 Python；引擎日志里 `python: using …` 是选中的那个，`py:` 开头的是 worker 的标准错误（蜘蛛的 `print` 和 Python 的完整报错）。`?refresh=1` 让引擎重新找 Python。
- **数据位置**：订阅、历史、收藏在 `~/.tvbox-next/engine`；窗口大小、音量等客户端偏好在系统的应用设置里。

## 9. 踩过的坑

- jlink 裁出的运行时要包含 `jdk.zipfs`：dex2jar 通过名字找 zip 文件系统，`jdeps` 查不出这个依赖，漏掉时所有 jar 蜘蛛报 "cant find zipfs support"。开发时用完整 JDK 不会暴露，所以打包脚本里有自检。

- dex2jar 用 `Dex2jar.from(bytes).to(path)`；写到 `ByteArrayOutputStream` 的那个接口产不出类。
- Python 的免安装版（embeddable）有 `python3XX._pth`：它不读 `PYTHONPATH`、不把脚本所在目录放进 `sys.path`、没有 `site-packages` 也没有 pip。所以 worker 自己往 `sys.path` 里插 bridge 和包目录，pip 从 wheel 里直接运行（`python pip-xx.whl/pip install …`）。
- Windows 的 `PATH` 里常有微软商店的 `python.exe` 占位程序（`WindowsApps`），带参数运行时只打印"去商店安装"并以 9009 退出；不能把"`python` 在 PATH 上"当成"有 Python"。macOS 上苹果的 `/usr/bin/python3` 在没装开发者工具时会弹出安装窗口，所以先看 `xcode-select -p`。
- 蜘蛛和原生库会往标准输出打印东西。worker 一启动就把真正的 stdin / stdout 复制给协议，再把文件描述符 0、1 重定向，协议输出只用 ASCII 的 JSON（`ensure_ascii`），不受控制台编码影响。
- pip 拒绝没有 `Content-Type: text/html` 的 simple 索引页（"Skipping page … because the GET request got Content-Type: Unknown"），自己写假索引时要带上。
- 从 Git Bash 用 curl 发含中文的 JSON 时，中文会按系统代码页而不是 UTF-8 发出去（`-d '{"line":"代理"}'` 到了引擎就不是"代理"了）；用 `--data-binary @文件`。
- 转换出来的类不一定过 JVM 校验器，JDK 21 上要 `-XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote`。
- Edge 的启动进程会立刻退出并把工作交给另一个进程：不能等它的退出码，要轮询 `DevToolsActivePort`。
- 改变外壳布局（进全屏、窗口变窄）会重建所有页面，除非页面挂在 `GlobalKey` 下面。
- media_kit 的 `Player` 不能在组件测试里创建，页面里要惰性创建。点播页的播放器来自 `AppState.playerBackend`，组件测试传入 `test/fake_player.dart` 里的假播放器（`Player(platformPlayer: …)`，不加载 libmpv），由测试决定每个地址是能播、报错还是没反应。
- media_kit 在 `open()` 之后就把 `playing` 置为 true，不管媒体打不打得开；也没有"加载失败"事件，只有 mpv 的错误日志（`stream.error`），其中不少并不致命。判断线路死活要看播放位置有没有在走，见 `player_page.dart`。
- 同时带 `onTap` 和 `onDoubleTap` 的 `GestureDetector`，它里面所有按钮的点击都要等双击的时限（300 毫秒）过去才生效。播放页因此只让画面那一层监听单击和双击，控制条、提示、侧栏是它在 `Stack` 里的兄弟层，不是子节点；新加的按钮也别放进画面那一层里。
- `DecoratedBox`（比如控制条的渐变）和文字会拦下落在自己范围内的点击，叠在下面的东西就收不到。播放页里只用来看的东西（渐变、标题、时间、提示文字）都包了 `IgnorePointer`，这样按钮之间的空白处点下去仍然是点画面。
- media_kit 给 libmpv 设了 `cache-on-disk=yes`，但没给 `demuxer-cache-dir`，而 libmpv 没有配置目录时找不到默认位置，所以缓存其实一直在内存里（`demuxer-cache-state` 里没有 `file-cache-bytes`）。要落盘必须自己给目录，见 `player_cache.dart`。
- `demuxer-cache-state` 用 `getProperty` 读出来是 JSON 字符串，`seekable-ranges` 是 libmpv 不读网络就能跳到的范围。跳转开始时 `time-pos` 立刻变成目标位置，`seeking` 从 yes 回到 no 才是真出了画面——量跳转耗时要看后者。
- ffmpeg 的 HLS 读取器（`http_multiple`）在读当前分片的数据之前，会先把下一个分片的请求发出去并**等它的应答头**。所以引擎对 `/hls/…` 必须立即应答，不能等片源；否则每次跳转白等一次片源的首字节时间。
- 同一个缘故，直连慢片源时 libmpv 实际用着两条连接；量"改动前"的速度时别按单连接算。
- Windows 上不能给还开着的文件改名或删除（`java.io` 打开文件不带共享删除，而 `java.nio.file` 在 Android 7 上没有）。流缓存因此让下载完的文件在还有人读的时候继续叫 `.part`，等读者都关了再改名；清理时删不掉的文件先留着。
- 引擎代码要能在 Android 7 上跑：不用 `java.time`、`java.util.Base64`。
- 用 shell 一行命令改 Kotlin / Dart 源码时，`\n`、`$` 容易被 shell 吃掉，改用编辑器或脚本文件。
- `dart format` 的行宽在 `analysis_options.yaml` 里定为 160，别用默认值重排整个目录。

- Linux 上窗口的边框和标题栏是窗口管理器画的，窗口上屏之前 GTK 不知道它们多厚。window_manager（nativeapi）在这时把"连边框的大小"当成内容大小，窗口每启动一次就高出一个标题栏。所以 Linux 上记住的是窗口左上角和**内容**的大小，上屏后再把位置设一次（`desktop_window.dart`）。在 Wayland 上应用本来就不能决定窗口位置。
- Java 在 Linux 上的 `user.home` 取自系统的用户数据库，不看 `$HOME`：换了 `HOME` 跑应用，引擎的数据仍在真正的家目录下。
- 虚拟屏幕（Xvfb）上要跑一个窗口管理器（CI 用 Openbox），全屏是窗口管理器做的，没有它 `isFullScreen` 一直是 false；Flutter 自带的 Linux 窗口默认 1280×720，比 Windows 的小，集成测试里有一步因此找不到首页第一行，现在 Linux 也默认 1360×860。
- Flutter 在 Windows 上默认用 Impeller，会多占两百多 MB 提交内存；`windows/runner/main.cpp` 里已关闭。JVM 不带 `-Xms` 时按物理内存的比例预留堆，引擎的启动参数里已限定。实测数字见 [tech-choices.md](tech-choices.md) 第 4 节。
- 安卓模拟器（`-gpu swiftshader_indirect`）上 libmpv 的 OpenGL 输出建不起上下文（logcat：`eglCreateContext: EGL_BAD_ATTRIBUTE`），media_kit 默认的 `vo=gpu` 只有声音、画面全黑。所以模拟器上换成 `vo=mediacodec_embed`（`player_backend.dart`）。模拟器解码 1080p 很慢，1080p 的网络片源（演示里的 mux 测试流）在模拟器上常常要等很久，换台时 libmpv 的 `stop` 也会跟着卡住；在模拟器上试播放用演示网盘的文件或低分辨率的频道。
- 视频组件（media_kit 的 `Video`）换了父节点就会被重建，在安卓上新建的那个是黑的。播放页和直播页的画面因此挂在 `GlobalKey` 下面，竖屏 / 全屏 / 画中画之间切换时只是挪位置。
- flutter_test 把平台报成安卓。`test/flutter_test_config.dart` 让没有 `DeviceFormScope` 的测试按桌面跑（`DeviceFormScope.debugFormWithoutScope`）；测手机 / 平板 / 电视的测试把应用包在 `DeviceFormScope.fixed(DeviceForm.phone, …)` 里。

## 10. 名字与图标

- 名字：映舟（Yingzhou）。用户看得到的地方用"映舟"；文件名、可执行文件、包名等用 `yingzhou`（Windows `yingzhou.exe`，macOS `Yingzhou.app`，Linux `yingzhou` 和 deb 包 `yingzhou`）。Linux 的应用 ID 和安卓包名一样是 `io.github.sa1koro.yingzhou`：`.desktop` 文件、图标、界面设置目录（`~/.local/share/<应用 ID>`）都用它，不能改。Dart 包名 `tvbox_client`、仓库目录 `tvbox-next`、引擎数据目录 `~/.tvbox-next` 暂不改。
- 图标源文件在 `docs/brand/`：`yingzhou-logo.svg`（标准）、`yingzhou-logo-small.svg`（16–32 px 用，去掉水波、放大帆和船身）。改了之后运行 `node tools/brand/render-icons.mjs`，它用无头 Edge/Chrome 按每个尺寸矢量渲染，生成 Windows `.ico`、macOS AppIcon、Linux 的 hicolor 图标（`client/linux/icons/`）、安卓启动图标和网页图标。

## 11. 约定

- 提交信息用英文，一句话说清做了什么；每个迭代一次提交。
- 移植自其他项目的代码，在 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) 里登记来源和许可证。
- 改了协议就同步改 [protocol.md](protocol.md)；做完一个功能就更新 [status.md](status.md) 和 [requirements.md](requirements.md) 里的状态。

## 12. 手机与平板（安卓）

设计见 [architecture.md](architecture.md) 第 4 节"手机与平板"。代码：设备形态用和电视共用的 `lib/ui/device_form.dart`；`lib/mobile/playback_host.dart` 与 `android/.../PlaybackChannel.kt`（亮度、媒体音量、常亮、画中画、是不是模拟器）、`lib/pages/touch_gestures.dart`（画面上的手势）、`lib/pages/player_mobile.dart`（全屏与转屏、锁、竖屏的选集区、触屏控制条），以及 `player_page.dart` / `live_page.dart` 里只在 `isTouch(context)` 时走的分支；外壳、海报墙、详情页的窄屏布局在 `ui/shell.dart`、`ui/poster.dart`、`pages/detail_page.dart`。

- **组件测试**：`test/phone_layout_test.dart`（各尺寸下的导航、每个页签不溢出、海报列数、详情页的触控尺寸、返回回首页）、`test/touch_player_test.dart`（播放页和直播页：竖屏 / 横屏布局、全屏与方向、返回、单击、双击、拖动跳转、亮度音量、长按倍速、锁、常亮、画中画、切后台暂停、平板、桌面不变），`test/downloads_test.dart` 最后一个用例是手机上的下载面板。手机一侧（`yingzhou/playback`、`SystemChrome`）在测试里是假的，测试检查发给它的调用。
- **模拟器**：建一个手机 AVD（`avdmanager create avd -n <名字> -k "system-images;android-34;google_apis;x86_64" -d pixel_7`），无窗口启动（`emulator -avd <名字> -port <端口> -no-window -gpu swiftshader_indirect -no-snapshot-save`），装调试包（`flutter build apk --debug`，`adb -s emulator-<端口> install -r build/app/outputs/flutter-apk/app-debug.apk`）。在电脑上起演示引擎（`--demo --port <端口>`），应用里订阅 `http://10.0.2.2:<端口>/demo/config.json`；网盘可以添加 WebDAV `http://10.0.2.2:<端口>/demo/dav/`（账号 `demo` / `demo`），它的文件是引擎现做的、在模拟器上播放和跳转都快。截图 `adb -s emulator-<端口> exec-out screencap -p > shot.png`；转屏 `adb shell settings put system accelerometer_rotation 0` 再 `settings put system user_rotation 1`（0 竖、1 横）；深色模式 `adb shell cmd uimode night yes`。
- `adb shell input` 每条命令要几百毫秒，两次点击之间超过双击的时限，点不出双击；双击靠组件测试。拖动用 `input swipe x1 y1 x2 y2 <毫秒>`（起点终点相同就是长按），放到后台跑、中途截图能看到拖动中的提示。
- 只有真机能确认的：硬件解码实际选了什么（`hwdec-current`）、发热和掉帧、亮度在屏幕上的效果、刘海和挖孔屏、各家系统对画中画的处理。

## 13. Android 电视（遥控器）

设计见 [architecture.md](architecture.md) 第 4 节"电视与遥控器"。代码：`client/lib/ui/device_form.dart`（是不是电视，和手机会话共用）、`client/lib/ui/tv/`（外框、焦点、外壳、输入框、键盘、对话框）、`client/lib/pages/player_tv.dart`、`live_tv.dart`、`ui_mode_settings.dart`，安卓侧 `DeviceChannel.kt`。

**组件测试**：`flutter test test/tv_focus_test.dart test/tv_player_test.dart`。页面用 `DeviceFormScope.fixed(DeviceForm.tv, child: TvboxApp(...))` 包起来，视口 1920×1080、像素比 2（960×540 逻辑像素，和 1080p 电视一样）。按键用 `tester.sendKeyEvent(key, platform: 'android')` 发，这样和安卓发来的一样（DPAD_CENTER 是 `select`、MENU 是 `contextMenu`）；测试的按键模拟器找不到 BACK（`goBack`）对应的物理键，要加 `physicalKey: PhysicalKeyboardKey.escape`。"系统返回"用 `tester.binding.handlePopRoute()`。

**模拟器**：这台机器上只有手机的系统映像，没有 Android TV 映像。用它建一个横屏 1080p、有方向键的模拟器（不要动用户自己的 `tvbox34`）：

```bash
echo no | avdmanager create avd -n yz-tv -k "system-images;android-34;google_apis;x86_64"   # Windows 上是 avdmanager.bat
# 改 ~/.android/avd/yz-tv.avd/config.ini：
#   hw.lcd.width=1920  hw.lcd.height=1080  hw.lcd.density=320  hw.initialOrientation=landscape
#   hw.dPad=yes  hw.keyboard=yes  hw.ramSize=4G  hw.gpu.mode=swiftshader_indirect  showDeviceFrame=no
emulator -avd yz-tv -port 5564 -no-window -gpu swiftshader_indirect -no-snapshot-save -no-boot-anim
```

手机映像不报告自己是电视，应用会用触屏界面。用 `run-as` 把界面模式写进应用的设置（调试包才行），相当于在「设置 → 外观 → 界面模式」里选「电视遥控」：

```bash
# shared_prefs/FlutterSharedPreferences.xml 里加一行 <string name="flutter.ui.form">tv</string>
adb -s emulator-5564 push prefs.xml /data/local/tmp/yz_prefs.xml
adb -s emulator-5564 shell run-as io.github.sa1koro.yingzhou cp /data/local/tmp/yz_prefs.xml shared_prefs/FlutterSharedPreferences.xml
```

Git Bash 会把 `/data/...` 这样的参数改成 Windows 路径，adb 命令前加 `MSYS_NO_PATHCONV=1`。

内容用主机上的演示引擎（`--demo --port <端口>`），让模拟器里的内置引擎订阅它：`adb forward tcp:<端口2> tcp:9978` 后对 `http://127.0.0.1:<端口2>/api/v1/subscriptions` POST `{"url":"http://10.0.2.2:<端口>/demo/config.json"}`，再 `POST .../subscriptions/<id>/activate`。直接把客户端指向 `http://10.0.2.2:<端口>` 不行：演示引擎把带外来 `Host` 的请求当成局域网设备，要配对。

遥控器按键用 `adb shell input keyevent`：`DPAD_UP` / `DPAD_DOWN` / `DPAD_LEFT` / `DPAD_RIGHT` / `DPAD_CENTER`、`BACK`、`MENU`、`CHANNEL_UP` / `CHANNEL_DOWN`、`MEDIA_PLAY_PAUSE`、`MEDIA_NEXT`、数字 `0`–`9`；按住用 `--longpress`。截图 `adb exec-out screencap -p > x.png`。注意：

- 模拟器开机后处在"触摸模式"，第一个方向键只用来退出触摸模式，不会传给应用；真电视没有触摸模式。
- `flutter run` 的热重载要从标准输入读按键，这台机器上没法从后台喂给它；改了代码用 `flutter run --no-resident -d emulator-5564` 重新构建安装（Dart 改动约 2–4 分钟）。
- 这台机器上无窗口、软件渲染（SwiftShader）的模拟器里，media_kit 能打开媒体（时长显示出来），但播放位置一直不走，画面是黑的，点播线路最后都报"15 秒没有画面"；去掉 `-no-audio` 也一样。按键、面板、焦点不受影响。实际播放要在有 GPU 的模拟器或真机上看。
- 在这台机器上，系统输入法（Gboard）弹出来时模拟器进程偶尔整个崩溃（退出码 139），和应用无关；重启模拟器即可。不弹输入法也能测输入框：焦点在输入框上时 `adb shell input text "…"` 直接打字（走实体键盘那条路）。
- 真正的 Android TV 映像或设备会多出：系统报告电视模式（不用改设置）、leanback 桌面上的横幅、没有状态栏、遥控器的语音键和"设置""直播"之类的专用键（应用没有处理），以及电视版输入法（Gboard for TV）的行为。这些在手机映像上都验证不到。

## 14. Docker 镜像（NAS）

> **镜像本身还没有构建、运行过**：开发机上没有 Docker（也不打算装）。下面"已检查"列出的是没有 Docker 时能查的部分；第一次真正的构建会在 CI 上（仓库推到 GitHub 之后），或者在有 Docker 的机器上手动做。

文件：

| 文件 | 作用 |
|---|---|
| `engine/Dockerfile` | 三段：① 在构建机自己的 CPU 上用 Gradle 编译（`--platform=$BUILDPLATFORM`，字节码各平台一样）；② 用**目标 CPU** 的 JDK 做 jlink（jlink 出的运行时只能在它的 CPU 上跑），模块列表和 `tools/package-desktop.sh` 相同；③ `debian:bookworm-slim` + 运行时 + 引擎 jar + Chromium（`WITH_CHROMIUM=false` 去掉）+ tini + curl |
| `engine/docker-entrypoint.sh` | 启动命令：JVM 参数与桌面应用的内置引擎相同，加 UTF-8 输出；引擎参数 `--lan --port $TVBOX_PORT --data /data --name $TVBOX_NAME`，容器参数追加在后面 |
| `engine/docker-chromium.sh` | `TVBOX_BROWSER` 指向它：`chromium --no-sandbox --disable-dev-shm-usage` |
| `engine/docker-compose.yml` | 示例：数据卷、9978 端口、`shm_size`，注释里有 host 网络和不带 Chromium 的写法 |
| `engine/.dockerignore` | 只把源码和脚本送进构建（不要 `build/`、`.gradle/`） |
| `.github/workflows/engine-image.yml` | 构建 amd64 镜像并冒烟测试，再构建 amd64 + arm64；打 `v*` 标签或手动运行勾选 push 时推到 `ghcr.io/<owner>/yingzhou-engine` |

需要 BuildKit（Docker 23 起默认；用了 `--platform=$BUILDPLATFORM`、`RUN --mount=type=cache`、`COPY --chmod`）。

```bash
cd engine
docker build -t yingzhou-engine .
docker run -d --name yingzhou -p 9978:9978 -v yingzhou-data:/data --shm-size 256m yingzhou-engine
docker logs yingzhou                                     # 配对码
docker buildx build --platform linux/amd64,linux/arm64 -t yingzhou-engine .   # 两个平台（arm64 的 jlink 在 QEMU 里跑，慢一些）
```

设计要点：

- 以非 root 用户 `yingzhou`（UID/GID 10001）运行，`HOME` 和数据都在 `/data`（卷）。绑定挂载目录时要先 `chown 10001:10001`。
- 局域网模式：`--lan` 监听 0.0.0.0、共享强制打开，启动时把地址和配对码打印到日志。容器里列出的地址是容器自己的，用户要用宿主机地址。
- 经端口映射进来的请求来自 Docker 网关，不是回环地址，所以宿主机上的客户端也要配对；容器内的健康检查是回环地址，`/api/v1/info` 本来也不要令牌。
- 健康检查 `curl -fsS http://127.0.0.1:$TVBOX_PORT/api/v1/info`，60 秒启动宽限。
- QuickJS 的 JNI 库 `quickjs-jvm.jar` 里带 `linux_x64` 和 `linux_aarch64`，两个平台的 JS 蜘蛛都能跑；jar 蜘蛛是纯字节码。
- mDNS 出不了桥接网络；要自动发现就用 `network_mode: host`。
- Chromium 无沙盒：容器里没有它的沙盒需要的用户命名空间。代价是被嗅探的网页一旦攻破渲染进程就直接在容器里（以非 root 用户）。不放心就不带 Chromium。

已检查（没有 Docker 的条件下）：

- 用镜像里同样的模块列表 jlink 出运行时（Windows 上），带镜像入口脚本里同样的 JVM 参数运行 `--demo --check --strict` 和 `--demo --check --play --strict`，都通过（退出码 0）。
- 用同样的参数加 `--lan --port 19984 --data <临时目录>` 启动：日志里打印了地址和配对码，`/api/v1/lan` 显示 `forced=true`，从局域网地址访问 `/api/v1/sites` 得 401、`/api/v1/info` 得 200。
- `sh -n` 检查两个脚本；YAML 解析 compose 和 workflow 文件；逐行对照 Dockerfile 最佳实践（固定的基础镜像系列、多阶段、缓存挂载、依赖层在源码层之前、`--no-install-recommends` 并清 apt 列表、非 root、tini、健康检查、`.dockerignore`）。

没有检查：镜像能否构建（Gradle 在容器里、Debian 的 `chromium` 包、arm64 下 QEMU 里的 jlink）、容器里 Chromium 能否嗅探、健康检查、卷的权限、host 网络下的 mDNS。CI 的冒烟测试覆盖前四项中的 amd64 部分。

基础镜像只固定到系列（`eclipse-temurin:21-jdk`、`debian:bookworm-slim`），每次构建会拿到当时的安全更新；需要可重复构建时用 `--build-arg JDK_IMAGE=…@sha256:…` 固定摘要。
