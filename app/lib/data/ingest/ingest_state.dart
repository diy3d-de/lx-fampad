// Home-Assistant-Anbindung der Zähler (Abschnitt 6l), Zustand für die Oberfläche und Auslöser des Abholens.
//
// Nur für Eltern und Admins (Rolle der Sitzung, nie Familienrolle oder Betreiber-Flag); für alle anderen bleibt der Zustand leer und nichts wird gelesen oder abgerufen. Der Schalter
// "Werte automatisch abholen" gilt JE GERÄT (lokal in `sync_meta`, Schlüssel `ingest_abholen`, Standard aus, beim Koppeln an). Abgeholt wird nur mit eingeschaltetem Schalter UND vorhandenem
// Postfach-Schlüssel (nur das Abholgerät hat ihn). Auslöser: nach Anmeldung/Start, beim Öffnen der Zähler-Seite, alle 3 Stunden solange die App im VORDERGRUND ist (der Takt hängt am
// App-Lebenszyklus: im Hintergrund steht er still, beim Zurückkehren holt die App nach, wenn der letzte Lauf länger als der Takt her ist), "Jetzt abholen"; nie parallel
// (ein Lauf, siehe [IngestDienst]), nie im Hintergrund-Isolate, kein Push. Der Zustand enthält nur Zahlen und die vorgelegten Werte, die auf eine Entscheidung warten; er wird beim
// Abmelden und Personenwechsel verworfen (der Postfach-Schlüssel bleibt wie der Personenschlüssel liegen). Nie Werte loggen.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart' show AppLifecycleListener, AppLifecycleState, WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart' show kApiBase, kInviteHost;
import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../crypto/e2ee_state.dart' show cryptoProviderProvider, schluesselSpeicherProvider;
import '../crypto/schluessel_speicher.dart';
import '../database_provider.dart';
import '../zaehler/zaehler_repository.dart';
import '../zaehler/zaehler_state.dart';
import 'ingest_dienst.dart';
import 'ingest_kopplung.dart';
import 'ingest_weitergabe.dart';

/// Schlüssel in `sync_meta`: Schalter dieses Geräts (`1`/`0`) und die zuletzt bekannte Antwort des Servers zur Verfügbarkeit des Einwurfs.
const String kIngestAbholenSchluessel = 'ingest_abholen';
const String kIngestVerfuegbarSchluessel = 'ingest_verfuegbar';

/// Basisadresse des Servers für den Kopplungscode (nur https, ohne Pfad; null: keine gültige Adresse). Im Web die Adresse der Seite, in der App `API_BASE`.
final ingestServerAdresseProvider = Provider<String?>((ref) => kopplungsAdresse(kApiBase.isNotEmpty ? kApiBase : (kIsWeb ? Uri.base.origin : 'https://$kInviteHost')));

/// Abstand der automatischen Läufe (solange die App im Vordergrund ist); null = keiner (Tests).
final ingestTaktProvider = Provider<Duration?>((ref) => const Duration(hours: 3));

/// Frühestens nach so langer Zeit löst das Öffnen der Zähler-Seite einen neuen Lauf aus.
const Duration kIngestOeffnenAbstand = Duration(minutes: 1);

final ingestDienstProvider = Provider<IngestDienst>((ref) {
  return IngestDienst(
    api: ref.watch(apiProvider),
    krypto: () => ref.read(cryptoProviderProvider.future),
    postfach: PostfachSpeicher(ref.watch(schluesselSpeicherProvider)),
    zaehler: RepoIngestZaehler(ref.watch(zaehlerRepositoryProvider)),
    ich: () => ref.read(authProvider).user?.id,
  );
});

/// Weitergabe des Postfach-Schlüssels an ein weiteres eigenes Gerät (Abschnitt 6l, ingest_weitergabe.dart).
final ingestWeitergabeProvider = Provider<IngestWeitergabe>((ref) {
  return IngestWeitergabe(
    api: ref.watch(apiProvider),
    krypto: () => ref.read(cryptoProviderProvider.future),
    postfach: PostfachSpeicher(ref.watch(schluesselSpeicherProvider)),
    ich: () => ref.read(authProvider).user?.id,
  );
});

