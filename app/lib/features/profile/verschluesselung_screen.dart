// Profil > Verschlüsselung (Phase 1 der Ende-zu-Ende-Verschlüsselung): Status, Einrichtung, neues Gerät verbinden, Sicherheitscode,
// Warnungen bei Schlüsselwechsel. Die Schlüssel schützen die Chats (Ende-zu-Ende); diese Seite verwaltet sie.
// Ehrlichkeit: "aktiv" (grün) erscheint nur, wenn der Server eine BESTÄTIGTE Sicherung meldet; sonst "offen". Sicherungen heißen "liegt beim Server (seit …)",
// nie "gesichert". "Gerät abgeben" (Schlüssel UND lokale Daten löschen) ist die einzige Aktion, die einen Schlüssel löscht, und bleibt ohne bestätigte
// Sicherung gesperrt; "Neuen Schlüssel erzeugen" gibt es nur im Notfallbereich hinter einer Checkliste.
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show MemberStatus, Role;
import '../../data/auth/auth_state.dart';
import '../../data/api/eltern_modelle.dart' show AnfrageZustand;
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/eltern_state.dart';
import '../../data/crypto/schluessel_speicher.dart' show SpeicherDauer;
import '../../data/crypto/sicherheitscode.dart';
import '../../data/crypto/vertrauen.dart';
import '../../data/crypto/wiederherstellungstest.dart';
import '../../data/ingest/ingest_kopplung.dart' show PostfachSpeicher;
import '../../data/sync_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/benutzer_avatar.dart';
import '../auth/auth_widgets.dart';
import '../auth/geraetespeicher_reparatur.dart';
import '../auth/step_up.dart';
import 'geraet_verbinden_screens.dart';
import 'eltern_screens.dart';
import 'prf_sicherung_screen.dart';
import 'profile_screen.dart';
import 'pw_sicherung_screen.dart';
import 'wiederherstellung_testen_screen.dart';
import 'wiederherstellungsschluessel_screen.dart';
import 'wort_bestaetigung.dart';

class VerschluesselungScreen extends ConsumerStatefulWidget {
  const VerschluesselungScreen({super.key});

  @override
  ConsumerState<VerschluesselungScreen> createState() => _VerschluesselungScreenState();
}

