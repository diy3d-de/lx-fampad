// Profil › Sicherheit › Nachrichten-Schutz › Eltern-Wiederherstellung (nur wenn der Server sie anbietet): zwei Seiten.
//  - [ElternWiederherstellungScreen] (Kinder-Konten): Zustimmung geben, zurücknehmen, aktualisieren; auf einem Gerät ohne Schlüssel die Eltern um Hilfe bitten (Wartefrist, Kurzcode).
//  - [ElternHilfeScreen] (Admin und Eltern): Kinder, die eine Hinterlegung gemacht haben, und ihre Anfragen: übernehmen, Kurzcode des Kindes eingeben, freigeben oder ablehnen.
// Ablauf und Sicherheitsüberlegung: Projektbeschreibung 9a. Das Kind bleibt immer Herr des Verfahrens: Es stimmt zu, es kann jederzeit abbrechen oder zurücknehmen, und die Eltern
// bekommen nur etwas, wenn es ihnen den Code nennt. Der Server sieht nie einen Schlüssel.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/eltern_modelle.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/eltern_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'profile_screen.dart' show EinstellungsZeile;

String _zeit(DateTime t) => DateFormat('d. MMM yyyy, HH:mm', 'de_DE').format(t.toLocal());

/// Acht Ziffern in zwei Vierergruppen ("1234 5678").
String kurzcodeAnzeige(String code) => code.length == 8 ? '${code.substring(0, 4)} ${code.substring(4)}' : code;

// ------------------------------------------------------------------------------------------------------------------------------ Kinder

class ElternWiederherstellungScreen extends ConsumerStatefulWidget {
  const ElternWiederherstellungScreen({super.key});

  @override
  ConsumerState<ElternWiederherstellungScreen> createState() => _ElternWiederherstellungScreenState();
}

class _ElternWiederherstellungScreenState extends ConsumerState<ElternWiederherstellungScreen> with AktionsZustand<ElternWiederherstellungScreen> {
  AnfrageAnsicht? _ansicht;
  String? _ladeFehler;
  bool _zugestimmt = false;
  String? _hinweis;
  Timer? _takt;
  bool _holt = false;

