// Web: die Zahl der ungelesenen Nachrichten im Titel des Browser-Tabs ("(3) lx-familyhub"). Nur document.title, keine Fremdpakete, keine CSP-Änderung.
import 'package:web/web.dart' as web;

String? _basis;

void tabTitelSetzen(int ungelesen) {
  final basis = _basis ??= web.document.title;
  web.document.title = ungelesen > 0 ? '(${ungelesen > 99 ? '99+' : ungelesen}) $basis' : basis;
}