/// Kennt der Server den Einwurf (Schalter `INGEST_ENABLED`)? Nur für Eltern und Admins gefragt. Zuerst `GET /version` (`features.ingest`); meldet ein älterer Server das Feld nicht, der alte
/// Weg mit einem Probe-Aufruf (`GET /ingest/zaehler/pending?limit=1`, 404 = nein). Ohne Antwort (offline) gilt die zuletzt bekannte; ohne bekannte Antwort: nein. Neu bestimmt bei jeder Anmeldung.
final ingestVerfuegbarProvider = FutureProvider<bool>((ref) async {
  if (!ref.watch(zaehlerDarfProvider)) return false;
  final db = ref.read(appDatabaseProvider);
  try {
    final angabe = (await ref.read(apiProvider).serverFaehigkeiten()).ingest;
    if (angabe != null) {
      unawaited(db.metaSchreiben(kIngestVerfuegbarSchluessel, angabe ? '1' : '0'));
      return angabe;
    }
    await ref.read(apiProvider).ingestWartende(limit: 1);
    unawaited(db.metaSchreiben(kIngestVerfuegbarSchluessel, '1'));
    return true;
  } on ApiException catch (e) {
    if (e.status == 404 && e.code == 'not_found') {
      unawaited(db.metaSchreiben(kIngestVerfuegbarSchluessel, '0'));
      return false;
    }
    return await db.metaLesen(kIngestVerfuegbarSchluessel) == '1';
  } on Object {
    return false;
  }
});

class IngestZustand {
  /// Schalter und Postfach-Schlüssel sind gelesen.
  final bool geladen;

  /// Schalter "Werte automatisch abholen" dieses Geräts.
  final bool schalter;

  /// Dieses Gerät hat den Postfach-Schlüssel (ist das Abholgerät).
  final bool postfachDa;
  final bool laeuft;
  final IngestLauf? letzter;

  /// Werte, die auf die Entscheidung der Person warten (aus dem letzten Lauf, abzüglich der schon entschiedenen).
  final List<IngestPruefEintrag> zuPruefen;
  const IngestZustand({this.geladen = false, this.schalter = false, this.postfachDa = false, this.laeuft = false, this.letzter, this.zuPruefen = const []});

  /// Wird gerade abgeholt oder kann es (Schalter an, Schlüssel da)?
  bool get aktiv => schalter && postfachDa;

  IngestZustand kopie({bool? geladen, bool? schalter, bool? postfachDa, bool? laeuft, IngestLauf? Function()? letzter, List<IngestPruefEintrag>? zuPruefen}) => IngestZustand(
    geladen: geladen ?? this.geladen,
    schalter: schalter ?? this.schalter,
    postfachDa: postfachDa ?? this.postfachDa,
    laeuft: laeuft ?? this.laeuft,
    letzter: letzter != null ? letzter() : this.letzter,
    zuPruefen: zuPruefen ?? this.zuPruefen,
  );
}

class IngestNotifier extends Notifier<IngestZustand> {
  Timer? _takt;
  DateTime? _zuletzt;

  /// Päckchen, über die die Person entschieden hat (eingetragen, verworfen, Zählerwechsel): bis zum nächsten Lauf gemerkt und aus der Liste "Zu prüfen" gefiltert, damit ein Lauf, der
  /// VOR der Entscheidung begann, sie nicht wieder einblendet. Nur Kennungen, nie Werte.
  final _entschiedeneIds = <String>{};

  /// Ist die App im Vordergrund? Nur dann läuft der Takt.
  var _vordergrund = true;

  @override
  IngestZustand build() {
    // je angemeldeter Person neu (Abmelden, Personenwechsel, Rollenwechsel): der Zustand wird verworfen, der Schlüssel im Schlüsselspeicher bleibt
    final person = ref.watch(authProvider.select((s) => (s.user?.id, s.user?.role)));
    ref.onDispose(() => _takt?.cancel());
    _entschiedeneIds.clear();
    _lebenszyklusBeobachten();
    if (person.$1 != null && ref.watch(zaehlerDarfProvider)) unawaited(_start());
    return const IngestZustand();
  }

  /// Der Takt steht still, solange die App nicht im Vordergrund ist; beim Zurückkehren wird ein überfälliger Lauf nachgeholt. Ohne Flutter-Bindung (reine Tests) bleibt es beim Vordergrund.
  void _lebenszyklusBeobachten() {
    try {
      final aktuell = WidgetsBinding.instance.lifecycleState;
      _vordergrund = aktuell == null || aktuell == AppLifecycleState.resumed || aktuell == AppLifecycleState.inactive;
      final l = AppLifecycleListener(
        onStateChange: (z) {
          final vorn = z == AppLifecycleState.resumed || z == AppLifecycleState.inactive;
          if (vorn == _vordergrund) return;
          _vordergrund = vorn;
          _taktSetzen();
          if (vorn && _lauffaehig() && _ueberfaellig()) unawaited(abholen());
        },
      );
      ref.onDispose(l.dispose);
    } on Object {
      // keine Flutter-Bindung: kein Lebenszyklus, der Takt läuft wie sonst
    }
  }