  ElternSteuerung get _s => ref.read(elternSteuerungProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_aktualisieren());
  }

  @override
  void dispose() {
    _takt?.cancel();
    super.dispose();
  }

  /// Holt den Stand der Anfrage (und führt aus, was dieses Gerät tun muss). Ein laufender Abruf wird nie doppelt gestartet.
  Future<void> _aktualisieren() async {
    if (_holt) return;
    _holt = true;
    AnfrageAnsicht? a;
    String? fehlerText0;
    try {
      a = await _s.anfrageAktualisieren();
    } on Object catch (e) {
      fehlerText0 = fehlerText(e);
    }
    _holt = false;
    if (!mounted) return;
    final warOffen = _ansicht?.anfrage.zustand.offen ?? false;
    setState(() {
      _ansicht = a ?? (fehlerText0 == null ? null : _ansicht);
      _ladeFehler = fehlerText0;
    });
    if (a != null && a.uebernommen) unawaited(ref.read(e2eeProvider.notifier).laden());
    // solange eine Anfrage offen ist, regelmäßig nachsehen (Wartefrist, Übernahme, Freigabe); ein Fehler (kurz offline) beendet das Nachsehen NICHT, wenn der letzte Stand offen war
    final weiter = fehlerText0 != null ? warOffen : (a != null && a.anfrage.zustand.offen);
    if (!weiter) {
      _takt?.cancel();
      _takt = null;
    } else {
      _takt ??= Timer.periodic(const Duration(seconds: 15), (_) => unawaited(_aktualisieren()));
    }
  }

  Future<void> _einwilligen() async {
    EinwilligungErgebnis? r;
    final ok = await ausfuehren(() async {
      final res = await mitStepUp(context, ref, () => _s.einwilligen());
      if (res == null) throw const EingabeFehler('Nicht abgeschlossen. Bestätige mit Passkey oder Code, um es zu speichern.');
      r = res;
    });
    if (ok && mounted && r != null) {
      setState(() {
        _zugestimmt = false;
        _hinweis = 'Deine Eltern (${r!.hinterlegt.join(', ')}) können dir jetzt helfen.${r!.uebersprungen.isEmpty ? '' : ' Noch nicht dabei: ${r!.uebersprungen.join(', ')} (ihr Schlüssel ist diesem Gerät noch nicht bekannt).'}';
      });
    }
  }

  Future<void> _zuruecknehmen() async {
    final ja = await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Eltern-Wiederherstellung zurücknehmen?'),
        content: const Text('Deine Eltern können dir dann nicht mehr helfen, deinen Schlüssel zurückzuholen. Du kannst es jederzeit wieder erlauben.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Zurücknehmen')),
        ],
      ),
    );
    if (ja != true || !mounted) return;
    final ok = await ausfuehren(() async {
      final res = await mitStepUp(context, ref, () async {
        await _s.zuruecknehmen();
        return true;
      });
      if (res != true) throw const EingabeFehler('Nicht abgeschlossen. Bestätige mit Passkey oder Code.');
    });
    if (ok && mounted) {
      setState(() {
        _ansicht = null;
        _hinweis = 'Die Eltern-Wiederherstellung ist zurückgenommen.';
      });
      _takt?.cancel();
    }
  }

  Future<void> _bitten() async {
    final ok = await ausfuehren(() async {
      final res = await mitStepUp(context, ref, () async {
        await _s.anfrageStellen();
        return true;
      });
      if (res != true) throw const EingabeFehler('Nicht abgeschlossen. Bestätige mit Passkey oder Code, um die Anfrage zu stellen.');
    });
    if (ok && mounted) {
      setState(() => _hinweis = null);
      await _aktualisieren();
    }
  }

  Future<void> _abbrechen(String id) async {
    final ok = await ausfuehren(() => _s.anfrageAbbrechen(id));
    if (ok && mounted) {
      setState(() => _hinweis = 'Die Anfrage ist abgebrochen.');
      await _aktualisieren();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(e2eeProvider);
    final stand = ref.watch(hinterlegungProvider).value ?? HinterlegungStand.keine;
    final hatSchluessel = s.status == E2eeStatus.bereit;
    return BildschirmSchutz(
      child: AuthSeite(
        label: 'Eltern-wiederherstellung',
        titel: 'Eltern-Wiederherstellung',
        maxBreite: kMaxContentWidth,
        kinder: [
          const Text(
            'Wenn du alle deine Geräte und deine Sicherungen verlierst, ist dein Chat-Verlauf sonst weg. Mit dieser Funktion können deine Eltern dir helfen, deinen Schlüssel zurückzuholen: '
            'Du erlaubst es einmal, und im Notfall bittest du sie darum. In der App läuft das nur mit deinem Wissen: Es gibt eine Wartefrist, du und deine Eltern bekommen Hinweise, du kannst jederzeit abbrechen, '
            'und deine Eltern geben erst frei, wenn du ihnen einen Code nennst. Der Server sieht deinen Schlüssel nie.',
            style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 8),
          const Text(
            'Bitte bedenke: Mit deiner Erlaubnis liegt eine verschlüsselte Kopie deines Schlüssels beim Server, die jedes dieser Elternteile mit seinem eigenen Schlüssel öffnen kann. '
            'Wer von deinen Eltern außerdem Zugriff auf die Datenbank des Servers hat (zum Beispiel der Betreiber), könnte sie also ohne Wartefrist und ohne dein Wissen öffnen, nicht nur über diese App. '
            'Erlaube es nur Eltern, denen du so weit vertraust. Du kannst es jederzeit zurücknehmen.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kWarn),
          ),
          const SizedBox(height: 16),
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          if (_ladeFehler != null && fehler == null) ...[MeldungsBox(_ladeFehler!), const SizedBox(height: 12)],
          if (_hinweis != null) ...[MeldungsBox(_hinweis!, fehler: false), const SizedBox(height: 12)],
          if (!stand.berechtigt)
            const MeldungsBox('Die Eltern-Wiederherstellung gibt es nur für Kinder-Konten.', fehler: false)
          else ...[
            const MonoLabel('Meine Zustimmung'),
            const SizedBox(height: 8),
            if (stand.aktiv) ..._aktiv(stand, hatSchluessel) else ..._inaktiv(hatSchluessel),
            const SizedBox(height: 20),
            if (!hatSchluessel || _ansicht != null) ..._anfrage(stand, hatSchluessel),
          ],
        ],
      ),
    );
  }

  List<Widget> _inaktiv(bool hatSchluessel) => [
    EinstellungsZeile(icon: Icons.family_restroom, titel: 'Aus', untertitel: 'Deine Eltern können dir nicht helfen.', status: const RollenPille('Aus', farbe: kWarn)),
    const SizedBox(height: 8),
    if (!hatSchluessel)
      const Text('Erlauben kannst du es nur auf einem Gerät, auf dem dein Schlüssel liegt.', style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted))
    else ...[
      CheckboxListTile(
        value: _zugestimmt,
        onChanged: laeuft ? null : (v) => setState(() => _zugestimmt = v ?? false),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('Ich möchte, dass meine Eltern mir helfen dürfen, meinen Schlüssel zurückzuholen.', style: TextStyle(fontSize: 14)),
        subtitle: const Text('Dein Schlüssel wird dafür, für jedes Elternteil einzeln verschlüsselt, abgelegt. Nur dieses Elternteil kann die Kopie mit seinem Schlüssel öffnen.', style: TextStyle(fontSize: 12, color: kTextMuted)),
      ),
      const SizedBox(height: 8),
      HauptKnopf(text: 'Eltern erlauben, mir zu helfen', icon: Icons.family_restroom, laeuft: laeuft, onPressed: _zugestimmt ? _einwilligen : null),
    ],
  ];

  List<Widget> _aktiv(HinterlegungStand stand, bool hatSchluessel) {
    final veraltet = stand.eltern.any((e) => e.veraltet);
    return [
      EinstellungsZeile(
        icon: Icons.family_restroom,
        titel: 'An',
        untertitel: stand.seit == null ? 'Deine Eltern können dir helfen.' : 'seit ${_zeit(stand.seit!)}',
        status: veraltet ? const RollenPille('Aktualisieren', farbe: kWarn) : const RollenPille('Aktiv', farbe: kTerminal),
      ),
      const SizedBox(height: 8),
      for (final e in stand.eltern)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('${e.veraltet ? '⚠ ' : '✓ '}${e.name}${e.veraltet ? ' (veraltet: bitte aktualisieren)' : ''}', style: TextStyle(fontSize: 13, color: e.veraltet ? kWarn : kText)),
        ),
      const SizedBox(height: 8),
      if (hatSchluessel) ...[
        ZweitKnopf(text: 'Hinterlegung aktualisieren', icon: Icons.refresh, onPressed: laeuft ? null : _einwilligen),
        const SizedBox(height: 8),
      ],
      ZweitKnopf(text: 'Zurücknehmen', icon: Icons.block, onPressed: laeuft ? null : _zuruecknehmen),
    ];
  }

  List<Widget> _anfrage(HinterlegungStand stand, bool hatSchluessel) {
    final a = _ansicht?.anfrage;
    final z = a?.zustand;
    return [
      const MonoLabel('Schlüssel zurückholen'),
      const SizedBox(height: 8),
      if (a == null || (z != null && !z.offen && z != AnfrageZustand.fertig)) ...[
        if (z == AnfrageZustand.abgelehnt) const MeldungsBox('Ein Elternteil hat die Anfrage abgelehnt. Sprich mit ihnen und stelle sie bei Bedarf noch einmal.', fehler: false),
        if (z == AnfrageZustand.abgebrochen) const MeldungsBox('Die Anfrage wurde abgebrochen.', fehler: false),
        if (z == AnfrageZustand.abgelaufen) const MeldungsBox('Die Anfrage ist abgelaufen. Du kannst eine neue stellen.', fehler: false),
        if (z != null) const SizedBox(height: 8),
        if (!hatSchluessel && stand.aktiv)
          HauptKnopf(text: 'Meine Eltern um Hilfe bitten', icon: Icons.sos_outlined, laeuft: laeuft, onPressed: _bitten)
        else if (!hatSchluessel)
          const Text('Deine Eltern können dir erst helfen, wenn du es vorher erlaubt hast (auf einem Gerät mit deinem Schlüssel).', style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted)),
      ] else
        ..._laufend(a),
    ];
  }

  List<Widget> _laufend(AnfrageDto a) {
    final code = _ansicht?.kurzcode;
    return [
      switch (a.zustand) {
        AnfrageZustand.wartet => MeldungsBox(
          'Deine Anfrage läuft. Deine Eltern wurden benachrichtigt. Ab ${_zeit(a.bereitAb)} kann ein Elternteil sie übernehmen (Wartefrist). Warst du das nicht, brich sie ab.',
          fehler: false,
        ),
        AnfrageZustand.uebernommen => MeldungsBox('${a.elternteilName ?? 'Ein Elternteil'} hat deine Anfrage übernommen. Einen Moment …', fehler: false),
        AnfrageZustand.offengelegt => MeldungsBox('Nenne ${a.elternteilName ?? 'dem Elternteil'} jetzt diesen Code, persönlich oder am Telefon, nicht per Chat:', fehler: false),
        AnfrageZustand.freigegeben => const MeldungsBox('Freigegeben. Dein Schlüssel wird übernommen …', fehler: false),
        AnfrageZustand.fertig => const MeldungsBox('Dein Schlüssel ist zurück. Dein Chat-Verlauf ist wieder lesbar.', fehler: false),
        _ => const SizedBox.shrink(),
      },
      if (code != null && (a.zustand == AnfrageZustand.offengelegt || a.zustand == AnfrageZustand.freigegeben)) ...[
        const SizedBox(height: 12),
        Semantics(
          label: 'Dein Code: ${code.split('').join(' ')}',
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(kurzcodeAnzeige(code), style: const TextStyle(fontFamily: kFontMono, fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: 3, color: kAccent)),
            ),
          ),
        ),
      ],
      if (_ansicht?.uebernommen == true) ...[const SizedBox(height: 8), const Text('Du kannst diese Seite schließen.', style: TextStyle(fontSize: 13, color: kTextMuted))],
      if (a.zustand.offen) ...[
        const SizedBox(height: 12),
        ZweitKnopf(text: 'Anfrage abbrechen', icon: Icons.close, onPressed: laeuft ? null : () => _abbrechen(a.id)),
      ],
    ];
  }
}

