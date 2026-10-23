// Standort teilen: eigenes Teilen starten und beenden, Liste der Personen, die gerade mit mir teilen (Name, Genauigkeit, Alter der Position,
// "zuletzt gesehen vor …"). Alles flüchtig und Ende-zu-Ende verschlüsselt (Erklärung im Text, Verfahren: docs/PROJEKTBESCHREIBUNG.md, 6f).
// Eine Karte kommt später über [standortKartenBuilderProvider] (standort_karte.dart) oberhalb der Liste dazu.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/database_provider.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/lists/members.dart';
import '../../data/standort/standort_dienst.dart';
import '../../data/standort/standort_einstellungen.dart';
import '../../data/standort/standort_hinweis.dart';
import '../../data/standort/standort_modelle.dart';
import '../../ui/widgets.dart';
import '../../widgets/benutzer_avatar.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import '../chat/chat_krypto_ui.dart' show personKryptoHindernis;
import '../lists/list_dialogs.dart' show AuswahlKnopf;
import 'standort_karte.dart';

class StandortScreen extends ConsumerStatefulWidget {
  /// Im Desktop-Layout als Bereich der Shell (Seitenleiste bleibt): ohne eigenen Hintergrund, ohne Zurück-Pfeil. Sonst eigene Seite (mobil, gepusht).
  final bool eingebettet;
  const StandortScreen({super.key, this.eingebettet = false});

  @override
  ConsumerState<StandortScreen> createState() => _StandortScreenState();
}

class _StandortScreenState extends ConsumerState<StandortScreen> with WidgetsBindingObserver {
  Timer? _auffrischen;
  var _dauer = 1;
  var _takt = kStandortTaktStandard;
  Set<String>? _gewaehlt;
  var _beschaeftigt = false;

