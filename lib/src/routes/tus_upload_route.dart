import 'dart:async';
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
/// Native implementation built for Serverpod 4 using Relic Web Server, ORM, and Cloud Storage.
///
/// Features & Extensions:
/// - Core Protocol (`HEAD`, `PATCH`, `OPTIONS`, `GET`)
/// - Extensions: `creation`, `creation-with-upload`, `creation-defer-length`, `expiration`, `checksum`, `termination`, `concatenation`
/// - Per-upload Concurrency Locking (prevents parallel PATCH race conditions on the same resource)
/// - Expiration enforcement (`410 Gone` on expired sessions) & `startExpirationCleanupWorker`
/// - Configurable upload size limit (`Tus-Max-Size`)
/// - Event Hooks (`onUploadCreate`, `onUploadFinish`, `onUploadCancel`, `onChunkComplete`)
/// - Base64 Metadata parsing (`parseMetadata`)
class TusUploadRoute extends Route {
  static const String _defaultTempDirPath = '/tmp/tus_uploads';
  static const String _tusVersion = '1.0.0';
  static const String _supportedChecksumAlgorithms = 'sha1,md5,sha256';

  final String tempDirPath;
  final int? maxSize; // Maximum allowed upload size in bytes

  // Per-file id concurrency locks
  final Map<String, Completer<void>> _locks = {};

  // Event hooks
  final Future<void> Function(
    Session session,
    TusUploadSession uploadSession,
    Map<String, String> metadata,
  )? onUploadCreate;
  final Future<void> Function(
    Session session,
    TusUploadSession uploadSession,
  )? onUploadFinish;
  final Future<void> Function(
    Session session,
    String fileId,
  )? onUploadCancel;
  final Future<void> Function(
    Session session,
    TusUploadSession uploadSession,
    int chunkSize,
  )? onChunkComplete;

