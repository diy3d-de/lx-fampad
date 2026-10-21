// Bereich "Betrieb" (nur für den Betreiber des Servers, fast nur lesend): Übersicht (Kacheln, Schlüssel-Ampel, Warnungen, Dienste, Funktionen, Versionen,
// Ereignisse), Mitglieder (Mitglieder und Geräte, Paket 2a) und Protokoll (Audit mit Filter). Zeigt nie Geheimnisse, Standorte oder Chat-Inhalte und startet
// nichts auf dem Server; geschrieben wird nur Weniges (Konto entsperren, eigene Warnungen ein/aus), jeweils mit Step-up.
// Unterseite wie das Konto: mobil eine Vollseite, im Desktop-Layout eine Seite im Inhaltsbereich der Shell (Marker [kBetriebMarke]).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/betrieb/betrieb_modelle.dart';
import '../../data/betrieb/betrieb_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'betrieb_anzeige.dart';
import 'betrieb_mitglieder.dart';
import 'betrieb_schluessel.dart';

/// Marker in den Argumenten der Route (kein Routenname, siehe [kKontoMarke]): die Desktop-Shell erkennt daran, dass "Betrieb" offen ist.
const kBetriebMarke = 'betrieb-seite';

class BetriebScreen extends ConsumerStatefulWidget {
  const BetriebScreen({super.key});

  static Route<void> route() => MaterialPageRoute<void>(settings: const RouteSettings(arguments: kBetriebMarke), builder: (_) => const BetriebScreen());

  @override
  ConsumerState<BetriebScreen> createState() => _BetriebScreenState();
}

enum _Seite { uebersicht, mitglieder, protokoll }

