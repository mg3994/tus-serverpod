import 'package:serverpod/serverpod.dart';

import 'routes/tus_upload_route.dart';

/// Server entry point demonstrating Serverpod 4 initialization and Relic web server route registration.
void run(List<String> args) async {
  // Initialize Serverpod 4 using simplified single-argument constructor
  final pod = Serverpod(args);

  // Instantiates custom TUS route with max upload size limit and event hooks
  final tusRoute = TusUploadRoute(
    maxSize: 5 * 1024 * 1024 * 1024, // 5 GB limit
    onUploadCreate: (session, uploadSession, metadata) async {
      session.log('TUS Upload created: ${uploadSession.fileId}, metadata: $metadata');
    },
    onChunkComplete: (session, uploadSession, chunkSize) async {
      session.log('TUS Chunk received: $chunkSize bytes for ${uploadSession.fileId}');
    },
    onUploadFinish: (session, uploadSession) async {
      session.log('TUS Upload finished: ${uploadSession.fileId}');
    },
    onUploadCancel: (session, fileId) async {
      session.log('TUS Upload cancelled: $fileId');
    },
  );

  // Mount the custom TUS Upload Route onto Relic Web Server
  pod.webServer.addRoute(tusRoute, '/tus/*');

  // Start the Serverpod instance
  await pod.start();
}
