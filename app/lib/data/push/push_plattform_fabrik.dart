// Bedingter Import: mit dart:io (Android, Tests) die UnifiedPush-Umsetzung, sonst (Web) die leere. So gelangt das Paket nie in den Web-Build.
export 'push_plattform_stub.dart' if (dart.library.io) 'push_plattform_up.dart';
