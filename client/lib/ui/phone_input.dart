import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

import 'device_form.dart';
import 'phone_input_server.dart';

export 'phone_input_server.dart' show PhoneInputRequest, PhoneKeyboard;

/// Whether to offer "手机输入" here: on TVs, desktops and tablets, not on a phone (it is the phone) or the web.
bool phoneInputAvailable(BuildContext context) => !kIsWeb && !isPhone(context);

/// Shows the QR code of a one-off page for typing [request] on a phone, and waits for the text (null when the
/// window was closed without one).
Future<String?> showPhoneInput(BuildContext context, PhoneInputRequest request) =>
    showDialog<String>(context: context, builder: (_) => PhoneInputDialog(request: request));

/// "手机输入" next to a field: what is typed on the phone goes to [onReceived].
class PhoneInputButton extends StatelessWidget {
  const PhoneInputButton({super.key, required this.request, required this.onReceived, this.enabled = true});

  final PhoneInputRequest request;
  final ValueChanged<String> onReceived;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: enabled
          ? () async {
              final text = await showPhoneInput(context, request);
              if (text != null && text.isNotEmpty) onReceived(text);
            }
          : null,
      icon: const Icon(Icons.qr_code_2_rounded),
      label: const Text('手机输入'),
    );
  }
}

class PhoneInputDialog extends StatefulWidget {
  const PhoneInputDialog({super.key, required this.request, this.findAddresses, this.startServer});

  final PhoneInputRequest request;

  /// For tests: this device's addresses (default [PhoneInputServer.lanAddresses]) and the server (default
  /// [PhoneInputServer.start] on every IPv4 address).
  final Future<List<String>> Function()? findAddresses;
  final Future<PhoneInputServer> Function(PhoneInputRequest request)? startServer;

  @override
  State<PhoneInputDialog> createState() => _PhoneInputDialogState();
}

class _PhoneInputDialogState extends State<PhoneInputDialog> {
  PhoneInputServer? _server;
  List<String> _addresses = const [];
  String? _host;
  String? _error;
  bool _expired = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(_server?.close());
    super.dispose();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _expired = false;
    });
    try {
      final addresses = await (widget.findAddresses ?? PhoneInputServer.lanAddresses)();
      if (!mounted) return;
      if (addresses.isEmpty) {
        setState(() => _error = '这台设备没有连上局域网（Wi-Fi 或网线），手机输入用不了。');
        return;
      }
      final server = await (widget.startServer ?? PhoneInputServer.start)(widget.request);
      if (!mounted) {
        unawaited(server.close());
        return;
      }
      setState(() {
        _server = server;
        _addresses = addresses;
        _host = addresses.contains(_host) ? _host : addresses.first;
      });
      _tick?.cancel();
      _tick = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
      final text = await server.result;
      if (!mounted || !identical(server, _server)) return;
      _tick?.cancel();
      if (text != null) {
        Navigator.of(context).pop(text);
      } else {
        setState(() => _expired = true);
      }
    } on SocketException catch (e) {
      if (mounted) setState(() => _error = '无法开始手机输入：${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tv = isTv(context);
    final server = _server;
    final url = server == null || _host == null ? null : server.urlFor(_host!).toString();
    final left = server == null ? Duration.zero : server.expiresAt.difference(DateTime.now());
    final remaining = left.isNegative ? Duration.zero : left;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: tv ? 15 : 13);

    Widget body;
    if (_error != null) {
      body = Text(_error!, key: const Key('phone-input-error'));
    } else if (url == null) {
      body = const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
    } else {
      final qrSize = tv ? 240.0 : 220.0;
      final qr = Opacity(
        opacity: _expired ? 0.25 : 1,
        child: QrView(key: const Key('phone-input-qr'), data: url, size: qrSize),
      );
      final text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '用手机扫码（相机、微信都可以），在打开的网页里填好${widget.request.title}，点「发送」。',
            style: TextStyle(fontSize: tv ? 18 : 15),
          ),
          const SizedBox(height: 8),
          Text('手机要和这台设备连在同一个 Wi-Fi 或路由器下。', style: muted),
          const SizedBox(height: 12),
          Text('也可以在手机浏览器里打开：', style: muted),
          SelectableText(url, key: const Key('phone-input-url'), style: TextStyle(fontSize: tv ? 16 : 13, fontFamily: 'monospace')),
          if (_addresses.length > 1) ...[
            const SizedBox(height: 12),
            Text('扫不开就换一个地址：', style: muted),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in _addresses)
                  ChoiceChip(label: Text(a), selected: a == _host, onSelected: (_) => setState(() => _host = a)),
              ],
            ),
          ],
        ],
      );
      body = LayoutBuilder(
        builder: (context, c) => c.maxWidth >= 520
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [qr, const SizedBox(width: 24), Expanded(child: text)])
            : Column(mainAxisSize: MainAxisSize.min, children: [qr, const SizedBox(height: 16), text]),
      );
    }

    // Beside the buttons rather than under the text, where a TV's short screen would cut it off.
    final expiry = server == null || _error != null
        ? const SizedBox.shrink()
        : Text(
            _expired ? '二维码已失效' : '${remaining.inMinutes}:${(remaining.inSeconds % 60).toString().padLeft(2, '0')} 后失效，只能用一次',
            key: const Key('phone-input-expiry'),
            style: muted.copyWith(color: _expired ? scheme.error : null),
          );
    return AlertDialog(
      title: Text('用手机输入${widget.request.title}'),
      content: SizedBox(width: tv ? 720 : 600, child: SingleChildScrollView(child: body)),
      actionsAlignment: MainAxisAlignment.spaceBetween,
      actions: [
        expiry,
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_expired || _error != null) ...[
              FilledButton.tonal(onPressed: _start, child: const Text('重新生成')),
              const SizedBox(width: 8),
            ],
            TextButton(autofocus: true, onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
          ],
        ),
      ],
    );
  }
}

/// A QR code of [data], dark on white with the quiet zone around it whatever the theme (scanners need both).
class QrView extends StatelessWidget {
  const QrView({super.key, required this.data, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = QrImage(QrCode(payload: QrPayload.fromString(data), errorCorrectLevel: QrErrorCorrectLevel.medium));
    return Semantics(
      label: '二维码：$data',
      image: true,
      child: Container(
        width: size,
        height: size,
        padding: EdgeInsets.all(size * 0.07),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: CustomPaint(painter: _QrPainter(image)),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = image.moduleCount;
    final cell = size.shortestSide / n;
    final path = Path();
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        // A hair wider than the cell, so neighbouring modules meet without seams.
        if (image.isDark(y, x)) path.addRect(Rect.fromLTWH(x * cell, y * cell, cell + 0.4, cell + 0.4));
      }
    }
    canvas.drawPath(path, Paint()..color = const Color(0xFF111111));
  }

  @override
  bool shouldRepaint(_QrPainter old) => !identical(old.image, image);
}
