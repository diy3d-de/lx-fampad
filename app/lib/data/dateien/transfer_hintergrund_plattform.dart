// Plattformweiche des Übertragungs-Vordergrunddienstes (bedingter Import: dart:io nur auf Android/Desktop, nie im Web).
export 'transfer_hintergrund_stub.dart' if (dart.library.io) 'transfer_hintergrund_android.dart';
