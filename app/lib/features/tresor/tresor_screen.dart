// Bereich "Tresor" (Abschnitt 6m): gesperrter Einstieg mit Entsperren, danach die Übersicht (Kategorien mit Zähler, Einträge je Kategorie, Suche, "Eintrag hinzufügen"). Mobil eine Seite
// (Blatt "Mehr"), Desktop ein Bereich der Shell. NUR für Eltern und Admins: wer keine Rolle dafür hat, sieht eine neutrale Seite ohne Inhalt (auch über Seitenleiste oder Rollenwechsel
// zur Laufzeit ist nichts erreichbar). Alles ist Ende-zu-Ende verschlüsselt und gehört allen Eltern gemeinsam; es gibt keinen Push, keine Kachel, keine Erinnerung und keine Suche außerhalb.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/dateien/tresor_anhang_state.dart';
import '../../data/tresor/tresor_daten.dart';
import '../../data/tresor/tresor_logik.dart';
import '../../data/tresor/tresor_modelle.dart';
import '../../data/tresor/tresor_repository.dart' show TresorAnsicht;
import '../../data/tresor/tresor_sperre.dart';
import '../../data/tresor/tresor_state.dart';
import '../../ui/widgets.dart';
import '../../widgets/kopfzeile.dart';
import '../auth/auth_widgets.dart';
import '../shell/desktop_shell.dart' show DesktopShellMarke;
import '../shell/shell_tab.dart';
import 'tresor_bausteine.dart';
import 'tresor_eintrag_screen.dart';
import 'tresor_editor.dart';

/// Öffnet den Bereich als eigene Seite (mobil); im Desktop-Layout ist er ein Bereich der Shell (siehe [tresorOeffnen]).
Route<void> tresorRoute() => MaterialPageRoute<void>(builder: (_) => const TresorScreen());

/// Öffnet den Bereich: im Desktop-Layout als Bereich der Shell, sonst als eigene Seite. Für alle außer Eltern und Admins passiert nichts.
void tresorOeffnen(BuildContext context) {
  final c = ProviderScope.containerOf(context);
  if (!c.read(tresorDarfProvider)) return;
  if (DesktopShellMarke.vorhanden(context)) {
    c.read(shellTabProvider.notifier).waehlen(kTresorTab);
    return;
  }
  unawaited(Navigator.of(context).push<void>(tresorRoute()));
}

class TresorScreen extends ConsumerWidget {
  /// Im Desktop-Layout ein Bereich der Shell: ohne eigenes Gerüst, ohne Zurück-Pfeil, mit der gemeinsamen Kopfzeile.
  final bool eingebettet;
  const TresorScreen({super.key, this.eingebettet = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(tresorDarfProvider)) return TresorNichtVerfuegbar(eingebettet: eingebettet);
    final entsperrt = ref.watch(tresorSperreProvider.select((s) => s.entsperrt));
    // in der Desktop-Shell bleibt der Bereich im Stapel: der Bildschirmschutz gilt nur, solange er zu sehen ist
    final sichtbar = !eingebettet || ref.watch(shellTabProvider) == kTresorTab;
    return TresorSeite(schutz: sichtbar, child: entsperrt ? _Uebersicht(eingebettet: eingebettet) : _Gesperrt(eingebettet: eingebettet));
  }
}

/// Rahmen: mobil eine Seite mit Zurück-Pfeil, im Desktop-Layout ein Bereich mit der gemeinsamen Kopfzeile.
class _Rahmen extends StatelessWidget {
  final bool eingebettet;
  final List<Widget> kinder;
  final Widget? aktion;
  const _Rahmen({required this.eingebettet, required this.kinder, this.aktion});

