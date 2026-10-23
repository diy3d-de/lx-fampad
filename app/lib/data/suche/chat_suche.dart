// Chat-Suche, nur lokal und nur im Arbeitsspeicher: durchsucht die Nachrichten, die dieses Gerät entschlüsseln kann (über NachrichtenInhalt, also
// auf demselben Weg wie die Anzeige). Es gibt KEINEN Klartext-Index auf der Platte und nichts geht an den Server; der Klartext lebt nur in diesem
// Objekt und wird mit [verwerfen] (beim Schließen der Suche) gelöscht. Klartext wird nie geloggt. Nachrichten, die nicht entschlüsselt werden
// können, bleiben außen vor und werden gezählt (ehrlicher Hinweis in der Oberfläche).
import '../app_database.dart';
import '../chat/chat_zusatz_inhalt.dart' show umfrageLesen;
import '../chat/nachrichten_inhalt.dart';
import 'such_logik.dart';

/// Höchstzahl der durchsuchten Nachrichten je Chat (die jüngsten).
const kChatSucheMaxNachrichten = 2000;

/// Höchstzahl der Treffer, die die Oberfläche zeigt.
const kChatSucheMaxTreffer = 200;

/// So viele noch nicht geöffnete Nachrichten werden höchstens gleichzeitig angefordert (der Zwischenspeicher der Entschlüsselung ist begrenzt).
const kChatSucheFenster = 150;

class ChatTreffer {
  final String nachrichtId;
  final String konversationId;
  final String? autorId;
  final DateTime zeit;
  final Ausschnitt ausschnitt;
  const ChatTreffer({required this.nachrichtId, required this.konversationId, required this.autorId, required this.zeit, required this.ausschnitt});
}

class ChatSuchStand {
  /// Treffer, neueste zuerst (höchstens [kChatSucheMaxTreffer]).
  final List<ChatTreffer> treffer;
  final int trefferGesamt;

  /// Nachrichten, deren Text bekannt ist.
  final int durchsuchbar;

  /// Nachrichten, die (derzeit) nicht entschlüsselt werden können.
  final int nichtDurchsuchbar;

  /// Nachrichten, die noch geöffnet werden.
  final int offen;
  const ChatSuchStand({this.treffer = const [], this.trefferGesamt = 0, this.durchsuchbar = 0, this.nichtDurchsuchbar = 0, this.offen = 0});

  bool get laeuft => offen > 0;
}

/// Durchsuchbarer Klartext im Arbeitsspeicher. [inhalt] liefert den Inhalt einer Nachricht wie die Anzeige.
class ChatSucher {
  final DekodierterInhalt Function(Nachricht) inhalt;
  final Map<String, ({String wire, String text})> _text = {};
  final Map<String, String> _nicht = {};
  List<Nachricht> _liste = const [];
  int _offen = 0;

  ChatSucher({required this.inhalt});

  /// Nimmt die aktuelle Nachrichtenliste (beliebig sortiert; nur die jüngsten [kChatSucheMaxNachrichten] je Konversation zählen) und fordert fehlende
  /// Inhalte an. Aufruf nach jeder Änderung der Liste und der Entschlüsselung. Liefert, ob noch Nachrichten geöffnet werden.
  bool aktualisieren(List<Nachricht> alle) {
    final je = <String, List<Nachricht>>{};
    for (final n in alle) {
      (je[n.konversationId] ??= []).add(n);
    }
    final auswahl = <Nachricht>[];
    for (final l in je.values) {
      l.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      auswahl.addAll(l.length > kChatSucheMaxNachrichten ? l.sublist(0, kChatSucheMaxNachrichten) : l);
    }
    auswahl.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    _liste = auswahl;
    final ids = {for (final n in auswahl) n.id};
    _text.removeWhere((id, _) => !ids.contains(id));
    _nicht.removeWhere((id, _) => !ids.contains(id));
    var offen = 0;
    var angefordert = 0;
    for (final n in auswahl) {
      final bekannt = _text[n.id];
      if (bekannt != null && bekannt.wire == n.inhalt) continue;
      if (_nicht[n.id] == n.inhalt) continue;
      if (angefordert >= kChatSucheFenster) {
        offen++;
        continue;
      }
      final d = inhalt(n);
      switch (d.status) {
        case InhaltStatus.bereit:
          _text.remove(n.id);
          _nicht.remove(n.id);
          final t = _suchtext(d.text);
          _text[n.id] = (wire: n.inhalt, text: t);
        case InhaltStatus.nichtEntschluesselbar:
          _text.remove(n.id);
          _nicht[n.id] = n.inhalt;
        case InhaltStatus.wirdEntschluesselt:
          angefordert++;
          offen++;
      }
    }
    _offen = offen;
    return offen > 0;
  }

  /// Text für die Suche: Umfragen als Frage und Antworten, sonst der Nachrichtentext.
  static String _suchtext(String klartext) {
    final u = umfrageLesen(klartext);
    if (u == null) return klartext;
    return '${u.frage}\n${u.optionen.join('\n')}';
  }

  /// Treffer für [eingabe] (neueste zuerst); leere Eingabe: keine Treffer, aber der Stand der Durchsuchbarkeit.
  ChatSuchStand suche(String eingabe) {
    final woerter = suchWoerter(eingabe);
    final gueltig = woerter.isNotEmpty && normalisiere(eingabe).trim().length >= 2;
    var gesamt = 0;
    final treffer = <ChatTreffer>[];
    if (gueltig) {
      for (final n in _liste) {
        final t = _text[n.id];
        if (t == null) continue;
        final b = finde(t.text, woerter);
        if (b == null) continue;
        gesamt++;
        if (treffer.length < kChatSucheMaxTreffer) {
          treffer.add(ChatTreffer(nachrichtId: n.id, konversationId: n.konversationId, autorId: n.autorId, zeit: n.createdAt, ausschnitt: ausschnitt(t.text, b)));
        }
      }
    }
    return ChatSuchStand(treffer: treffer, trefferGesamt: gesamt, durchsuchbar: _text.values.where((v) => v.text.isNotEmpty).length, nichtDurchsuchbar: _nicht.length, offen: _offen);
  }

  /// Löscht allen Klartext (beim Schließen der Suche).
  void verwerfen() {
    _text.clear();
    _nicht.clear();
    _liste = const [];
    _offen = 0;
  }
}