class _BetriebScreenState extends ConsumerState<BetriebScreen> {
  _Seite _seite = _Seite.uebersicht;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      unawaited(ref.read(betriebStatusProvider.notifier).laden());
      unawaited(ref.read(betriebSchluesselProvider.notifier).laden());
      unawaited(ref.read(betriebWarnungenProvider.notifier).laden());
      unawaited(_protokollLaden(still: true));
      unawaited(_mitgliederLaden(still: true));
    });
  }

  /// Lädt Mitglieder und Geräte; braucht es ein Step-up, fragt [still] = false danach, sonst bleibt die Seite mit dem Knopf "Bestätigen und anzeigen" stehen.
  Future<void> _mitgliederLaden({bool still = false}) async {
    final n = ref.read(betriebMitgliederProvider.notifier);
    try {
      if (still) {
        await n.laden();
      } else {
        await mitStepUp(context, ref, () => n.laden());
      }
    } on Object {
      // Step-up nötig (still) oder Fehler: steht im Zustand bzw. die Seite bietet "Bestätigen und anzeigen" an
    }
  }

  /// Lädt das Protokoll; braucht es ein Step-up, fragt [still] = false danach, sonst bleibt die Seite mit dem Hinweis stehen.
  Future<void> _protokollLaden({bool still = false, ProtokollArt? art}) async {
    final n = ref.read(betriebProtokollProvider.notifier);
    try {
      if (still) {
        await n.laden(art: art);
      } else {
        await mitStepUp(context, ref, () => n.laden(art: art));
      }
    } on Object {
      // Step-up nötig (still) oder Fehler: steht im Zustand bzw. die Seite bietet "Bestätigen und anzeigen" an
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(betriebStatusProvider);
    // hält das Protokoll am Leben (autoDispose): initState lädt es schon, bevor die Seite es anzeigt
    ref.watch(betriebProtokollProvider.select((p) => p.geladen));
    ref.watch(betriebMitgliederProvider.select((p) => p.geladen));
    // halten Schlüssel-Ampel und Warnstand am Leben (autoDispose): initState lädt sie schon, bevor die Übersicht sie anzeigt
    ref.watch(betriebSchluesselProvider.select((p) => p.wert != null || p.fehler != null));
    ref.watch(betriebWarnungenProvider.select((p) => p.wert != null || p.fehler != null));
    return AuthSeite(
      label: '// betrieb',
      titel: 'Betrieb',
      maxBreite: kMaxContentWidth,
      aktionen: [
        IconButton(
          tooltip: 'Prüfung neu starten',
          icon: st.laedt ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
          onPressed: st.laedt
              ? null
              : () {
                  unawaited(ref.read(betriebStatusProvider.notifier).laden(frisch: true));
                  unawaited(ref.read(betriebSchluesselProvider.notifier).laden());
                  unawaited(ref.read(betriebWarnungenProvider.notifier).laden());
                  // auch die Ereignisse und Mitglieder neu laden; auf den anderen Seiten still (ohne Step-up-Abfrage), auf der eigenen Seite mit
                  unawaited(_protokollLaden(still: _seite != _Seite.protokoll));
                  unawaited(_mitgliederLaden(still: _seite != _Seite.mitglieder));
                },
        ),
      ],
      kinder: [
        _Reiterleiste(
          reiter: [
            ('Übersicht', _seite == _Seite.uebersicht, () => setState(() => _seite = _Seite.uebersicht)),
            (
              'Mitglieder',
              _seite == _Seite.mitglieder,
              () {
                setState(() => _seite = _Seite.mitglieder);
                if (!ref.read(betriebMitgliederProvider).geladen) unawaited(_mitgliederLaden());
              },
            ),
            (
              'Protokoll',
              _seite == _Seite.protokoll,
              () {
                setState(() => _seite = _Seite.protokoll);
                if (!ref.read(betriebProtokollProvider).geladen) unawaited(_protokollLaden());
              },
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_seite == _Seite.uebersicht)
          _Uebersicht(
            oeffneProtokoll: () {
              setState(() => _seite = _Seite.protokoll);
              unawaited(_protokollLaden());
            },
            oeffneMitglieder: () {
              setState(() => _seite = _Seite.mitglieder);
              if (!ref.read(betriebMitgliederProvider).geladen) unawaited(_mitgliederLaden());
            },
            protokollBestaetigen: () => _protokollLaden(),
          )
        else if (_seite == _Seite.mitglieder)
          BetriebMitgliederSeite(neuLaden: () => _mitgliederLaden())
        else
          _Protokoll(neuLaden: _protokollLaden),
      ],
    );
  }
}

/// Die Reiter der Seite: nebeneinander, bei großer Schrift (Textskala) untereinander, damit nichts abgeschnitten wird.
class _Reiterleiste extends StatelessWidget {
  final List<(String, bool, VoidCallback)> reiter;
  const _Reiterleiste({required this.reiter});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final grosseSchrift = MediaQuery.textScalerOf(context).scale(10) > 12;
      final spalten = grosseSchrift ? 1 : reiter.length;
      final breite = (c.maxWidth - (spalten - 1) * 8) / spalten;
      return Wrap(spacing: 8, runSpacing: 8, children: [for (final (text, gewaehlt, onTap) in reiter) SizedBox(width: breite, child: _Reiter(text: text, gewaehlt: gewaehlt, onTap: onTap))]);
    },
  );
}

class _Reiter extends StatelessWidget {
  final String text;
  final bool gewaehlt;
  final VoidCallback onTap;
  const _Reiter({required this.text, required this.gewaehlt, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: gewaehlt,
    label: text,
    excludeSemantics: true,
    child: Material(
      color: gewaehlt ? kAccentSoft : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: gewaehlt ? kAccent : kBorder)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w700, color: gewaehlt ? kAccent : kText)),
        ),
      ),
    ),
  );
}

// ------------------------------------------------------------------ Übersicht