  @override
  Widget build(BuildContext context) {
    if (!eingebettet) {
      return AuthSeite(label: '// ende-zu-ende verschlüsselt', titel: 'Tresor', maxBreite: kMaxContentWidth, fussleiste: aktion, kinder: kinder);
    }
    return Material(
      type: MaterialType.transparency,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [const TabKopfzeile(title: 'Tresor'), const SizedBox(height: 16), ...kinder, if (aktion != null) ...[const SizedBox(height: 16), aktion!]]),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- gesperrt

class _Gesperrt extends ConsumerStatefulWidget {
  final bool eingebettet;
  const _Gesperrt({required this.eingebettet});

  @override
  ConsumerState<_Gesperrt> createState() => _GesperrtState();
}

class _GesperrtState extends ConsumerState<_Gesperrt> {
  var _laeuft = false;

  Future<void> _entsperren() async {
    setState(() => _laeuft = true);
    try {
      await tresorEntsperren(context, ref);
    } finally {
      if (mounted) setState(() => _laeuft = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Rahmen(
    eingebettet: widget.eingebettet,
    kinder: [
      LxCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const ExcludeSemantics(child: Icon(Icons.lock_outline, size: 40, color: kAccent)),
            const SizedBox(height: 12),
            const Text('Der Tresor ist gesperrt', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kTextStrong)),
            const SizedBox(height: 6),
            const Text('Zum Öffnen bestätigst du noch einmal, dass du es bist (Passkey oder Code).', textAlign: TextAlign.center, style: TextStyle(color: kTextMuted, height: 1.4)),
            const SizedBox(height: 16),
            HauptKnopf(text: 'Tresor entsperren', icon: Icons.lock_open_outlined, laeuft: _laeuft, onPressed: _entsperren),
          ],
        ),
      ),
      const SizedBox(height: 12),
      const TresorHinweis(titel: 'Für alle Eltern', text: 'Der Tresor gehört allen Eltern gemeinsam und liegt Ende-zu-Ende verschlüsselt auf euren Geräten. Der Server sieht nur unlesbare Daten, auch ein Betreiber kann nichts lesen.', icon: Icons.groups_outlined),
      const SizedBox(height: 12),
      TresorHinweis(
        titel: 'Automatisch gesperrt',
        text: 'Nach ${ref.watch(tresorAutoSperreProvider).inMinutes} Minuten ohne Eingabe und beim Wechsel in eine andere App.',
        icon: Icons.timer_outlined,
        farbe: kWarn,
      ),
    ],
  );
}

// ---------------------------------------------------------------- Übersicht

class _Uebersicht extends ConsumerStatefulWidget {
  final bool eingebettet;
  const _Uebersicht({required this.eingebettet});

  @override
  ConsumerState<_Uebersicht> createState() => _UebersichtState();
}

class _UebersichtState extends ConsumerState<_Uebersicht> {
  final _suche = TextEditingController();
  final _offen = <String>{};