  TusUploadRoute({
    this.tempDirPath = _defaultTempDirPath,
    this.maxSize,
    this.onUploadCreate,
    this.onUploadFinish,
    this.onUploadCancel,
    this.onChunkComplete,
  }) {
    final tempDir = Directory(tempDirPath);
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }
  }

  @override
  Future<Response> handleCall(Session session, Request request) async {
    final overrideMethod = _getHeader(request, 'x-http-method-override');
    final method = (overrideMethod ?? request.method.value).toUpperCase();

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
          return await _withLock(_extractFileId(request), () => _handlePatch(session, request));
        case 'DELETE':
          return await _withLock(_extractFileId(request), () => _handleDelete(session, request));
        case 'GET':
          return await _handleGet(session, request);
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

  /// Concurrency lock helper ensuring single-thread execution per file ID
  Future<Response> _withLock(String? fileId, Future<Response> Function() action) async {
    if (fileId == null) return await action();

    while (_locks.containsKey(fileId)) {
      await _locks[fileId]!.future;
    }

    final completer = Completer<void>();
    _locks[fileId] = completer;

    try {
      return await action();
    } finally {
      _locks.remove(fileId);
      completer.complete();
    }
  }

  /// OPTIONS: Server capabilities preflight
  Response _handleOptions(Request request) {
    return Response(
      statusCode: 204,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
        'Tus-Version': _tusVersion,
        'Tus-Extension':
            'creation,creation-with-upload,creation-defer-length,expiration,checksum,termination,concatenation',
        'Tus-Checksum-Algorithm': _supportedChecksumAlgorithms,
        if (maxSize != null) 'Tus-Max-Size': maxSize.toString(),
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

    if (concatType != 'final') {
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

        if (maxSize != null && uploadLength > maxSize!) {
          return Response(
            statusCode: 413, // Payload Too Large
            headers: _buildHeaders(extraHeaders: {'Tus-Max-Size': maxSize.toString()}),
            body: Body.text('Upload-Length exceeds maximum allowed size ($maxSize bytes)'),
          );
        }
      }
    }

    final rawMetadata = _getHeader(request, 'upload-metadata');
    final fileId = const Uuid().v4();
    final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 24));

    final initialSession = TusUploadSession(
      fileId: fileId,
      uploadLength: uploadLength,
      uploadOffset: 0,
      metadata: rawMetadata,
      isDeferredLength: isDeferred,
      concatType: concatType,
      concatParts: concatParts,
      isComplete: false,
      expiresAt: expiresAt,
    );

    var uploadSession = await TusUploadSession.db.insertRow(session, initialSession);

    final tempFile = File('$tempDirPath/$fileId');
    if (!await tempFile.exists()) {
      await tempFile.create(recursive: true);
    }

    if (onUploadCreate != null) {
      final parsedMetadata = parseMetadata(rawMetadata);
      await onUploadCreate!(session, uploadSession, parsedMetadata);
    }

    // Concatenation final creation
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

        final partFile = File('$tempDirPath/$partId');
        if (await partFile.exists()) {
          final stream = partFile.openRead();
          await sink.addStream(stream);
          combinedLength += await partFile.length();
        } else {
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
      uploadSession = await TusUploadSession.db.updateRow(session, uploadSession);

      final completedBytes = await tempFile.readAsBytes();
      await session.storage.storeFile(
        storageId: 'public',
        path: fileId,
        byteData: ByteData.sublistView(completedBytes),
      );

      if (await tempFile.exists()) {
        await tempFile.delete();
      }

      if (onUploadFinish != null) {
        await onUploadFinish!(session, uploadSession);
      }
    }

    // Creation With Upload
    final contentType = _getHeader(request, 'content-type');
    if (concatType != 'final' &&
        contentType != null &&
        contentType.contains('application/offset+octet-stream')) {
      final bodyBytes = await _readStreamBytes(request.read());
      if (bodyBytes.isNotEmpty) {
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

        if (onChunkComplete != null) {
          await onChunkComplete!(session, uploadSession, bodyBytes.length);
        }

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

          if (onUploadFinish != null) {
            await onUploadFinish!(session, uploadSession);
          }
        }

        uploadSession = await TusUploadSession.db.updateRow(session, uploadSession);
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

    // Expiration check
    if (!uploadSession.isComplete && uploadSession.expiresAt.isBefore(DateTime.now().toUtc())) {
      return Response(
        statusCode: 410, // Gone
        headers: _buildHeaders(),
        body: Body.text('Upload session has expired'),
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

    var uploadSession = await TusUploadSession.db.findFirstRow(
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

    if (!uploadSession.isComplete && uploadSession.expiresAt.isBefore(DateTime.now().toUtc())) {
      return Response(
        statusCode: 410, // Gone
        headers: _buildHeaders(),
        body: Body.text('Upload session has expired'),
      );
    }

    if (uploadSession.concatType == 'final') {
      return Response(
        statusCode: 403,
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
        statusCode: 409,
        headers: _buildHeaders(extraHeaders: {
          'Tus-Resumable': _tusVersion,
          'Upload-Offset': uploadSession.uploadOffset.toString(),
        }),
        body: Body.text('Upload-Offset mismatch'),
      );
    }

    if (uploadSession.isDeferredLength && uploadSession.uploadLength == null) {
      final newLengthHeader = _getHeader(request, 'upload-length');
      if (newLengthHeader != null) {
        final parsedLength = int.tryParse(newLengthHeader);
        if (parsedLength != null && parsedLength >= uploadSession.uploadOffset) {
          if (maxSize != null && parsedLength > maxSize!) {
            return Response(
              statusCode: 413,
              headers: _buildHeaders(extraHeaders: {'Tus-Max-Size': maxSize.toString()}),
              body: Body.text('Upload-Length exceeds maximum allowed size ($maxSize bytes)'),
            );
          }
          uploadSession.uploadLength = parsedLength;
          uploadSession.isDeferredLength = false;
        }
      }
    }

    final chunkBytes = await _readStreamBytes(request.read());

    final checksumHeader = _getHeader(request, 'upload-checksum');
    if (checksumHeader != null) {
      final verifyErr = _verifyChecksum(chunkBytes, checksumHeader);
      if (verifyErr != null) {
        return verifyErr;
      }
    }

    final tempFile = File('$tempDirPath/$fileId');
    await tempFile.writeAsBytes(chunkBytes, mode: FileMode.append);

    final newOffset = uploadSession.uploadOffset + chunkBytes.length;
    uploadSession.uploadOffset = newOffset;

    if (onChunkComplete != null) {
      await onChunkComplete!(session, uploadSession, chunkBytes.length);
    }

    final isComplete =
        uploadSession.uploadLength != null && newOffset >= uploadSession.uploadLength!;
    uploadSession.isComplete = isComplete;

    uploadSession = await TusUploadSession.db.updateRow(session, uploadSession);

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

      if (onUploadFinish != null) {
        await onUploadFinish!(session, uploadSession);
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

    final tempFile = File('$tempDirPath/$fileId');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    await TusUploadSession.db.deleteRow(session, uploadSession);

    if (onUploadCancel != null) {
      await onUploadCancel!(session, fileId);
    }

    return Response(
      statusCode: 204,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
      }),
    );
  }

  /// GET: Download completed uploaded file
  Future<Response> _handleGet(Session session, Request request) async {
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
        body: Body.text('File not found'),
      );
    }

    if (!uploadSession.isComplete) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Upload is still in progress'),
      );
    }

    final byteData = await session.storage.retrieveFile(
      storageId: 'public',
      path: fileId,
    );

    if (byteData == null) {
      return Response(
        statusCode: 404,
        headers: _buildHeaders(),
        body: Body.text('File missing from storage'),
      );
    }

    final uint8List = byteData.buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes);

    return Response(
      statusCode: 200,
      headers: _buildHeaders(extraHeaders: {
        'Content-Type': 'application/octet-stream',
        'Content-Length': uint8List.length.toString(),
      }),
      body: Body.binary(uint8List),
    );
  }

  /// Starts a background worker that periodically purges expired uploads
  Timer startExpirationCleanupWorker(
    Serverpod pod, {
    Duration interval = const Duration(hours: 1),
  }) {
    return Timer.periodic(interval, (_) async {
      final session = await pod.createSession();
      try {
        final purgedCount = await cleanExpiredUploads(session);
        if (purgedCount > 0) {
          session.log('TUS Expiration Worker: Purged $purgedCount expired upload sessions');
        }
      } catch (e) {
        session.log('TUS Expiration Worker error: $e', level: LogLevel.error);
      } finally {
        await session.close();
      }
    });
  }

  /// Utility method to purge expired upload sessions and temporary disk files
  Future<int> cleanExpiredUploads(Session session) async {
    final now = DateTime.now().toUtc();
    final expiredSessions = await TusUploadSession.db.find(
      session,
      where: (t) => t.expiresAt.lessThan(now) & t.isComplete.equals(false),
    );

    int count = 0;
    for (final s in expiredSessions) {
      final tempFile = File('$tempDirPath/${s.fileId}');
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      await TusUploadSession.db.deleteRow(session, s);
      count++;
    }
    return count;
  }

  /// Utility method to parse Base64 encoded Upload-Metadata header string
  static Map<String, String> parseMetadata(String? metadataHeader) {
    if (metadataHeader == null || metadataHeader.trim().isEmpty) {
      return {};
    }

    final metadata = <String, String>{};
    final pairs = metadataHeader.trim().split(',');

    for (final pair in pairs) {
      final parts = pair.trim().split(' ');
      if (parts.isEmpty) continue;

      final key = parts[0].trim();
      if (key.isEmpty) continue;

      if (parts.length > 1) {
        try {
          final decodedValue = utf8.decode(base64.decode(parts[1].trim()));
          metadata[key] = decodedValue;
        } catch (_) {
          metadata[key] = parts[1].trim();
        }
      } else {
        metadata[key] = '';
      }
    }

    return metadata;
  }

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
        statusCode: 460,
        headers: _buildHeaders(),
        body: Body.text('Checksum Mismatch'),
      );
    }

    return null;
  }

  Future<Uint8List> _readStreamBytes(Stream<List<int>> stream) async {
    final builder = BytesBuilder();
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  String _formatHttpDate(DateTime date) {
    return HttpDate.format(date.toUtc());
  }

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
