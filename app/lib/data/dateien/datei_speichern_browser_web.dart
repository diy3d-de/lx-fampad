// Web: Download über einen eigenen Anker mit der Adresse des Servers. Der Browser sendet das Cookie der Sitzung selbst, der Server antwortet mit `Content-Disposition: attachment`: die Datei geht in
// den Download-Ordner, nie über den Arbeitsspeicher der Seite. Ein Token steht nie in der Adresse. true heißt nur "Download angestoßen".
import 'package:web/web.dart' as web;

bool browserLaden(String adresse, String name) {
  try {
    final anker = web.HTMLAnchorElement()
      ..href = adresse
      ..download = name
      ..style.display = 'none';
    web.document.body?.append(anker);
    anker.click();
    anker.remove();
    return true;
  } on Object {
    return false;
  }
}