class _VerschluesselungScreenState extends ConsumerState<VerschluesselungScreen> with AktionsZustand<VerschluesselungScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(ref.read(e2eeProvider.notifier).laden()));
  }

  E2eeController get _c => ref.read(e2eeProvider.notifier);

  Future<void> _oeffne(Widget seite) async {
    await Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => seite));
    if (mounted) unawaited(_c.laden());
  }

  Future<bool> _bestaetigen(String titel, String text, String knopf) async =>
      await showDialog<bool>(useRootNavigator: false,
        context: context,
        builder: (_) => AlertDialog(
          title: Text(titel),
          content: Text(text),
          scrollable: true,
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Abbrechen')),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: kDanger),
              child: Text(knopf),
            ),
          ],
        ),
      ) ??
      false;

  /// Erstmalige Einrichtung: Schlüssel erzeugen, dann den Wiederherstellungsschlüssel zeigen und sichern lassen.
  Future<void> _einrichten() async {
    Einrichtung? e;
    final ok = await ausfuehren(() async => e = await _c.einrichten());
    final einrichtung = e;
    if (!ok || einrichtung == null || !mounted) return;
    await _oeffne(WiederherstellungsschluesselScreen(einrichtung: einrichtung));
  }

  Future<void> _neuerSchluessel() async {
    Einrichtung? e;
    final ok = await ausfuehren(() async => e = await _c.neuerWiederherstellungsschluessel());
    final einrichtung = e;
    if (!ok || einrichtung == null || !mounted) return;
    await _oeffne(WiederherstellungsschluesselScreen(einrichtung: einrichtung, ersatz: true));
  }

  Future<void> _wechseln() async {
    final ja = await wortBestaetigen(
      context,
      titel: 'Neuen Schlüssel erzeugen?',
      text:
          'Das ist der letzte Ausweg. Mit einem neuen Schlüssel kannst du verschlüsselte Inhalte, die mit deinem bisherigen Schlüssel geschützt waren, nicht mehr lesen. '
          'Alle anderen in der Familie sehen eine Warnung, dass sich dein Schlüssel geändert hat.',
      haken: const [
        'Ich habe keinen Wiederherstellungsschlüssel.',
        'Ich habe kein anderes Gerät mit meinem Schlüssel.',
        'Ich kenne kein Passwort der Passwort-Sicherung.',
        'Alte Chats gehen unwiderruflich verloren.',
      ],
      wort: 'ersetzen',
      knopf: 'Neuen Schlüssel erzeugen',
    );
    if (!ja || !mounted) return;
    Einrichtung? e;
    final ok = await ausfuehren(() async => e = await mitStepUp(context, ref, _c.schluesselWechseln));
    final einrichtung = e;
    if (!ok || einrichtung == null || !mounted) return;
    await _oeffne(WiederherstellungsschluesselScreen(einrichtung: einrichtung));
  }

  Future<void> _verwerfen() async {
    final ja = await _bestaetigen(
      'Dieses Gerät neu verbinden?',
      'Der Schlüssel auf diesem Gerät wird nicht mehr benutzt, aber nicht gelöscht: Er bleibt hier als "Alter Schlüssel" aufbewahrt. '
      'Danach verbindest du das Gerät wieder per QR-Code von einem anderen Gerät, mit deinem Wiederherstellungsschlüssel oder mit dem Passwort deiner Passwort-Sicherung.',
      'Neu verbinden',
    );
    if (!ja || !mounted) return;
    await ausfuehren(_c.lokalenSchluesselVerwerfen);
  }

  /// Einen aufbewahrten alten Schlüssel endgültig verwerfen: nur mit getipptem Wort.
  Future<void> _quarantaeneVerwerfen(QuarantaeneEintrag e) async {
    final ja = await wortBestaetigen(
      context,
      titel: 'Alten Schlüssel verwerfen?',
      text:
          'Die App benutzt diesen alten Schlüssel nirgends. Wenn du ihn verwirfst, ist er endgültig weg. Nur ein Chat-Verlauf, der allein mit diesem alten Schlüssel lesbar wäre, '
          'wäre dann nicht mehr zu retten.',
      wort: 'löschen',
      knopf: 'Endgültig verwerfen',
    );
    if (!ja || !mounted) return;
    await ausfuehren(() => _c.quarantaeneVerwerfen(e.name));
  }

  /// "Gerät abgeben": Schlüssel UND lokale Daten löschen, abmelden. Gesperrt ohne bestätigte Sicherung (Anzeige in [_geraetAbgeben]); hier nochmals mit Haken und
  /// getipptem Wort. Liegen frühere Schlüssel auf dem Gerät (Quarantäne, abweichender Schlüssel), gibt es einen eigenen Pflicht-Haken mit der Anzahl.
  Future<void> _geraetAbgebenAusfuehren() async {
    final n = ref.read(e2eeProvider).fruehereSchluessel;
    // noch nicht gesendete Änderungen (Ausgang) gehen mit den lokalen Daten verloren: vorher einmal abgleichen, den Rest (auch abgelehnte) aus der Datenbank nennen
    final store = ref.read(syncStoreProvider);
    final sync = ref.read(syncProvider.notifier);
    var offen = 0;
    var abgelehnt = 0;
    try {
      if (await store.offeneAnzahl() > 0) await sync.synchronisieren(manuell: true);
      offen = await store.offeneAnzahl();
      abgelehnt = await store.abgelehnteAnzahl();
    } on Object {
      // der Stand des Ausgangs ließ sich nicht lesen: ohne Warnung weiter (die Rückfrage unten bleibt)
    }
    // dieses Gerät holt die Werte aus Home Assistant ab (hat den Postfach-Schlüssel): mit ihm gehen sie verloren, bis neu gekoppelt wird
    var holtHaAb = false;
    final uid = ref.read(authProvider).user?.id;
    if (uid != null) {
      try {
        holtHaAb = await PostfachSpeicher(ref.read(schluesselSpeicherProvider)).vorhanden(uid);
      } on Object {
        // nicht lesbar: ohne den Zusatz weiter
      }
    }
    if (!mounted) return;
    final ja = await wortBestaetigen(
      context,
      titel: 'Gerät abgeben?',
      text:
          'Dein Schlüssel und alle lokalen Daten werden von diesem Gerät gelöscht, und du wirst abgemeldet. Dein Konto, deine Chats auf dem Server und deine Sicherung bleiben. '
          'Deinen Verlauf bekommst du danach nur mit deiner Sicherung oder von einem anderen Gerät mit deinem Schlüssel wieder.'
          '${holtHaAb ? ' Dieses Gerät holt auch die Werte aus Home Assistant ab: Home Assistant liefert danach nichts mehr, bis du neu koppelst.' : ''}',
      haken: [
        if (offen > 0)
          'Ich weiß: ${offen == 1 ? '1 noch nicht gesendete Änderung (z. B. eine Nachricht) geht' : '$offen noch nicht gesendete Änderungen (z. B. Nachrichten) gehen'} verloren. '
              'Die Synchronisierung eben hat sie nicht übertragen.',
        if (abgelehnt > 0)
          'Ich weiß: ${abgelehnt == 1 ? '1 nicht gesendete Nachricht (Änderung) mit Fehler geht' : '$abgelehnt nicht gesendete Nachrichten (Änderungen) mit Fehler gehen'} verloren (vom Server abgelehnt).',
        'Ich weiß: Ohne meine Sicherung (Wiederherstellungsschlüssel oder Passwort der Passwort-Sicherung) kommt mein Verlauf nicht zurück.',
        if (n > 0)
          n == 1
              ? 'Auf diesem Gerät liegt noch 1 früherer Schlüssel, der nur hier existiert. Er wird ebenfalls gelöscht.'
              : 'Auf diesem Gerät liegen noch $n frühere Schlüssel, die nur hier existieren. Sie werden ebenfalls gelöscht.',
      ],
      wort: 'löschen',
      knopf: 'Gerät abgeben',
    );
    if (!ja || !mounted) return;
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    GeraetAbgabeErgebnis? ergebnis;
    final ok = await ausfuehren(() async => ergebnis = await _c.geraetAbgeben());
    if (!ok) return; // nichts wurde gelöscht: der Grund steht im Fehlerkasten
    nav.popUntil((r) => r.isFirst);
    final e = ergebnis;
    final teile = <String>[
      if (e == null || e.schluesselGeloescht)
        'Schlüssel und lokale Daten sind von diesem Gerät gelöscht, du bist abgemeldet.'
      else
        'Du bist abgemeldet, aber der Schlüssel konnte nicht gelöscht werden: Lösche die App-Daten oder setze das Gerät zurück. Beim nächsten Start versucht die App es noch einmal.',
      if (e != null && !e.serverAbgemeldet)
        'Der Server war nicht erreichbar: Die Sitzung dort bleibt bis zum Ablauf gültig; beende sie später unter "Angemeldete Geräte".',
      if (e != null && !e.datenSauber)
        'Die lokalen Daten ließen sich nicht vollständig löschen: Lösche zusätzlich die App-Daten oder setze das Gerät zurück.'
      else if (kIsWeb)
        'Im Browser wurden die Zeilen der Datenbank gelöscht, ihre Datei kann Reste enthalten: Lösche zusätzlich die Websitedaten dieser Seite.',
    ];
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(duration: const Duration(seconds: 12), content: Text(teile.join(' '))));
  }

  /// Weg zu einer Sicherung: die Passwort-Sicherung, wenn der Server sie anbietet, sonst der Wiederherstellungsschlüssel.
  Future<void> _sicherungAnlegen(E2eeState s) => s.pwSicherungVerfuegbar ? _oeffne(const PwSicherungScreen()) : _neuerSchluessel();

  Future<void> _vertrauenZuruecksetzen() async {
    final ja = await _bestaetigen(
      'Vertrauen zurücksetzen?',
      'Dieses Gerät vergisst dann alle gemerkten Schlüssel der Familie und den Stand der Chat-Mitglieder. Danach gilt jeder Schlüssel, den der Server nennt, wieder als "beim ersten Sehen" '
      'vertrauenswürdig: Ein falsch untergeschobener Schlüssel würde nicht auffallen. In Chats gilt die erste lesbare Epoche als Basis, und bewusst entfernte Personen könnten '
      'ohne Rückfrage zurückkommen. Vergleiche danach die Sicherheitscodes und die Mitglieder deiner Chats mit den Personen. Verschlüsselte Chats bleiben lesbar.',
      'Vertrauen zurücksetzen',
    );
    if (!ja || !mounted) return;
    await ausfuehren(_c.vertrauenZuruecksetzen);
  }

  Future<void> _akzeptieren(SchluesselWarnung w, String name) async {
    final ja = await _bestaetigen(
      'Neuen Schlüssel akzeptieren?',
      'Akzeptiere den neuen Schlüssel von $name nur, wenn $name den Wechsel bestätigt hat, am besten durch Vergleichen des Sicherheitscodes. '
      'Sonst könnte jemand einen falschen Schlüssel untergeschoben haben.',
      'Neuen Schlüssel akzeptieren',
    );
    if (!ja || !mounted) return;
    await ausfuehren(() => _c.warnungAkzeptieren(w.userId));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(e2eeProvider);
    final auth = ref.watch(authProvider);
    return AuthSeite(
      label: '// verschlüsselung',
      titel: 'Verschlüsselung',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Mit einem persönlichen Schlüssel, der nur auf deinen Geräten liegt, werden deine Chat-Nachrichten so geschützt, dass sie nicht einmal der Server lesen kann. '
          'Ohne eingerichteten Schlüssel kannst du Chats nicht lesen und nicht schreiben.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        ..._warnungen(s),
        ..._inhalt(s, auth),
      ],
    );
  }

  List<Widget> _warnungen(E2eeState s) {
    if (s.warnungen.isEmpty) return const [];
    String name(String id) => s.mitglieder.where((m) => m.id == id).map((m) => m.displayName).firstOrNull ?? 'Unbekannt';
    return [
      for (final w in s.warnungen) ...[
        _WarnKarte(
          name: name(w.userId),
          warnung: w,
          onAkzeptieren: laeuft ? null : () => _akzeptieren(w, name(w.userId)),
        ),
        const SizedBox(height: 12),
      ],
    ];
  }

  List<Widget> _inhalt(E2eeState s, AuthState auth) {
    switch (s.status) {
      case E2eeStatus.laedt:
        return const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))];
      case E2eeStatus.nichtVerfuegbar:
        return [
          MeldungsBox(s.meldung ?? 'Die Verschlüsselung ist gerade nicht verfügbar.'),
          const SizedBox(height: 12),
          if (s.vertrauenDefekt) ...[
            ZweitKnopf(text: 'Vertrauen zurücksetzen', icon: Icons.restart_alt, onPressed: laeuft ? null : _vertrauenZuruecksetzen),
            const GeraeteSpeicherKnopf(),
          ] else
            ZweitKnopf(text: 'Erneut versuchen', icon: Icons.refresh, onPressed: laeuft ? null : () => unawaited(_c.laden())),
          ..._zusatz(s),
        ];
      case E2eeStatus.keinSchluessel:
        return [
          const MonoLabel('// status'),
          const SizedBox(height: 8),
          const EinstellungsZeile(icon: Icons.lock_open, titel: 'Nicht eingerichtet', untertitel: 'noch kein schlüssel'),
          const SizedBox(height: 8),
          const Text(
            'Bei der Einrichtung entsteht dein Schlüssel auf diesem Gerät. Du bekommst einen Wiederherstellungsschlüssel, den du sicher aufbewahrst, '
            'damit du ihn auch nach Geräteverlust nicht verlierst.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 12),
          HauptKnopf(text: 'Verschlüsselung einrichten', icon: Icons.lock_outline, laeuft: laeuft, onPressed: _einrichten),
          ..._zusatz(s),
        ];
      case E2eeStatus.geraetNichtVerbunden:
        return [
          const MonoLabel('// status'),
          const SizedBox(height: 8),
          const EinstellungsZeile(icon: Icons.phonelink_lock, titel: 'Dieses Gerät ist nicht verbunden', untertitel: 'schlüssel fehlt hier'),
          const SizedBox(height: 8),
          const Text(
            'Dein Schlüssel liegt auf einem anderen Gerät. Verbinde dieses Gerät per QR-Code oder Code von dort, oder mit deinem Wiederherstellungsschlüssel.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          if (s.vertrauenDefekt && s.meldung != null) ...[const SizedBox(height: 12), MeldungsBox(s.meldung!)],
          const SizedBox(height: 12),
          HauptKnopf(text: 'Mit anderem Gerät verbinden', icon: Icons.qr_code_scanner, onPressed: laeuft ? null : () => _oeffne(const GeraetVerbindenScreen())),
          const SizedBox(height: 8),
          ZweitKnopf(
            text: 'Mit Wiederherstellungsschlüssel verbinden',
            icon: Icons.key_outlined,
            onPressed: laeuft || !s.hatSicherung ? null : () => _oeffne(const WiederherstellungVerbindenScreen()),
          ),
          if (!s.hatSicherung) ...[
            const SizedBox(height: 8),
            const Text('Es gibt noch keine Sicherung mit einem Wiederherstellungsschlüssel.', style: TextStyle(fontSize: 13, color: kTextMuted)),
          ],
          if (s.pwSicherungVerfuegbar) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Mit Passwort verbinden', icon: Icons.password, onPressed: laeuft ? null : () => _oeffne(const PwVerbindenScreen())),
          ],
          if (s.elternWiederherstellungVerfuegbar && auth.user?.role == Role.child) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Von meinen Eltern zurückholen', icon: Icons.family_restroom, onPressed: laeuft ? null : () => _oeffne(const ElternWiederherstellungScreen())),
          ],
          if (s.prfSicherungVerfuegbar && (auth.me?.passkeys ?? 0) > 0) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Mit Passkey verbinden', icon: Icons.fingerprint, onPressed: laeuft ? null : () => _oeffne(const PrfVerbindenScreen())),
          ],
          if (s.vertrauenDefekt) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Vertrauen zurücksetzen', icon: Icons.restart_alt, onPressed: laeuft ? null : _vertrauenZuruecksetzen),
            // der Schlüsselspeicher selbst ist kaputt (Android-Keystore-Schlüssel verloren): bewusste Reparatur, nur nach Probe und Rückfrage
            const GeraeteSpeicherKnopf(),
          ],
          // bewusst KEIN "Neuen Schlüssel erzeugen" auf dieser Seite: wer sein Gerät nur nicht verbunden hat, soll verbinden, nicht ersetzen
          ..._zusatz(s),
        ];
      case E2eeStatus.abweichend:
        return [
          const MeldungsBox(
            'Der Schlüssel auf diesem Gerät passt nicht mehr zu deinem Konto. Vermutlich wurde er auf einem anderen Gerät gewechselt. Verbinde dieses Gerät neu: '
            'Der bisherige Schlüssel wird dabei nicht gelöscht, sondern hier aufbewahrt.',
          ),
          const SizedBox(height: 12),
          HauptKnopf(text: 'Dieses Gerät neu verbinden', icon: Icons.sync_problem, laeuft: laeuft, onPressed: _verwerfen),
          ..._zusatz(s),
        ];
      case E2eeStatus.bereit:
        return [
          const MonoLabel('// status'),
          const SizedBox(height: 8),
          EinstellungsZeile(
            icon: Icons.lock,
            titel: 'Eingerichtet',
            untertitel: 'schlüsselversion ${s.serverSchluessel?.version ?? 1}',
            // grün nur mit bestätigter Sicherung beim Server: ohne sie oder bei unbekanntem Stand "offen"
            status: s.sicherungBestaetigt ? const RollenPille('aktiv', farbe: kTerminal) : const RollenPille('offen', farbe: kWarn),
          ),
          if (!s.sicherungBestaetigt) ...[_SicherungOffen(onSichern: laeuft ? null : () => _sicherungAnlegen(s)), const SizedBox(height: 8)],
          ..._testErinnerung(s),
          EinstellungsZeile(
            icon: Icons.key_outlined,
            titel: 'Wiederherstellungsschlüssel',
            untertitel: !s.hatSicherung
                ? 'keine sicherung · jetzt erzeugen'
                : s.wiederherstellungAm != null
                ? 'sicherung liegt beim server (seit ${_datum(s.wiederherstellungAm!)}) · neuen erzeugen'
                : 'sicherung liegt beim server · stand unbestätigt · neuen erzeugen',
            status: s.hatSicherung && s.wiederherstellungAm != null ? null : const RollenPille('offen', farbe: kWarn),
            onTap: laeuft ? null : _neuerSchluessel,
          ),
          if (s.pwSicherungVerfuegbar) _pwZeile(s),
          if (s.prfSicherungVerfuegbar && (auth.me?.passkeys ?? 0) > 0) _prfZeile(s),
          _testZeile(s),
          ..._elternZeilen(s, auth),
          EinstellungsZeile(
            icon: Icons.qr_code_2,
            titel: 'Neues Gerät verbinden',
            untertitel: 'qr-code oder code zeigen',
            onTap: laeuft ? null : () => _oeffne(const UebertragungAnbietenScreen()),
          ),
          const SizedBox(height: 12),
          _SicherheitscodeKarte(state: s, eigeneId: auth.user?.id),
          ..._zusatz(s, notfall: true),
        ];
    }
  }

  static String _datum(DateTime t) => DateFormat('d. MMM yyyy', 'de_DE').format(t.toLocal());

  /// Gemeinsame Abschnitte unter dem Status: Browser-Hinweis, aufbewahrte alte Schlüssel, Hinweis auf ältere Sicherungen und der eingeklappte Bereich
  /// "Erweitert" (Gerät abgeben, bei [notfall] der Notfallbereich, Vertrauensmodell).
  List<Widget> _zusatz(E2eeState s, {bool notfall = false}) => [
    ..._browserHinweis(s),
    ..._quarantaene(s),
    ..._archiv(s),
    const SizedBox(height: 16),
    _Erweitert(
      children: [
        ..._geraetAbgeben(s),
        if (notfall) ...[const SizedBox(height: 16), _gefahr()],
        const SizedBox(height: 16),
        const _Vertrauensmodell(),
      ],
    ),
  ];

  /// Web: Hat der Browser die dauerhafte Ablage nicht zugesagt, darf er die Schlüssel-Daten löschen; ließ sich das nicht klären, steht nur das da (keine Tatsache).
  List<Widget> _browserHinweis(E2eeState s) {
    switch (s.speicherDauer) {
      case SpeicherDauer.verweigert:
        return [
          const SizedBox(height: 16),
          const MeldungsBox(
            'Der Browser darf diese Daten löschen, zum Beispiel bei knappem Speicher. Installiere die App oder verbinde ein zweites Gerät, damit dein Schlüssel nicht allein hier liegt.',
            fehler: false,
          ),
          const SizedBox(height: 8),
          ZweitKnopf(text: 'Dauerhaften Speicher anfragen', icon: Icons.save_outlined, onPressed: laeuft ? null : () => ausfuehren(_c.dauerhaftenSpeicherAnfordern)),
        ];
      case SpeicherDauer.unbekannt:
        return const [
          SizedBox(height: 16),
          Text(
            'Ob der Browser diese Daten dauerhaft behält, ließ sich nicht klären.',
            style: TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
          ),
        ];
      case SpeicherDauer.gewaehrt:
      case SpeicherDauer.nichtZutreffend:
        return const [];
    }
  }

  /// Ruhiger Hinweis: Der Server hält ältere Sicherungen (nie gelöscht).
  List<Widget> _archiv(E2eeState s) {
    final n = s.archivAnzahl ?? 0;
    if (n <= 0 || s.status != E2eeStatus.bereit) return const [];
    return [
      const SizedBox(height: 12),
      Text(
        n == 1 ? '1 ältere Sicherung liegt beim Server.' : '$n ältere Sicherungen liegen beim Server.',
        style: const TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
      ),
    ];
  }

  /// Aufbewahrte alte Schlüssel dieses Geräts: nur ein Hinweis, die App benutzt sie nirgends und löscht sie nie automatisch.
  List<Widget> _quarantaene(E2eeState s) {
    if (s.quarantaene.isEmpty) return const [];
    final df = DateFormat('d. MMM yyyy, HH:mm', 'de_DE');
    return [
      const SizedBox(height: 16),
      const MonoLabel('// alter schlüssel auf diesem gerät', color: kTextMuted),
      const SizedBox(height: 8),
      const Text(
        'Dieses Gerät hat einen früheren Schlüssel von dir aufbewahrt, statt ihn zu löschen. Die App benutzt ihn nirgends; er liegt nur hier, bis du ihn verwirfst '
        'oder das Gerät abgibst. Du musst nichts tun.',
        style: TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
      ),
      const SizedBox(height: 8),
      for (final e in s.quarantaene)
        LxCard(
          padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
          child: Row(
            children: [
              const Icon(Icons.history, color: kTextMuted, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  e.seit == null ? 'Alter Schlüssel auf diesem Gerät' : 'Alter Schlüssel auf diesem Gerät · seit ${df.format(e.seit!.toLocal())}',
                  style: const TextStyle(fontSize: 13, height: 1.3),
                ),
              ),
              TextButton(
                onPressed: laeuft ? null : () => _quarantaeneVerwerfen(e),
                style: TextButton.styleFrom(foregroundColor: kDanger, minimumSize: const Size(48, 48)),
                child: const Text('Verwerfen'),
              ),
            ],
          ),
        ),
    ];
  }

  /// "Gerät abgeben – alles löschen": die einzige Aktion, die einen Schlüssel löscht. Gesperrt ohne bestätigte Sicherung beim Server. Ist der Stand beim Server nicht
  /// ladbar (Status "nicht verfügbar"), zeigt die Seite den Bereich gar nicht (nur "Erneut versuchen"); die Sperre gilt dann trotzdem im Controller.
  List<Widget> _geraetAbgeben(E2eeState s) {
    final lage = geraetAbgabeLage(s);
    if (lage == GeraetAbgabeLage.nichtsZuLoeschen || lage == GeraetAbgabeLage.standUnbekannt) return const [];
    final gesperrt = lage == GeraetAbgabeLage.keineBestaetigteSicherung
        ? 'Gesperrt: Beim Server liegt keine bestätigte Sicherung deines Schlüssels. Ohne sie wäre dein Chat-Verlauf nach dem Löschen unwiederbringlich verloren. '
              'Lege zuerst eine Sicherung an.'
        : null;
    return [
      const MonoLabel('// gerät abgeben', color: kTextMuted),
      const SizedBox(height: 8),
      const Text(
        'Wenn du dieses Gerät weitergibst oder verkaufst, oder an einem gemeinsam genutzten Computer: Das löscht deinen Schlüssel und alle lokalen Daten von diesem Gerät und meldet dich ab. '
        'Normales Abmelden löscht den Schlüssel nie.',
        style: TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: laeuft || gesperrt != null ? null : _geraetAbgebenAusfuehren,
        style: OutlinedButton.styleFrom(foregroundColor: kDanger, side: BorderSide(color: gesperrt != null ? kBorder : kDanger), minimumSize: const Size.fromHeight(48)),
        icon: const Icon(Icons.delete_forever_outlined),
        label: const Text('Gerät abgeben – alles löschen', textAlign: TextAlign.center),
      ),
      if (gesperrt != null) ...[
        const SizedBox(height: 8),
        Text(gesperrt, style: const TextStyle(fontSize: 13, height: 1.4, color: kWarn)),
        if (s.status == E2eeStatus.bereit) ...[
          const SizedBox(height: 8),
          ZweitKnopf(text: 'Sicherung anlegen', icon: Icons.shield_outlined, onPressed: laeuft ? null : () => _sicherungAnlegen(s)),
        ],
      ],
    ];
  }

  /// Passwort-Sicherung (nur wenn der Server sie anbietet): zusätzlich zum Wiederherstellungsschlüssel, ersetzt ihn nicht.
  /// Es zählt der Stand beim Server (bestätigt seit …); der Vermerk dieses Geräts allein reicht nicht für "liegt beim Server".
  Widget _pwZeile(E2eeState s) {
    final v = s.pwSicherungVersion;
    final aktuell = s.serverSchluessel?.version;
    final bestaetigt = s.pwBestaetigtAm;
    final (String untertitel, Widget? pille) = s.pwSicherungVeraltet && s.status == E2eeStatus.bereit
        ? ('veraltet nach Passwort-Reset · Sicherung erneuern', const RollenPille('erneuern', farbe: kWarn))
        : bestaetigt != null
        ? ('liegt beim server (seit ${_datum(bestaetigt)}) · neues passwort wählen', null)
        : v == null
        ? ('nicht gesichert · jetzt einrichten', const RollenPille('offen', farbe: kWarn))
        : v == aktuell
        ? ('auf diesem gerät angelegt · server meldet keinen stand', const RollenPille('offen', farbe: kWarn))
        : ('veraltet · neu sichern', const RollenPille('offen', farbe: kWarn));
    return EinstellungsZeile(
      icon: Icons.password,
      titel: 'Passwort-Sicherung',
      untertitel: untertitel,
      status: pille,
      onTap: laeuft ? null : () => _oeffne(const PwSicherungScreen()),
    );
  }

  /// Wiederherstellungstest: die Zeile zeigt, wann zuletzt getestet wurde; nach 90 Tagen (mit eingeschalteter Erinnerung) steht oben eine ruhige Erinnerung. Rein lokal.
  Widget _testZeile(E2eeState s) {
    final stand = ref.watch(testStandProvider).value ?? const TestStand();
    final faellig = testFaellig(s, stand, DateTime.now());
    return EinstellungsZeile(
      icon: Icons.rule,
      titel: 'Wiederherstellung testen',
      untertitel: testZeitText(stand),
      status: faellig ? const RollenPille('fällig', farbe: kWarn) : null,
      onTap: laeuft ? null : () => _oeffne(const WiederherstellungTestenScreen()),
    );
  }

  /// Eltern-Wiederherstellung (nur mit Schalter des Servers): Kinder erlauben ihren Eltern zu helfen; Eltern sehen, wem sie helfen können und ob jemand um Hilfe bittet.
  List<Widget> _elternZeilen(E2eeState s, AuthState auth) {
    if (!s.elternWiederherstellungVerfuegbar) return const [];
    final rolle = auth.user?.role;
    if (rolle == Role.child) {
      final aktiv = ref.watch(elternHilfeAktivProvider);
      return [
        EinstellungsZeile(
          icon: Icons.family_restroom,
          titel: 'Eltern-Wiederherstellung',
          untertitel: aktiv ? 'deine eltern können dir helfen' : 'aus · eltern helfen lassen',
          status: aktiv ? const RollenPille('aktiv', farbe: kTerminal) : const RollenPille('aus', farbe: kWarn),
          onTap: laeuft ? null : () => _oeffne(const ElternWiederherstellungScreen()),
        ),
      ];
    }
    if (rolle == Role.admin || rolle == Role.parent) {
      final h = ref.watch(hilfeProvider).value;
      if (h == null || h.kinder.isEmpty) return const [];
      final offen = h.anfragen.where((a) => a.anfrage.zustand.offen && a.anfrage.zustand != AnfrageZustand.freigegeben).length;
      return [
        EinstellungsZeile(
          icon: Icons.child_care,
          titel: 'Kindern helfen',
          untertitel: offen > 0 ? '$offen anfrage${offen == 1 ? '' : 'n'} offen' : '${h.kinder.length} kind${h.kinder.length == 1 ? '' : 'er'} · du kannst helfen',
          status: offen > 0 ? const RollenPille('anfrage', farbe: kWarn) : null,
          onTap: laeuft ? null : () => _oeffne(const ElternHilfeScreen()),
        ),
      ];
    }
    return const [];
  }

  List<Widget> _testErinnerung(E2eeState s) {
    final stand = ref.watch(testStandProvider).value ?? const TestStand();
    if (!testFaellig(s, stand, DateTime.now())) return const [];
    return [
      const MeldungsBox(
        'Es ist über 90 Tage her, dass du deine Wiederherstellung geprüft hast. Teste jetzt, ob sich deine Sicherung noch öffnen lässt: das dauert eine Minute und verändert nichts.',
        fehler: false,
      ),
      const SizedBox(height: 8),
      ZweitKnopf(text: 'Wiederherstellung testen', icon: Icons.rule, onPressed: laeuft ? null : () => _oeffne(const WiederherstellungTestenScreen())),
      const SizedBox(height: 8),
    ];
  }

  /// Passkey-Sicherung (nur wenn der Server sie anbietet und die Person einen Passkey hat): zusätzlich zu den anderen Wegen. Es zählt der Stand beim Server.
  Widget _prfZeile(E2eeState s) {
    final bestaetigt = s.prfBestaetigtAm;
    final (String untertitel, Widget? pille) = s.prfSicherungVeraltet && s.prfCredentialIds.isEmpty
        ? ('veraltet nach Schlüsselwechsel · Sicherung erneuern', const RollenPille('erneuern', farbe: kWarn))
        : bestaetigt != null && s.prfCredentialIds.isNotEmpty && !s.prfSynchronisiert
        ? ('liegt beim server · zählt (noch) nicht: dein passkey meldet sich nicht als synchronisiert', const RollenPille('nur dieses gerät', farbe: kWarn))
        : bestaetigt != null && s.prfCredentialIds.isNotEmpty
        ? ('liegt beim server (seit ${_datum(bestaetigt)}) · erneuern', null)
        : ('nicht gesichert · jetzt einrichten', const RollenPille('offen', farbe: kWarn));
    return EinstellungsZeile(
      icon: Icons.fingerprint,
      titel: 'Passkey-Sicherung',
      untertitel: untertitel,
      status: pille,
      onTap: laeuft ? null : () => _oeffne(const PrfSicherungScreen()),
    );
  }

  Widget _gefahr() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const MonoLabel('// notfall', color: kTextMuted),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: laeuft ? null : _wechseln,
        style: OutlinedButton.styleFrom(foregroundColor: kDanger, side: const BorderSide(color: kDanger), minimumSize: const Size.fromHeight(48)),
        icon: const Icon(Icons.warning_amber_rounded),
        label: const Text('Neuen Schlüssel erzeugen …', textAlign: TextAlign.center),
      ),
      const SizedBox(height: 4),
      const Text(
        'Letzter Ausweg, nur nach einer Checkliste: wenn dir kein Gerät, kein Wiederherstellungsschlüssel und kein Passwort der Passwort-Sicherung mehr bleibt. Alte verschlüsselte Inhalte lassen sich dann nicht mehr lesen.',
        style: TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
      ),
    ],
  );
}

