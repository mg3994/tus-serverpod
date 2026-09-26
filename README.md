# Serverpod Native TUS Resumable Upload Server Implementation

This implementation provides a native, production-ready, full-featured implementation of the [tus resumable upload protocol v1.0.0](https://tus.io/protocols/resumable-upload) built directly into Serverpod 4.1.0-beta.1 using Serverpod's built-in Relic web server, Serverpod ORM, and cloud storage features.

## Protocol Features & Extensions
- **Core Protocol**: `HEAD`, `PATCH`, `OPTIONS`, `GET`
- **Creation (`creation`)**: `POST` request to initialize upload resource
- **Creation With Upload (`creation-with-upload`)**: Upload chunk inside `POST` creation request
- **Creation Defer Length (`creation-defer-length`)**: Deferred length via `Upload-Defer-Length: 1`
- **Expiration (`expiration`)**: `Upload-Expires` tracking in RFC 9110 HTTP-date format, with `410 Gone` on expired sessions.
- **Sliding Window Expiration**: Every valid `PATCH` request automatically extends `expiresAt` (e.g. by 24h), allowing active retries to continue seamlessly without expiring mid-upload.
- **Checksum (`checksum`)**: Payload integrity validation supporting `sha1`, `md5`, and `sha256` (returning HTTP `460 Checksum Mismatch` on failure)
- **Termination (`termination`)**: `DELETE` method to cancel upload and free resources
- **Concatenation (`concatenation`)**: Concatenate partial uploads (`Upload-Concat: partial` & `final;...`)
- **Concurrency Locking**: Per-file mutex locking (`_locks`) preventing race conditions on concurrent `PATCH` requests
- **Expiration Worker**: `startExpirationCleanupWorker` background worker to purge abandoned uploads
- **Max Size Limits**: Enforces `maxSize` and responds with HTTP `413 Payload Too Large`
- **Event Hooks**: `onUploadCreate`, `onUploadFinish`, `onUploadCancel`, `onChunkComplete`
- **Metadata Parser**: Base64 `Upload-Metadata` parser (`TusUploadRoute.parseMetadata`)
- **Cleanup Utility**: Purge expired abandoned uploads via `cleanExpiredUploads`
- **Method Override**: `X-HTTP-Method-Override` support for restricted clients

---

## Step 1: Database Model (`tus_upload_session.spy.yaml`)

Location: `lib/src/models/tus_upload_session.spy.yaml`

```yaml
class: TusUploadSession
table: tus_upload_session
fields:
  fileId: String
  uploadLength: int?
  uploadOffset: int
  metadata: String?
  isDeferredLength: bool, default=false
  concatType: String?
  concatParts: String?
  isComplete: bool, default=false
  expiresAt: DateTime
indexes:
  file_id_idx:
    fields: fileId
    unique: true
```

---

## Step 2 & 3: `TusUploadRoute` Class & CORS Utility (`tus_upload_route.dart`)

Location: `lib/src/routes/tus_upload_route.dart`

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:relic/relic.dart';
import 'package:serverpod/serverpod.dart';
import 'package:uuid/uuid.dart';

import '../generated/protocol.dart';

class TusUploadRoute extends Route { ... }
```

---

## Step 4: Route Registration (`server.dart`)

Location: `lib/src/server.dart`

```dart
import 'package:serverpod/serverpod.dart';

import 'routes/tus_upload_route.dart';

void run(List<String> args) async {
  final pod = Serverpod(args);

  final tusRoute = TusUploadRoute(
    maxSize: 5 * 1024 * 1024 * 1024, // 5 GB
    expirationDuration: const Duration(hours: 24), // Sliding window extension duration
    onUploadCreate: (session, uploadSession, metadata) async {
      session.log('Upload created: ${uploadSession.fileId}');
    },
    onChunkComplete: (session, uploadSession, chunkSize) async {
      session.log('Chunk received: $chunkSize bytes');
    },
    onUploadFinish: (session, uploadSession) async {
      session.log('Upload completed: ${uploadSession.fileId}');
    },
    onUploadCancel: (session, fileId) async {
      session.log('Upload cancelled: $fileId');
    },
  );

  // Optional: start background expiration cleanup worker
  tusRoute.startExpirationCleanupWorker(pod);

  pod.webServer.addRoute(tusRoute, '/tus/*');
  await pod.start();
}
```
