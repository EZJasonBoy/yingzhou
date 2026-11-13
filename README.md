# tvbox-next

> 工作名。一个兼容 TVBox 配置与蜘蛛协议的全平台影视客户端：一个 Kotlin 引擎 + 一个 Flutter 客户端 + 一套 HTTP 协议。

- 架构设计：[docs/architecture.md](docs/architecture.md)
- 引擎协议：[docs/protocol.md](docs/protocol.md)

## 目录

| 目录 | 内容 |
|---|---|
| `engine/` | Kotlin/JVM 引擎（Gradle）：`core` 协议逻辑、`api` HTTP 路由、`server` 独立进程入口 |
| `client/` | Flutter 客户端（Windows / macOS / Linux / Android / iOS） |
| `docs/` | 设计文档 |

## 开发

需要 JDK 21、Flutter 3.50+；Android 需要 Android SDK；Windows 桌面需要 Visual Studio 的"使用 C++ 的桌面开发"工作负载。

```bash
# 引擎：测试、运行（默认只监听 127.0.0.1:9978）
cd engine
./gradlew test
./gradlew :server:run --args="--port 9978 --subscribe <订阅地址>"

# 客户端
cd client
flutter test
flutter run -d windows
```

桌面客户端启动时，如果 127.0.0.1:9978 上没有引擎，会自动在后台启动内置引擎（开发时用 `engine/server/build/install/tvbox-engine`，打包后用 `engine/` 目录和自带的精简 JRE），客户端退出时引擎随之退出。

打包 Windows 版（客户端 + 引擎 + jlink 精简 JRE，输出 `dist/tvbox-next-windows-x64.zip`）：

```bash
tools/package-desktop.sh
```

## 许可

AGPL-3.0，见 [LICENSE](LICENSE)。

- 部分实现移植自 [TVBoxOS](https://github.com/q215613905/TVBoxOS) 与 [takagen99/Box](https://github.com/takagen99/Box)（AGPL-3.0）。
- `engine/core/.../util/UriUtil.kt` 移植自 ExoPlayer（Apache-2.0），保留原版权声明。
- 参考了 [Win-box](https://github.com/yagami-hue/Win-box)（MIT）的设计与踩坑记录。

本项目只是播放器外壳，不内置、不提供任何影视内容或订阅源。
