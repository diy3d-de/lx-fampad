// Bereich "Dateien" (Abschnitt 6n): Übersicht mit Ordnern und Dateien des aktuellen Ordners, Brotkrumen, Kontingent-Balken, Filter (Alle, Zuletzt, Offline, Von mir), Sortierung und dem Knopf
// "Hochladen". Mobil eine Seite hinter "Mehr", im Desktop-Layout ein Bereich der Shell (Unterseiten laufen dort im Inhalts-Navigator). Der Bereich erscheint nur, wenn der Server die Dateiablage
// meldet (`dateienVerfuegbarProvider`). Dateien erscheinen nirgends sonst (nicht in Suche, Teilen, Wandtablet, Widget, Push, Erinnerungen, Betreiber-Ansicht). Fortschritt von Übertragungen steht
// nur in der Liste der Übertragungen; hier nur ein Hinweis mit der Zahl. Teilen gibt es nur in der Familie (Freigabe), nie per Link nach außen.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/dateien/datei_alle.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_repository.dart';
import '../../data/dateien/datei_state.dart';
import '../../data/dateien/transfer_dienst.dart';
import '../../data/dateien/transfer_modelle.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../shell/shell_tab.dart';
import 'datei_screen.dart';
import 'dateien_aktionen.dart';
import 'dateien_bausteine.dart';
import 'ordner_screen.dart';
import 'uebertragungen_screen.dart';

/// Öffnet den Bereich: im Desktop-Layout als Bereich der Shell, sonst als eigene Seite. Ohne Dateiablage auf dem Server passiert nichts (kein Deep-Link in einen nicht vorhandenen Bereich).
void dateienOeffnen(BuildContext context) {
  final c = ProviderScope.containerOf(context);
  if (!(c.read(dateienVerfuegbarProvider).value ?? false)) return;
  if (DesktopShellMarke.vorhanden(context)) {
    c.read(shellTabProvider.notifier).waehlen(kDateienTab);
    return;
  }
  unawaited(Navigator.of(context).push<void>(MaterialPageRoute<void>(builder: (_) => const DateienScreen())));
}

enum DateiFilter { alle, zuletzt, offline, vonMir }

String _sortText(DateiSortierung s) => switch (s) {
  DateiSortierung.name => 'Name',
  DateiSortierung.geaendert => 'Zuletzt geändert',
  DateiSortierung.groesse => 'Größe',
};

class DateienScreen extends ConsumerStatefulWidget {
  /// Im Desktop-Layout ein Bereich der Shell: ohne eigenes Gerüst, mit der gemeinsamen Kopfzeile.
  final bool eingebettet;
  const DateienScreen({super.key, this.eingebettet = false});

  @override
  ConsumerState<DateienScreen> createState() => _DateienScreenState();
}

class _DateienScreenState extends ConsumerState<DateienScreen> {
  String? _ordnerId;
  var _filter = DateiFilter.alle;
  var _sortierung = DateiSortierung.name;

  void _ordnerWaehlen(String? id) => setState(() {
    _ordnerId = id;
    _filter = DateiFilter.alle;
  });

  Future<void> _hochladen() => hochladenBlattOeffnen(context, ref, ordnerId: _filter == DateiFilter.alle ? _ordnerId : null);

  void _uebertragungen() => unawaited(Navigator.of(context).push<void>(UebertragungenScreen.route()));

