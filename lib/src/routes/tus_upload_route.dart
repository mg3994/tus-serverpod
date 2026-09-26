import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:relic/relic.dart';
import 'package:serverpod/serverpod.dart';
import 'package:uuid/uuid.dart';

import '../generated/protocol.dart';

/// Full-featured, production-ready TUS (Resumable Upload Protocol v1.0.0) Server Route.
///
/// Implements Core TUS specification and Extensions:
/// - Core Protocol (HEAD, PATCH, OPTIONS)
/// - Creation (`creation`)
/// - Creation With Upload (`creation-with-upload`)
/// - Creation Defer Length (`creation-defer-length`)
/// - Expiration (`expiration`)
/// - Checksum (`checksum`) - sha1, md5, sha256
/// - Termination (`termination`)
/// - Concatenation (`concatenation`)
class TusUploadRoute extends Route {
  static const String _tempDirPath = '/tmp/tus_uploads';
  static const String _tusVersion = '1.0.0';
  static const String _supportedChecksumAlgorithms = 'sha1,md5,sha256';

  TusUploadRoute() {
    final tempDir = Directory(_tempDirPath);
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }
  }

  @override
  Future<Response> handleCall(Session session, Request request) async {
    // Support X-HTTP-Method-Override header
    final overrideMethod = _getHeader(request, 'x-http-method-override');
    final method = (overrideMethod ?? request.method.value).toUpperCase();

    // Verify TUS protocol version for non-OPTIONS requests if provided
    final clientTusVersion = _getHeader(request, 'tus-resumable');
    if (method != 'OPTIONS' && clientTusVersion != null && clientTusVersion != _tusVersion) {
      return Response(
        statusCode: 412, // Precondition Failed
        headers: _buildHeaders(extraHeaders: {'Tus-Version': _tusVersion}),
        body: Body.text('Precondition Failed: Unsupported TUS Protocol Version'),
      );
    }

    try {
      switch (method) {
        case 'OPTIONS':
          return _handleOptions(request);
        case 'POST':
          return await _handlePost(session, request);
        case 'HEAD':
          return await _handleHead(session, request);
        case 'PATCH':
          return await _handlePatch(session, request);
        case 'DELETE':
          return await _handleDelete(session, request);
        default:
          return Response(
            statusCode: 405, // Method Not Allowed
            headers: _buildHeaders(),
            body: Body.text('Method Not Allowed'),
          );
      }
    } catch (e, stackTrace) {
      session.log('Error handling TUS request: $e\n$stackTrace', level: LogLevel.error);
      return Response(
        statusCode: 500,
        headers: _buildHeaders(),
        body: Body.text('Internal Server Error: ${e.toString()}'),
      );
    }
  }

  /// OPTIONS: Capabilities discovery
  Response _handleOptions(Request request) {
    return Response(
      statusCode: 204,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
        'Tus-Version': _tusVersion,
        'Tus-Extension':
            'creation,creation-with-upload,creation-defer-length,expiration,checksum,termination,concatenation',
        'Tus-Checksum-Algorithm': _supportedChecksumAlgorithms,
      }),
    );
  }

  /// POST: Creation, Creation With Upload, Creation Defer Length, and Concatenation
  Future<Response> _handlePost(Session session, Request request) async {
    final concatHeader = _getHeader(request, 'upload-concat');
    String? concatType;
    String? concatParts;

    if (concatHeader != null) {
      if (concatHeader.trim().toLowerCase() == 'partial') {
        concatType = 'partial';
      } else if (concatHeader.trim().toLowerCase().startsWith('final;')) {
        concatType = 'final';
        concatParts = concatHeader.trim().substring(6).trim();
      } else {
        return Response(
          statusCode: 400,
          headers: _buildHeaders(),
          body: Body.text('Invalid Upload-Concat header format'),
        );
      }
    }

    int? uploadLength;
    bool isDeferred = false;

    if (concatType == 'final') {
      // Final concatenation does not require Upload-Length
    } else {
      final rawDeferLength = _getHeader(request, 'upload-defer-length');
      if (rawDeferLength == '1') {
        isDeferred = true;
      } else {
        final rawLength = _getHeader(request, 'upload-length');
        if (rawLength == null) {
          return Response(
            statusCode: 400,
            headers: _buildHeaders(),
            body: Body.text('Missing Upload-Length or Upload-Defer-Length header'),
          );
        }
        uploadLength = int.tryParse(rawLength);
        if (uploadLength == null || uploadLength < 0) {
          return Response(
            statusCode: 400,
            headers: _buildHeaders(),
            body: Body.text('Invalid Upload-Length value'),
          );
        }
      }
    }

    final metadata = _getHeader(request, 'upload-metadata');
    final fileId = const Uuid().v4();
    final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 24));

    final uploadSession = TusUploadSession(
      fileId: fileId,
      uploadLength: uploadLength,
      uploadOffset: 0,
      metadata: metadata,
      isDeferredLength: isDeferred,
      concatType: concatType,
      concatParts: concatParts,
      isComplete: false,
      expiresAt: expiresAt,
    );

    await TusUploadSession.db.insertRow(session, uploadSession);

    final tempFile = File('$_tempDirPath/$fileId');
    if (!await tempFile.exists()) {
      await tempFile.create(recursive: true);
    }

    // Handle Concatenation final creation
    if (concatType == 'final') {
      final parts = concatParts!.split(' ').where((s) => s.isNotEmpty).toList();
      final sink = tempFile.openWrite(mode: FileMode.append);

      int combinedLength = 0;
      for (final partPath in parts) {
        final partId = partPath.split('/').where((s) => s.isNotEmpty).last;
        final partSession = await TusUploadSession.db.findFirstRow(
          session,
          where: (t) => t.fileId.equals(partId),
        );

        if (partSession == null || !partSession.isComplete) {
          await sink.close();
          await tempFile.delete();
          await TusUploadSession.db.deleteRow(session, uploadSession);
          return Response(
            statusCode: 400,
            headers: _buildHeaders(),
            body: Body.text('Partial upload $partId is incomplete or missing'),
          );
        }

        final partFile = File('$_tempDirPath/$partId');
        if (await partFile.exists()) {
          final stream = partFile.openRead();
          await sink.addStream(stream);
          combinedLength += await partFile.length();
        } else {
          // Check if already in cloud storage
          final bytes = await session.storage.retrieveFile(
            storageId: 'public',
            path: partId,
          );
          if (bytes != null) {
            sink.add(bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes));
            combinedLength += bytes.lengthInBytes;
          }
        }
      }

      await sink.flush();
      await sink.close();

      uploadSession.uploadLength = combinedLength;
      uploadSession.uploadOffset = combinedLength;
      uploadSession.isComplete = true;
      await TusUploadSession.db.updateRow(session, uploadSession);

      final completedBytes = await tempFile.readAsBytes();
      await session.storage.storeFile(
        storageId: 'public',
        path: fileId,
        byteData: ByteData.sublistView(completedBytes),
      );

      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    // Handle Creation With Upload extension if request body is present and contentType is application/offset+octet-stream
    final contentType = _getHeader(request, 'content-type');
    if (concatType != 'final' &&
        contentType != null &&
        contentType.contains('application/offset+octet-stream')) {
      final bodyBytes = await _readStreamBytes(request.read());
      if (bodyBytes.isNotEmpty) {
        // Check optional Upload-Checksum header
        final checksumHeader = _getHeader(request, 'upload-checksum');
        if (checksumHeader != null) {
          final verifyErr = _verifyChecksum(bodyBytes, checksumHeader);
          if (verifyErr != null) {
            return verifyErr;
          }
        }

        await tempFile.writeAsBytes(bodyBytes, mode: FileMode.append);
        final currentOffset = bodyBytes.length;
        uploadSession.uploadOffset = currentOffset;

        if (uploadLength != null && currentOffset >= uploadLength) {
          uploadSession.isComplete = true;
          await session.storage.storeFile(
            storageId: 'public',
            path: fileId,
            byteData: ByteData.sublistView(bodyBytes),
          );
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        }

        await TusUploadSession.db.updateRow(session, uploadSession);
      }
    }

    final locationUrl = '${request.requestedUri.path.replaceAll(RegExp(r'/$'), '')}/$fileId';

    return Response(
      statusCode: 201,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
        'Location': locationUrl,
        if (uploadSession.uploadLength != null)
          'Upload-Length': uploadSession.uploadLength.toString(),
        if (uploadSession.isDeferredLength) 'Upload-Defer-Length': '1',
        'Upload-Offset': uploadSession.uploadOffset.toString(),
        'Upload-Expires': _formatHttpDate(expiresAt),
      }),
    );
  }

  /// HEAD: Status check
  Future<Response> _handleHead(Session session, Request request) async {
    final fileId = _extractFileId(request);
    if (fileId == null) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Missing file ID in URL'),
      );
    }

    final uploadSession = await TusUploadSession.db.findFirstRow(
      session,
      where: (t) => t.fileId.equals(fileId),
    );

    if (uploadSession == null) {
      return Response(
        statusCode: 404,
        headers: _buildHeaders(),
        body: Body.text('Upload session not found'),
      );
    }

    final headers = <String, String>{
      'Tus-Resumable': _tusVersion,
      'Upload-Offset': uploadSession.uploadOffset.toString(),
      'Cache-Control': 'no-store',
      'Upload-Expires': _formatHttpDate(uploadSession.expiresAt),
    };

    if (uploadSession.uploadLength != null) {
      headers['Upload-Length'] = uploadSession.uploadLength.toString();
    } else if (uploadSession.isDeferredLength) {
      headers['Upload-Defer-Length'] = '1';
    }

    if (uploadSession.metadata != null) {
      headers['Upload-Metadata'] = uploadSession.metadata!;
    }

    if (uploadSession.concatType != null) {
      if (uploadSession.concatType == 'partial') {
        headers['Upload-Concat'] = 'partial';
      } else if (uploadSession.concatType == 'final' && uploadSession.concatParts != null) {
        headers['Upload-Concat'] = 'final;${uploadSession.concatParts}';
      }
    }

    return Response(
      statusCode: 200,
      headers: _buildHeaders(extraHeaders: headers),
    );
  }

  /// PATCH: Receive upload chunk
  Future<Response> _handlePatch(Session session, Request request) async {
    final fileId = _extractFileId(request);
    if (fileId == null) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Missing file ID in URL'),
      );
    }

    final contentType = _getHeader(request, 'content-type');
    if (contentType == null || !contentType.contains('application/offset+octet-stream')) {
      return Response(
        statusCode: 415,
        headers: _buildHeaders(),
        body: Body.text('Content-Type must be application/offset+octet-stream'),
      );
    }

    final uploadSession = await TusUploadSession.db.findFirstRow(
      session,
      where: (t) => t.fileId.equals(fileId),
    );

    if (uploadSession == null) {
      return Response(
        statusCode: 404,
        headers: _buildHeaders(),
        body: Body.text('Upload session not found'),
      );
    }

    if (uploadSession.concatType == 'final') {
      return Response(
        statusCode: 403, // Forbidden to PATCH final concat resource
        headers: _buildHeaders(),
        body: Body.text('Cannot PATCH a final concatenated upload'),
      );
    }

    if (uploadSession.isComplete) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Upload session is already complete'),
      );
    }

    final rawOffset = _getHeader(request, 'upload-offset');
    final clientOffset = rawOffset != null ? int.tryParse(rawOffset) : null;

    if (clientOffset == null || clientOffset != uploadSession.uploadOffset) {
      return Response(
        statusCode: 409, // Conflict
        headers: _buildHeaders(extraHeaders: {
          'Tus-Resumable': _tusVersion,
          'Upload-Offset': uploadSession.uploadOffset.toString(),
        }),
        body: Body.text('Upload-Offset mismatch'),
      );
    }

    // Handle deferred length provided on PATCH
    if (uploadSession.isDeferredLength && uploadSession.uploadLength == null) {
      final newLengthHeader = _getHeader(request, 'upload-length');
      if (newLengthHeader != null) {
        final parsedLength = int.tryParse(newLengthHeader);
        if (parsedLength != null && parsedLength >= uploadSession.uploadOffset) {
          uploadSession.uploadLength = parsedLength;
          uploadSession.isDeferredLength = false;
        }
      }
    }

    final chunkBytes = await _readStreamBytes(request.read());

    // Validate Upload-Checksum if provided
    final checksumHeader = _getHeader(request, 'upload-checksum');
    if (checksumHeader != null) {
      final verifyErr = _verifyChecksum(chunkBytes, checksumHeader);
      if (verifyErr != null) {
        return verifyErr;
      }
    }

    final tempFile = File('$_tempDirPath/$fileId');
    await tempFile.writeAsBytes(chunkBytes, mode: FileMode.append);

    final newOffset = uploadSession.uploadOffset + chunkBytes.length;
    uploadSession.uploadOffset = newOffset;

    final isComplete =
        uploadSession.uploadLength != null && newOffset >= uploadSession.uploadLength!;
    uploadSession.isComplete = isComplete;

    await TusUploadSession.db.updateRow(session, uploadSession);

    if (isComplete) {
      final fileBytes = await tempFile.readAsBytes();
      await session.storage.storeFile(
        storageId: 'public',
        path: fileId,
        byteData: ByteData.sublistView(fileBytes),
      );

      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    }

    return Response(
      statusCode: 204,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
        'Upload-Offset': newOffset.toString(),
        'Upload-Expires': _formatHttpDate(uploadSession.expiresAt),
      }),
    );
  }

  /// DELETE: Termination extension
  Future<Response> _handleDelete(Session session, Request request) async {
    final fileId = _extractFileId(request);
    if (fileId == null) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Missing file ID in URL'),
      );
    }

    final uploadSession = await TusUploadSession.db.findFirstRow(
      session,
      where: (t) => t.fileId.equals(fileId),
    );

    if (uploadSession == null) {
      return Response(
        statusCode: 404,
        headers: _buildHeaders(),
        body: Body.text('Upload session not found'),
      );
    }

    final tempFile = File('$_tempDirPath/$fileId');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    await TusUploadSession.db.deleteRow(session, uploadSession);

    return Response(
      statusCode: 204,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
      }),
    );
  }

  /// Helper to verify Upload-Checksum header against payload bytes
  Response? _verifyChecksum(Uint8List bytes, String checksumHeader) {
    final parts = checksumHeader.trim().split(' ');
    if (parts.length != 2) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Invalid Upload-Checksum header format'),
      );
    }

    final algo = parts[0].toLowerCase();
    final expectedBase64 = parts[1];

    Digest digest;
    switch (algo) {
      case 'sha1':
        digest = sha1.convert(bytes);
        break;
      case 'md5':
        digest = md5.convert(bytes);
        break;
      case 'sha256':
        digest = sha256.convert(bytes);
        break;
      default:
        return Response(
          statusCode: 400,
          headers: _buildHeaders(),
          body: Body.text('Unsupported checksum algorithm'),
        );
    }

    final actualBase64 = base64.encode(digest.bytes);
    if (actualBase64 != expectedBase64) {
      return Response(
        statusCode: 460, // TUS Checksum Mismatch status code
        headers: _buildHeaders(),
        body: Body.text('Checksum Mismatch'),
      );
    }

    return null;
  }

  /// Helper to convert byte stream to Uint8List
  Future<Uint8List> _readStreamBytes(Stream<List<int>> stream) async {
    final builder = BytesBuilder();
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// Format DateTime to RFC 9110 HTTP-date format (e.g. Wed, 25 Jun 2024 16:00:00 GMT)
  String _formatHttpDate(DateTime date) {
    return HttpDate.format(date.toUtc());
  }

  /// Build CORS & TUS headers
  Map<String, String> _buildHeaders({Map<String, String>? extraHeaders}) {
    final headers = <String, String>{
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'POST, GET, HEAD, PATCH, DELETE, OPTIONS',
      'Access-Control-Allow-Headers':
          'Origin, X-Requested-With, Content-Type, Accept, Authorization, Tus-Resumable, Upload-Length, Upload-Metadata, Upload-Offset, Upload-Defer-Length, Upload-Concat, Upload-Checksum, X-HTTP-Method-Override',
      'Access-Control-Expose-Headers':
          'Upload-Offset, Location, Upload-Length, Tus-Version, Tus-Resumable, Tus-Max-Size, Tus-Extension, Upload-Expires, Upload-Metadata, Upload-Defer-Length, Upload-Concat, Tus-Checksum-Algorithm',
    };

    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    return headers;
  }

  String? _getHeader(Request request, String name) {
    final targetName = name.toLowerCase();
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == targetName) {
        return entry.value;
      }
    }
    return null;
  }

  String? _extractFileId(Request request) {
    final segments = request.requestedUri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    return segments.last;
  }
}
