# 开发指南

## 1. 环境

| 工具 | 版本 | 用途 |
|---|---|---|
| JDK | 21（Temurin） | 引擎；打包时用它的 `jlink` 裁出精简 JRE |
| Flutter | 3.50+ | 客户端 |
| Visual Studio | "使用 C++ 的桌面开发"工作负载 | Windows 客户端；还需要打开系统的**开发者模式**（插件要建符号链接） |
| Xcode | — | macOS 客户端 |
| Android SDK | platforms;android-36、build-tools;36.0.0 | 只在构建 Android 客户端或重建演示 jar 时需要 |

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
  core/          协议逻辑，纯 JVM，Android 上也跑：config / site / search / play / live
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
  macos/ windows/
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
flutter run -d windows                      # 没有引擎在 9978 上时会自己拉起上面 installDist 的引擎
```

引擎参数：`--port`、`--lan`（监听局域网）、`--data <目录>`（默认 `~/.tvbox-next/engine`）、`--subscribe <地址>`、`--demo`、`--dev-cors`、`--exit-with-stdin`。

## 4. 演示引擎

`--demo` 会在引擎里起一个假的站点并订阅它，开发和测试都用它，不依赖任何真实订阅：

```bash
cd engine && ./gradlew :server:run --args="--demo --dev-cors --port 19978"
```

它提供：一个采集站、一个 JS 蜘蛛站、一个 jar 蜘蛛站、一个需要嗅探的站；JSON 解析、jar 聚合解析、嗅探解析各一个；一条去广告规则；一个带节目单的直播源（含一个第一条线路是死链的频道，用来测自动换线）。演示模式的数据默认只在内存里。

演示 jar 的源码在 `engine/server/demo-jar/`，改了之后跑 `build.sh`（javac + d8）重新生成。

## 5. 在真实 Windows 应用里跑集成测试

单元测试覆盖不到播放器、窗口和全屏。`client/integration_test/` 里的测试会启动真正的应用，连演示引擎，一步步操作：

```bash
# 先在另一个终端启动演示引擎（见上），然后：
cd client
flutter test integration_test/desktop_play_test.dart -d windows --dart-define=SHOT_DIR=<截图目录>
flutter test integration_test/live_test.dart -d windows --dart-define=SHOT_DIR=<截图目录>
```

每一步会打印 `MARK:<步骤>`，给了 `SHOT_DIR` 就在那一步存一张截图（应用内截图，包含视频画面；从外部截测试窗口是黑的）。

## 6. 打包

```bash
tools/package-desktop.sh
```

- Windows（Git Bash）：`dist/yingzhou-windows-x64.zip`，解压后运行 `yingzhou.exe`。未压缩的目录在 `client/build/windows/x64/runner/Release`。
- macOS：`dist/yingzhou-macos-<arm64|x86_64>.dmg`（应用是 `Yingzhou.app`，显示名"映舟"）。JRE 跟构建机的 CPU 走；默认临时签名，设 `SIGN_IDENTITY` 用开发者证书。
- 没有 Mac：推到 GitHub 后手动触发或打 `v*` 标签，`.github/workflows/desktop.yml` 出三个包。

包里有：Flutter 应用、`engine/lib`（引擎 jar）、`engine/jre`（jlink 裁出的运行时）。用户不用装 Java。

包在生成前会自检：用裁剪好的运行时跑一遍演示配置里的采集站、JS 蜘蛛、jar 蜘蛛、嗅探和直播（`--demo --check --play --strict`），任何一项失败就中止。精简运行时用的是整个 Java SE 加几个 JDK 模块（见脚本里的 `modules`），因为蜘蛛 jar 是别人的代码，用到什么模块没法靠 `jdeps` 预知。

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

- **内置引擎没起来**：启动失败时界面上的错误提示带着引擎最后几行输出。也可以手动跑 `engine/jre/bin/java -cp "engine/lib/*" tvbox.engine.server.MainKt` 看报错。
- **9978 被占**：已有引擎在跑时客户端直接用它，不会再启动一个。
- **嗅探不可用**：引擎启动时会打印找到的浏览器；装在非标准位置时设环境变量 `TVBOX_BROWSER`。
- **jar 蜘蛛报缺类**：转换时会列出 jar 用到但桩类里没有的安卓类，在 `engine/runtime-jar/src/main/java/android/**` 补。
- **数据位置**：订阅、历史、收藏在 `~/.tvbox-next/engine`；窗口大小、音量等客户端偏好在系统的应用设置里。

## 9. 踩过的坑

- jlink 裁出的运行时要包含 `jdk.zipfs`：dex2jar 通过名字找 zip 文件系统，`jdeps` 查不出这个依赖，漏掉时所有 jar 蜘蛛报 "cant find zipfs support"。开发时用完整 JDK 不会暴露，所以打包脚本里有自检。

- dex2jar 用 `Dex2jar.from(bytes).to(path)`；写到 `ByteArrayOutputStream` 的那个接口产不出类。
- 转换出来的类不一定过 JVM 校验器，JDK 21 上要 `-XX:+UnlockDiagnosticVMOptions -XX:-BytecodeVerificationRemote`。
- Edge 的启动进程会立刻退出并把工作交给另一个进程：不能等它的退出码，要轮询 `DevToolsActivePort`。
- 改变外壳布局（进全屏、窗口变窄）会重建所有页面，除非页面挂在 `GlobalKey` 下面。
- media_kit 的 `Player` 不能在组件测试里创建，页面里要惰性创建。
- 引擎代码要能在 Android 7 上跑：不用 `java.time`、`java.util.Base64`。
- 用 shell 一行命令改 Kotlin / Dart 源码时，`\n`、`$` 容易被 shell 吃掉，改用编辑器或脚本文件。
- `dart format` 的行宽在 `analysis_options.yaml` 里定为 160，别用默认值重排整个目录。

- Flutter 在 Windows 上默认用 Impeller，会多占两百多 MB 提交内存；`windows/runner/main.cpp` 里已关闭。JVM 不带 `-Xms` 时按物理内存的比例预留堆，引擎的启动参数里已限定。实测数字见 [tech-choices.md](tech-choices.md) 第 4 节。

## 10. 名字与图标

- 名字：映舟（Yingzhou）。用户看得到的地方用"映舟"；文件名、可执行文件、包名等用 `yingzhou`（Windows `yingzhou.exe`，macOS `Yingzhou.app`）。Dart 包名 `tvbox_client`、仓库目录 `tvbox-next`、引擎数据目录 `~/.tvbox-next` 暂不改。
- 图标源文件在 `docs/brand/`：`yingzhou-logo.svg`（标准）、`yingzhou-logo-small.svg`（16–32 px 用，去掉水波、放大帆和船身）。改了之后运行 `node tools/brand/render-icons.mjs`，它用无头 Edge/Chrome 按每个尺寸矢量渲染，生成 Windows `.ico`、macOS AppIcon、安卓启动图标和网页图标。

## 11. 约定

- 提交信息用英文，一句话说清做了什么；每个迭代一次提交。
- 移植自其他项目的代码，在 [THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md) 里登记来源和许可证。
- 改了协议就同步改 [protocol.md](protocol.md)；做完一个功能就更新 [status.md](status.md) 和 [requirements.md](requirements.md) 里的状态。