// ------------------------------------------------------------------------------------------------------------------------------ Eltern

class ElternHilfeScreen extends ConsumerStatefulWidget {
  const ElternHilfeScreen({super.key});

  @override
  ConsumerState<ElternHilfeScreen> createState() => _ElternHilfeScreenState();
}

class _ElternHilfeScreenState extends ConsumerState<ElternHilfeScreen> with AktionsZustand<ElternHilfeScreen> {
  final Map<String, TextEditingController> _codes = {};
  Timer? _takt;
  String? _hinweis;

  ElternSteuerung get _s => ref.read(elternSteuerungProvider);

  @override
  void initState() {
    super.initState();
    _takt = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && !laeuft) ref.invalidate(hilfeProvider);
    });
  }

  @override
  void dispose() {
    _takt?.cancel();
    for (final c in _codes.values) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _code(String id) => _codes.putIfAbsent(id, TextEditingController.new);

  Future<void> _tun(String hinweis, Future<void> Function() aktion) async {
    final ok = await ausfuehren(aktion);
    if (mounted) {
      if (ok) setState(() => _hinweis = hinweis);
      ref.invalidate(hilfeProvider);
    }
  }

  Future<void> _uebernehmen(HilfeAnfrage a) => _tun('Du hast die Anfrage übernommen. Sobald das Kind sein Gerät öffnet, erscheint hier die Eingabe für den Code.', () async {
    final r = await mitStepUp(context, ref, () async {
      await _s.uebernehmen(a);
      return true;
    });
    if (r != true) throw const EingabeFehler('Nicht abgeschlossen. Bestätige mit Passkey oder Code.');
  });

  Future<void> _freigeben(HilfeAnfrage a) => _tun('Freigegeben. Das Kind übernimmt seinen Schlüssel jetzt.', () async {
    final code = _code(a.anfrage.id).text;
    if (!RegExp(r'^\s*\d{4}\s?\d{4}\s*$').hasMatch(code)) throw const EingabeFehler('Bitte gib den 8-stelligen Code ein, den das Kind dir nennt.');
    final r = await mitStepUp(context, ref, () async {
      await _s.freigeben(a, code.replaceAll(RegExp(r'\s'), ''));
      return true;
    });
    if (r != true) throw const EingabeFehler('Nicht abgeschlossen. Bestätige mit Passkey oder Code.');
    _code(a.anfrage.id).clear();
  });

  Future<void> _ablehnen(HilfeAnfrage a) => _tun('Die Anfrage ist abgelehnt.', () => _s.ablehnen(a.anfrage.id));

  @override
  Widget build(BuildContext context) {
    final u = ref.watch(hilfeProvider);
    final ich = ref.watch(authProvider.select((a) => a.user?.id));
    final daten = u.value ?? HilfeUebersicht.leer;
    return BildschirmSchutz(
      child: AuthSeite(
        label: 'Kinder helfen',
        titel: 'Kindern helfen',
        maxBreite: kMaxContentWidth,
        kinder: [
          const Text(
            'Kinder können dir erlauben, ihnen bei der Wiederherstellung ihres Schlüssels zu helfen. Hier siehst du, für wen das gilt und ob jemand um Hilfe bittet. '
            'Hilf nur, wenn du mit dem Kind gesprochen hast: Du gibst erst frei, wenn es dir einen Code nennt.',
            style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
          if (_hinweis != null) ...[MeldungsBox(_hinweis!, fehler: false), const SizedBox(height: 12)],
          if (u.isLoading && !u.hasValue) const Center(child: CircularProgressIndicator()),
          if (daten.kinder.isEmpty && !u.isLoading) const MeldungsBox('Noch hat kein Kind dir erlaubt, zu helfen.', fehler: false),
          for (final k in daten.kinder)
            EinstellungsZeile(
              icon: Icons.child_care,
              titel: k.name,
              untertitel: k.veraltet ? 'Die Hinterlegung ist veraltet. Das Kind muss sie aktualisieren.' : 'Du kannst helfen.',
              status: k.veraltet ? const RollenPille('Veraltet', farbe: kWarn) : null,
            ),
          if (daten.anfragen.isNotEmpty) ...[
            const SizedBox(height: 16),
            const MonoLabel('Anfragen'),
            const SizedBox(height: 8),
            for (final a in daten.anfragen) ..._anfrage(a, ich),
          ],
        ],
      ),
    );
  }

  List<Widget> _anfrage(HilfeAnfrage a, String? ich) {
    final z = a.anfrage.zustand;
    final meine = a.anfrage.elternteilId == ich;
    final bereit = a.anfrage.bereit(DateTime.now());
    final kindVeraltet = ref.read(hilfeProvider).value?.kinder.where((k) => k.id == a.kindId).firstOrNull?.veraltet ?? false;
    return [
      LxCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${a.kindName} bittet um Hilfe', style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)),
            const SizedBox(height: 6),
            if (z == AnfrageZustand.wartet && !bereit)
              Text('Wartefrist bis ${_zeit(a.anfrage.bereitAb)}. Bis dahin kannst du nichts tun; sprich in Ruhe mit dem Kind.', style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted)),
            if (z == AnfrageZustand.wartet && bereit && kindVeraltet)
              const Text(
                'Die Hinterlegung dieses Kindes ist veraltet (sein Schlüssel oder dein Schlüssel hat sich geändert): du kannst die Anfrage nicht übernehmen. Das Kind muss die Hinterlegung auf einem Gerät mit seinem Schlüssel aktualisieren.',
                style: TextStyle(fontSize: 13, height: 1.4, color: kWarn),
              ),
            if (z == AnfrageZustand.wartet && bereit && !kindVeraltet) ...[
              const Text('Die Wartefrist ist vorbei. Sprich zuerst mit dem Kind: War es das wirklich? Dann übernimm die Anfrage.', style: TextStyle(fontSize: 13, height: 1.4, color: kTextMuted)),
              const SizedBox(height: 8),
              HauptKnopf(text: 'Anfrage übernehmen', icon: Icons.volunteer_activism_outlined, laeuft: laeuft, onPressed: () => _uebernehmen(a)),
            ],
            if (z == AnfrageZustand.uebernommen)
              Text(meine ? 'Du hast sie übernommen. Warte, bis das Kind sein Gerät öffnet …' : '${a.anfrage.elternteilName ?? 'Ein anderes Elternteil'} kümmert sich darum.', style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted)),
            if (z == AnfrageZustand.offengelegt && meine) ...[
              Text('Frage ${a.kindName} nach dem Code auf seinem Gerät und gib ihn hier ein.', style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted)),
              const SizedBox(height: 8),
              TextField(
                controller: _code(a.anfrage.id),
                enabled: !laeuft,
                keyboardType: TextInputType.number,
                autocorrect: false,
                enableSuggestions: false,
                style: const TextStyle(fontFamily: kFontMono, fontSize: 20, letterSpacing: 2, color: kAccent),
                decoration: const InputDecoration(labelText: 'Code des Kindes (8 Ziffern)'),
              ),
              const SizedBox(height: 8),
              HauptKnopf(text: 'Freigeben', icon: Icons.lock_open, laeuft: laeuft, onPressed: () => _freigeben(a)),
              const SizedBox(height: 8),
              ZweitKnopf(text: 'Ablehnen', icon: Icons.block, onPressed: laeuft ? null : () => _ablehnen(a)),
            ],
            if (z == AnfrageZustand.offengelegt && !meine)
              Text('${a.anfrage.elternteilName ?? 'Ein anderes Elternteil'} kümmert sich darum.', style: const TextStyle(fontSize: 13, color: kTextMuted)),
            if (z == AnfrageZustand.freigegeben) const Text('Freigegeben. Das Kind übernimmt seinen Schlüssel.', style: TextStyle(fontSize: 13, color: kTerminal)),
            if (z == AnfrageZustand.wartet || z == AnfrageZustand.uebernommen) ...[
              const SizedBox(height: 8),
              LinkKnopf('Ablehnen', onPressed: laeuft ? null : () => _ablehnen(a)),
            ],
          ],
        ),
      ),
      const SizedBox(height: 8),
    ];
  }
}
