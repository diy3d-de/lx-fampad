// Ordnerseite (Abschnitt 6n): Freigabe "Familie" oder "Nur Eltern" (nur Eltern und Admins ändern sie; die Datenschicht ordnet die Stapel so, dass die Regel bei jedem Schritt gilt), Hinweis zur Regel,
// Größe, Unterordner sowie Umbenennen, Verschieben und Löschen (Kinder nur für eigene Ordner; ein Ordner mit Inhalt nur durch Eltern). Ist die Freigabe blockiert, erklärt die Seite den Grund und
// bietet an, die übergeordneten Ordner mitzuändern. Beim Verschieben gelten Zyklus- und Tiefenprüfung (höchstens 6 Ebenen).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/dateien/datei_alle.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_modelle.dart';
import '../../data/dateien/datei_repository.dart';
import '../../data/dateien/datei_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart' show zeigeHinweis;
import 'dateien_aktionen.dart';
import 'dateien_bausteine.dart';

class OrdnerScreen extends ConsumerWidget {
  final String ordnerId;
  const OrdnerScreen({super.key, required this.ordnerId});

  static Route<void> route(String id) => MaterialPageRoute<void>(builder: (_) => OrdnerScreen(ordnerId: id));

  Future<void> _umbenennen(BuildContext context, WidgetRef ref, OrdnerZeile o) async {
    final name = await nameAbfragen(context, titel: 'Ordner umbenennen', knopf: 'Umbenennen', start: o.name, label: 'Name des Ordners');
    if (name == null || !context.mounted) return;
    try {
      await ref.read(dateiRepositoryProvider).ordnerUmbenennen(o.id, name);
    } on Object catch (e) {
      if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
    }
  }

  Future<void> _verschieben(BuildContext context, WidgetRef ref, OrdnerZeile o) async {
    final wahl = await ordnerWaehlen(context, ref, titel: 'Ordner verschieben nach', aktuell: o.parentId, audience: o.audience, bewegterOrdner: o.id);
    if (wahl == null || !context.mounted) return;
    try {
      await ref.read(dateiRepositoryProvider).ordnerVerschieben(o.id, wahl.id);
    } on Object catch (e) {
      if (context.mounted) zeigeHinweis(context, dateiFehlerText(e));
    }
  }

  Future<void> _loeschen(BuildContext context, WidgetRef ref, OrdnerZeile o) async {
    // die Seite schließt von selbst, sobald der Ordner aus der Datenbank verschwindet (build)
    await ordnerLoeschenFragen(context, ref, o);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rechte = ref.watch(dateiRechteProvider);
    final alleAsync = ref.watch(alleOrdnerProvider);
    final alle = alleAsync.value ?? const <OrdnerZeile>[];
    final o = alle.where((x) => x.id == ordnerId).firstOrNull;
    if (o == null) {
      if (alleAsync.hasValue) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (context.mounted && (ModalRoute.of(context)?.isCurrent ?? false)) unawaited(Navigator.of(context).maybePop());
        });
      }
      return const DateiRahmen(label: '// ordner', titel: 'Ordner', child: Text('Diesen Ordner gibt es nicht mehr.', style: TextStyle(color: kTextMuted)));
    }
    final dateien = ref.watch(alleDateienProvider).value ?? const <DateiEintrag>[];
    final ids = {o.id, ...unterordnerVonUnten(alle, o.id).map((x) => x.id)};
    final drin = dateien.where((d) => ids.contains(d.datei.ordnerId)).toList();
    final groesse = drin.fold<int>(0, (s, d) => s + d.groesse);
    final unter = ordnerSortiert(alle.where((x) => x.parentId == o.id));
    final eltern = o.audience == kStufeEltern;
    final darfAendern = rechte.darfAendern(o.ownerId);
    return DateiRahmen(
      label: eltern ? '// ordner · nur eltern' : '// ordner · familie',
      titel: o.name,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LxCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const MonoLabel('// freigabe'),
                const SizedBox(height: 8),
                if (rechte.darfStufeAendern)
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      DateiChip(label: 'Familie', icon: Icons.groups_outlined, gewaehlt: !eltern, onTap: () => unawaited(ordnerFreigabeAendern(context, ref, o, kStufeFamilie))),
                      DateiChip(label: 'Nur Eltern', icon: Icons.lock_outline, gewaehlt: eltern, onTap: () => unawaited(ordnerFreigabeAendern(context, ref, o, kStufeEltern))),
                    ],
                  )
                else
                  StufenPille(o.audience),
                const SizedBox(height: 10),
                _Wert('Gilt für', 'Unterordner und Dateien'),
                _Wert('Größe', '${groesseText(groesse)} · ${dateienAnzahlText(drin.length)}'),
              ],
            ),
          ),
          const SizedBox(height: 12),
          DateiHinweis(
            icon: Icons.account_tree_outlined,
            titel: 'Die Freigabe vererbt sich',
            text: eltern
                ? 'Neue Dateien und Unterordner dürfen nicht offener sein als der Ordner. Kinder sehen diesen Ordner und alles darin nicht.'
                : 'Neue Dateien und Unterordner dürfen nicht offener sein als der Ordner. Stellst du ihn auf „Nur Eltern“, ziehen alle Einträge darunter mit.',
          ),
          if (unter.isNotEmpty) ...[
            const SizedBox(height: 16),
            const MonoLabel('// unterordner'),
            const SizedBox(height: 8),
            for (final u in unter)
              EintragZeile(
                vorne: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: kAccent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(10)),
                  child: const ExcludeSemantics(child: Icon(Icons.folder_outlined, color: kAccent)),
                ),
                titel: u.name,
                untertitel: 'Ordner',
                pille: rechte.erwachsen ? StufenPille(u.audience) : null,
                semantik: 'Unterordner ${u.name}. Verwalten',
                onTap: () => unawaited(Navigator.of(context).push<void>(OrdnerScreen.route(u.id))),
              ),
          ],
          const SizedBox(height: 16),
          if (darfAendern) ...[
            ZeilenKnopf(icon: Icons.drive_file_rename_outline, text: 'Ordner umbenennen', onTap: () => unawaited(_umbenennen(context, ref, o))),
            ZeilenKnopf(icon: Icons.drive_file_move_outlined, text: 'Ordner verschieben', onTap: () => unawaited(_verschieben(context, ref, o))),
          ],
          if (rechte.darfLoeschen(o.ownerId)) ZeilenKnopf(icon: Icons.delete_outline, text: 'Ordner löschen', farbe: kDanger, onTap: () => unawaited(_loeschen(context, ref, o))),
        ],
      ),
    );
  }
}

class _Wert extends StatelessWidget {
  final String name;
  final String wert;
  const _Wert(this.name, this.wert);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Semantics(
      container: true,
      label: '$name: $wert',
      excludeSemantics: true,
      child: Wrap(
        spacing: 8,
        children: [
          Text(name, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
          Text(wert, style: const TextStyle(fontSize: 13)),
        ],
      ),
    ),
  );
}

/// Eine Aktion als volle Zeile (mindestens 52 px hoch), mit Symbol und Text.
class ZeilenKnopf extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onTap;
  final Color farbe;
  const ZeilenKnopf({super.key, required this.icon, required this.text, required this.onTap, this.farbe = kText});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      button: true,
      enabled: onTap != null,
      label: text,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: kSurface.withValues(alpha: 0.7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: kBorder)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 52),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: onTap == null ? kTextFaint : (farbe == kText ? kAccent : farbe)),
                  const SizedBox(width: 12),
                  Expanded(child: Text(text, style: TextStyle(color: onTap == null ? kTextMuted : farbe))),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
