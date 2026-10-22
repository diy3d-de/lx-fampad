// Abfuhrtermine ("Müll"): der Server lädt die Datei des Abfallkalenders, die App fragt nur den eigenen Server (`GET /waste`) und hält den
// letzten Stand lokal vor (Offline-Stand, `sync_meta`). Die UI wartet nie auf den Server. Einstellungen (Erinnerung, Uhrzeit, Arten, Anzeige
// im Kalender) gelten je Gerät und liegen nur lokal in `sync_meta`, nie auf dem Server.
//  - Abruf beim Start, bei der Rückkehr in die App (Wurzel-Widget) und alle paar Stunden, solange die Oberfläche offen ist.
//  - Neues Jahr: taucht in der Antwort ein Jahr auf, das dieses Gerät noch nicht gesehen hat, bekommen Eltern/Admins (Rolle, nie die
//    Familienrolle) einmal eine lokale Benachrichtigung "Abfuhrtermine 20XX sind da". Der erste Abruf eines Geräts setzt nur die Grundlinie.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../api/models.dart' show Role;
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../erinnerungen/erinnerung_planung.dart' show GeplanteErinnerung;
import '../push/chat_benachrichtiger_provider.dart';
import 'muell_logik.dart';
import 'muell_modelle.dart';

const kMuellCacheSchluessel = 'muell_cache';
const kMuellErinnerungAnSchluessel = 'muell_erinnerung_an';
const kMuellErinnerungZeitSchluessel = 'muell_erinnerung_zeit';
const kMuellErinnerungArtenSchluessel = 'muell_erinnerung_arten';
const kMuellKalenderSchluessel = 'muell_kalender';
const kMuellJahreGesehenSchluessel = 'muell_jahre_gesehen';

/// Feste Kennung der Benachrichtigung "Abfuhrtermine 20XX sind da".
const int kMuellJahrBenachrichtigungsId = 0x700003;

/// So oft fragt die App den Server, solange die Oberfläche offen ist (der Server ruft die Datei höchstens selten ab).
const kMuellAbfrageIntervall = Duration(hours: 3);

/// Abstand der erneuten Abfrage; null = keine (nur Tests, damit kein Timer stehen bleibt).
final muellTaktProvider = Provider<Duration?>((ref) => kMuellAbfrageIntervall);

/// Abstand der Abfragen, während die Seite nach einer angeforderten Prüfung auf das Ergebnis wartet (nur solange die Seite offen ist).
final muellPruefAbfrageProvider = Provider<Duration>((ref) => const Duration(seconds: 5));

/// Uhr (für Tests überschreibbar).
final muellUhrProvider = Provider<DateTime Function()>((ref) => DateTime.now);

class MuellEinstellungen {
  /// Erinnerung am Abend vor der Abholung (nur Eltern/Admins; Standard an).
  final bool erinnerungAn;

  /// Uhrzeit der Erinnerung in Minuten ab Mitternacht (Standard 18:00).
  final int minuten;

  /// Arten, für die erinnert wird (Standard: alle außer Sonderabfall).
  final Set<MuellArt> arten;

  /// Abfuhrtermine im Kalender anzeigen (nur Anzeige; Standard aus; gilt für alle Mitglieder).
  final bool imKalender;
  const MuellEinstellungen({this.erinnerungAn = true, this.minuten = kMuellStandardZeit, this.arten = kMuellStandardErinnerung, this.imKalender = false});

  MuellEinstellungen kopie({bool? erinnerungAn, int? minuten, Set<MuellArt>? arten, bool? imKalender}) =>
      MuellEinstellungen(erinnerungAn: erinnerungAn ?? this.erinnerungAn, minuten: minuten ?? this.minuten, arten: arten ?? this.arten, imKalender: imKalender ?? this.imKalender);

  @override
  bool operator ==(Object other) =>
      other is MuellEinstellungen && other.erinnerungAn == erinnerungAn && other.minuten == minuten && other.imKalender == imKalender && other.arten.length == arten.length && other.arten.containsAll(arten);

  @override
  int get hashCode => Object.hash(erinnerungAn, minuten, imKalender, arten.length);
}

