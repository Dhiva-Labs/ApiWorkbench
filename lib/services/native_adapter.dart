import 'package:native_dio_adapter/native_dio_adapter.dart';

import 'http_service.dart';

/// Lets every [HttpService] send HTTP/3 requests through the platform's own
/// HTTP stack on Android, iOS and macOS. Called once by the app at startup.
///
/// Only the Flutter app imports this file: native_dio_adapter depends on
/// Flutter, which the command-line runner cannot load.
void useNativeHttpAdapters() {
  // On Android devices whose Cronet providers are all disabled (no Google
  // Play services, AOSP emulators) the adapter falls back to HTTP/1.1
  // instead of failing every request.
  HttpService.defaultNativeAdapter = (fallback) =>
      NativeAdapter(createFallbackAdapter: (_, _) => fallback());
}
