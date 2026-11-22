import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let engineQueue = DispatchQueue(label: "yingzhou.go-engine.lifecycle")

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "yingzhou/go_engine", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { [engineQueue] call, result in
      switch call.method {
      case "start":
        guard let arguments = call.arguments as? [String: Any],
          let port = arguments["port"] as? Int, (0...65535).contains(port)
        else {
          result(FlutterError(code: "INVALID_PORT", message: "端口需要在 0 到 65535 之间", details: nil))
          return
        }
        engineQueue.async {
          do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
              in: .userDomainMask, appropriateFor: nil, create: true)
            let directory = support.appendingPathComponent("YingzhouGo", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var failure: UnsafeMutablePointer<CChar>?
            let boundPort = directory.path.withCString { YingzhouGoStart(Int32(port), $0, &failure) }
            defer { free(failure) }
            if boundPort > 0 {
              DispatchQueue.main.async { result(Int(boundPort)) }
            } else {
              let message = failure.map { String(cString: $0) } ?? "本机 Go 引擎启动失败"
              DispatchQueue.main.async { result(FlutterError(code: "GO_ENGINE_START", message: message, details: nil)) }
            }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "GO_ENGINE_STORAGE", message: error.localizedDescription, details: nil)) }
          }
        }
      case "stop":
        engineQueue.async {
          YingzhouGoStop()
          DispatchQueue.main.async { result(nil) }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