class _Uebersicht extends ConsumerWidget {
  final VoidCallback oeffneProtokoll;
  final VoidCallback oeffneMitglieder;
  final Future<void> Function() protokollBestaetigen;
  const _Uebersicht({required this.oeffneProtokoll, required this.oeffneMitglieder, required this.protokollBestaetigen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(betriebStatusProvider);
    final s = st.status;
    if (s == null) {
      return st.fehler != null
          ? MeldungsBox(fehlerText(st.fehler!))
          : const MeldungsBox('Der Zustand wird geladen …', fehler: false);
    }
    final jetzt = DateTime.now();
    final farbe = gesamtFarbe(s.gesamt, unbekannt: s.unbekannt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (st.fehler != null) ...[MeldungsBox('${fehlerText(st.fehler!)} Angezeigt wird der letzte Stand.'), const SizedBox(height: 12)],
        Semantics(
          liveRegion: true,
          child: Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              StatusPill('● ${gesamtText(s.gesamt, unbekannt: s.unbekannt)}', color: farbe),
              Text('Stand ${uhrzeit(s.erzeugt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Kacheln(s: s, jetzt: jetzt),
        const SizedBox(height: 20),
        FamilienAmpelKarte(oeffneMitglieder: oeffneMitglieder),
        const SizedBox(height: 20),
        const WarnungenKarte(),
        const SizedBox(height: 20),
        const MonoLabel('// dienste'),
        const SizedBox(height: 8),
        _Dienste(s: s, jetzt: jetzt),
        const SizedBox(height: 4),
        const Text('Neustart und Konfiguration bewusst nur per SSH auf dem Server.', style: TextStyle(fontSize: 12, color: kTextMuted)),
        const SizedBox(height: 20),
        const MonoLabel('// funktionen'),
        const SizedBox(height: 8),
        _Funktionen(s: s),
        const SizedBox(height: 20),
        const MonoLabel('// versionen'),
        const SizedBox(height: 8),
        _Versionen(s: s),
        const SizedBox(height: 20),
        _Ereignisse(oeffneProtokoll: oeffneProtokoll, bestaetigen: protokollBestaetigen, jetzt: jetzt),
        const SizedBox(height: 16),
        const Text(
          'Das Dashboard zeigt nie Geheimnisse (Schlüssel, Token, Passwörter, Standorte, Chat-Inhalte) und startet keine Systembefehle.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}

class _Kachel extends StatelessWidget {
  final String label;
  final String wert;
  final String hinweis;
  final Color farbe;
  const _Kachel({required this.label, required this.wert, required this.hinweis, required this.farbe});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '${label.replaceFirst('// ', '')}: $wert, $hinweis',
    excludeSemantics: true,
    child: LxCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MonoLabel(label),
          const SizedBox(height: 6),
          Text(wert, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: farbe)),
          const SizedBox(height: 4),
          Text(hinweis, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
        ],
      ),
    ),
  );
}

class _Kacheln extends StatelessWidget {
  final BetriebStatus s;
  final DateTime jetzt;
  const _Kacheln({required this.s, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final mig = s.migrationen;
    final backup = s.sicherung;
    final platte = s.platte;
    final kacheln = [
      _Kachel(label: '// server', wert: s.serverVersion, hinweis: 'online seit ${laufzeitText(s.laufzeitSekunden)}', farbe: kTerminal),
      _Kachel(
        label: '// datenbank',
        wert: s.datenbankOk ? groesseText(s.datenbankBytes) : 'Störung',
        hinweis: !s.datenbankOk
            ? 'nicht erreichbar'
            : (mig.angewendet == null ? (mig.grantFehlt ? 'Migrationsstand unbekannt: Grant fehlt, siehe README' : 'Migrationsstand unbekannt') : 'Migrationen ${mig.angewendet} von ${mig.erwartet ?? '?'}'),
        farbe: s.datenbankOk ? kText : kDanger,
      ),
      _Kachel(
        label: '// letzte sicherung',
        wert: backup.letzterErfolg == null ? 'unbekannt' : uhrzeit(backup.letzterErfolg!),
        hinweis: backup.letzterErfolg == null
            ? 'Statusdatei nicht lesbar'
            : '${zeitText(backup.letzterErfolg!, jetzt)} · ${groesseText(backup.bytes)}',
        farbe: backup.stufe == BetriebStufe.unbekannt ? kTextMuted : stufeFarbe(backup.stufe),
      ),
      _Kachel(
        label: '// speicher',
        wert: platte == null ? 'unbekannt' : '${platte.belegtProzent} %',
        hinweis: platte == null ? 'nicht ermittelbar' : '${groesseText(platte.gesamt - platte.frei)} von ${groesseText(platte.gesamt)} belegt',
        farbe: platte == null ? kTextMuted : (platte.belegtProzent >= 95 ? kDanger : (platte.belegtProzent >= 85 ? kWarn : kText)),
      ),
      _Kachel(label: '// mitglieder', wert: '${s.mitglieder}', hinweis: '${s.geraete} Geräte · ${s.sitzungen} Sitzungen', farbe: kText),
    ];
    return LayoutBuilder(
      builder: (context, c) {
        // große Schrift: eine Spalte, sonst brechen die Kacheln um
        final grosseSchrift = MediaQuery.textScalerOf(context).scale(10) > 13;
        final spalten = grosseSchrift ? 1 : (c.maxWidth >= 600 ? 3 : 2);
        final breite = (c.maxWidth - (spalten - 1) * 10) / spalten;
        return Wrap(spacing: 10, runSpacing: 10, children: [for (final k in kacheln) SizedBox(width: breite, child: k)]);
      },
    );
  }
}

class _Zeile extends StatelessWidget {
  final String name;
  final String info;
  final Widget pille;
  const _Zeile({required this.name, required this.info, required this.pille});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(info, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // begrenzt (lange Versionskennungen brechen um, statt die Zeile zu sprengen)
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 150), child: pille),
        ],
      ),
    ),
  );
}

