// Home-Assistant-Anbindung der Zähler (Abschnitt 6l), Abholen der Päckchen. Läuft nur im Vordergrund der App (nie im Hintergrund-Isolate, kein Push) und nur auf dem Abholgerät
// (dem Gerät mit dem Postfach-Schlüssel).
//
// Ablauf eines Laufs: die wartenden Päckchen der EIGENEN Verbindungen seitenweise holen (`GET /ingest/zaehler/pending?token=<Verbindung>`, mit dem `next`-Zeiger; die Verbindungen
// merkt sich das Gerät beim Koppeln neben dem Postfach-Schlüssel, ein Gerät aus der Zeit davor holt wie früher alle), jedes öffnen (Sealed Box, JSON, MAC, Kanal, Datum, Stand),
// die gültigen nach Kanal und Tag ordnen und je Wert entscheiden (`ingest_logik.dart`): eintragen (als normaler Zählerstand, Herkunft "automatisch"), schon vorhanden (nichts
// überschreiben) oder zu prüfen. Danach `POST /ingest/zaehler/ack` NUR für Erledigtes: eingetragen, schon vorhanden, ungültig (ein Päckchen DIESES Postfachs, das sich öffnen ließ,
// aber falsche Felder oder einen falschen MAC hat; zählt nur; ein Päckchen mit gültigem MAC, aber unlesbarem Stand (zum Beispiel mehr als 10 Stellen) wird NIE still quittiert, sondern als "zu prüfen"
// vorgelegt und nur nach ausdrücklichem Verwerfen quittiert). Päckchen, die sich mit dem Schlüssel dieses Geräts nicht öffnen lassen (anderes Postfach) oder eine unbekannte Version
// haben (neuere Integration), gehören einem anderen Gerät oder einer neueren App: sie werden NIE quittiert (sonst löschten sich zwei Abholgeräte gegenseitig die Werte) und nur
// gezählt ([IngestLauf.fremd]). Päckchen zu einem Kanal ohne Zähler und Werte zur Prüfung bleiben beim Server (höchstens 30 Tage) und erscheinen beim nächsten Lauf wieder; ein Fehler
// beim Eintragen quittiert nie. Ein Lauf ist idempotent: wird die Quittung nicht angenommen, sind die Päckchen beim nächsten Mal "schon vorhanden". Nie Werte, Kanäle oder Päckchen loggen.
import 'dart:async';

import '../api/api_error.dart';
import '../api/fampad_api.dart';
import '../crypto/crypto_provider.dart';
import '../calendar/zeitzonen.dart' show familienOrt, wandUhr;
import '../crypto/schluessel_speicher.dart';
import '../zaehler/zaehler_logik.dart';
import '../zaehler/zaehler_modelle.dart';
import '../zaehler/zaehler_repository.dart';
import 'ingest_kopplung.dart';
import 'ingest_logik.dart';
import 'ingest_modelle.dart';
import 'ingest_paket.dart';

/// Wie viele Seiten (je 200) ein Lauf höchstens holt (der Server hält höchstens 3000 Päckchen je Familie).
const int kMaxIngestSeiten = 30;

/// Der Zugriff auf die Zähler der App (in Tests ersetzbar).
abstract interface class IngestZaehlerZugriff {
  /// Die lesbaren Zähler (ID -> Inhalt).
  Future<Map<String, ZaehlerInhalt>> zaehler();

  /// Die Stände eines Zählers.
  Future<List<Stand>> staende(String zaehlerId);

  /// Trägt den Stand [milli] für den Kalendertag [tag] automatisch ein (Herkunft "automatisch").
  Future<void> eintragen(String zaehlerId, DateTime tag, int milli);
}

class RepoIngestZaehler implements IngestZaehlerZugriff {
  final ZaehlerRepository repo;
  const RepoIngestZaehler(this.repo);

  @override
  Future<Map<String, ZaehlerInhalt>> zaehler() async => {
    for (final a in await repo.alleZaehler())
      if (a.inhalt != null) a.id: a.inhalt!,
  };

