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