class _Liste extends StatelessWidget {
  final List<Widget> zeilen;
  const _Liste(this.zeilen);

  @override
  Widget build(BuildContext context) => LxCard(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
    child: Column(
      children: [
        for (var i = 0; i < zeilen.length; i++) ...[if (i > 0) const Divider(height: 1, color: kBorderSoft), zeilen[i]],
      ],
    ),
  );
}

class _Dienste extends StatelessWidget {
  final BetriebStatus s;
  final DateTime jetzt;
  const _Dienste({required this.s, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    String? z(String id, String k) => s.dienst(id)?.detail[k]?.toString();
    BetriebStufe stufe(String id) => s.dienst(id)?.stufe ?? BetriebStufe.unbekannt;
    final w = s.dienst('weather');
    final wetterInfo = switch (w?.stufe) {
      BetriebStufe.aus => 'ausgeschaltet',
      BetriebStufe.fehler => 'Zugangsdaten ungültig, neu einrichten',
      BetriebStufe.warn when w?.detail['configured'] == false => 'keine Zugangsdaten gespeichert',
      BetriebStufe.warn || BetriebStufe.ok => z('weather', 'lastOkMinutesAgo') == null ? 'noch kein Abruf' : 'Letzter Abruf ${vorText(Duration(minutes: int.tryParse(z('weather', 'lastOkMinutesAgo')!) ?? 0))}',
      _ => 'Zustand unbekannt',
    };
    final ms = s.datenbankMs;
    final tage = s.zertifikatTage;
    final zeilen = <(String, String, BetriebStufe, String)>[
      ('lx-fampad (API)', 'Version ${s.serverVersion} · ${s.speicherMb} MB RAM', stufe('api'), 'läuft'),
      (
        'PostgreSQL',
        s.datenbankOk ? 'Antwort ${ms ?? '?'} ms · ${groesseText(s.datenbankBytes)}${s.migrationen.ausstehend == true ? ' · Migration ausstehend' : ''}${s.migrationen.angewendet == null ? (s.migrationen.grantFehlt ? ' · Grant fehlt, siehe README' : '') : ''}' : 'nicht erreichbar',
        stufe('database'),
        'läuft',
      ),
      ('lx-fampad-weather', wetterInfo, stufe('weather'), 'läuft'),
      (
        'ntfy (Push-Wecker)',
        stufe('ntfy') == BetriebStufe.aus ? 'ausgeschaltet' : (stufe('ntfy') == BetriebStufe.ok ? 'UnifiedPush · ${s.pushGeraete} Geräte angemeldet' : 'lokal nicht erreichbar'),
        stufe('ntfy'),
        'läuft',
      ),
      (
        'Caddy (geteilt mit lx-labs.dev)',
        s.zertifikatBis == null ? 'nur lesen: Zertifikat nicht ermittelbar' : 'nur lesen: Zertifikat gültig bis ${datumText(s.zertifikatBis!)}${tage == null ? '' : ' (noch $tage Tage)'}',
        stufe('caddy'),
        'gültig',
      ),
    ];
    return _Liste([
      for (final (name, info, stufeWert, okText) in zeilen)
        _Zeile(name: name, info: info, pille: StatusPill(stufeText(stufeWert, okText: okText), color: stufeFarbe(stufeWert))),
    ]);
  }
}

class _Funktionen extends StatelessWidget {
  final BetriebStatus s;
  const _Funktionen({required this.s});