class MuellZustand {
  final MuellDto? dto;
  final DateTime? abgerufen;
  final bool laedt;

  /// Die letzte Abfrage ist gescheitert (offline oder Serverfehler); der Stand stammt dann aus der Ablage.
  final bool fehler;

  /// Ablage und Einstellungen sind gelesen (der Erinnerungsdienst plant vorher nichts, sonst würde ein leeres Fenster Alarme löschen).
  final bool ablageGelesen;
  final MuellEinstellungen einst;

  /// Zähler: steigt mit jedem neuen Stand der Daten (Auslöser für den Erinnerungsdienst).
  final int stand;
  const MuellZustand({this.dto, this.abgerufen, this.laedt = false, this.fehler = false, this.ablageGelesen = false, this.einst = const MuellEinstellungen(), this.stand = 0});

  /// Der Server hat die Abfuhrtermine eingeschaltet.
  bool get verfuegbar => dto?.verfuegbar ?? false;

  /// Es gibt Termine zu zeigen.
  bool get hatTermine => verfuegbar && dto!.tage.isNotEmpty;

  List<MuellTag> get tage => dto?.tage ?? const [];

  MuellZustand mit({MuellDto? dto, DateTime? abgerufen, bool? laedt, bool? fehler, bool? ablageGelesen, MuellEinstellungen? einst, int? stand}) => MuellZustand(
    dto: dto ?? this.dto,
    abgerufen: abgerufen ?? this.abgerufen,
    laedt: laedt ?? this.laedt,
    fehler: fehler ?? this.fehler,
    ablageGelesen: ablageGelesen ?? this.ablageGelesen,
    einst: einst ?? this.einst,
    stand: stand ?? this.stand,
  );
}

/// Ergebnis von "Jetzt nach neuer Datei suchen".
enum MuellAnfrage { angefordert, zuOft, fehlgeschlagen }

class MuellNotifier extends Notifier<MuellZustand> {
  Timer? _timer;
  bool _laeuft = false;

  @override
  MuellZustand build() {
    // je angemeldeter Person neu (Abmelden, Personenwechsel)
    // (auch bei einem Rollenwechsel: die Erinnerung hängt an der Rolle)
    final person = ref.watch(authProvider.select((s) => (s.user?.id, s.user?.role)));
    ref.onDispose(() => _timer?.cancel());
    if (person.$1 != null) unawaited(_start());
    return const MuellZustand();
  }

  Future<void> _start() async {
    await _ablageLesen();
    if (!ref.mounted) return;
    await aktualisieren();
  }