  late final StandortSeiteOffen _offen;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Die Person sieht die Freigaben jetzt selbst: Hinweise verschwinden, und solange diese Seite (gepusht) offen ist, kommen keine neuen Hinweise
    _offen = ref.read(standortSeiteOffenProvider.notifier);
    final hinweis = ref.read(standortBenachrichtigerProvider);
    Future.microtask(() {
      if (!widget.eingebettet) _offen.setzen(true);
      unawaited(hinweis.alleEntfernen());
    });
    // Alter und Restzeit ("vor 3 Min", "noch 40 Min") aktuell halten
    _auffrischen = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    if (!widget.eingebettet) {
      Future.microtask(() {
        try {
          _offen.setzen(false);
        } catch (_) {
          // der Container ist schon abgebaut (Abmelden)
        }
      });
    }
    WidgetsBinding.instance.removeObserver(this);
    _auffrischen?.cancel();
    super.dispose();
  }

  /// Zurück aus den Android-Einstellungen: Stand der Akkuoptimierung neu lesen.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      ref.invalidate(akkuUneingeschraenktProvider);
      final w = _rueckkehr;
      if (w != null && !w.isCompleted) w.complete();
    }
  }

  /// Wartet auf die Rückkehr aus dem Systemdialog (Akku): ein Vordergrunddienst darf erst aus der sichtbaren App gestartet werden.
  Completer<void>? _rueckkehr;

  /// Beim ersten Teilen mit eingeschränktem Akku (Samsung: "Optimiert") einmal ausdrücklich fragen; danach genügt der Hinweis auf der Seite.
  /// Liefert false, wenn die Person abbricht.
  Future<bool> _akkuHinweis() async {
    final port = ref.read(standortPortProvider);
    final db = ref.read(appDatabaseProvider);
    if (await port.akkuUneingeschraenkt() != false) return true;
    if (await db.metaLesen(kAkkuHinweisGezeigt) != null) return true;
    await db.metaSchreiben(kAkkuHinweisGezeigt, '1');
    if (!mounted) return false;
    final antwort = await showDialog<String>(useRootNavigator: false,
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('Akku: Teilen im Hintergrund'),
        content: const Text(
          'Android bremst Apps im Hintergrund, vor allem bei gesperrtem Bildschirm (bei Samsung: Akku "Optimiert"). Dann bricht das Teilen ab. '
          'Erlaube $kAppName, ohne Einschränkung zu laufen (Akku: "Nicht eingeschränkt").',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop('nein'), child: const Text('Trotzdem teilen')),
          FilledButton(onPressed: () => Navigator.of(c).pop('ja'), child: const Text('Erlauben')),
        ],
      ),
    );
    if (antwort == 'ja') {
      final warten = _rueckkehr = Completer<void>();
      if (await port.akkuAnfragen()) {
        // der Systemdialog liegt über der App: erst nach der Rückkehr geht es weiter (sonst startet der Dienst aus dem Hintergrund und scheitert)
        await warten.future.timeout(const Duration(seconds: 60), onTimeout: () {});
      }
      _rueckkehr = null;
      ref.invalidate(akkuUneingeschraenktProvider);
    }
    return antwort != null;
  }

  DateTime get _jetzt => ref.read(standortUhrProvider)();

  Future<void> _teilen(List<UserDto> andere) async {
    final dauer = kStandortDauern[_dauer].wirksam;
    final waehlen = _gewaehlt ?? const <String>{};
    setState(() => _beschaeftigt = true);
    try {
      if (!await _akkuHinweis()) return;
      final ok = await ref.read(standortProvider.notifier).teilen(dauer: dauer, empfaenger: waehlen, takt: _takt);
      if (!ok && mounted) {
        final m = ref.read(standortProvider).meldung;
        if (m != null) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(SnackBar(content: Text(m)));
        }
      }
    } finally {
      if (mounted) setState(() => _beschaeftigt = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = ref.watch(standortProvider);
    final port = ref.watch(standortPortProvider);
    final mitglieder = ref.watch(mitgliederProvider);
    final ich = ref.watch(authProvider.select((s) => s.user));
    final namen = ref.watch(standortMitgliederProvider);
    final krypto = ref.watch(e2eeProvider);
    final andere = [for (final u in mitglieder.value ?? const <UserDto>[]) if (u.id != ich?.id) u];
    if (_gewaehlt == null && ich != null && andere.isNotEmpty) _gewaehlt = standardEmpfaenger(ich, andere);
    final jetzt = _jetzt;
    final einst = ref.watch(standortEinstellungenProvider);
    final alle = st.geteilt.values.toList()
      ..sort((a, b) => (namen[a.userId]?.displayName ?? '').toLowerCase().compareTo((namen[b.userId]?.displayName ?? '').toLowerCase()));
    // Entfernung zu mir: nur aus dem eigenen Standort, den das Gerät liefert, solange ich selbst teile (nie heimlich abgefragt)
    final eigene = st.phase == StandortPhase.teilt ? st.eigene : null;
    final gefiltert = filterNachDistanz(alle, eigene, einst.distanz);
    final liste = gefiltert.sichtbar;
    final karte = ref.watch(standortKartenBuilderProvider);
    final mitPosition = [for (final p in liste) if (p.hatPosition) p];

    return _huelle(
      ListView(
        // eingebettet wie bei den anderen Bereichen 16 oben; als eigene Seite sitzt der Zurück-Pfeil (48 px) darüber
        padding: EdgeInsets.fromLTRB(20, widget.eingebettet ? 16 : 0, 20, 24),
        children: [
          if (!widget.eingebettet)
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(tooltip: 'Zurück', icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).maybePop()),
            ),
          const TabKopfzeile(title: 'Standort'),
          const SizedBox(height: 16),
          const MonoLabel('// mein standort'),
          const SizedBox(height: 8),
          if (!port.verfuegbar)
            const MeldungsBox('Deinen Standort teilen kannst du nur in der Android-App. Hier siehst du, wer gerade mit dir teilt.', fehler: false)
          else if (st.teilt)
            _Teilen(st: st, namen: namen, jetzt: jetzt)
          else
            _Start(
              st: st,
              andere: andere,
              laedt: mitglieder.isLoading && andere.isEmpty,
              gewaehlt: _gewaehlt ?? const {},
              dauer: _dauer,
              takt: _takt,
              beschaeftigt: _beschaeftigt,
              krypto: krypto,
              onDauer: (i) => setState(() => _dauer = i),
              onTakt: (t) => setState(() => _takt = t),
              onUmschalten: (id) => setState(() {
                final s = {...?_gewaehlt};
                s.contains(id) ? s.remove(id) : s.add(id);
                _gewaehlt = s;
              }),
              onStart: () => unawaited(_teilen(andere)),
            ),
          const SizedBox(height: 24),
          const MonoLabel('// familie'),
          const SizedBox(height: 8),
          if (karte != null && (mitPosition.isNotEmpty || st.eigene != null && st.phase == StandortPhase.teilt)) ...[
            karte(context, mitPosition, namen),
            const SizedBox(height: 12),
          ],
          if (alle.isNotEmpty) ...[_DistanzAuswahl(filter: einst.distanz, eigeneBekannt: eigene != null, ausgeblendet: gefiltert.ausgeblendet), const SizedBox(height: 12)],
          if (alle.isEmpty)
            const LxCard(
              child: EmptyState(icon: Icons.location_off_outlined, title: 'Niemand teilt gerade', hint: 'Wenn jemand aus der Familie seinen Standort teilt, siehst du ihn hier.'),
            )
          else if (liste.isEmpty)
            const LxCard(
              child: EmptyState(icon: Icons.social_distance_outlined, title: 'Niemand in dieser Entfernung', hint: 'Wähle oben eine größere Entfernung oder "Alle".'),
            )
          else
            for (final p in liste) ...[
              _Zeile(
                p: p,
                nutzer: namen[p.userId],
                jetzt: jetzt,
                stumm: einst.istStumm(p.userId),
                entfernung: eigene != null && p.hatPosition ? abstandMeter(eigene.breite, eigene.laenge, p.breite!, p.laenge!) : null,
              ),
              const SizedBox(height: 8),
            ],
          if (port.verfuegbar) ...[const SizedBox(height: 16), const _AkkuHinweis()],
        ],
      ),
    );
  }

  Widget _huelle(Widget liste) {
    if (widget.eingebettet) return Material(type: MaterialType.transparency, child: liste);
    return Scaffold(
      backgroundColor: kBg,
      body: LxBackground(
        child: Material(type: MaterialType.transparency, child: SafeArea(child: LxContentWidth(child: liste))),
      ),
    );
  }
}

