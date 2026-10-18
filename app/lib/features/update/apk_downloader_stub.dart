import 'package:http/http.dart' as http;

import 'apk_downloader.dart';

/// Web: APK-Updates gibt es nicht.
Future<String> apkHerunterladen({
  required http.Client client,
  required Uri url,
  required String erwartetSha256,
  required int groesse,
  required FortschrittCallback onFortschritt,
}) =>
    throw UnsupportedError('APK-Updates gibt es nur unter Android');

/// Web: APK-Updates gibt es nicht.
Future<bool> apkPruefsummeStimmt(String pfad, String erwartetSha256) =>
    throw UnsupportedError('APK-Updates gibt es nur unter Android');