  @override
  void dispose() {
    _suche.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(tresorDatenProvider);
    final anfrage = ref.watch(tresorSucheProvider);
    final bis = ref.watch(tresorSperreProvider.select((s) => s.bis));
    final lesbar = daten.lesbare;
    final neuKnopf = FilledButton.icon(
      onPressed: () => tresorEditorOeffnen(context),
      icon: const Icon(Icons.add),
      label: const Text('Eintrag hinzufügen'),
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
    );
    return _Rahmen(
      eingebettet: widget.eingebettet,
      aktion: neuKnopf,
      kinder: [
        Row(
          children: [
            Expanded(
              child: Semantics(
                container: true,
                label: bis == null ? 'Gesperrt' : 'Entsperrt bis ${tresorUhrzeit(bis)} Uhr',
                excludeSemantics: true,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: kTerminal.withValues(alpha: 0.14), border: Border.all(color: kTerminal.withValues(alpha: 0.5)), borderRadius: BorderRadius.circular(999)),
                      child: const Text('ENTSPERRT', style: TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 0.9, color: kTerminal)),
                    ),
                    if (bis != null) Text('bis ${tresorUhrzeit(bis)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: () => ref.read(tresorSperreProvider.notifier).sperren(),
              icon: const Icon(Icons.lock_outline, size: 18),
              label: const Text('Sperren'),
              style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const TresorHinweis(titel: 'Für alle Eltern sichtbar', text: 'Alle Eltern und Admins sehen und bearbeiten alle Einträge hier. Kinder haben keinen Zugriff.', icon: Icons.groups_outlined),
        const SizedBox(height: 12),
        TextField(
          controller: _suche,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.search,
          onChanged: ref.read(tresorSucheProvider.notifier).setzen,
          decoration: InputDecoration(
            labelText: 'Im Tresor suchen',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: anfrage.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Suche leeren',
                    constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _suche.clear();
                      ref.read(tresorSucheProvider.notifier).setzen('');
                    },
                  ),
          ),
        ),
        const SizedBox(height: 12),
        if (!daten.geladen)
          const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
        else if (lesbar.isEmpty && daten.unlesbare.isEmpty)
          const EmptyState(icon: Icons.lock_outline, title: 'Noch nichts im Tresor', hint: 'Lege WLAN-Zugang, Versicherungen oder Notfall-Infos an. Alle Eltern sehen sie.')
        else if (anfrage.trim().isNotEmpty)
          ..._treffer(daten, anfrage)
        else
          ..._kategorien(lesbar),
        if (daten.geladen && daten.unlesbare.isNotEmpty) ...[
          const SizedBox(height: 12),
          TresorHinweis(
            titel: '${daten.unlesbare.length} ${daten.unlesbare.length == 1 ? 'Eintrag lässt' : 'Einträge lassen'} sich gerade nicht lesen',
            text: 'Der Schlüssel fehlt noch oder die App ist zu alt. Öffne die App später noch einmal, nach einem Update oder sobald ein anderes Elternteil online war.',
            icon: Icons.visibility_off_outlined,
            farbe: kWarn,
          ),
        ],
        const SizedBox(height: 12),
        TresorHinweis(
          titel: 'Automatisch gesperrt',
          text: 'Nach ${ref.watch(tresorAutoSperreProvider).inMinutes} Minuten ohne Eingabe und beim Wechsel in eine andere App. Gesucht wird nur in Titeln, Bezeichnungen und offenen Werten, nie in geheimen Werten und Notizen.',
          icon: Icons.timer_outlined,
          farbe: kWarn,
        ),
      ],
    );
  }

  List<Widget> _treffer(TresorDaten daten, String anfrage) {
    final t = tresorTreffer(daten, anfrage);
    if (t.isEmpty) return const [EmptyState(icon: Icons.search_off, title: 'Keine Treffer', hint: 'Probiere ein anderes Wort.')];
    return [for (final e in t) _EintragZeile(e, mitKategorie: true)];
  }

