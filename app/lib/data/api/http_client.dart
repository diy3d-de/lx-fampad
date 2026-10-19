// Erzeugt den HTTP-Client der App: Android mit getrenntem Verbindungsaufbau (http_client_io.dart), Web mit dem Browser-Client.
export 'http_client_stub.dart' if (dart.library.io) 'http_client_io.dart';
