// Push-Zustand dieses Geräts (Android): Schalter, Verteiler (ntfy-App), Endpunkt beim Server, Test-Wecker.
//
// Ablauf: Einschalten -> Verteiler wählen (gespeichert oder Standard; mehrere: die Person wählt) -> registrieren -> der Verteiler liefert
// den Endpunkt -> PUT /me/push (der Server prüft Host und Pfad) -> bereit. Bei jedem Start wird erneut registriert (Vorgabe von
// UnifiedPush); ein neuer Endpunkt ersetzt den alten. Ein Wecker löst einen Abgleich aus und danach [EreignisBenachrichtiger].
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/api_error.dart';
import '../auth/auth_state.dart';
import '../database_provider.dart';
import '../sync_state.dart';
import 'push_plattform.dart';
import 'push_plattform_fabrik.dart';
import 'push_wecker.dart';

/// Schlüssel in sync_meta (verschwindet mit der lokalen Datenbank beim Abmelden).
const kPushAn = 'pushAn';

enum PushTest { laeuft, angekommen, nichtAngekommen, serverFehler }

class PushZustand {
  final bool unterstuetzt;
  final bool geladen;

  /// Schalter: die Person will Benachrichtigungen auf diesem Gerät.
  final bool gewuenscht;

  /// Gewählter Verteiler (Paketname) oder null.
  final String? verteiler;

  /// Es ist kein Verteiler (ntfy-App) installiert.
  final bool verteilerFehlt;

  /// Mehrere Verteiler installiert: die Person wählt (Paketnamen).
  final List<String> auswahl;

  /// Der Server hat Push eingerichtet.
  final bool serverBereit;

  /// Der Server kennt den Endpunkt dieses Geräts und er ist aktiv.
  final bool angemeldet;
  final DateTime? letzterWecker;
  final bool beschaeftigt;
  final String? fehler;
  final PushTest? test;

  const PushZustand({
    this.unterstuetzt = false,
    this.geladen = false,
    this.gewuenscht = false,
    this.verteiler,
    this.verteilerFehlt = false,
    this.auswahl = const [],
    this.serverBereit = true,
    this.angemeldet = false,
    this.letzterWecker,
    this.beschaeftigt = false,
    this.fehler,
    this.test,
  });

  PushZustand copyWith({
    bool? unterstuetzt,
    bool? geladen,
    bool? gewuenscht,
    String? verteiler,
    bool verteilerLoeschen = false,
    bool? verteilerFehlt,
    List<String>? auswahl,
    bool? serverBereit,
    bool? angemeldet,
    DateTime? letzterWecker,
    bool? beschaeftigt,
    String? fehler,
    bool fehlerLoeschen = false,
    PushTest? test,
    bool testLoeschen = false,
  }) => PushZustand(
    unterstuetzt: unterstuetzt ?? this.unterstuetzt,
    geladen: geladen ?? this.geladen,
    gewuenscht: gewuenscht ?? this.gewuenscht,
    verteiler: verteilerLoeschen ? null : (verteiler ?? this.verteiler),
    verteilerFehlt: verteilerFehlt ?? this.verteilerFehlt,
    auswahl: auswahl ?? this.auswahl,
    serverBereit: serverBereit ?? this.serverBereit,
    angemeldet: angemeldet ?? this.angemeldet,
    letzterWecker: letzterWecker ?? this.letzterWecker,
    beschaeftigt: beschaeftigt ?? this.beschaeftigt,
    fehler: fehlerLoeschen ? null : (fehler ?? this.fehler),
    test: testLoeschen ? null : (test ?? this.test),
  );
}

final pushPlattformProvider = Provider<PushPlattform>((ref) => neuePushPlattform());

/// Mindestabstand zwischen zwei Abgleichen nach Weckern bei laufender App (Tests: kürzer).
final pushWeckerAbstandProvider = Provider<Duration>((ref) => const Duration(seconds: 10));

/// Wie lange der Test auf das Eintreffen des Weckers wartet (Tests: kürzer).
final pushTestWartezeitProvider = Provider<Duration>((ref) => const Duration(seconds: 20));

String _grundText(String grund) => switch (grund) {
  'network' => 'Die Anmeldung beim Verteiler brauchte Netz und ist gescheitert. Versuche es später erneut.',
  'actionRequired' => 'Die ntfy-App braucht eine Eingabe von dir: Öffne sie und prüfe Server und Benutzer.',
  _ => 'Die ntfy-App hat die Anmeldung abgelehnt. Prüfe dort Server und Benutzer.',
};

class PushController extends Notifier<PushZustand> {
  PushPlattform get _p => ref.read(pushPlattformProvider);
  bool _initialisiert = false;
  Completer<void>? _testWecker;

  /// Nach einem abgelehnten Endpunkt (fremdes Topic, ungültig) wird genau einmal neu registriert (der Verteiler vergibt ein neues Topic).
  bool _neuVersucht = false;

