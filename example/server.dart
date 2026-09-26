import 'package:serverpod/serverpod.dart';
import 'package:serverpod_tus/serverpod_tus.dart';

void main() {
  print('Example Serverpod TUS Server Configuration:');
  final route = TusUploadRoute(
    tempDirectoryPath: '/tmp/tus_uploads',
    storageId: 'public',
  );
  print('Route instantiated: ${route.runtimeType}');
}

void registerRoute(Serverpod pod) {
  pod.webServer.addRoute(
    TusUploadRoute(
      tempDirectoryPath: '/tmp/tus_uploads',
      storageId: 'public',
    ),
    '/tus/*',
  );
}