  List<Widget> _inhalt() {
    final rechte = ref.watch(dateiRechteProvider);
    final alleAsync = ref.watch(alleOrdnerProvider);
    final alle = alleAsync.value ?? const <OrdnerZeile>[];
    final pfad = ordnerPfad(alle, _ordnerId);
    // der geöffnete Ordner ist weg (auf einem anderen Gerät gelöscht oder nicht mehr sichtbar): zurück nach oben
    if (_ordnerId != null && alleAsync.hasValue && pfad.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _ordnerId = null);
      });
    }
    final cacheDa = ref.watch(dateiCacheDienstProvider).verfuegbar;
    final transfers = ref.watch(dateiTransfersProvider);
    final laufend = transfers.where((z) => z.aktiv).length;
    final fehler = transfers.where((z) => z.zustandTyp == TransferZustand.fehler || z.zustandTyp == TransferZustand.dateiNoetig).length;

    final kinder = <Widget>[
      const KontingentKarte(),
      if (laufend + fehler > 0) ...[
        const SizedBox(height: 8),
        Semantics(
          container: true,
          button: true,
          label: 'Übertragungen: ${[if (laufend > 0) '$laufend ${laufend == 1 ? 'läuft' : 'laufen'}', if (fehler > 0) '$fehler ${fehler == 1 ? 'braucht' : 'brauchen'} dich'].join(', ')}. Öffnen',
          excludeSemantics: true,
          onTap: _uebertragungen,
          child: LxCard(
            onTap: _uebertragungen,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Icon(fehler > 0 ? Icons.error_outline : Icons.sync, size: 18, color: fehler > 0 ? kWarn : kAccent),
                const SizedBox(width: 10),
                Expanded(child: Text([if (laufend > 0) '$laufend ${laufend == 1 ? 'Übertragung läuft' : 'Übertragungen laufen'}', if (fehler > 0) '$fehler ${fehler == 1 ? 'Übertragung braucht dich' : 'Übertragungen brauchen dich'}'].join(' · '), style: const TextStyle(fontSize: 13))),
                const Icon(Icons.chevron_right, color: kTextMuted),
              ],
            ),
          ),
        ),
      ],
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          DateiChip(label: 'Alle', gewaehlt: _filter == DateiFilter.alle, onTap: () => setState(() => _filter = DateiFilter.alle)),
          DateiChip(label: 'Zuletzt', gewaehlt: _filter == DateiFilter.zuletzt, onTap: () => setState(() => _filter = DateiFilter.zuletzt)),
          if (cacheDa) DateiChip(label: 'Offline', gewaehlt: _filter == DateiFilter.offline, onTap: () => setState(() => _filter = DateiFilter.offline)),
          DateiChip(label: 'Von mir', gewaehlt: _filter == DateiFilter.vonMir, onTap: () => setState(() => _filter = DateiFilter.vonMir)),
        ],
      ),
      const SizedBox(height: 4),
      Row(
        children: [
          Expanded(child: _filter == DateiFilter.alle ? Brotkrumen(pfad: pfad, onWaehlen: _ordnerWaehlen) : MonoLabel(_filterName(_filter))),
          PopupMenuButton<DateiSortierung>(
            tooltip: 'Sortieren, jetzt: ${_sortText(_sortierung)}',
            icon: const Icon(Icons.sort),
            initialValue: _sortierung,
            onSelected: (s) => setState(() => _sortierung = s),
            itemBuilder: (_) => [for (final s in DateiSortierung.values) PopupMenuItem(value: s, child: Text(_sortText(s)))],
          ),
          if (_filter == DateiFilter.alle && pfad.isNotEmpty)
            IconButton(tooltip: 'Ordner verwalten', icon: const Icon(Icons.tune), onPressed: () => unawaited(Navigator.of(context).push<void>(OrdnerScreen.route(pfad.last.id)))),
        ],
      ),
      const SizedBox(height: 4),
      ..._liste(rechte, alle, pfad, cacheDa),
    ];
    return kinder;
  }

  String _filterName(DateiFilter f) => switch (f) {
    DateiFilter.alle => 'alle',
    DateiFilter.zuletzt => 'zuletzt',
    DateiFilter.offline => 'offline verfügbar',
    DateiFilter.vonMir => 'von mir',
  };

  List<Widget> _liste(DateiRechte rechte, List<OrdnerZeile> alle, List<OrdnerZeile> pfad, bool cacheDa) {
    if (_filter == DateiFilter.alle) {
      final ordner = ref.watch(ordnerInProvider(_ordnerId));
      final dateien = ref.watch(dateienInProvider(_ordnerId));
      if (ordner.hasError || dateien.hasError) return const [DateiHinweis(icon: Icons.error_outline, text: 'Die Dateien lassen sich gerade nicht lesen.', farbe: kDanger)];
      if (!ordner.hasValue || !dateien.hasValue) return const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))];
      final os = ordner.value!;
      final ds = dateienSortiert<DateiEintrag>([for (final d in dateien.value!) if (!d.ohneFassung) d], _sortierung, name: (d) => d.name, geaendert: (d) => d.geaendert, groesse: (d) => d.groesse);
      if (os.isEmpty && ds.isEmpty) {
        return [
          EmptyState(
            icon: Icons.folder_open_outlined,
            title: _ordnerId == null ? 'Noch keine Dateien' : 'Dieser Ordner ist leer',
            hint: _ordnerId == null ? 'Lade etwas hoch oder lege einen Ordner an.' : 'Lade eine Datei hoch oder lege einen Unterordner an.',
          ),
        ];
      }
      return [for (final o in os) _OrdnerZeile(o, alle, rechte, onOeffnen: () => _ordnerWaehlen(o.id)), for (final d in ds) _DateiZeile(d, alle, rechte)];
    }
    final alleDateien = ref.watch(alleDateienProvider);
    if (alleDateien.hasError) return const [DateiHinweis(icon: Icons.error_outline, text: 'Die Dateien lassen sich gerade nicht lesen.', farbe: kDanger)];
    if (!alleDateien.hasValue) return const [Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))];
    var l = [for (final d in alleDateien.value!) if (!d.ohneFassung) d];
    switch (_filter) {
      case DateiFilter.zuletzt:
        l = dateienSortiert<DateiEintrag>(l, DateiSortierung.geaendert, name: (d) => d.name, geaendert: (d) => d.geaendert, groesse: (d) => d.groesse).take(30).toList();
      case DateiFilter.offline:
        final offline = ref.watch(offlineBlobsProvider).value ?? const <String>{};
        l = l.where((d) => d.neueste != null && offline.contains(d.neueste!.blobId)).toList();
      case DateiFilter.vonMir:
        l = l.where((d) => d.datei.ownerId != null && d.datei.ownerId == rechte.ich).toList();
      case DateiFilter.alle:
        break;
    }
    if (_filter != DateiFilter.zuletzt) l = dateienSortiert<DateiEintrag>(l, _sortierung, name: (d) => d.name, geaendert: (d) => d.geaendert, groesse: (d) => d.groesse);
    if (l.isEmpty) {
      return [
        switch (_filter) {
          DateiFilter.offline => const EmptyState(icon: Icons.offline_pin_outlined, title: 'Keine Offline-Dateien', hint: 'Öffne eine Datei und schalte „Offline verfügbar“ ein.'),
          DateiFilter.vonMir => const EmptyState(icon: Icons.folder_open_outlined, title: 'Noch nichts von dir', hint: 'Dateien, die du hochlädst, stehen hier.'),
          _ => const EmptyState(icon: Icons.folder_open_outlined, title: 'Noch keine Dateien', hint: 'Lade etwas hoch oder lege einen Ordner an.'),
        },
      ];
    }
    return [for (final d in l) _DateiZeile(d, alle, rechte, mitPfad: true)];
  }

  @override
  Widget build(BuildContext context) {
    // Kontingent neu holen, sobald Übertragungen enden
    ref.listen(dateiTransfersProvider, (alt, neu) {
      if (neu.where((z) => z.aktiv).length < (alt?.where((z) => z.aktiv).length ?? 0)) ref.invalidate(dateiNutzungProvider);
    });
    final kinder = _inhalt();
    final hochladenKnopf = FloatingActionButton.extended(onPressed: _hochladen, icon: const Icon(Icons.add), label: const Text('Hochladen'), tooltip: 'Hochladen');
    if (widget.eingebettet) {
      return Material(
        type: MaterialType.transparency,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const TabKopfzeile(title: 'Dateien'),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        FilledButton.icon(onPressed: _hochladen, icon: const Icon(Icons.add), label: const Text('Hochladen')),
                        OutlinedButton.icon(onPressed: _uebertragungen, icon: const Icon(Icons.swap_vert), label: const Text('Übertragungen')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ...kinder,
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return PopScope(
      canPop: _ordnerId == null || _filter != DateiFilter.alle,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        final alle = ref.read(alleOrdnerProvider).value ?? const <OrdnerZeile>[];
        final pfad = ordnerPfad(alle, _ordnerId);
        _ordnerWaehlen(pfad.length >= 2 ? pfad[pfad.length - 2].id : null);
      },
      child: DateiRahmen(
        label: 'Familie',
        titel: 'Dateien',
        knopf: hochladenKnopf,
        aktionen: [IconButton(tooltip: 'Übertragungen', icon: const Icon(Icons.swap_vert), onPressed: _uebertragungen)],
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: kinder),
      ),
    );
  }
}