  @override
  Widget build(BuildContext context) {
    Widget pille(bool an, {String ja = 'an', String nein = 'aus'}) => StatusPill(an ? ja : nein, color: an ? kTerminal : kTextMuted);
    return _Liste([
      _Zeile(name: 'Wetter anzeigen', info: 'Dienst + Konfiguration', pille: pille(s.schalterWetter)),
      _Zeile(name: 'Push-Wecker (ntfy)', info: 'Server-Konfiguration', pille: pille(s.schalterPush)),
      _Zeile(name: 'Passwort-Sicherung', info: 'E2EE_PW_BACKUP · Server-Datei, Neustart', pille: pille(s.schalterPwSicherung)),
      _Zeile(name: 'Klartext-Passwort-Anmeldung', info: 'AUTH_LEGACY_PASSWORD_LOGIN · Server-Datei, Neustart', pille: pille(s.schalterKlartextLogin)),
      _Zeile(name: 'Karte (PMTiles)', info: s.karteDa ? 'Datei vorhanden · ${groesseText(s.karteBytes)}' : 'keine Datei gefunden', pille: pille(s.karteDa, ja: 'da', nein: 'fehlt')),
    ]);
  }
}

class _Versionen extends StatelessWidget {
  final BetriebStatus s;
  const _Versionen({required this.s});

  @override
  Widget build(BuildContext context) {
    final app = s.appVersion;
    Widget version(String? v) => Text(v ?? 'unbekannt', textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontMono, fontSize: 13, color: v == null ? kTextMuted : kText));
    return _Liste([
      _Zeile(name: 'Server', info: 'Protokoll ${s.protokoll} · Migrationen ${s.migrationen.letzte?.substring(0, 4) ?? 'unbekannt'}', pille: version(s.serverVersion)),
      _Zeile(name: 'Web-App', info: 'ausgelieferter Build', pille: version(s.webVersion)),
      _Zeile(name: 'Android-App', info: 'Release-Manifest', pille: version(app == null ? null : '${app.version}${app.versionCode == null ? '' : '+${app.versionCode}'}')),
      _Zeile(name: 'Mindestversion App', info: 'ältere Apps müssen aktualisieren', pille: version(s.mindestversionApp)),
    ]);
  }
}