  bool _lauffaehig() => ref.mounted && ref.read(zaehlerDarfProvider) && state.aktiv && !state.laeuft;

  bool _ueberfaellig() {
    final takt = ref.read(ingestTaktProvider);
    final z = _zuletzt;
    return takt != null && (z == null || DateTime.now().difference(z) >= takt);
  }

  Future<void> _start() async {
    try {
      await _ablageLesen();
    } on Object {
      return; // Schlüsselspeicher oder Datenbank nicht lesbar: es bleibt alles aus, ein späterer Auslöser versucht es wieder
    }
    if (!ref.mounted) return;
    _taktSetzen();
    await abholen();
  }

  /// Der Takt läuft nur, solange abgeholt werden soll (Schalter an und Schlüssel da) und die App im Vordergrund ist; sonst steht kein Timer.
  void _taktSetzen() {
    _takt?.cancel();
    _takt = null;
    final takt = ref.read(ingestTaktProvider);
    if (takt != null && state.aktiv && _vordergrund) _takt = Timer.periodic(takt, (_) => unawaited(abholen()));
  }

  Future<void> _ablageLesen() async {
    final uid = ref.read(authProvider).user?.id;
    if (uid == null) return;
    final an = await ref.read(appDatabaseProvider).metaLesen(kIngestAbholenSchluessel) == '1';
    final da = await PostfachSpeicher(ref.read(schluesselSpeicherProvider)).vorhanden(uid);
    if (!ref.mounted) return;
    state = state.kopie(geladen: true, schalter: an, postfachDa: da);
    _taktSetzen();
  }

  /// Liest Schalter und Schlüssel neu (nach dem Koppeln oder Trennen).
  Future<void> neuLesen() async {
    try {
      await _ablageLesen();
    } on Object {
      // bleibt unverändert
    }
  }

  /// Schalter "Werte automatisch abholen" dieses Geräts. Ohne Postfach-Schlüssel lässt er sich nicht einschalten (dieses Gerät könnte nichts öffnen).
  Future<void> schalterSetzen(bool an) async {
    if (an && !state.postfachDa) return;
    await ref.read(appDatabaseProvider).metaSchreiben(kIngestAbholenSchluessel, an ? '1' : '0');
    if (!ref.mounted) return;
    state = state.kopie(schalter: an);
    _taktSetzen();
    if (an) await abholen();
  }

  /// Auf dem Abholgerät: zeigt ein Angebot für ein weiteres eigenes Gerät (nur Eltern und Admins, nur mit Postfach-Schlüssel). Wirft [WeitergabeFehler].
  Future<WeitergabeAnzeige> weitergabeAnbieten() async {
    if (!ref.read(zaehlerDarfProvider)) throw const WeitergabeFehler(WeitergabeFehlerArt.nichtBereit);
    return ref.read(ingestWeitergabeProvider).anbieten();
  }

  /// Auf dem Zielgerät: übernimmt den Postfach-Schlüssel aus QR/Code, merkt die Verbindungen, schaltet das Abholen auf diesem Gerät ein und holt gleich ab (nur Eltern und Admins). Wirft [WeitergabeFehler].
  Future<WeitergabeErgebnis> weitergabeAnnehmen(String eingabe) async {
    if (!ref.read(zaehlerDarfProvider)) throw const WeitergabeFehler(WeitergabeFehlerArt.nichtBereit);
    final r = await ref.read(ingestWeitergabeProvider).annehmen(eingabe);
    await neuLesen();
    await schalterSetzen(true);
    return r;
  }

  /// Holt jetzt ab (nur mit Schalter und Schlüssel, nur Eltern/Admins). Ein Lauf zur Zeit; der Zustand zeigt das Ergebnis. Fehler stören nichts.
  Future<void> abholen() async {
    if (!ref.mounted || !ref.read(zaehlerDarfProvider) || !state.aktiv || state.laeuft) return;
    state = state.kopie(laeuft: true);
    // was bis jetzt entschieden ist, steht beim Server schon als quittiert; was WÄHREND des Laufs entschieden wird, kann in dessen Ergebnis noch vorkommen und wird herausgefiltert
    final vorLauf = {..._entschiedeneIds};
    try {
      final lauf = await ref.read(ingestDienstProvider).abholen();
      _zuletzt = DateTime.now();
      if (!ref.mounted) return;
      // ein abgebrochener Lauf behält die zuletzt bekannten Werte zur Prüfung (nichts verschwindet, nur weil das Netz fehlt)
      final neu = lauf.abbruch == null ? [for (final e in lauf.zuPruefen) if (!_entschiedeneIds.contains(e.paketId)) e] : state.zuPruefen;
      if (lauf.abbruch == null) _entschiedeneIds.removeAll(vorLauf); // bis zum nächsten Lauf gemerkt, danach kennt der Server den Stand
      state = state.kopie(laeuft: false, letzter: () => lauf, zuPruefen: neu);
    } on Object {
      if (ref.mounted) state = state.kopie(laeuft: false);
    }
  }

