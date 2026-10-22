// Wiederherstellungstest und Erinnerung alle 90 Tage (Projektbeschreibung 9a, "P1-Rest"). Eine Sicherung, die nie probiert wurde, ist keine: der Test holt die Sicherung beim
// Server, öffnet sie mit dem, was die Person eintippt oder bestätigt (Wiederherstellungsschlüssel, Passwort der Passwort-Sicherung oder Passkey), und vergleicht den
// geöffneten Schlüssel mit dem aktuellen öffentlichen Schlüssel des Servers. Er VERÄNDERT NICHTS: kein Schlüssel wird übernommen, geschrieben oder ersetzt, keine Sicherung
// neu angelegt (Quelle des Vergleichs ist der Server). Der Zeitpunkt des letzten Tests und der Schalter der Erinnerung liegen rein lokal im Schlüsselspeicher dieses
// Geräts (öffentlich, kein Geheimnis, bleiben beim Abmelden); der Server erfährt nichts davon (kein Zeitplan, keine Erinnerung vom Server).
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/fampad_api.dart';
import '../auth/auth_state.dart';
import '../auth/eigener_abruf.dart';
import 'bytes.dart';
import 'crypto_fehler.dart';
import 'e2ee_state.dart';
import 'prf_state.dart';
import 'pw_ablauf.dart';
import 'schluessel.dart';
import 'wiederherstellung.dart';

/// Wie oft die App an den Test erinnert.
const kTestIntervall = Duration(days: 90);

/// Womit getestet wurde.
enum PruefWeg {
  wiederherstellungsschluessel,
  passwort,
  passkey;

  static PruefWeg? parse(String? s) => PruefWeg.values.where((w) => w.name == s).firstOrNull;
}

/// Letzter erfolgreicher Test dieses Geräts (null: noch nie) und Schalter der Erinnerung (Standard an).
class TestStand {
  final DateTime? zuletzt;
  final PruefWeg? weg;
  final bool erinnerungAn;
  const TestStand({this.zuletzt, this.weg, this.erinnerungAn = true});
}

/// Von wann an zählen die 90 Tage: ab dem letzten Test, mindestens aber ab der ältesten bestätigten Sicherung (wer nie testet, wird nicht schon am ersten Tag erinnert).
/// null: es gibt keine bestätigte Sicherung (dann gibt es nichts zu testen; die Absicherungs-Ampel drängt auf eine Sicherung).
DateTime? testBezug(E2eeState s, TestStand t) {
  final sicherungen = <DateTime>[
    if (s.hatSicherung && s.wiederherstellungAm != null) s.wiederherstellungAm!,
    if (s.pwBestaetigtAm != null && !s.pwSicherungVeraltet) s.pwBestaetigtAm!,
    if (s.prfBestaetigtAm != null && s.prfCredentialIds.isNotEmpty) s.prfBestaetigtAm!,
  ];
  if (sicherungen.isEmpty) return null;
  final seit = sicherungen.reduce((a, b) => a.isBefore(b) ? a : b);
  final z = t.zuletzt;
  return z != null && z.isAfter(seit) ? z : seit;
}

/// Ist die Erinnerung fällig? Nur mit eingeschalteter Erinnerung, mit einer bestätigten Sicherung und wenn der Bezug mindestens [kTestIntervall] zurückliegt.
bool testFaellig(E2eeState s, TestStand t, DateTime jetzt) {
  if (!t.erinnerungAn || s.status != E2eeStatus.bereit) return false;
  final bezug = testBezug(s, t);
  return bezug != null && !jetzt.isBefore(bezug.add(kTestIntervall));
}

/// Kein Schlüsselmaterial: Zeitpunkt, Weg und Schalter. Liegen unter dem Präfix `e2ee.kv.` neben den übrigen öffentlichen Vermerken.
String testVermerkName(String userId) => 'e2ee.kv.test.$userId';
String testAusName(String userId) => 'e2ee.kv.testaus.$userId';

class WiederherstellungsPruefung {
  final Ref ref;
  WiederherstellungsPruefung(this.ref);

  E2eeController get _e2ee => ref.read(e2eeProvider.notifier);
  FampadApi get _api => ref.read(apiProvider);

  String get _userId {
    final id = ref.read(authProvider).user?.id;
    if (id == null) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Du bist nicht angemeldet.');
    return id;
  }

  /// Der Test-Stand dieses Geräts; jeder Lesefehler ergibt den Standard ("noch nie getestet", Erinnerung an).
  Future<TestStand> lesen() async {
    final sp = ref.read(schluesselSpeicherProvider);
    final id = ref.read(authProvider).user?.id;
    if (id == null) return const TestStand();
    DateTime? zuletzt;
    PruefWeg? weg;
    var an = true;
    try {
      final b = await sp.lesen(testVermerkName(id));
      if (b != null) {
        final teile = String.fromCharCodes(b).split('|');
        zuletzt = DateTime.tryParse(teile.first);
        weg = teile.length > 1 ? PruefWeg.parse(teile[1]) : null;
      }
      an = (await sp.lesen(testAusName(id))) == null;
    } on Object {
      // nur eine Erinnerung: im Zweifel der Standard
    }
    return TestStand(zuletzt: zuletzt, weg: weg, erinnerungAn: an);
  }

