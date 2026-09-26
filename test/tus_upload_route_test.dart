import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../lib/src/routes/tus_upload_route.dart';

void main() {
  group('TusUploadRoute Helper Unit Tests', () {
    test('parseMetadata correctly parses Base64 encoded metadata string', () {
      final filenameBase64 = base64.encode(utf8.encode('test_document.pdf'));
      final rawHeader = 'filename $filenameBase64,is_confidential';

      final metadata = TusUploadRoute.parseMetadata(rawHeader);

      expect(metadata['filename'], equals('test_document.pdf'));
      expect(metadata['is_confidential'], equals(''));
    });

    test('parseMetadata returns empty map for null or empty string', () {
      expect(TusUploadRoute.parseMetadata(null), isEmpty);
      expect(TusUploadRoute.parseMetadata(''), isEmpty);
      expect(TusUploadRoute.parseMetadata('   '), isEmpty);
    });

    test('SHA1 and MD5 Checksum calculation matches expected Base64 value', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));

      final sha1Digest = sha1.convert(bytes);
      final sha1Base64 = base64.encode(sha1Digest.bytes);

      final md5Digest = md5.convert(bytes);
      final md5Base64 = base64.encode(md5Digest.bytes);

      expect(sha1Base64, equals('Kq5sNclPz7QV2+lfQIuc6R7oRu0='));
      expect(md5Base64, equals('5EB63BBBE01EEED093CB22BB8F5ACDC3'.toLowerCase()));
    });
  });
}