  static int? _zeitLesen(String? t) {
    final m = t == null ? null : RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t);
    if (m == null) return null;
    final h = int.parse(m[1]!);
    final min = int.parse(m[2]!);
    return h > 23 || min > 59 ? null : h * 60 + min;
  }

  Future<void> _ablageLesen() async {
    var einst = const MuellEinstellungen();
    MuellDto? dto;
    DateTime? abgerufen;
    try {
      final db = ref.read(appDatabaseProvider);
      final an = await db.metaLesen(kMuellErinnerungAnSchluessel);
      final zeit = _zeitLesen(await db.metaLesen(kMuellErinnerungZeitSchluessel));
      final artenText = await db.metaLesen(kMuellErinnerungArtenSchluessel);
      final kal = await db.metaLesen(kMuellKalenderSchluessel);
      Set<MuellArt> arten = kMuellStandardErinnerung;
      if (artenText != null) arten = {for (final c in artenText.split(',')) if (c.isNotEmpty) MuellArt.aus(c)};
      einst = MuellEinstellungen(erinnerungAn: an != 'nein', minuten: zeit ?? kMuellStandardZeit, arten: arten, imKalender: kal == 'ja');
      final cache = await db.metaLesen(kMuellCacheSchluessel);
      if (cache != null) {
        try {
          final m = jsonDecode(cache) as Map<String, dynamic>;
          dto = MuellDto.fromJson(m['daten']);
          abgerufen = DateTime.tryParse(m['abgerufen'] as String? ?? '');
        } on Object {
          dto = null; // beschädigte Ablage: ignorieren
        }
      }
    } on Object {
      // Datenbank nicht lesbar: Standard
    }
    if (!ref.mounted) return;
    // Was die Person schon gesetzt hat, bevor das Lesen fertig war, bleibt (die Einstellungen werden nur beim Start gelesen)
    state = state.mit(dto: state.dto ?? dto, abgerufen: state.abgerufen ?? abgerufen, einst: _einstGesetzt ? state.einst : einst, ablageGelesen: true, stand: state.stand + 1);
  }

  bool _einstGesetzt = false;

  /// Holt den Stand vom Server; bei Fehlern bleibt der Stand aus der Ablage stehen (`fehler`). 404 = die Abfuhrtermine sind auf dem Server aus.
  Future<void> aktualisieren() async {
    if (_laeuft || !ref.mounted) return;
    _laeuft = true;
    state = state.mit(laedt: true);
    try {
      final roh = await ref.read(apiProvider).muellRoh();
      final dto = MuellDto.fromJson(roh);
      final jetzt = ref.read(muellUhrProvider)();
      if (!ref.mounted) return;
      state = state.mit(dto: dto, abgerufen: jetzt, laedt: false, fehler: false, stand: state.stand + 1);
      try {
        await ref.read(appDatabaseProvider).metaSchreiben(kMuellCacheSchluessel, jsonEncode({'abgerufen': jetzt.toIso8601String(), 'daten': roh}));
      } on Object {
        // nicht speicherbar: gilt bis zum Schließen
      }
      await _neuesJahrPruefen(dto);
    } on ApiException catch (e) {
      if (!ref.mounted) return;
      if (e.status == 404) {
        // auf dem Server ausgeschaltet: Kachel, Seitenleiste und Erinnerungen entfallen; die Ablage wird geleert
        state = state.mit(dto: MuellDto.nichtVerfuegbar, laedt: false, fehler: false, stand: state.stand + 1);
        try {
          await ref.read(appDatabaseProvider).metaLoeschen(kMuellCacheSchluessel);
        } on Object {
          // egal
        }
      } else {
        state = state.mit(laedt: false, fehler: true);
      }
    } on Object {
      if (ref.mounted) state = state.mit(laedt: false, fehler: true);
    } finally {
      _laeuft = false;
      final takt = ref.mounted ? ref.read(muellTaktProvider) : null;
      if (takt != null) {
        _timer?.cancel();
        _timer = Timer(takt, () => unawaited(aktualisieren()));
      }
    }
  }

  /// Eltern und Admins (Rolle, nie die Familienrolle).
  bool get _darfErinnern {
    final r = ref.read(authProvider).user?.role;
    return r == Role.admin || r == Role.parent;
  }

  /// Ein Jahr, das dieses Gerät noch nicht kannte: einmal ein Hinweis für Eltern/Admins. Der erste Abruf setzt nur die Grundlinie.
  Future<void> _neuesJahrPruefen(MuellDto dto) async {
    try {
      final db = ref.read(appDatabaseProvider);
      final gesehenText = await db.metaLesen(kMuellJahreGesehenSchluessel);
      final jetzt = dto.geladeneJahre;
      if (jetzt.isEmpty) return;
      final gesehen = {for (final j in (gesehenText ?? '').split(',')) if (int.tryParse(j) != null) int.parse(j)};
      final neu = jetzt.difference(gesehen);
      if (neu.isEmpty) return;
      Future<void> merken() => db.metaSchreiben(kMuellJahreGesehenSchluessel, ([...gesehen, ...neu]..sort()).join(','));
      // Grundlinie (erster Abruf), Kinder und der Browser (keine Benachrichtigungen): gleich als gesehen merken
      if (gesehenText == null || !_darfErinnern || kIsWeb) {
        await merken();
        return;
      }
      final jahr = (neu.toList()..sort()).last;
      final anzeige = ref.read(chatAnzeigePortProvider);
      // Erst nach erfolgreicher Anzeige als gesehen markieren: ohne Erlaubnis oder bei einem Fehler kommt der Hinweis beim nächsten Abruf noch einmal
      if (!await anzeige.initialisieren()) return;
      if (await anzeige.zeigenSicherheit(id: kMuellJahrBenachrichtigungsId, titel: 'Abfuhrtermine $jahr sind da', text: 'Öffne Müll, um sie anzusehen.', nutzlast: kMuellPayload)) await merken();
    } on Object {
      // ein Zusatz: nie den Abruf stören
    }
  }

  /// Fordert die Prüfung auf eine neue Datei an (Eltern/Admins). Meldungen nur aus der Antwort: zu oft = freundlicher Hinweis.
  Future<MuellAnfrage> pruefenAnfordern() async {
    try {
      await ref.read(apiProvider).muellPruefenAnfordern();
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.zuVieleAnfragen) return MuellAnfrage.zuOft;
      return MuellAnfrage.fehlgeschlagen;
    } on Object {
      return MuellAnfrage.fehlgeschlagen;
    }
    return MuellAnfrage.angefordert;
  }

  Future<void> _schreiben(String k, String v) async {
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(k, v);
    } on Object {
      // gilt dann nur bis zum Schließen
    }
  }

  void _einst(MuellEinstellungen e) {
    _einstGesetzt = true;
    state = state.mit(einst: e, stand: state.stand + 1);
  }

  Future<void> erinnerungAnSetzen(bool an) async {
    _einst(state.einst.kopie(erinnerungAn: an));
    await _schreiben(kMuellErinnerungAnSchluessel, an ? 'ja' : 'nein');
  }

  Future<void> zeitSetzen(int minuten) async {
    _einst(state.einst.kopie(minuten: minuten));
    await _schreiben(kMuellErinnerungZeitSchluessel, uhrzeitAusMinuten(minuten));
  }

  Future<void> artSetzen(MuellArt art, bool an) async {
    final arten = {...state.einst.arten};
    an ? arten.add(art) : arten.remove(art);
    _einst(state.einst.kopie(arten: arten));
    await _schreiben(kMuellErinnerungArtenSchluessel, ([for (final a in MuellArt.values) if (arten.contains(a)) a.code]).join(','));
  }

  Future<void> kalenderSetzen(bool an) async {
    _einst(state.einst.kopie(imKalender: an));
    await _schreiben(kMuellKalenderSchluessel, an ? 'ja' : 'nein');
  }
}