/// Startkarte: Erklärung, Dauer, Empfänger, Knopf.
class _Start extends StatelessWidget {
  final StandortState st;
  final List<UserDto> andere;
  final bool laedt;
  final Set<String> gewaehlt;
  final int dauer;
  final StandortTakt takt;
  final bool beschaeftigt;
  final E2eeState krypto;
  final ValueChanged<int> onDauer;
  final ValueChanged<StandortTakt> onTakt;
  final ValueChanged<String> onUmschalten;
  final VoidCallback onStart;
  const _Start({
    required this.st,
    required this.andere,
    required this.laedt,
    required this.gewaehlt,
    required this.dauer,
    required this.takt,
    required this.beschaeftigt,
    required this.krypto,
    required this.onDauer,
    required this.onTakt,
    required this.onUmschalten,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) => LxCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Du entscheidest, wann und mit wem du deinen Standort teilst. Er ist Ende-zu-Ende verschlüsselt, wird nirgends gespeichert und endet automatisch. '
          'Solange du teilst, zeigt dein Handy eine ständige Benachrichtigung, in der du es jederzeit beenden kannst.',
          style: TextStyle(fontSize: 13, color: kTextMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        const MonoLabel('// dauer'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (var i = 0; i < kStandortDauern.length; i++) AuswahlKnopf(text: kStandortDauern[i].label, gewaehlt: dauer == i, onTap: () => onDauer(i))],
        ),
        if (kStandortDauern[dauer].dauer == null) ...[
          const SizedBox(height: 6),
          Text('höchstens ${kStandortHoechstdauer.inHours} Stunden', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
        ],
        const SizedBox(height: 16),
        const MonoLabel('// aktualisierung'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [for (final t in StandortTakt.values) AuswahlKnopf(text: t.label, gewaehlt: takt == t, onTap: () => onTakt(t))],
        ),
        const SizedBox(height: 6),
        const Text('Öfter senden zeigt Bewegungen genauer, kostet aber mehr Akku. Wer still steht, meldet sich seltener.', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
        const SizedBox(height: 16),
        const MonoLabel('// mit wem'),
        const SizedBox(height: 4),
        if (laedt)
          const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()))
        else if (andere.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Es gibt noch keine weiteren Mitglieder.', style: TextStyle(color: kTextMuted)))
        else
          for (final u in andere) _Auswahlzeile(u: u, gewaehlt: gewaehlt.contains(u.id), hindernis: personKryptoHindernis(krypto, u.id), onTap: () => onUmschalten(u.id)),
        const SizedBox(height: 12),
        HauptKnopf(text: 'Standort teilen', icon: Icons.my_location, laeuft: beschaeftigt || st.phase == StandortPhase.startet, onPressed: gewaehlt.isEmpty ? null : onStart),
        if (st.meldung != null) ...[const SizedBox(height: 12), MeldungsBox(st.meldung!)],
      ],
    ),
  );
}