  /// Schaltet die Erinnerung ein oder aus (nur lokal).
  Future<void> erinnerungSetzen(bool an) async {
    final sp = ref.read(schluesselSpeicherProvider);
    if (an) {
      await sp.loeschen(testAusName(_userId));
    } else {
      await sp.schreiben(testAusName(_userId), Uint8List.fromList([49]));
    }
    ref.invalidate(testStandProvider);
  }

  Future<void> _merken(PruefWeg weg) async {
    try {
      final sp = ref.read(schluesselSpeicherProvider);
      await sp.schreiben(testVermerkName(_userId), utf8Bytes('${DateTime.now().toUtc().toIso8601String()}|${weg.name}'));
    } on Object {
      // der Test selbst ist gelungen; ohne Vermerk erinnert die App eben früher
    }
    ref.invalidate(testStandProvider);
  }

  /// Vergleicht den geöffneten Schlüssel mit dem aktuellen öffentlichen Schlüssel des Servers und überschreibt ihn danach. Übernimmt NIE etwas.
  Future<void> _vergleichen(Personenschluessel geoeffnet, int keyVersion) async {
    try {
      final server = (await _api.eigeneSchluessel()).schluessel;
      if (server == null || server.version != keyVersion || !server.gleichWie(geoeffnet.oeffentlich(server.version))) {
        throw const CryptoFehler(
          CryptoFehlerArt.schluessel,
          'Die Sicherung lässt sich öffnen, gehört aber nicht zu deinem aktuellen Schlüssel. Lege die Sicherung neu an (Profil > Bin ich abgesichert?).',
        );
      }
    } finally {
      geoeffnet.loeschen();
    }
  }

  /// Test mit dem Wiederherstellungsschlüssel (Step-up legt die Oberfläche um den Aufruf). Der Abruf steht in der Ereignisliste und warnt die anderen Geräte
  /// (der Server kann einen Test nicht von einem Angriff unterscheiden): die Oberfläche sagt es vorher.
  Future<void> mitWiederherstellungsschluessel(String eingabe) async {
    final crypto = await _e2ee.kryptoFuerAblauf();
    final wk = Wiederherstellung.lesen(eingabe);
    try {
      final blob = await _api.sicherungAbrufen();
      final Sicherung sicherung;
      try {
        sicherung = Wiederherstellung.sicherungOeffnen(crypto, blob: blob.blob, wiederherstellungsschluessel: wk, userId: _userId);
      } on CryptoFehler catch (e) {
        if (e.art == CryptoFehlerArt.entschluesselung) {
          throw const CryptoFehler(CryptoFehlerArt.entschluesselung, 'Der Wiederherstellungsschlüssel passt nicht zu deiner Sicherung.');
        }
        rethrow;
      }
      await _vergleichen(sicherung.schluessel, sicherung.keyVersion);
    } finally {
      loescheBytes(wk);
    }
    await _merken(PruefWeg.wiederherstellungsschluessel);
  }

  /// Test mit dem Passwort der Passwort-Sicherung (Step-up legt die Oberfläche um den Aufruf). Eine veraltete Sicherung (nach einem Passwort-Reset) besteht den Test nicht.
  Future<void> mitPasswort(String passwort) async {
    final crypto = await _e2ee.kryptoFuerAblauf();
    final email = ref.read(authProvider).user?.email;
    if (email == null || email.trim().isEmpty) throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Zu deinem Konto gehört keine E-Mail-Adresse.');
    await ref.read(eigenerPwAbrufMarkeProvider)();
    final r = await PwSicherungAblauf(crypto: crypto, api: _api, userId: _userId, email: email).abrufenUndOeffnen(passwort);
    if (r.veraltet) {
      r.schluessel.loeschen();
      throw const CryptoFehler(CryptoFehlerArt.schluessel, 'Deine Passwort-Sicherung ist veraltet (nach dem Zurücksetzen des Passworts). Lege sie neu an.');
    }
    await _vergleichen(r.schluessel, r.keyVersion);
    await _merken(PruefWeg.passwort);
  }

  /// Test mit dem Passkey (eine Geste). false, wenn der Passkey-Speicher PRF nicht unterstützt (nichts geschehen).
  Future<bool> mitPasskey() async {
    final ok = await ref.read(prfSteuerungProvider).sicherungTesten(_vergleichen);
    if (ok) await _merken(PruefWeg.passkey);
    return ok;
  }
}

final wiederherstellungsPruefungProvider = Provider<WiederherstellungsPruefung>((ref) => WiederherstellungsPruefung(ref));

/// Der Test-Stand dieses Geräts (neu gelesen nach jedem Test und jeder Änderung des Schalters).
final testStandProvider = FutureProvider.autoDispose<TestStand>((ref) => ref.read(wiederherstellungsPruefungProvider).lesen(), retry: (_, _) => null);