/// Eingeklappter Bereich "Erweitert": Gerät abgeben, Notfall und Vertrauensmodell stehen nicht im Weg, sind aber da.
class _Erweitert extends StatelessWidget {
  final List<Widget> children;
  const _Erweitert({required this.children});

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      title: const Text('Erweitert', style: TextStyle(fontWeight: FontWeight.w600)),
      subtitle: const Text('gerät abgeben · notfall · vertrauensmodell', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
      children: children,
    ),
  );
}

/// Hinweis (gelb, nicht grün): Der Server kennt keine bestätigte Sicherung, oder er meldet den Stand nicht. Bleibt sichtbar, bis eine Sicherung bestätigt ist.
class _SicherungOffen extends StatelessWidget {
  final VoidCallback? onSichern;
  const _SicherungOffen({required this.onSichern});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: 'Sicherung offen',
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kWarn.withValues(alpha: 0.08),
        border: Border.all(color: kWarn.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.warning_amber_rounded, color: kWarn, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Sicherung offen: Beim Server liegt keine bestätigte Sicherung deines Schlüssels (oder der Server meldet sie nicht). '
                  'Verlierst du alle Geräte mit deinem Schlüssel, ist dein Chat-Verlauf nicht zu retten.',
                  style: TextStyle(fontSize: 13, height: 1.4, color: kText),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ZweitKnopf(text: 'Jetzt sichern', icon: Icons.shield_outlined, onPressed: onSichern),
        ],
      ),
    ),
  );
}