class _Ereignisse extends ConsumerWidget {
  final VoidCallback oeffneProtokoll;
  final Future<void> Function() bestaetigen;
  final DateTime jetzt;
  const _Ereignisse({required this.oeffneProtokoll, required this.bestaetigen, required this.jetzt});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(betriebProtokollProvider);
    final neueste = p.eintraege.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: MonoLabel('// ereignisse')),
            TextButton(onPressed: oeffneProtokoll, style: TextButton.styleFrom(minimumSize: const Size(44, 44)), child: const Text('Alle ansehen')),
          ],
        ),
        if (!p.geladen)
          p.fehler != null
              ? MeldungsBox(fehlerText(p.fehler!))
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Das Protokoll nennt Personen und Netze und braucht deshalb eine frische Bestätigung.', style: TextStyle(fontSize: 13, color: kTextMuted)),
                    const SizedBox(height: 8),
                    ZweitKnopf(text: 'Bestätigen und anzeigen', icon: Icons.verified_user_outlined, onPressed: p.laedt ? null : () => unawaited(bestaetigen())),
                  ],
                )
        else if (neueste.isEmpty)
          const Text('Noch keine Einträge.', style: TextStyle(color: kTextMuted))
        else
          _Liste([for (final e in neueste) _EintragZeile(e: e, jetzt: jetzt)]),
      ],
    );
  }
}

// ------------------------------------------------------------------ Protokoll

class _EintragZeile extends StatelessWidget {
  final ProtokollEintrag e;
  final DateTime jetzt;
  const _EintragZeile({required this.e, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final wer = [if (e.person != null) e.person!, if (e.netz != null) e.netz!].join(' · ');
    final text = ereignisText(e.ereignis);
    final zeit = zeitText(e.zeit, jetzt);
    return Semantics(
      container: true,
      label: '$zeit, $text${wer.isEmpty ? '' : ', $wer'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(padding: const EdgeInsets.only(top: 5), child: Icon(Icons.circle, size: 9, color: artFarbe(e.art))),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(zeit, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                    if (wer.isNotEmpty) Text(wer, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Protokoll extends ConsumerWidget {
  final Future<void> Function({bool still, ProtokollArt? art}) neuLaden;
  const _Protokoll({required this.neuLaden});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(betriebProtokollProvider);
    final jetzt = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('// audit-protokoll'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in ProtokollArt.values)
              Semantics(
                button: true,
                selected: p.art == a,
                label: 'Filter ${a.label}',
                excludeSemantics: true,
                child: Material(
                  color: p.art == a ? kAccentSoft : Colors.transparent,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: BorderSide(color: p.art == a ? kAccent : kBorder)),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => unawaited(neuLaden(art: a)),
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(a.label, style: TextStyle(fontWeight: FontWeight.w600, color: p.art == a ? kAccent : kText)),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (p.fehler != null) ...[MeldungsBox(fehlerText(p.fehler!)), const SizedBox(height: 12)],
        if (!p.geladen && p.fehler == null)
          p.laedt
              ? const MeldungsBox('Das Protokoll wird geladen …', fehler: false)
              : ZweitKnopf(text: 'Bestätigen und anzeigen', icon: Icons.verified_user_outlined, onPressed: () => unawaited(neuLaden())),
        if (p.geladen && p.eintraege.isEmpty) const Text('Keine Einträge in dieser Auswahl.', style: TextStyle(color: kTextMuted)),
        if (p.eintraege.isNotEmpty) _Liste([for (final e in p.eintraege) _EintragZeile(e: e, jetzt: jetzt)]),
        if (p.weiter != null) ...[
          const SizedBox(height: 12),
          ZweitKnopf(text: p.laedt ? 'Lädt …' : 'Ältere Einträge laden', icon: Icons.expand_more, onPressed: p.laedt ? null : () => unawaited(ref.read(betriebProtokollProvider.notifier).mehr())),
        ],
        const SizedBox(height: 12),
        const Text(
          'Das Protokoll enthält nie Inhalte, Schlüssel oder Standorte, nur Art, Zeit, Person und gekürzte Netzadresse. Es wird nur angehängt und nie bearbeitet.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}
