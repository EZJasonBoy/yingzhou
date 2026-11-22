import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'models.dart';

class GoEngine {
  const GoEngine();

  static const _channel = MethodChannel('yingzhou/go_engine');

  Future<int> start() async {
    try {
      final port = await _channel.invokeMethod<int>('start', {'port': 0});
      if (port != null && port > 0 && port <= 65535) return port;
      throw const EngineException('GO_START', '本机 Go 引擎没有返回可用端口');
    } on PlatformException catch (failure) {
      throw EngineException('GO_START', '本机 Go 引擎启动失败：${failure.message ?? failure.code}');
    } on MissingPluginException {
      throw const EngineException('GO_START', '此安装包缺少本机 Go 引擎');
    }
  }

  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (failure) {
      throw EngineException('GO_STOP', '本机 Go 引擎停止失败：${failure.message ?? failure.code}');
    }
  }
}

GoEngine? createGoEngine() => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS ? const GoEngine() : null;