  List<Widget> _kategorien(List<TresorAnsicht> lesbar) {
    final zaehler = tresorKategorieZaehler([for (final e in lesbar) e.inhalt!]);
    // eigene Kategorien: eine Zeile je (gefaltetem) Namen
    final eigene = <String, ({String name, List<TresorAnsicht> eintraege})>{};
    for (final e in lesbar.where((e) => e.inhalt!.kategorie == TresorKategorie.eigene)) {
      final k = foldeText(e.inhalt!.kategorieName.trim());
      final alt = eigene[k];
      eigene[k] = (name: alt?.name ?? e.inhalt!.kategorieName.trim(), eintraege: [...?alt?.eintraege, e]);
    }
    final zeilen = <Widget>[
      for (final k in TresorKategorie.values.where((k) => k != TresorKategorie.eigene))
        _KategorieZeile(
          schluessel: k.wire,
          titel: k == TresorKategorie.notfall ? 'Notfall-Infos' : k.anzeige,
          beispiele: tresorKategorieBeispiele(k.wire),
          icon: tresorKategorieIcon(k.wire),
          farbe: tresorKategorieFarbe(k.wire),
          eintraege: [for (final e in lesbar) if (e.inhalt!.kategorie == k) e],
          anzahl: zaehler[k] ?? 0,
          offen: _offen.contains(k.wire),
          umschalten: () => setState(() => _offen.contains(k.wire) ? _offen.remove(k.wire) : _offen.add(k.wire)),
        ),
      for (final MapEntry(:key, :value) in eigene.entries)
        _KategorieZeile(
          schluessel: 'eigene:$key',
          titel: value.name,
          beispiele: tresorKategorieBeispiele('eigene'),
          icon: tresorKategorieIcon('eigene'),
          farbe: tresorKategorieFarbe('eigene'),
          eintraege: value.eintraege,
          anzahl: value.eintraege.length,
          offen: _offen.contains('eigene:$key'),
          umschalten: () => setState(() => _offen.contains('eigene:$key') ? _offen.remove('eigene:$key') : _offen.add('eigene:$key')),
        ),
    ];
    return [for (final z in zeilen) Padding(padding: const EdgeInsets.only(bottom: 8), child: z)];
  }
}

String _eintraegeWort(int n) => '$n ${n == 1 ? 'Eintrag' : 'Einträge'}';

class _KategorieZeile extends StatelessWidget {
  final String schluessel;
  final String titel;
  final String beispiele;
  final IconData icon;
  final Color farbe;
  final List<TresorAnsicht> eintraege;
  final int anzahl;
  final bool offen;
  final VoidCallback umschalten;
  const _KategorieZeile({required this.schluessel, required this.titel, required this.beispiele, required this.icon, required this.farbe, required this.eintraege, required this.anzahl, required this.offen, required this.umschalten});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        button: true,
        expanded: offen,
        label: '$titel, ${_eintraegeWort(anzahl)}',
        excludeSemantics: true,
        onTap: umschalten,
        child: LxCard(
          onTap: umschalten,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              children: [
                Icon(icon, color: farbe, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(titel, style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)),
                      Text(beispiele, style: const TextStyle(fontSize: 12, color: kTextMuted, height: 1.3)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                  decoration: BoxDecoration(color: kAccentSoft, borderRadius: BorderRadius.circular(999)),
                  child: Text('$anzahl', style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kAccent)),
                ),
                Icon(offen ? Icons.expand_less : Icons.expand_more, color: kTextMuted),
              ],
            ),
          ),
        ),
      ),
      if (offen)
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 6),
          child: eintraege.isEmpty
              ? const Padding(padding: EdgeInsets.symmetric(vertical: 8, horizontal: 4), child: Text('Noch kein Eintrag in dieser Gruppe.', style: TextStyle(color: kTextMuted)))
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final e in eintraege) _EintragZeile(e)]),
        ),
    ],
  );
}

class _EintragZeile extends ConsumerWidget {
  final TresorAnsicht eintrag;
  final bool mitKategorie;
  const _EintragZeile(this.eintrag, {this.mitKategorie = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Zahl der angehängten Dokumente (nur wenn es Dokumente gibt: entsperrt, Dateiablage verfügbar)
    final docs = ref.watch(tresorAnhaengeProvider.select((v) => v.value?.where((a) => a.eintragId == eintrag.id).length ?? 0));
    final i = eintrag.inhalt!;
    final n = i.felder.length;
    final unter = [if (mitKategorie) i.kategorieAnzeige, '$n ${n == 1 ? 'Feld' : 'Felder'}'].join(' · ');
    void oeffnen() => unawaited(Navigator.of(context).push<void>(tresorUnterseiteRoute((_) => TresorEintragScreen(id: eintrag.id))));
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        button: true,
        label: '${i.titel}, $unter${docs > 0 ? ', $docs ${docs == 1 ? 'Dokument' : 'Dokumente'}' : ''}',
        excludeSemantics: true,
        onTap: oeffnen,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: oeffnen,
          child: Container(
            constraints: const BoxConstraints(minHeight: 52),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(border: Border.all(color: kBorderSoft), borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Icon(tresorKategorieIcon(i.kategorie.wire), size: 18, color: tresorKategorieFarbe(i.kategorie.wire)),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(i.titel, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(unter, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                    ],
                  ),
                ),
                if (docs > 0) ...[
                  const Icon(Icons.attach_file, size: 16, color: kTextMuted),
                  Text('$docs', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                  const SizedBox(width: 4),
                ],
                const Icon(Icons.chevron_right, color: kTextMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