/// Warnung: Der Schlüssel einer Person hat sich geändert (oder fehlt jetzt).
class _WarnKarte extends StatelessWidget {
  final String name;
  final SchluesselWarnung warnung;
  final VoidCallback? onAkzeptieren;
  const _WarnKarte({required this.name, required this.warnung, required this.onAkzeptieren});

  @override
  Widget build(BuildContext context) {
    final alt = VertrauensPruefer.codeVon(warnung.userId, warnung.gemerkt);
    final neu = warnung.aktuell == null ? null : personenSicherheitscode(MitgliedSchluessel(warnung.userId, warnung.aktuell!));
    return Semantics(
      container: true,
      label: 'Warnung: Der Schlüssel von $name hat sich geändert',
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kDanger.withValues(alpha: 0.08),
          border: Border.all(color: kDanger.withValues(alpha: 0.5)),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, color: kDanger),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    warnung.rueckfall
                        ? 'Der Server nennt für $name einen ÄLTEREN Schlüssel als bisher.'
                        : neu == null
                        ? 'Der Schlüssel von $name fehlt jetzt.'
                        : 'Der Schlüssel von $name hat sich geändert.',
                    style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (warnung.rueckfall)
              const Text(
                'Schlüsselversionen steigen nur. Ein Rückfall ist ein Hinweis auf einen Fehler oder einen Angriff auf den Server; die App akzeptiert ihn nie. Melde das dem Admin.',
                style: TextStyle(fontSize: 13, height: 1.4, color: kText),
              )
            else
              const Text(
              'Das kann vorkommen, wenn die Person ein neues Konto oder alle Geräte verloren hat. Es kann aber auch ein Angriff sein. Frage die Person und vergleiche den Sicherheitscode, '
              'bevor du den neuen Schlüssel akzeptierst. Bis dahin vertraut die App ihm nicht.',
              style: TextStyle(fontSize: 13, height: 1.4, color: kText),
            ),
            const SizedBox(height: 8),
            Text('bisher: $alt', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
            if (neu != null) Text('neu:    $neu', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kWarn)),
            const SizedBox(height: 10),
            if (!warnung.rueckfall) ZweitKnopf(text: 'Neuen Schlüssel akzeptieren', icon: Icons.check, onPressed: onAkzeptieren),
          ],
        ),
      ),
    );
  }
}