  @override
  Future<List<Stand>> staende(String zaehlerId) => repo.staende(zaehlerId);

  @override
  Future<void> eintragen(String zaehlerId, DateTime tag, int milli) async {
    await repo.standErfassen(zaehlerId, datum: tag, milli: milli, automatisch: true);
  }
}

/// Ein Wert, der auf die Entscheidung der Person wartet.
class IngestPruefEintrag {
  final String paketId;
  final String zaehlerId;
  final String kanal;
  final DateTime tag;
  final int milli;
  final String einheit;
  final PruefGrund grund;
  final int? davorMilli;
  final int? tagesVerbrauchMilli;
  final int? ueblichMilli;

  /// Wann der Server das Päckchen bekam (null: unbekannt); daraus folgt der Hinweis "wird bald vom Server gelöscht".
  final DateTime? empfangen;

  /// Nur bei [PruefGrund.ungueltig]: der gekürzte Text des Stands (nur Anzeige); [milli] ist dann 0 und bedeutungslos.
  final String? standText;
  const IngestPruefEintrag({
    required this.paketId,
    required this.zaehlerId,
    required this.kanal,
    required this.tag,
    required this.milli,
    required this.einheit,
    required this.grund,
    this.davorMilli,
    this.tagesVerbrauchMilli,
    this.ueblichMilli,
    this.empfangen,
    this.standText,
  });
}

/// Warum ein Lauf nicht stattfand oder abgebrochen wurde.
enum IngestAbbruch {
  /// Der Server hat den Einwurf nicht eingeschaltet (404): kein Fehler.
  nichtVerfuegbar,

  /// Dieses Gerät hat den Postfach-Schlüssel nicht (die Verbindung wurde auf einem anderen Gerät gekoppelt).
  keinSchluessel,

  /// Der Schlüsselspeicher ließ sich nicht lesen (vorübergehend oder beschädigt).
  schluesselFehler,

  /// Kein Netz oder der Server antwortete nicht.
  netz,

  /// Nicht angemeldet, ohne Berechtigung oder die Verschlüsselung ist nicht bereit.
  nichtBereit,
}

/// Ergebnis eines Laufs (nur Zahlen, nie ein Wert).
class IngestLauf {
  final DateTime zeit;
  final IngestAbbruch? abbruch;
  final int eingetragen;
  final int vorhanden;
  final int ungueltig;

  /// Päckchen, die sich mit dem Schlüssel dieses Geräts nicht öffnen lassen oder eine unbekannte Version haben: sie bleiben beim Server (nie quittiert), vielleicht gehören sie einem anderen Gerät.
  final int fremd;
  final int ohneZaehler;

  /// Das älteste Empfangsdatum unter den Päckchen ohne Zähler (null: keine oder unbekannt): Grundlage des Hinweises "wird bald vom Server gelöscht".
  final DateTime? aeltestOhneZaehler;
  final int fehler;

  /// Alle Päckchen, die der Server noch hält (abgeholt, aber nicht quittiert eingerechnet die zu prüfenden).
  final int wartend;
  final bool quittungFehlgeschlagen;
  final List<IngestPruefEintrag> zuPruefen;
  const IngestLauf({
    required this.zeit,
    this.abbruch,
    this.eingetragen = 0,
    this.vorhanden = 0,
    this.ungueltig = 0,
    this.fremd = 0,
    this.ohneZaehler = 0,
    this.aeltestOhneZaehler,
    this.fehler = 0,
    this.wartend = 0,
    this.quittungFehlgeschlagen = false,
    this.zuPruefen = const [],
  });

  bool get ok => abbruch == null;
}

class IngestDienst {
  final FampadApi api;
  final Future<CryptoProvider> Function() krypto;
  final PostfachSpeicher postfach;
  final IngestZaehlerZugriff zaehler;
  final String? Function() ich;
  final DateTime Function() _jetzt;

  IngestDienst({required this.api, required this.krypto, required this.postfach, required this.zaehler, required this.ich, DateTime Function()? jetzt}) : _jetzt = jetzt ?? DateTime.now;