class _OrdnerZeile extends ConsumerWidget {
  final OrdnerZeile o;
  final List<OrdnerZeile> alle;
  final DateiRechte rechte;
  final VoidCallback onOeffnen;
  const _OrdnerZeile(this.o, this.alle, this.rechte, {required this.onOeffnen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unterordner = alle.where((x) => x.parentId == o.id).length;
    return EintragZeile(
      vorne: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
        child: const ExcludeSemantics(child: Icon(Icons.folder_outlined, color: kAccent)),
      ),
      titel: o.name,
      untertitel: unterordner == 0 ? 'Ordner' : 'Ordner · $unterordner Unterordner',
      pille: rechte.erwachsen ? StufenPille(o.audience) : null,
      semantik: 'Ordner ${o.name}${rechte.erwachsen ? ', ${stufeText(o.audience)}' : ''}. Öffnen',
      onTap: onOeffnen,
      hinten: SizedBox(
        width: 48,
        height: 48,
        child: IconButton(tooltip: 'Ordner ${o.name} verwalten', icon: const Icon(Icons.tune), onPressed: () => unawaited(Navigator.of(context).push<void>(OrdnerScreen.route(o.id)))),
      ),
    );
  }
}

class _DateiZeile extends ConsumerWidget {
  final DateiEintrag d;
  final List<OrdnerZeile> alle;
  final DateiRechte rechte;
  final bool mitPfad;
  const _DateiZeile(this.d, this.alle, this.rechte, {this.mitPfad = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final art = vorschauArt(d.mime, d.name);
    final ort = mitPfad ? ordnerPfadText(alle, d.datei.ordnerId) : '';
    final offline = ref.watch(offlineBlobsProvider).value ?? const <String>{};
    final istOffline = d.neueste != null && offline.contains(d.neueste!.blobId);
    final unter = [groesseText(d.groesse), dateiZeit(d.geaendert), if (mitPfad) ort.isEmpty ? 'oberste Ebene' : ort, if (istOffline) 'offline', if (d.lokalNeu) 'wird gesendet'].join(' · ');
    return EintragZeile(
      vorne: DateiMiniatur(thumbBlobId: d.thumbBlobId, art: art),
      titel: d.name,
      untertitel: unter,
      pille: rechte.erwachsen ? StufenPille(d.audience) : null,
      semantik: '${d.name}, ${groesseText(d.groesse)}, geändert ${dateiZeit(d.geaendert)}${rechte.erwachsen ? ', ${stufeText(d.audience)}' : ''}${istOffline ? ', offline verfügbar' : ''}. Öffnen',
      onTap: () => unawaited(Navigator.of(context).push<void>(DateiScreen.route(d.id))),
    );
  }
}