  /// Meldet der Verteiler kurz nach unserer eigenen Abmeldung "abgemeldet", ist das keine Abmeldung durch ihn.
  DateTime _eigeneAbmeldung = DateTime.fromMillisecondsSinceEpoch(0);

  WeckerLauf? _weckerLauf;

  @override
  PushZustand build() {
    ref.onDispose(() => _weckerLauf?.beenden());
    return PushZustand(unterstuetzt: ref.read(pushPlattformProvider).unterstuetzt);
  }

  Future<void> _verteilerAbmelden() {
    _eigeneAbmeldung = DateTime.now();
    return _p.abmelden();
  }

  Future<void> _initialisieren() async {
    if (_initialisiert) return;
    _initialisiert = true;
    try {
      await _p.initialisieren(
        PushRueckrufe(
          beiEndpunkt: (url) => unawaited(_endpunktMelden(url)),
          beiFehler: (grund) {
            if (ref.mounted) state = state.copyWith(fehler: _grundText(grund), beschaeftigt: false);
          },
          beiAbgemeldet: () => unawaited(_verteilerHatAbgemeldet()),
          beiWecker: () => unawaited(_wecker()),
        ),
      );
    } catch (_) {
      _initialisiert = false;
      rethrow;
    }
  }

  /// Nach der Anmeldung (HomeShell): Zustand laden, bei gewünschtem Push registrieren (bei jedem Start).
  Future<void> starten() async {
    if (!state.unterstuetzt) return;
    try {
      final an = await ref.read(appDatabaseProvider).metaLesen(kPushAn) == '1';
      if (!ref.mounted) return;
      state = state.copyWith(gewuenscht: an, geladen: true);
      await _initialisieren();
      final v = await _p.aktuellerVerteiler();
      if (ref.mounted) state = state.copyWith(verteiler: v, verteilerLoeschen: v == null);
      await laden();
      if (an && v != null && ref.mounted) await _p.registrieren();
    } catch (_) {
      if (ref.mounted) state = state.copyWith(geladen: true);
    }
  }

  /// Liest den Stand beim Server (Endpunkt angemeldet? Push eingerichtet?).
  Future<void> laden() async {
    if (!state.unterstuetzt) return;
    try {
      final s = await ref.read(apiProvider).pushStatus();
      if (ref.mounted) state = state.copyWith(serverBereit: s.available, angemeldet: s.registered && s.active);
    } catch (_) {
      // offline: der letzte bekannte Stand bleibt
    }
  }

  /// Die Seite hat die Verteiler-Auswahl übernommen (zeigt den Dialog), sie soll nicht erneut erscheinen.
  void auswahlAbgeholt() => state = state.copyWith(auswahl: const []);

  Future<void> einschalten() async {
    if (!state.unterstuetzt || state.beschaeftigt) return;
    state = state.copyWith(beschaeftigt: true, fehlerLoeschen: true, verteilerFehlt: false, auswahl: const [], testLoeschen: true);
    _neuVersucht = false;
    try {
      await _initialisieren();
      var v = await _p.aktuellerVerteiler();
      if (v == null) {
        if (!await _p.standardVerteilerNutzen()) {
          final liste = await _p.verteiler();
          if (liste.isEmpty) {
            state = state.copyWith(beschaeftigt: false, verteilerFehlt: true);
            return;
          }
          if (liste.length > 1) {
            state = state.copyWith(beschaeftigt: false, auswahl: liste);
            return;
          }
          await _p.verteilerSpeichern(liste.first);
        }
        v = await _p.aktuellerVerteiler();
      }
      await ref.read(appDatabaseProvider).metaSchreiben(kPushAn, '1');
      state = state.copyWith(gewuenscht: true, verteiler: v);
      await _p.registrieren();
      // der Endpunkt kommt über den Rückruf; bis dahin zeigt die Seite "wird angemeldet"
      state = state.copyWith(beschaeftigt: false);
    } catch (_) {
      if (ref.mounted) {
        state = state.copyWith(
          beschaeftigt: false,
          fehler: 'Benachrichtigungen konnten nicht eingeschaltet werden. Prüfe, ob die ntfy-App installiert ist.',
        );
      }
    }
  }

  /// Die Person hat bei mehreren Verteilern einen gewählt.
  Future<void> verteilerWaehlen(String name) async {
    state = state.copyWith(auswahl: const []);
    try {
      await _p.verteilerSpeichern(name);
    } catch (_) {
      state = state.copyWith(fehler: 'Der Verteiler konnte nicht gespeichert werden.');
      return;
    }
    await einschalten();
  }

