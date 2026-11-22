import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

const _redH264Video =
    'AAAAHGZ0eXBpc281AAACAGlzbzVpc282bXA0MQAAAsNtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAAAAABAAABAAAAAAAA'
    'AAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAB6nRy'
    'YWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAA'
    'AAAAAAAAAEAAAAAAQAAAADAAAAAAAYZtZGlhAAAAIG1kaGQAAAAAAAAAAAAAAAAAAEAAAAAAAFXEAAAAAAAtaGRscgAAAAAAAAAA'
    'dmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxlcgAAAAExbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAA'
    'AAAAAAABAAAADHVybCAAAAABAAAA8XN0YmwAAAClc3RzZAAAAAAAAAABAAAAlWF2YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAA'
    'QAAwAEgAAABIAAAAAAAAAAEMTGF2YyBsaWJ4MjY0AAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAAAvYXZjQwFCwAr/4QAXZ0LACtkE'
    'ewEQAAADABAAAAMBAPEiZIABAAVoy4PLIAAAABBwYXNwAAAAAQAAAAEAAAAQc3R0cwAAAAAAAAAAAAAAEHN0c2MAAAAAAAAAAAAA'
    'ABRzdHN6AAAAAAAAAAAAAAAAAAAAEHN0Y28AAAAAAAAAAAAAAChtdmV4AAAAIHRyZXgAAAAAAAAAAQAAAAEAAAAAAAAAAAAAAAAA'
    'AAA9dWR0YQAAADVtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAAhpbHN0AAAAyG1vb2YAAAAQbWZo'
    'ZAAAAAAAAAABAAAAsHRyYWYAAAAcdGZoZAACADgAAAABAAAIAAAAACEBAQAAAAAAFHRmZHQBAAAAAAAAAAAAAAAAAAB4dHJ1bgAA'
    'AgUAAAAYAAAA0AIAAAAAAAAhAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoA'
    'AAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAAKAAAACgAAAAoAAAEPbWRhdAAAAB1liIQEPEYoAAoSxwABH1jgACwhJycnXXXXXXXX'
    'gAAAAAZBmjgIeNgAAAAGQZpUAh42AAAABkGaYBDxsAAAAAZBmoAQ8bAAAAAGQZqgEPGwAAAABkGawBDxsAAAAAZBmuAQ8bAAAAAG'
    'QZsAEPGwAAAABkGbIBDxsAAAAAZBm0AQ8bAAAAAGQZtgEPGwAAAABkGbgBDxsAAAAAZBm6AQ8bAAAAAGQZvAEPGwAAAABkGb4BDx'
    'sAAAAAZBmgAQ8bAAAAAGQZogEPGwAAAABkGaQBDxsAAAAAZBmmAQ8bAAAAAGQZqAEPGwAAAABkGaoD/GwAAAAAZBmsA/xsAAAAAG'
    'QZrgO8bAAAAAQ21mcmEAAAArdGZyYQEAAAAAAAABAAAAAAAAAAEAAAAAAAAAAAAAAAAAAALfAQEBAAAAEG1mcm8AAAAAAAAAQw==';

Future<void> serveIosFixture(SendPort events) async {
  final video = base64Decode(_redH264Video);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  events.send(server.port);
  await for (final request in server) {
    final response = request.response;
    final path = request.uri.path;
    response.headers.contentType = ContentType.json;
    switch (path) {
      case '/config.json':
        response.write(
          jsonEncode({
            'sites': [
              {'key': 'fixture', 'name': '本机推送', 'type': 3, 'api': 'csp_Push'},
            ],
          }),
        );
      case '/clip.mp4':
        _serveVideo(request, video);
      case '/api/v1/info':
        response.write(jsonEncode({'name': 'remote-fixture', 'version': '1', 'platform': 'remote', 'protocol': 1}));
      case '/api/v1/subscriptions':
        response.write('[]');
      case '/api/v1/settings':
        response.write('{}');
      case '/api/v1/config':
        response.statusCode = HttpStatus.notFound;
        response.write(
          jsonEncode({
            'error': {'code': 'NO_CONFIG', 'message': 'No active subscription'},
          }),
        );
      default:
        response.statusCode = HttpStatus.notFound;
    }
    events.send('${request.method} $path ${response.statusCode} range=${request.headers.value(HttpHeaders.rangeHeader)} length=${response.contentLength}');
    await response.close();
  }
}

void _serveVideo(HttpRequest request, Uint8List video) {
  final response = request.response;
  response.headers.contentType = ContentType('video', 'mp4');
  response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
  var first = 0;
  var last = video.length - 1;
  final range = request.headers.value(HttpHeaders.rangeHeader);
  if (range != null) {
    final match = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(range);
    first = int.tryParse(match?.group(1) ?? '') ?? video.length;
    last = min(last, int.tryParse(match?.group(2) ?? '') ?? last);
    if (first > last) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      response.headers.set(HttpHeaders.contentRangeHeader, 'bytes */${video.length}');
      return;
    }
    response.statusCode = HttpStatus.partialContent;
    response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $first-$last/${video.length}');
  }
  response.contentLength = last - first + 1;
  if (request.method != 'HEAD') response.add(Uint8List.sublistView(video, first, last + 1));
}
