# Serverpod Native TUS Resumable Upload Server Implementation

This implementation provides a native, production-ready implementation of the [tus resumable upload protocol v1.0.0](https://tus.io/protocols/resumable-upload.html) built directly into Serverpod 4.1.0-beta.1 using Serverpod's built-in Relic web server, Serverpod ORM, and cloud storage features.

---

## Step 1: Database Model (`tus_upload_session.spy.yaml`)

Location: `lib/src/models/tus_upload_session.spy.yaml`

```yaml
class: TusUploadSession
table: tus_upload_session
fields:
  fileId: String
  uploadLength: int
  uploadOffset: int
  metadata: String?
  isComplete: bool, default=false
  expiresAt: DateTime
indexes:
  file_id_idx:
    fields: fileId
    unique: true
```

*Note: Run `serverpod start` or `serverpod generate` to generate the Dart model classes and DB migrations.*

---

## Step 2 & 3: `TusUploadRoute` Class & CORS Utility (`tus_upload_route.dart`)

Location: `lib/src/routes/tus_upload_route.dart`

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:relic/relic.dart';
import 'package:serverpod/serverpod.dart';
import 'package:uuid/uuid.dart';

import '../generated/protocol.dart';

/// Production-ready TUS (Resumable Upload Protocol v1.0.0) Server Route.
///
/// Implements `relic.Route` to handle resumable uploads natively inside
/// Serverpod web server using Serverpod ORM and Relic HTTP request/response abstractions.
class TusUploadRoute extends Route {
  static const String _tempDirPath = '/tmp/tus_uploads';
  static const String _tusVersion = '1.0.0';

  TusUploadRoute() {
    // Ensure temporary upload directory exists at startup
    final tempDir = Directory(_tempDirPath);
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }
  }

  @override
  Future<Response> handleCall(Session session, Request request) async {
    final method = request.method.value.toUpperCase();

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

  /// OPTIONS: Server discovery / capabilities preflight
  Response _handleOptions(Request request) {
    return Response(
      statusCode: 204,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
        'Tus-Version': _tusVersion,
        'Tus-Extension': 'creation,termination',
      }),
    );
  }

  /// POST: Creation extension - initializes upload session
  Future<Response> _handlePost(Session session, Request request) async {
    final rawLength = _getHeader(request, 'upload-length');
    if (rawLength == null) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Missing Upload-Length header'),
      );
    }

    final uploadLength = int.tryParse(rawLength);
    if (uploadLength == null || uploadLength < 0) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Invalid Upload-Length header value'),
      );
    }

    final metadata = _getHeader(request, 'upload-metadata');
    final fileId = const Uuid().v4();
    final expiresAt = DateTime.now().toUtc().add(const Duration(hours: 24));

    // Create DB upload session using Serverpod ORM
    final uploadSession = TusUploadSession(
      fileId: fileId,
      uploadLength: uploadLength,
      uploadOffset: 0,
      metadata: metadata,
      isComplete: false,
      expiresAt: expiresAt,
    );

    await TusUploadSession.db.insertRow(session, uploadSession);

    // Prepare temporary local file on disk
    final tempFile = File('$_tempDirPath/$fileId');
    if (!await tempFile.exists()) {
      await tempFile.create(recursive: true);
    }

    final locationUrl = '${request.requestedUri.path.replaceAll(RegExp(r'/$'), '')}/$fileId';

    return Response(
      statusCode: 201,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
        'Location': locationUrl,
        'Upload-Length': uploadLength.toString(),
      }),
    );
  }

  /// HEAD: Retrieve current upload status and offset
  Future<Response> _handleHead(Session session, Request request) async {
    final fileId = _extractFileId(request);
    if (fileId == null) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Missing file ID in request URL'),
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

    return Response(
      statusCode: 200,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
        'Upload-Offset': uploadSession.uploadOffset.toString(),
        'Upload-Length': uploadSession.uploadLength.toString(),
        'Cache-Control': 'no-store',
      }),
    );
  }

  /// PATCH: Append raw upload chunk bytes
  Future<Response> _handlePatch(Session session, Request request) async {
    final fileId = _extractFileId(request);
    if (fileId == null) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Missing file ID in request URL'),
      );
    }

    // Validate Content-Type
    final contentType = _getHeader(request, 'content-type');
    if (contentType == null || !contentType.contains('application/offset+octet-stream')) {
      return Response(
        statusCode: 415,
        headers: _buildHeaders(),
        body: Body.text('Content-Type must be application/offset+octet-stream'),
      );
    }

    // Query DB session
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

    if (uploadSession.isComplete) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Upload session is already completed'),
      );
    }

    // Validate Upload-Offset header against current DB state
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

    // Stream incoming bytes directly to the temp file
    final tempFile = File('$_tempDirPath/$fileId');
    final sink = tempFile.openWrite(mode: FileMode.append);

    await sink.addStream(request.read());
    await sink.flush();
    await sink.close();

    final newOffset = await tempFile.length();

    // Check completion status
    final isComplete = newOffset >= uploadSession.uploadLength;

    // Update DB tracking state
    uploadSession.uploadOffset = newOffset;
    uploadSession.isComplete = isComplete;
    await TusUploadSession.db.updateRow(session, uploadSession);

    // When fully uploaded, transfer to Serverpod storage and clean up temp file
    if (isComplete) {
      final fileBytes = await tempFile.readAsBytes();
      final byteData = ByteData.sublistView(fileBytes);

      await session.storage.storeFile(
        storageId: 'public',
        path: fileId,
        byteData: byteData,
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
      }),
    );
  }

  /// DELETE: Termination extension - cancel upload session and delete resources
  Future<Response> _handleDelete(Session session, Request request) async {
    final fileId = _extractFileId(request);
    if (fileId == null) {
      return Response(
        statusCode: 400,
        headers: _buildHeaders(),
        body: Body.text('Missing file ID in request URL'),
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

    // Remove temporary file
    final tempFile = File('$_tempDirPath/$fileId');
    if (await tempFile.exists()) {
      await tempFile.delete();
    }

    // Remove DB session row
    await TusUploadSession.db.deleteRow(session, uploadSession);

    return Response(
      statusCode: 204,
      headers: _buildHeaders(extraHeaders: {
        'Tus-Resumable': _tusVersion,
      }),
    );
  }

  /// Step 3: Relic CORS Headers Utility Helper
  Map<String, String> _buildHeaders({Map<String, String>? extraHeaders}) {
    final headers = <String, String>{
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Methods': 'POST, GET, HEAD, PATCH, DELETE, OPTIONS',
      'Access-Control-Allow-Headers':
          'Origin, X-Requested-With, Content-Type, Accept, Authorization, Tus-Resumable, Upload-Length, Upload-Metadata, Upload-Offset',
      'Access-Control-Expose-Headers':
          'Upload-Offset, Location, Upload-Length, Tus-Version, Tus-Resumable, Tus-Max-Size, Tus-Extension',
    };

    if (extraHeaders != null) {
      headers.addAll(extraHeaders);
    }

    return headers;
  }

  /// Helper to get request header case-insensitively
  String? _getHeader(Request request, String name) {
    final targetName = name.toLowerCase();
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == targetName) {
        return entry.value;
      }
    }
    return null;
  }

  /// Helper to extract file ID from path segments
  String? _extractFileId(Request request) {
    final segments = request.requestedUri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) return null;
    return segments.last;
  }
}
```

---

## Step 4: Route Registration (`server.dart`)

Location: `lib/src/server.dart`

```dart
import 'package:serverpod/serverpod.dart';

import 'routes/tus_upload_route.dart';

/// Server entry point demonstrating Serverpod 4 initialization and Relic web server route registration.
void run(List<String> args) async {
  // Initialize Serverpod 4 using simplified single-argument constructor
  final pod = Serverpod(args);

  // Mount the custom TUS Upload Route onto Relic Web Server
  // Intercepts all subpaths under /tus/ (e.g. /tus/ and /tus/<fileId>)
  pod.webServer.addRoute(TusUploadRoute(), '/tus/*');

  // Start the Serverpod instance
  await pod.start();
}
```