  Future<IngestLauf>? _lauf;

  /// Läuft gerade ein Lauf?
  bool get laeuft => _lauf != null;

  /// Holt und verarbeitet die wartenden Päckchen. Ein Lauf zur Zeit: ein zweiter Aufruf während eines Laufs wartet auf denselben Lauf (nie zwei parallel).
  Future<IngestLauf> abholen() => _lauf ??= _abholen().whenComplete(() => _lauf = null);

  IngestLauf _abbruch(IngestAbbruch a) => IngestLauf(zeit: _jetzt(), abbruch: a);

  Future<IngestLauf> _abholen() async {
    final uid = ich();
    if (uid == null) return _abbruch(IngestAbbruch.nichtBereit);
    final PostfachSchluessel? schluessel;
    try {
      schluessel = await postfach.lesen(uid);
    } on SchluesselSpeicherFehler {
      return _abbruch(IngestAbbruch.schluesselFehler);
    }
    if (schluessel == null) return _abbruch(IngestAbbruch.keinSchluessel);
    try {
      // die eigenen Verbindungen (null oder leer: Gerät aus der Zeit davor, es holt alle Päckchen der Familie ab; nichts davon wird mehr ungeprüft gelöscht)
      final List<String>? eigene;
      try {
        eigene = await postfach.verbindungen(uid);
      } on SchluesselSpeicherFehler {
        return _abbruch(IngestAbbruch.schluesselFehler);
      }
      final CryptoProvider c;
      try {
        c = await krypto();
      } on Object {
        return _abbruch(IngestAbbruch.nichtBereit);
      }
      // 1. alle Seiten holen
      final pakete = <IngestPaket>[];
      try {
        for (final token in (eigene == null || eigene.isEmpty) ? <String?>[null] : <String?>[...eigene]) {
          String? next;
          var seiten = 0; // die Grenze gilt je Verbindung, nie gemeinsam (eine volle Verbindung darf die anderen nicht aushungern)
          while (seiten < kMaxIngestSeiten) {
            seiten++;
            final s = await api.ingestWartende(after: next, token: token);
            pakete.addAll(s.pakete);
            next = s.next;
            if (next == null) break;
          }
        }
      } on ApiException catch (e) {
        if (e.status == 404) return _abbruch(IngestAbbruch.nichtVerfuegbar);
        if (e.kind == ApiErrorKind.nichtAngemeldet || e.status == 403) return _abbruch(IngestAbbruch.nichtBereit);
        return _abbruch(IngestAbbruch.netz);
      }
      return await _verarbeiten(c, schluessel, pakete);
    } finally {
      schluessel.verwerfen();
    }
  }