  /// Beim Öffnen der Zähler-Seite: nur, wenn der letzte Lauf länger als [kIngestOeffnenAbstand] her ist.
  Future<void> beimOeffnen() async {
    final z = _zuletzt;
    if (z != null && DateTime.now().difference(z) < kIngestOeffnenAbstand) return;
    await abholen();
  }

  void _entschieden(IngestPruefEintrag e) {
    _entschiedeneIds.add(e.paketId);
    if (ref.mounted) state = state.kopie(zuPruefen: [for (final x in state.zuPruefen) if (x.paketId != e.paketId) x]);
  }

  /// "Trotzdem eintragen". Wirft bei einem Fehler (der Eintrag bleibt in der Liste).
  Future<void> pruefEintragen(IngestPruefEintrag e) async {
    await ref.read(ingestDienstProvider).pruefEintragen(e);
    _entschieden(e);
  }

  /// "Verwerfen".
  Future<void> verwerfen(IngestPruefEintrag e) async {
    await ref.read(ingestDienstProvider).verwerfen(e);
    _entschieden(e);
  }

  /// Nach einem Zählerwechsel mit dem Wert als Startstand.
  Future<void> erledigt(IngestPruefEintrag e) async {
    await ref.read(ingestDienstProvider).erledigt(e);
    _entschieden(e);
  }
}

final ingestProvider = NotifierProvider<IngestNotifier, IngestZustand>(IngestNotifier.new);

/// Hält den Zustand am Leben und löst nach Anmeldung/Start den ersten Lauf aus (am Wurzel-Widget, app.dart). Reine Beobachtung ohne Neuaufbau.
final ingestSteuerungProvider = Provider<void>((ref) {
  ref.watch(ingestProvider.select((_) => 0));
});

/// Verbindungen (nur Admins; Liste vom Server). Neu geholt, wenn die Seite sie braucht.
final ingestVerbindungenProvider = FutureProvider.autoDispose<List<IngestVerbindungStand>>((ref) async {
  final tokens = await ref.watch(apiProvider).ingestTokens();
  return [for (final t in tokens) IngestVerbindungStand(t.id, t.name, t.lastUsedAt, t.aktiv)];
});

/// Eine Verbindung für die Anzeige.
class IngestVerbindungStand {
  final String id;
  final String name;
  final DateTime? zuletztGehoert;
  final bool aktiv;
  const IngestVerbindungStand(this.id, this.name, this.zuletztGehoert, this.aktiv);
}

/// Löscht den Postfach-Schlüssel einer Person (nur "Gerät abgeben" und das Trennen der letzten Verbindung).
Future<void> postfachSchluesselLoeschen(SchluesselSpeicher speicher, String userId) => PostfachSpeicher(speicher).entfernen(userId);

/// Aktive Verbindungen, die DIESES Gerät nicht gekoppelt hat (also vermutlich ein anderes Abholgerät besitzt): Grundlage des Hinweises beim Koppeln. Nur Admins können die Liste
/// laden; bei jedem Fehler und wenn sich nichts sicher sagen lässt (Gerät aus der Zeit vor der Merkliste mit eigenem Postfach) ist die Liste leer.
final ingestFremdeVerbindungenProvider = FutureProvider.autoDispose<List<IngestVerbindungStand>>((ref) async {
  final uid = ref.read(authProvider).user?.id;
  if (uid == null) return const [];
  try {
    final speicher = PostfachSpeicher(ref.read(schluesselSpeicherProvider));
    final eigene = await speicher.verbindungen(uid);
    if (eigene == null && await speicher.vorhanden(uid)) return const [];
    final alle = await ref.watch(ingestVerbindungenProvider.future);
    return [for (final v in alle) if (v.aktiv && !(eigene ?? const <String>[]).contains(v.id)) v];
  } on Object {
    return const [];
  }
});
