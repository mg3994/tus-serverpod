# Serverpod TUS Server (`serverpod_tus`)

Native TUS (Resumable File Upload Protocol v1.0.0) implementation for Serverpod.

## Features

- Fully compliant with **TUS Protocol v1.0.0** (`OPTIONS`, `HEAD`, `POST`, `PATCH`, `DELETE`).
- Native integration with **Serverpod WebServer** via custom `Route`.
- Direct storage integration with Serverpod's `session.storage` (`CloudStorage`).
- Streaming disk-buffered chunk upload (`/tmp/tus_uploads`).
- Pre-configured CORS headers for clients such as Flutter `tusc`.

## Setup & Serverpod Registration (`server.dart`)

Register the route in your Serverpod server's `run()` method:

```dart
import 'package:serverpod/serverpod.dart';
import 'package:serverpod_tus/serverpod_tus.dart';

void run(List<String> args) async {
  final pod = Serverpod(
    args,
    Protocol(),
    Endpoints(),
  );

  // Mount TusUploadRoute on webServer
  pod.webServer.addRoute(
    TusUploadRoute(
      tempDirectoryPath: '/tmp/tus_uploads',
      storageId: 'public',
    ),
    '/tus/*',
  );

  await pod.start();
}
```

## Client Usage (`tusc` or Flutter/Web)

Configure your client (such as `tusc`) to point to the mounted path:

```dart
final client = TusClient(
  url: 'http://localhost:8082/tus/',
  file: myFile,
  metadata: {
    'filename': 'my_video.mp4',
  },
);

await client.upload();
```