class _Auswahlzeile extends StatelessWidget {
  final UserDto u;
  final bool gewaehlt;
  final String? hindernis;
  final VoidCallback onTap;
  const _Auswahlzeile({required this.u, required this.gewaehlt, required this.hindernis, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    checked: gewaehlt,
    label: '${u.displayName}, ${u.role.label}${hindernis == null ? '' : ', $hindernis'}',
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Row(
          children: [
            BenutzerAvatar(user: u, ersatzName: u.displayName, size: 32),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(u.displayName, maxLines: 2, overflow: TextOverflow.ellipsis),
                  if (hindernis != null) Text(hindernis!, style: const TextStyle(fontSize: 12, color: kWarn)),
                ],
              ),
            ),
            ExcludeSemantics(child: Checkbox(value: gewaehlt, onChanged: (_) => onTap())),
          ],
        ),
      ),
    ),
  );
}

/// Laufende Freigabe: Empfänger, Restzeit, letzte eigene Position, Beenden und Verlängern.
class _Teilen extends ConsumerWidget {
  final StandortState st;
  final Map<String, UserDto> namen;
  final DateTime jetzt;
  const _Teilen({required this.st, required this.namen, required this.jetzt});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ende = st.endetAt;
    final rest = ende?.difference(jetzt);
    final wer = [for (final id in st.empfaenger) namen[id]?.displayName ?? 'Unbekannt']..sort();
    final aus = [for (final id in st.ausgelassen) namen[id]?.displayName ?? 'Unbekannt']..sort();
    final eigene = st.eigene;
    final startet = st.phase == StandortPhase.startet;
    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.my_location, color: kTerminal),
              const SizedBox(width: 10),
              Expanded(child: Text(startet ? 'Teilen wird gestartet …' : 'Du teilst deinen Standort', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))),
              StatusPill(st.verbunden ? '● live' : '● offline', color: st.verbunden ? kTerminal : kTextMuted),
            ],
          ),
          const SizedBox(height: 8),
          Text(wer.isEmpty ? 'mit niemandem' : 'mit ${wer.join(', ')}', style: const TextStyle(color: kText)),
          if (rest != null) ...[
            const SizedBox(height: 4),
            Text(
              rest.isNegative ? 'endet gleich' : 'noch ${_restText(rest)} (bis ${DateFormat('HH:mm').format(ende!)} Uhr)',
              style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            eigene == null
                ? 'Warte auf die erste Position …'
                : 'Letzte Position: ${genauigkeitText(eigene.genauigkeit)}, ${alterText(jetzt.difference(eigene.zeit).isNegative ? Duration.zero : jetzt.difference(eigene.zeit))}',
            style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted),
          ),
          if (st.ortungAus) ...[const SizedBox(height: 12), const MeldungsBox('Die Ortung deines Geräts ist ausgeschaltet. Schalte sie in den Schnellmenüs von Android ein, sonst gibt es nichts zu teilen.')],
          if (!st.verbunden && !startet) ...[const SizedBox(height: 12), const MeldungsBox('Keine Verbindung zum Server. Es wird nichts nachgeschickt; sobald die Verbindung wieder steht, geht die neueste Position raus.', fehler: false)],
          if (aus.isNotEmpty) ...[
            const SizedBox(height: 12),
            MeldungsBox('Nicht geteilt mit ${aus.join(', ')}: der Schlüssel ist nicht bestätigt (Profil, Verschlüsselung).', fehler: false),
          ],
          const SizedBox(height: 16),
          Semantics(
            button: true,
            label: 'Teilen beenden',
            child: FilledButton.icon(
              onPressed: () => unawaited(ref.read(standortProvider.notifier).beenden(grund: 'Du teilst deinen Standort nicht mehr.')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: kDanger, foregroundColor: kBg),
              icon: const Icon(Icons.stop_circle_outlined),
              label: const Text('Teilen beenden'),
            ),
          ),
          const SizedBox(height: 8),
          ZweitKnopf(
            text: '1 Stunde länger',
            icon: Icons.more_time,
            onPressed: startet || st.amGesamtlimit ? null : () => unawaited(ref.read(standortProvider.notifier).verlaengern(const Duration(hours: 1))),
          ),
          if (st.amGesamtlimit)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                standortGesamtlimitText(),
                style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kWarn),
              ),
            ),
          if (st.meldung != null && !st.amGesamtlimit) ...[const SizedBox(height: 8), MeldungsBox(st.meldung!)],
        ],
      ),
    );
  }
}

