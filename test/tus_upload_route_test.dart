import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_tus/serverpod_tus.dart';
import 'package:test/test.dart';

void main() {
  group('TusUploadRoute Tests', () {
    late HttpServer server;
    late Directory tempDir;
    late String baseUrl;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('tus_route_test_');
      final route = TusUploadRoute(
        tempDirectoryPath: tempDir.path,
        storageId: 'public',
      );

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = 'http://${server.address.host}:${server.port}/tus';

      final mockSession = _TestSession();

      server.listen((HttpRequest httpRequest) async {
        final relicReq = await _convertHttpRequest(httpRequest);
        final result = await route.handleCall(mockSession, relicReq);
        await _writeResponse(httpRequest.response, result as Response);
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('OPTIONS returns TUS headers and CORS headers', () async {
      final res = await http.Client().send(http.Request('OPTIONS', Uri.parse('$baseUrl/')));
      expect(res.statusCode, equals(HttpStatus.noContent));
      expect(res.headers['tus-resumable'], equals('1.0.0'));
      expect(res.headers['tus-version'], equals('1.0.0'));
      expect(res.headers['tus-extension'], equals('creation,termination'));
      expect(res.headers['access-control-allow-origin'], equals('*'));
      expect(res.headers['access-control-expose-headers'], contains('Upload-Offset'));
    });

    test('Full Resumable Upload Lifecycle (POST -> HEAD -> PATCH -> DELETE)', () async {
      // 1. POST creation
      final postReq = http.Request('POST', Uri.parse('$baseUrl/'))
        ..headers['Tus-Resumable'] = '1.0.0'
        ..headers['Upload-Length'] = '12';

      final postRes = await postReq.send();
      expect(postRes.statusCode, equals(HttpStatus.created));
      expect(postRes.headers['location'], isNotNull);
      expect(postRes.headers['upload-offset'], equals('0'));

      final location = postRes.headers['location']!;
      final uploadUrl = Uri.parse('http://${server.address.host}:${server.port}$location');

      // 2. HEAD query offset
      final headReq = http.Request('HEAD', uploadUrl)..headers['Tus-Resumable'] = '1.0.0';
      final headRes = await headReq.send();
      expect(headRes.statusCode, equals(HttpStatus.ok));
      expect(headRes.headers['upload-offset'], equals('0'));
      expect(headRes.headers['upload-length'], equals('12'));

      // 3. PATCH first chunk
      final chunk1 = Uint8List.fromList(utf8.encode('Hello '));
      final patchReq1 = http.Request('PATCH', uploadUrl)
        ..headers['Tus-Resumable'] = '1.0.0'
        ..headers['Content-Type'] = 'application/offset+octet-stream'
        ..headers['Upload-Offset'] = '0'
        ..bodyBytes = chunk1;

      final patchRes1 = await patchReq1.send();
      expect(patchRes1.statusCode, equals(HttpStatus.noContent));
      expect(patchRes1.headers['upload-offset'], equals('6'));

      // 4. PATCH second chunk (completion)
      final chunk2 = Uint8List.fromList(utf8.encode('World!'));
      final patchReq2 = http.Request('PATCH', uploadUrl)
        ..headers['Tus-Resumable'] = '1.0.0'
        ..headers['Content-Type'] = 'application/offset+octet-stream'
        ..headers['Upload-Offset'] = '6'
        ..bodyBytes = chunk2;

      final patchRes2 = await patchReq2.send();
      expect(patchRes2.statusCode, equals(HttpStatus.noContent));
      expect(patchRes2.headers['upload-offset'], equals('12'));

      // 5. DELETE upload session
      final deleteReq = http.Request('DELETE', uploadUrl)..headers['Tus-Resumable'] = '1.0.0';
      final deleteRes = await deleteReq.send();
      expect(deleteRes.statusCode, equals(HttpStatus.noContent));

      // Subsequent HEAD returns 404
      final headReq2 = http.Request('HEAD', uploadUrl)..headers['Tus-Resumable'] = '1.0.0';
      final headRes2 = await headReq2.send();
      expect(headRes2.statusCode, equals(HttpStatus.notFound));
    });
  });
}

Future<Request> _convertHttpRequest(HttpRequest req) async {
  final method = Method.parse(req.method);
  final url = req.requestedUri;

  final headersMap = <String, List<String>>{};
  req.headers.forEach((name, values) {
    headersMap[name.toLowerCase()] = values;
  });

  final bodyBytes = await req.fold<BytesBuilder>(
    BytesBuilder(),
    (b, data) => b..add(data),
  ).then((b) => b.takeBytes());

  return RequestInternal.create(
    method,
    url,
    Object(),
    headers: Headers.fromMap(headersMap),
    body: Body.fromData(bodyBytes),
  );
}

Future<void> _writeResponse(HttpResponse response, Response relicResponse) async {
  response.statusCode = relicResponse.statusCode;
  relicResponse.headers.forEach((key, values) {
    for (final v in values) {
      response.headers.add(key, v);
    }
  });

  final bodyStream = relicResponse.body.read();
  await for (final chunk in bodyStream) {
    response.add(chunk);
  }
  await response.close();
}

class _TestSession implements Session {
  @override
  void log(String message, {LogLevel? level, dynamic exception, StackTrace? stackTrace}) {
    print('SESSION LOG: $message, EXCEPTION: $exception');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #storage) {
      return this;
    }
    if (invocation.memberName == #storeFile) {
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
