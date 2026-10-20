// Web: die Zahl der ungelesenen Nachrichten im Titel des Browser-Tabs ("(3) lx-familyhub"). Nur document.title, keine Fremdpakete, keine CSP-Änderung.
// Der Basistitel ist konstant (kAppName) und der Titel wird jedes Mal ganz gesetzt: so kann sich keine Zahl im Titel anhäufen oder hängen bleiben.
import 'package:web/web.dart' as web;

import '../constants.dart';

void tabTitelSetzen(int ungelesen) {
  web.document.title = ungelesen > 0 ? '(${ungelesen > 99 ? '99+' : ungelesen}) $kAppName' : kAppName;
}