String _restText(Duration d) {
  if (d.inMinutes < 1) return 'unter 1 Min';
  if (d.inMinutes < 60) return '${d.inMinutes} Min';
  final m = d.inMinutes % 60;
  return m == 0 ? '${d.inHours} Std' : '${d.inHours} Std $m Min';
}

/// Eine Person, die mit mir teilt.
class _Zeile extends StatelessWidget {
  final GeteiltePosition p;
  final UserDto? nutzer;
  final DateTime jetzt;
  final bool stumm;

  /// Luftlinie zu mir in Metern (null: eigener Standort nicht bekannt).
  final double? entfernung;
  const _Zeile({required this.p, required this.nutzer, required this.jetzt, this.stumm = false, this.entfernung});

  @override
  Widget build(BuildContext context) {
    final name = nutzer?.displayName ?? 'Unbekannt';
    final alter = p.alter(jetzt);
    final veraltet = p.veraltet(jetzt);
    final String zeile;
    if (p.ungeprueft) {
      zeile = 'Schlüssel nicht bestätigt, keine Position';
    } else if (!p.hatPosition) {
      zeile = 'wartet auf die erste Position';
    } else if (veraltet) {
      zeile = 'zuletzt gesehen ${alterText(alter!)} · ${genauigkeitText(p.genauigkeit)}';
    } else {
      zeile = '${genauigkeitText(p.genauigkeit)} · ${alterText(alter!)}';
    }
    final rest = p.endetAt.difference(jetzt);
    final entf = entfernung == null ? '' : ' · ${entfernungText(entfernung!)} entfernt';
    final semantik = '$name${stumm ? ', stumm' : ''}, $zeile$entf, teilt noch ${_restText(rest)}';
    return Semantics(
      container: true,
      child: LxCard(
        padding: const EdgeInsets.only(left: 14, right: 4, top: 10, bottom: 10),
        onTap: p.hatPosition ? () => _detail(context) : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              // Text und Tipp auf die Zeile für Screenreader zusammengefasst; der Stumm-Knopf bleibt als eigenes Element erreichbar
              Expanded(
                child: Semantics(
                  container: true,
                  button: p.hatPosition,
                  label: semantik,
                  excludeSemantics: true,
                  onTap: p.hatPosition ? () => _detail(context) : null,
                  child: Row(
                    children: [
                      BenutzerAvatar(user: nutzer, ersatzName: name, size: 36),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(zeile + entf, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: p.ungeprueft || veraltet ? kWarn : kTextMuted)),
                            if (stumm) const Text('stumm: keine Hinweise', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(_restText(rest), style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint)),
                    ],
                  ),
                ),
              ),
              _StummKnopf(userId: p.userId, name: name, stumm: stumm),
            ],
          ),
        ),
      ),
    );
  }

  void _detail(BuildContext context) {
    unawaited(
      showModalBottomSheet<void>(useRootNavigator: false,
        context: context,
        backgroundColor: kSurface,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => StandortDetail(p: p, nutzer: nutzer, jetzt: jetzt, entfernung: entfernung),
      ),
    );
  }
}