  Future<IngestLauf> _verarbeiten(CryptoProvider c, PostfachSchluessel s, List<IngestPaket> pakete) async {
    // "heute" ist der Kalendertag der Familienzone (Europe/Berlin), nie der der Gerätezeit (ein Gerät in einer anderen Zone sähe sonst um einen Tag verschoben)
    final wand = wandUhr(_jetzt(), familienOrt);
    final jetztTag = DateTime.utc(wand.year, wand.month, wand.day);
    final quittieren = <String>[];
    var ungueltig = 0;
    var fremd = 0;
    final gueltig = <({IngestPaket paket, IngestWert wert})>[];
    final unlesbar = <({IngestPaket paket, IngestUngueltigerStand stand})>[];
    for (final p in pakete) {
      final r = paketOeffnen(c, p.box, oeffentlich: s.oeffentlich, geheim: s.geheim, geheimnis: s.geheimnis);
      // ein Tag, der mehr als einen Tag in der Zukunft liegt (Uhr falsch gestellt), ist kein gültiger Stand
      if (r.ok && tagNummer(r.wert!.tag) <= tagNummer(jetztTag) + 1) {
        gueltig.add((paket: p, wert: r.wert!));
      } else if (r.fehler == PaketFehler.entschluesselung || r.fehler == PaketFehler.version) {
        fremd++; // anderes Postfach oder neuere Integration: nicht anfassen, nicht quittieren
      } else if (r.fehler == PaketFehler.stand && r.ungueltigerStand != null) {
        unlesbar.add((paket: p, stand: r.ungueltigerStand!)); // echt (MAC stimmt), aber der Wert ist unlesbar: der Person vorlegen, nie still quittieren
      } else {
        ungueltig++;
        quittieren.add(p.id);
      }
    }
    gueltig.sort((a, b) {
      final k = a.wert.kanal.compareTo(b.wert.kanal);
      if (k != 0) return k;
      final t = a.wert.tag.compareTo(b.wert.tag);
      return t != 0 ? t : a.paket.id.compareTo(b.paket.id);
    });
    final Map<String, ZaehlerInhalt> alle;
    try {
      alle = await zaehler.zaehler();
    } on Object {
      return _abbruch(IngestAbbruch.nichtBereit);
    }
    final zuordnung = kanalZuordnung(alle);
    final staende = <String, List<Stand>>{};
    var eingetragen = 0;
    var vorhanden = 0;
    var ohneZaehler = 0;
    DateTime? aeltestOhneZaehler;
    void ohne(DateTime? empfangen) {
      ohneZaehler++;
      if (empfangen != null && (aeltestOhneZaehler == null || empfangen.isBefore(aeltestOhneZaehler!))) aeltestOhneZaehler = empfangen;
    }

    var fehler = 0;
    final pruefen = <IngestPruefEintrag>[];
    for (final u in unlesbar) {
      final ziel = zuordnung[u.stand.kanal];
      if (ziel == null) {
        ohne(u.paket.empfangen);
        continue;
      }
      pruefen.add(IngestPruefEintrag(
        paketId: u.paket.id,
        zaehlerId: ziel.zaehlerId,
        kanal: u.stand.kanal,
        tag: u.stand.tag,
        milli: 0,
        einheit: u.stand.einheit,
        grund: PruefGrund.ungueltig,
        empfangen: u.paket.empfangen,
        standText: u.stand.text,
      ));
    }
    for (final g in gueltig) {
      final ziel = zuordnung[g.wert.kanal];
      if (ziel == null) {
        ohne(g.paket.empfangen);
        continue;
      }
      try {
        final bisher = staende[ziel.zaehlerId] ??= [...await zaehler.staende(ziel.zaehlerId)];
        var e = entscheide(bestehende: bisher, tag: g.wert.tag, milli: g.wert.milli, pruefen: ziel.inhalt.quelle?.pruefen ?? true);
        if (e.aktion == IngestAktion.eintragen) {
          // unmittelbar vor dem Schreiben den Stand frisch aus der Datenbank lesen: hat ein anderes Gerät den Tag inzwischen belegt (Abgleich), wird nichts doppelt eingetragen
          bisher
            ..clear()
            ..addAll(await zaehler.staende(ziel.zaehlerId));
          e = entscheide(bestehende: bisher, tag: g.wert.tag, milli: g.wert.milli, pruefen: ziel.inhalt.quelle?.pruefen ?? true);
        }
        switch (e.aktion) {
          case IngestAktion.vorhanden:
            vorhanden++;
            quittieren.add(g.paket.id);
          case IngestAktion.eintragen:
            await zaehler.eintragen(ziel.zaehlerId, g.wert.tag, g.wert.milli);
            bisher.add(Stand(g.wert.tag, g.wert.milli)); // spätere Werte desselben Laufs sehen ihn
            eingetragen++;
            quittieren.add(g.paket.id);
          case IngestAktion.pruefen:
            pruefen.add(IngestPruefEintrag(
              paketId: g.paket.id,
              zaehlerId: ziel.zaehlerId,
              kanal: g.wert.kanal,
              tag: g.wert.tag,
              milli: g.wert.milli,
              einheit: ziel.inhalt.einheit,
              grund: e.grund!,
              davorMilli: e.davorMilli,
              tagesVerbrauchMilli: e.tagesVerbrauchMilli,
              ueblichMilli: e.ueblichMilli,
              empfangen: g.paket.empfangen,
            ));
        }
      } on Object {
        fehler++; // nicht quittiert: der nächste Lauf versucht es wieder
      }
    }
    final q = await _quittieren(quittieren);
    final quittungFehler = q.fehlgeschlagen;
    return IngestLauf(
      zeit: _jetzt(),
      eingetragen: eingetragen,
      vorhanden: vorhanden,
      ungueltig: ungueltig,
      fremd: fremd,
      ohneZaehler: ohneZaehler,
      aeltestOhneZaehler: aeltestOhneZaehler,
      fehler: fehler,
      wartend: pakete.length - q.anzahl,
      quittungFehlgeschlagen: quittungFehler,
      zuPruefen: pruefen,
    );
  }

