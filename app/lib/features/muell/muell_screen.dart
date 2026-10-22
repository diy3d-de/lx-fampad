// Seite "Müll" (mobil eine Seite, Desktop ein Bereich der Shell): die nächste Abholung groß, Filter nach Abfallart, kommende Termine nach
// Tag, Legende und die nächste Abholung je Art. Alle Familienmitglieder (auch Kinder) sehen sie; Daten kommen vom eigenen Server (Offline-
// Stand lokal). Einstellungen (Erinnerung nur für Eltern/Admins, Anzeige im Kalender für alle) hinter dem Zahnrad.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/muell/muell_logik.dart';
import '../../data/muell/muell_modelle.dart';
import '../../data/muell/muell_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import 'muell_einstellungen_screen.dart';
import 'muell_widgets.dart';

class MuellScreen extends ConsumerStatefulWidget {
  /// Im Desktop-Layout ein Bereich der Shell (Seitenleiste und Fußzeile bleiben): ohne eigenes Gerüst, ohne Zurück-Pfeil, mit der gemeinsamen Kopfzeile.
  final bool eingebettet;
  const MuellScreen({super.key, this.eingebettet = false});

  @override
  ConsumerState<MuellScreen> createState() => _MuellScreenState();
}

class _MuellScreenState extends ConsumerState<MuellScreen> {
  MuellArt? _filter;
  var _anzahl = _seite;
  static const _seite = 30;

  @override
  void initState() {
    super.initState();
    // beim Öffnen frisch abfragen (nicht während des Aufbaus den Zustand ändern); der Server selbst ruft die Datei nur selten ab
    Future.microtask(() {
      if (mounted) unawaited(ref.read(muellProvider.notifier).aktualisieren());
    });
  }

  void _einstellungen() => unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const MuellEinstellungenScreen())));

  @override
  Widget build(BuildContext context) {
    final z = ref.watch(muellProvider);
    final jetzt = muellJetzt(ref);
    final aktionen = <Widget>[
      IconButton(
        tooltip: 'Aktualisieren',
        icon: z.laedt ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
        onPressed: z.laedt ? null : () => unawaited(ref.read(muellProvider.notifier).aktualisieren()),
      ),
      IconButton(tooltip: 'Einstellungen', icon: const Icon(Icons.settings_outlined), onPressed: _einstellungen),
    ];
    final ort = z.dto?.ort ?? '';
    final kinder = _inhalt(z, jetzt);
    if (!widget.eingebettet) {
      return AuthSeite(label: ort.isEmpty ? '// abfuhrtermine' : '// abfuhrtermine · ${ort.toLowerCase()}', titel: 'Müll', maxBreite: kMaxContentWidth, aktionen: aktionen, kinder: kinder);
    }
    return Material(
      type: MaterialType.transparency,
      child: RefreshIndicator(
        onRefresh: () => ref.read(muellProvider.notifier).aktualisieren(),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Row(children: [const Expanded(child: TabKopfzeile(title: 'Müll')), ...aktionen]),
            if (ort.isNotEmpty) ...[const SizedBox(height: 4), MonoLabel('// $ort')],
            const SizedBox(height: 16),
            ...kinder,
          ],
        ),
      ),
    );
  }

  List<Widget> _inhalt(MuellZustand z, DateTime jetzt) {
    if (!z.hatTermine) {
      return [
        if (z.dto != null && !z.verfuegbar)
          const MeldungsBox('Die Abfuhrtermine sind auf dem Server nicht eingeschaltet.', fehler: false)
        else if (z.fehler && z.dto == null)
          const MeldungsBox('Die Abfuhrtermine konnten nicht geladen werden. Es gibt noch keinen gespeicherten Stand.', fehler: false)
        else if (z.laedt || z.dto == null)
          const MeldungsBox('Die Abfuhrtermine werden geladen …', fehler: false)
        else
          const MeldungsBox('Es liegen noch keine Abfuhrtermine vor.', fehler: false),
      ];
    }
    final heute = muellHeute(jetzt);
    final tage = z.tage;
    final next = naechsteAbholung(tage, heute);
    final arten = vorkommendeArten(tage);
    final kommende = kommendeAbholungen(tage, heute, art: _filter, max: _anzahl + 1);
    final mehr = kommende.length > _anzahl;
    final sichtbar = kommende.take(_anzahl).toList();
    final naechste = _NaechsteKarte(abholung: next, tage: next == null ? 0 : tageBis(next.tag, heute));
    final filter = Wrap(
      spacing: 6,
      runSpacing: 2,
      children: [
        _Chip(label: 'Alle', gewaehlt: _filter == null, onTap: () => setState(() {
          _filter = null;
          _anzahl = _seite;
        })),
        for (final a in arten)
          _Chip(label: a.kurz, art: a, gewaehlt: _filter == a, onTap: () => setState(() {
            _filter = a;
            _anzahl = _seite;
          })),
      ],
    );
    final liste = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('// kommende termine'),
        const SizedBox(height: 4),
        if (sichtbar.isEmpty)
          const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Text('Keine weiteren Termine bekannt.', style: TextStyle(color: kTextMuted)))
        else
          for (final t in sichtbar) _TagZeile(tag: t, heute: heute),
        if (mehr)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: OutlinedButton(onPressed: () => setState(() => _anzahl += _seite), child: const Text('Weitere Termine anzeigen')),
          ),
      ],
    );
    final rechts = <Widget>[
      LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [const MonoLabel('// legende'), const SizedBox(height: 10), MuellLegende(arten: arten.isEmpty ? MuellArt.values : arten)],
        ),
      ),
      const SizedBox(height: 12),
      LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('// nächste je art'),
            const SizedBox(height: 8),
            for (final t in naechsteJeArt(tage, heute)) _JeArtZeile(abholung: t),
          ],
        ),
      ),
    ];
    final stand = z.abgerufen == null ? null : 'Stand ${muellZeitpunkt(z.abgerufen!)}${z.fehler ? ' · offline' : ''}';
    return [
      LayoutBuilder(
        builder: (context, c) {
          final zweispaltig = c.maxWidth >= 640;
          final links = <Widget>[naechste, const SizedBox(height: 12), filter, const SizedBox(height: 8), liste];
          if (!zweispaltig) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...links, const SizedBox(height: 16), ...rechts]);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: links)),
              const SizedBox(width: 16),
              Expanded(flex: 4, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rechts)),
            ],
          );
        },
      ),
      if (stand != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(stand, style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: z.fehler ? kWarn : kTextMuted))),
    ];
  }
}