/// Einzelheiten zu einer Person: Koordinaten, Genauigkeit, Alter, Restzeit (die Karte zeigt später an derselben Stelle den Marker).
class StandortDetail extends StatelessWidget {
  final GeteiltePosition p;
  final UserDto? nutzer;
  final DateTime jetzt;
  final double? entfernung;
  const StandortDetail({super.key, required this.p, required this.nutzer, required this.jetzt, this.entfernung});

  @override
  Widget build(BuildContext context) {
    final name = nutzer?.displayName ?? 'Unbekannt';
    final alter = p.alter(jetzt);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                BenutzerAvatar(user: nutzer, ersatzName: name, size: 44),
                const SizedBox(width: 12),
                Expanded(child: Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: kTextStrong))),
              ],
            ),
            const SizedBox(height: 16),
            _Zeile2('Position', p.hatPosition ? koordinatenText(p.breite!, p.laenge!) : 'noch keine'),
            _Zeile2('Genauigkeit', genauigkeitText(p.genauigkeit)),
            _Zeile2('Gemessen', alter == null ? 'unbekannt' : '${alterText(alter)} (${DateFormat('HH:mm:ss').format(p.messzeit!)} Uhr)'),
            _Zeile2('Teilt noch', _restText(p.endetAt.difference(jetzt))),
            if (entfernung != null) _Zeile2('Entfernung', '${entfernungText(entfernung!)} Luftlinie'),
            _StummSchalter(userId: p.userId, name: name),
            if (p.veraltet(jetzt)) const Padding(padding: EdgeInsets.only(top: 8), child: MeldungsBox('Die Position ist nicht mehr aktuell. Vielleicht hat die Person gerade keinen Empfang.', fehler: false)),
          ],
        ),
      ),
    );
  }
}

class _Zeile2 extends StatelessWidget {
  final String label;
  final String wert;
  const _Zeile2(this.label, this.wert);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: MonoLabel(label)),
        Expanded(child: Text(wert, style: const TextStyle(fontFamily: kFontMono, fontSize: 13, color: kText))),
      ],
    ),
  );
}

/// Merkt, dass der Hinweis zum Akkuschutz schon einmal gezeigt wurde (sync_meta, nur dieses Gerät).
const kAkkuHinweisGezeigt = 'standort.akkuHinweis';

/// Akkuschutz einiger Hersteller (Samsung u. a.): Er kann Apps im Hintergrund bremsen und damit das Teilen bei gesperrtem Bildschirm. Zeigt den Stand
/// (aus Sicht von Android) und führt zum Systemdialog bzw. zu den Einstellungen.
class _AkkuHinweis extends ConsumerWidget {
  const _AkkuHinweis();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stand = ref.watch(akkuUneingeschraenktProvider).value;
    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MonoLabel('// akku'),
          const SizedBox(height: 8),
          if (stand == true)
            const Text('Akku: nicht eingeschränkt. Das Teilen läuft auch bei gesperrtem Bildschirm weiter.', style: TextStyle(fontSize: 13, color: kTerminal, height: 1.4))
          else ...[
            if (stand == false) ...[
              const MeldungsBox('Der Akku ist für diese App eingeschränkt ("Optimiert"). Das Teilen kann im Hintergrund oder bei gesperrtem Bildschirm abbrechen.'),
              const SizedBox(height: 8),
            ],
            const Text(
              'Bei manchen Handys (zum Beispiel Samsung) beendet der Akkuschutz Apps im Hintergrund. Stelle $kAppName auf "Nicht eingeschränkt" '
              '(bei Samsung: Einstellungen, Akku, Hintergrundnutzungsbegrenzungen, Nie schlafende Apps; oder App-Info, Akku, Nicht eingeschränkt).',
              style: TextStyle(fontSize: 13, color: kTextMuted, height: 1.4),
            ),
            const SizedBox(height: 4),
            if (stand == false)
              ZweitKnopf(
                text: 'Ohne Einschränkung erlauben',
                icon: Icons.battery_charging_full_outlined,
                onPressed: () async {
                  await ref.read(standortPortProvider).akkuAnfragen();
                  ref.invalidate(akkuUneingeschraenktProvider);
                },
              ),
            LinkKnopf(
              'Akku-Einstellungen öffnen',
              icon: Icons.battery_saver_outlined,
              onPressed: () async {
                final ok = await ref.read(standortPortProvider).akkuEinstellungenOeffnen();
                if (!ok && context.mounted) {
                  ScaffoldMessenger.of(context)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(const SnackBar(content: Text('Die Einstellungen ließen sich nicht öffnen. Öffne die Android-Einstellungen, dort Apps und Akku.')));
                }
              },
            ),
          ],
        ],
      ),
    );
  }
}