/// Familien-Sicherheitscode und Codes je Person zum optionalen Vergleichen (vorlesen oder abgleichen, nicht über denselben Chat).
class _SicherheitscodeKarte extends StatelessWidget {
  final E2eeState state;
  final String? eigeneId;
  const _SicherheitscodeKarte({required this.state, required this.eigeneId});

  @override
  Widget build(BuildContext context) {
    final mitSchluessel = state.mitglieder.where((m) => m.schluessel != null && m.status == MemberStatus.active).toList();
    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MonoLabel('// sicherheitscode'),
          const SizedBox(height: 8),
          Semantics(
            label: 'Sicherheitscode der Familie: ${state.sicherheitscode}',
            child: SelectableText(
              state.sicherheitscode.isEmpty ? '–' : state.sicherheitscode,
              style: const TextStyle(fontFamily: kFontMono, fontSize: 18, height: 1.5, color: kAccent, letterSpacing: 1.2),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Dieser Code entsteht aus den öffentlichen Schlüsseln aller Familienmitglieder. Stimmt er auf euren Geräten überein (zum Beispiel beim nächsten Treffen oder am Telefon vorlesen), '
            'hat niemand Schlüssel untergeschoben. Das Vergleichen ist freiwillig.',
            style: TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
          ),
          if (mitSchluessel.isNotEmpty)
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Codes je Person', style: TextStyle(fontSize: 14)),
                children: [
                  for (final m in mitSchluessel)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          BenutzerAvatar(user: m, size: 32),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(m.id == eigeneId ? '${m.displayName} (du)' : m.displayName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                SelectableText(
                                  personenSicherheitscode(MitgliedSchluessel(m.id, m.schluessel!)),
                                  style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Ehrliche Erklärung, was die Verschlüsselung schützt und was nicht.
class _Vertrauensmodell extends StatelessWidget {
  const _Vertrauensmodell();

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      MonoLabel('// was das schützt', color: kTextMuted),
      SizedBox(height: 6),
      Text(
        'Geschützt vor einem Datenleck auf dem Server, vor dem Hoster und vor gestohlenen Sicherungen. '
        'Nicht geschützt: Wer wann mit wem schreibt (Metadaten) sieht der Server weiterhin. '
        'Und ein bösartiger Admin des Servers könnte falsche Schlüssel unterschieben; die App warnt bei Änderungen, '
        'sicher bist du aber erst, wenn ihr den Sicherheitscode einmal vergleicht.',
        style: TextStyle(fontSize: 12, height: 1.5, color: kTextMuted),
      ),
    ],
  );
}

/// Zeile für das Profil: zeigt den Zustand der Verschlüsselung (Warnung bei Schlüsselwechsel).
class VerschluesselungsZeile extends ConsumerWidget {
  final VoidCallback onTap;
  const VerschluesselungsZeile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(e2eeProvider);
    final (String untertitel, Widget? pille) = switch (s.status) {
      _ when s.warnungen.isNotEmpty => ('schlüssel geändert', const RollenPille('Warnung', farbe: kDanger)),
      // grün nur mit bestätigter Sicherung beim Server, sonst "offen"
      E2eeStatus.bereit => ('schlüssel · geräte verbinden', s.sicherungBestaetigt ? const RollenPille('aktiv', farbe: kTerminal) : const RollenPille('offen', farbe: kWarn)),
      E2eeStatus.keinSchluessel => ('nicht eingerichtet', null),
      E2eeStatus.geraetNichtVerbunden => ('gerät verbinden', const RollenPille('offen', farbe: kWarn)),
      E2eeStatus.abweichend => ('schlüssel weicht ab', const RollenPille('Warnung', farbe: kDanger)),
      _ => ('schlüssel · geräte verbinden', null),
    };
    return EinstellungsZeile(icon: Icons.lock_outline, titel: 'Verschlüsselung', untertitel: untertitel, status: pille, onTap: onTap);
  }
}