/// Die nächste Abholung groß: Symbole der Arten, Datum, Namen und Abstand.
class _NaechsteKarte extends StatelessWidget {
  final MuellTag? abholung;
  final int tage;
  const _NaechsteKarte({required this.abholung, required this.tage});

  @override
  Widget build(BuildContext context) {
    final t = abholung;
    return Semantics(
      container: true,
      label: t == null ? 'Nächste Abholung: keine bekannt' : 'Nächste Abholung: ${muellLangDatum(t.tag)}, ${artenText(t.arten)}, ${tageBisText(tage)}',
      excludeSemantics: true,
      child: LxCard(
        gewaehlt: t != null && tage <= 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('// nächste abholung'),
            const SizedBox(height: 10),
            if (t == null)
              const Text('Keine weitere Abholung bekannt', style: TextStyle(color: kTextMuted))
            else
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(child: MuellSymbolReihe(t.arten, groesse: 44)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(muellLangDatum(t.tag), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: kTextStrong, letterSpacing: -0.4)),
                        const SizedBox(height: 2),
                        Text('${artenText(t.arten)} · ${tageBisText(tage)}', style: const TextStyle(fontSize: 14, color: kTextMuted)),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Filter-Chip (mindestens 44 px hoch zum Antippen).
class _Chip extends StatelessWidget {
  final String label;
  final MuellArt? art;
  final bool gewaehlt;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.gewaehlt, required this.onTap, this.art});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: gewaehlt,
    label: art == null ? 'Alle Arten' : art!.name,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        // Align mit widthFactor statt Center: Center füllte im Wrap die ganze Breite, und die Chips stapelten sich untereinander
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: gewaehlt ? kAccent : kSurface,
              border: Border.all(color: gewaehlt ? kAccent : kBorder),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (art != null) ...[Icon(art!.icon, size: 14, color: gewaehlt ? kOnAccent : art!.farbe), const SizedBox(width: 6)],
                Text(label, style: TextStyle(fontSize: 13, color: gewaehlt ? kOnAccent : kTextMuted)),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Ein Tag der Terminliste: Tageszahl links, rechts die Arten (Symbol und Name).
class _TagZeile extends StatelessWidget {
  final MuellTag tag;
  final DateTime heute;
  const _TagZeile({required this.tag, required this.heute});

  @override
  Widget build(BuildContext context) {
    final k = muellTagKopf(tag.tag);
    final bald = tageBis(tag.tag, heute) <= 1;
    return Semantics(
      container: true,
      label: '${muellLangDatum(tag.tag)}, ${artenText(tag.arten)}',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: const BoxDecoration(border: Border(top: BorderSide(color: kBorderSoft))),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 62,
              child: Column(
                children: [
                  Text(k.zahl, style: TextStyle(fontFamily: kFontMono, fontSize: 24, fontWeight: FontWeight.w500, color: bald ? kAccent : kTextStrong, height: 1.1)),
                  Text(k.unten, maxLines: 1, style: const TextStyle(fontFamily: kFontMono, fontSize: 10, letterSpacing: 0.8, color: kTextFaint)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final a in tag.arten)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          MuellSymbol(a),
                          const SizedBox(width: 10),
                          Expanded(child: Text(a.name, style: const TextStyle(fontWeight: FontWeight.w600, color: kText))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JeArtZeile extends StatelessWidget {
  final MuellTag abholung;
  const _JeArtZeile({required this.abholung});

  @override
  Widget build(BuildContext context) {
    final a = abholung.arten.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          MuellSymbol(a, groesse: 22),
          const SizedBox(width: 8),
          Expanded(child: Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: kTextMuted))),
          const SizedBox(width: 8),
          Text(muellKurzDatum(abholung.tag), style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kText)),
        ],
      ),
    );
  }
}