  /// Quittiert in Stücken zu 200. [anzahl]: wie viele Päckchen tatsächlich quittiert wurden (nur angenommene Stücke); [fehlgeschlagen], wenn ein Stück nicht angenommen wurde (die übrigen
  /// Päckchen kommen beim nächsten Lauf wieder und sind dann "schon vorhanden").
  Future<({int anzahl, bool fehlgeschlagen})> _quittieren(List<String> ids) async {
    var anzahl = 0;
    var fehlgeschlagen = false;
    for (var i = 0; i < ids.length; i += 200) {
      final stueck = ids.sublist(i, i + 200 > ids.length ? ids.length : i + 200);
      try {
        await api.ingestQuittieren(stueck);
        anzahl += stueck.length;
      } on ApiException {
        fehlgeschlagen = true;
        break;
      }
    }
    return (anzahl: anzahl, fehlgeschlagen: fehlgeschlagen);
  }

  // ------------------------------------------------------------------ Entscheidung der Person über einen vorgelegten Wert

  /// "Trotzdem eintragen": trägt den Wert ein (steht für den Tag schon ein Stand, bleibt er) und quittiert das Päckchen. Wirft bei einem Fehler (nichts wird quittiert).
  Future<void> pruefEintragen(IngestPruefEintrag e) async {
    if (e.grund == PruefGrund.ungueltig) throw StateError('Ein unlesbarer Stand lässt sich nie eintragen.');
    final bisher = await zaehler.staende(e.zaehlerId);
    if (!bisher.any((s) => tagNummer(s.tag) == tagNummer(e.tag))) await zaehler.eintragen(e.zaehlerId, e.tag, e.milli);
    await api.ingestQuittieren([e.paketId]);
  }

  /// "Verwerfen": quittiert das Päckchen, ohne etwas einzutragen. Wirft bei einem Fehler des Servers.
  Future<void> verwerfen(IngestPruefEintrag e) async {
    await api.ingestQuittieren([e.paketId]);
  }

  /// Nach "Neuer Zähler ab hier" (der Zählerwechsel hat den Wert als Startstand geschrieben): das Päckchen quittieren.
  Future<void> erledigt(IngestPruefEintrag e) async {
    await api.ingestQuittieren([e.paketId]);
  }
}

/// Meldung zu einem Abbruch (feste Texte).
String ingestAbbruchText(IngestAbbruch a) => switch (a) {
  IngestAbbruch.nichtVerfuegbar => 'Der Server nimmt keine Werte aus Home Assistant an.',
  IngestAbbruch.keinSchluessel => 'Dieses Gerät kann nicht abholen; die Verbindung wurde auf einem anderen Gerät gekoppelt. Du kannst den Schlüssel unter Zähler › Home Assistant auf dieses Gerät übertragen.',
  IngestAbbruch.schluesselFehler => 'Der Schlüssel dieser Verbindung ließ sich auf diesem Gerät gerade nicht lesen.',
  IngestAbbruch.netz => 'Der Server ist gerade nicht erreichbar. Die Werte warten dort und kommen beim nächsten Mal.',
  IngestAbbruch.nichtBereit => 'Das Abholen ist gerade nicht möglich. Prüfe Anmeldung und Nachrichten-Schutz.',
};