/// Wirkung von "stumm", ehrlich: nur Hinweise auf diesem Gerät; Liste und Karte zeigen die Person weiter.
const kStummErklaerung =
    'Stumm: kein Hinweis "… teilt seinen Standort" auf diesem Gerät, auch nicht im Hintergrund. Die Person bleibt in Liste und Karte sichtbar. Gilt nur hier und lässt sich jederzeit aufheben.';

/// Kleiner Knopf in der Zeile: Stumm schalten bzw. aufheben (44 px Touch-Ziel).
class _StummKnopf extends ConsumerWidget {
  final String userId;
  final String name;
  final bool stumm;
  const _StummKnopf({required this.userId, required this.name, required this.stumm});

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    tooltip: stumm ? 'Stumm aufheben: $name' : 'Hinweise stumm schalten: $name',
    icon: Icon(stumm ? Icons.notifications_off_outlined : Icons.notifications_none_outlined, size: 20, color: stumm ? kWarn : kTextMuted),
    onPressed: () => unawaited(ref.read(standortEinstellungenProvider.notifier).stummSetzen(userId, !stumm)),
  );
}

/// Schalter mit Erklärung im Detailblatt.
class _StummSchalter extends ConsumerWidget {
  final String userId;
  final String name;
  const _StummSchalter({required this.userId, required this.name});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stumm = ref.watch(standortEinstellungenProvider.select((e) => e.istStumm(userId)));
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text('Hinweise von $name stumm'),
        subtitle: const Text(kStummErklaerung, style: TextStyle(fontSize: 12, color: kTextMuted, height: 1.4)),
        value: stumm,
        onChanged: (v) => unawaited(ref.read(standortEinstellungenProvider.notifier).stummSetzen(userId, v)),
      ),
    );
  }
}

/// Auswahl "Entfernung zu mir": nur mit bekanntem eigenem Standort (der ist nur bekannt, solange ich selbst teile).
class _DistanzAuswahl extends ConsumerWidget {
  final DistanzFilter filter;
  final bool eigeneBekannt;
  final int ausgeblendet;
  const _DistanzAuswahl({required this.filter, required this.eigeneBekannt, required this.ausgeblendet});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final knoepfe = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final f in DistanzFilter.values) AuswahlKnopf(text: f.label, gewaehlt: filter == f, onTap: () => unawaited(ref.read(standortEinstellungenProvider.notifier).distanzSetzen(f)))],
    );
    final String hinweis;
    if (!eigeneBekannt) {
      hinweis = 'Eigener Standort nicht bekannt: Er ist nur bekannt, solange du selbst teilst. Er wird nie heimlich abgefragt, darum ist der Filter aus.';
    } else if (filter.aktiv && ausgeblendet > 0) {
      hinweis = '$ausgeblendet ${ausgeblendet == 1 ? 'Person' : 'Personen'} ausgeblendet (zu weit weg oder noch ohne Position).';
    } else {
      hinweis = 'Luftlinie, lokal auf deinem Gerät berechnet.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const MonoLabel('// entfernung zu mir'),
        const SizedBox(height: 8),
        if (eigeneBekannt)
          knoepfe
        else
          ExcludeSemantics(
            child: IgnorePointer(child: Opacity(opacity: 0.4, child: knoepfe)),
          ),
        const SizedBox(height: 6),
        Text(
          hinweis,
          key: const Key('distanz-hinweis'),
          style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted),
        ),
      ],
    );
  }
}
