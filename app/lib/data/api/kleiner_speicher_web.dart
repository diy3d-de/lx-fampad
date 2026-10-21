import 'package:web/web.dart' as web;

String? kleinerSpeicherLesen(String key) {
  try {
    return web.window.localStorage.getItem(key);
  } catch (_) {
    return null;
  }
}

void kleinerSpeicherSchreiben(String key, String value) {
  try {
    web.window.localStorage.setItem(key, value);
  } catch (_) {
    // Speicher gesperrt oder voll: der Vermerk gilt dann nur bis zum Neuladen
  }
}