final muellProvider = NotifierProvider<MuellNotifier, MuellZustand>(MuellNotifier.new);

/// Aktuelle Zeit, einmal je Minute erneuert (nur solange etwas zuhört): "heute" und "morgen" wechseln um Mitternacht mit. Folgt [muellUhrProvider].
final muellJetztProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  final uhr = ref.watch(muellUhrProvider);
  yield uhr();
  yield* Stream<DateTime>.periodic(const Duration(minutes: 1), (_) => uhr());
});

/// Die aktuelle Zeit für die Oberfläche (vor dem ersten Takt die Uhr direkt).
DateTime muellJetzt(WidgetRef ref) => ref.watch(muellJetztProvider).value ?? ref.watch(muellUhrProvider)();

/// Erinnerungen am Abend vor der Abholung für den Erinnerungsdienst: nur Eltern/Admins (Rolle, nie die Familienrolle), nur mit eingeschaltetem
/// Schalter und eingeschaltetem Server; sonst leer. Der Erinnerungsdienst gleicht damit seine Planung ab (gemeinsames Fenster mit Terminen
/// und Aufgaben).
List<GeplanteErinnerung> muellErinnerungen(MuellZustand z, Role? rolle, DateTime jetzt) {
  if (rolle != Role.admin && rolle != Role.parent) return const [];
  if (!z.hatTermine || !z.einst.erinnerungAn) return const [];
  return planeMuellErinnerungen(tage: z.tage, aktiv: z.einst.arten, minuten: z.einst.minuten, jetzt: jetzt);
}

/// Anzeige im Kalender: Tage mit Abholung und ihre Arten, nur wenn der Schalter an ist (Standard aus) und der Server Termine liefert.
/// Reine Anzeige wie Feiertage und Ferien (nie als Termin gespeichert oder synchronisiert).
final muellKalenderTageProvider = Provider<Map<DateTime, List<MuellArt>>>((ref) {
  final z = ref.watch(muellProvider);
  if (!z.einst.imKalender || !z.hatTermine) return const {};
  return {for (final t in z.tage) t.tag: t.arten};
});