  Future<void> ausschalten() async {
    if (!state.unterstuetzt || state.beschaeftigt) return;
    state = state.copyWith(beschaeftigt: true, fehlerLoeschen: true, auswahl: const [], verteilerFehlt: false, testLoeschen: true);
    String? fehler;
    try {
      await ref.read(apiProvider).pushLoeschen();
    } on ApiException catch (e) {
      if (e.istNetzwerk) fehler = 'Der Server war nicht erreichbar: der Endpunkt dort bleibt bis zur nächsten Verbindung bestehen.';
    } catch (_) {}
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(kPushAn, '0');
      await _verteilerAbmelden();
    } catch (_) {}
    if (ref.mounted) state = state.copyWith(beschaeftigt: false, gewuenscht: false, angemeldet: false, fehler: fehler);
  }

  /// Der Server schickt einen Wecker an dieses Gerät; die Seite zeigt, ob er ankommt.
  Future<void> testen() async {
    if (state.beschaeftigt || state.test == PushTest.laeuft) return;
    state = state.copyWith(test: PushTest.laeuft, fehlerLoeschen: true);
    final da = Completer<void>();
    _testWecker = da;
    try {
      await ref.read(apiProvider).pushTest();
    } on ApiException catch (e) {
      _testWecker = null;
      if (ref.mounted) state = state.copyWith(test: PushTest.serverFehler, fehler: e.message);
      return;
    } catch (_) {
      _testWecker = null;
      if (ref.mounted) state = state.copyWith(test: PushTest.serverFehler, fehler: 'Der Test-Wecker konnte nicht gesendet werden.');
      return;
    }
    await da.future.timeout(ref.read(pushTestWartezeitProvider), onTimeout: () {});
    final angekommen = da.isCompleted;
    if (identical(_testWecker, da)) _testWecker = null;
    if (ref.mounted) state = state.copyWith(test: angekommen ? PushTest.angekommen : PushTest.nichtAngekommen);
  }

  Future<void> _endpunktMelden(String url) async {
    if (!ref.mounted || !state.gewuenscht) return;
    try {
      await ref.read(apiProvider).pushAnmelden(url);
      _neuVersucht = false;
      if (ref.mounted) state = state.copyWith(angemeldet: true, fehlerLoeschen: true);
      await laden();
    } on ApiException catch (e) {
      // Der Server lehnt den Endpunkt ab (ungültig, falscher ntfy-Server oder das Topic gehört schon einem Gerät, 409 endpoint_in_use):
      // genau einmal abmelden und neu registrieren, damit der Verteiler ein neues Topic vergibt. Hilft das nicht, bleibt die Meldung stehen.
      if ((e.hatCode('invalid_endpoint') || e.hatCode('endpoint_in_use')) && !_neuVersucht) {
        _neuVersucht = true;
        try {
          await _verteilerAbmelden();
          await _p.registrieren();
          return;
        } catch (_) {
          // fällt auf die Meldung zurück
        }
      }
      if (ref.mounted) state = state.copyWith(angemeldet: false, fehler: e.message);
    } catch (_) {
      if (ref.mounted) state = state.copyWith(angemeldet: false, fehler: 'Der Endpunkt konnte nicht beim Server angemeldet werden.');
    }
  }

  Future<void> _verteilerHatAbgemeldet() async {
    if (!ref.mounted) return;
    if (DateTime.now().difference(_eigeneAbmeldung) < const Duration(seconds: 5)) return; // Folge unserer eigenen Abmeldung
    try {
      await ref.read(apiProvider).pushLoeschen();
    } catch (_) {}
    try {
      await ref.read(appDatabaseProvider).metaSchreiben(kPushAn, '0');
    } catch (_) {}
    if (ref.mounted) {
      state = state.copyWith(gewuenscht: false, angemeldet: false, fehler: 'Die ntfy-App hat die Anmeldung beendet. Schalte Benachrichtigungen neu ein.');
    }
  }

  Future<void> _wecker() async {
    if (!ref.mounted) return;
    state = state.copyWith(letzterWecker: DateTime.now());
    final t = _testWecker;
    if (t != null && !t.isCompleted) t.complete();
    // gedrosselt und serialisiert: höchstens ein Abgleich je Mindestabstand, auch bei einer Flut von Weckern
    (_weckerLauf ??= WeckerLauf(abstand: ref.read(pushWeckerAbstandProvider), lauf: _weckerAbgleich)).ausloesen();
  }

  Future<void> _weckerAbgleich() async {
    if (!ref.mounted) return;
    await weckerAbgleichen(
      store: ref.read(syncStoreProvider),
      abgleich: () => ref.read(syncProvider.notifier).synchronisieren(manuell: true),
      ereignisse: ref.read(ereignisBenachrichtigerProvider),
    );
  }

  /// Beim Abmelden (Hook in auth_state.dart): Endpunkt beim Server löschen (nur wenn die Sitzung noch gilt) und beim Verteiler abmelden.
  Future<void> beimAbmelden({required bool serverLoeschen}) async {
    if (!state.unterstuetzt) return;
    if (serverLoeschen) {
      try {
        await ref.read(apiProvider).pushLoeschen().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    try {
      await _verteilerAbmelden();
    } catch (_) {}
    if (ref.mounted) state = PushZustand(unterstuetzt: state.unterstuetzt, geladen: state.geladen);
  }
}

final pushProvider = NotifierProvider<PushController, PushZustand>(PushController.new);
