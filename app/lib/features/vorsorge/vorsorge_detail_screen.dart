// Detail eines Vorsorge- oder Impf-Eintrags (Abschnitt 6p): Stand, Hinweis und Quelle, die erledigten Termine (zurücknehmbar), Erledigt eintragen, Bearbeiten und Löschen.
// Steht nur auf dem Gerät einer Person, die den Eintrag sehen darf; nichts davon geht über den Server (nur verschlüsselt) und nichts in eine Benachrichtigung.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/vorsorge/vorsorge_logik.dart';
import '../../data/vorsorge/vorsorge_repository.dart';
import '../../data/vorsorge/vorsorge_state.dart';
import '../../data/vorsorge/vorsorge_vorlagen.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../lists/list_dialogs.dart' show bestaetigen;
import 'vorsorge_anzeige.dart';
import 'vorsorge_dialoge.dart';

Future<void> vorsorgeDetailOeffnen(BuildContext context, String id) => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => VorsorgeDetailScreen(id: id)));

class VorsorgeDetailScreen extends ConsumerStatefulWidget {
  final String id;
  const VorsorgeDetailScreen({super.key, required this.id});

  @override
  ConsumerState<VorsorgeDetailScreen> createState() => _VorsorgeDetailScreenState();
}

class _VorsorgeDetailScreenState extends ConsumerState<VorsorgeDetailScreen> {
  String? _fehler;

  Future<void> _tun(Future<void> Function() f) async {
    setState(() => _fehler = null);
    try {
      await f();
    } on Object catch (e) {
      if (mounted) setState(() => _fehler = vorsorgeFehlerText(e));
    }
  }

  Future<void> _loeschen() async {
    final ja = await bestaetigen(context, titel: 'Eintrag löschen?', text: 'Der Eintrag samt allen erledigten Terminen verschwindet auf allen Geräten.', knopf: 'Löschen');
    if (!ja || !mounted) return;
    final nav = Navigator.of(context);
    await _tun(() async {
      await ref.read(vorsorgeRepositoryProvider).loeschen(widget.id);
      if (mounted) nav.pop();
    });
  }

  @override
  Widget build(BuildContext context) {
    final daten = ref.watch(vorsorgeAnsichtProvider);
    final a = daten.eintrag(widget.id);
    if (a == null) {
      // der Eintrag ist weg (gelöscht, Sicht verloren): die Seite schließt sich selbst, nur wenn sie gerade oben liegt
      if (daten.geladen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && (ModalRoute.of(context)?.isCurrent ?? false)) Navigator.of(context).maybePop();
        });
      }
      return const AuthSeite(titel: 'Vorsorge', maxBreite: kMaxContentWidth, kinder: [Text('Den Eintrag gibt es nicht mehr.', style: TextStyle(color: kTextMuted))]);
    }
    final i = a.inhalt;
    final person = daten.person(a.subjektId);
    final wer = a.subjektId.toLowerCase() == daten.ich?.toLowerCase() ? 'Für dich' : 'Für ${person?.displayName.split(RegExp(r'\s+')).first ?? 'ein Kind'}';
    if (i == null) {
      return AuthSeite(
        titel: 'Eintrag',
        label: wer,
        maxBreite: kMaxContentWidth,
        kinder: [Text(a.hinweis ?? 'Dieser Eintrag lässt sich gerade nicht lesen.', style: const TextStyle(color: kTextMuted))],
      );
    }
    final profil = daten.profilVon(a.subjektId);
    final v = vorsorgeVorlage(i.vorlage);
    final heute = vorsorgeHeute();
    final f = vorsorgeFaelligkeit(vorlage: v, eintrag: i, geburt: profil?.geburtTag, geschlecht: profil?.geschlecht, heute: heute);
    final zusatz = vorsorgeVerlaessigkeitText(v);
    return AuthSeite(
      titel: vorsorgeName(v, i),
      label: wer,
      maxBreite: kMaxContentWidth,
      kinder: [
        LxCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(vorsorgeStatusSymbol(f.status), color: f.offen ? kWarn : kTextMuted),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(vorsorgeStandText(f, heute), style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (f.dosenGesamt > 1 && f.status != VorsorgeStatus.erledigt) Text('Dosis ${f.dosis} von ${f.dosenGesamt}', style: const TextStyle(fontSize: 13, color: kTextMuted)),
                    Text(i.art.label, style: const TextStyle(fontSize: 13, color: kTextMuted)),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (profil == null && v != null && !v.nurHinweis) ...[
          const SizedBox(height: 10),
          const Text('Ohne Geburtsdatum kann die App kein Zeitfenster ausrechnen. Trag es auf der Übersicht im Profil ein.', style: TextStyle(color: kTextMuted, fontSize: 13)),
        ],
        if (v != null) ...[
          const SizedBox(height: 14),
          Text(v.hinweis, style: const TextStyle(height: 1.4)),
          if (zusatz != null) ...[const SizedBox(height: 6), Text(zusatz, style: const TextStyle(color: kWarn, fontSize: 13, fontWeight: FontWeight.w600))],
          const SizedBox(height: 8),
          const Text(kVorsorgeHinweis, style: TextStyle(color: kTextMuted, fontSize: 12, height: 1.4)),
          const SizedBox(height: 8),
          const MonoLabel('Quelle', color: kTextMuted),
          const SizedBox(height: 4),
          SelectableText(v.quelle, style: const TextStyle(fontSize: 12, color: kAccent)),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => unawaited(Clipboard.setData(ClipboardData(text: v.quelle))),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Link kopieren'),
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            ),
          ),
        ],
        const SizedBox(height: 10),
        const MonoLabel('Erledigt', color: kTextMuted),
        const SizedBox(height: 6),
        if (i.erledigt.isEmpty) const Text('Noch nichts eingetragen.', style: TextStyle(color: kTextMuted)),
        for (final t in i.erledigt.reversed)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 18, color: kTextMuted),
                const SizedBox(width: 8),
                Expanded(child: Text(vorsorgeTagAnzeige(t), style: const TextStyle(fontFeatures: kZiffern))),
                IconButton(
                  tooltip: 'Eintrag vom ${vorsorgeTagAnzeige(t)} zurücknehmen',
                  icon: const Icon(Icons.close, size: 18),
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  onPressed: () => unawaited(_tun(() => ref.read(vorsorgeRepositoryProvider).erledigtZuruecknehmen(widget.id, t))),
                ),
              ],
            ),
          ),
        if (i.notiz.isNotEmpty) ...[const SizedBox(height: 10), const MonoLabel('Notiz', color: kTextMuted), const SizedBox(height: 4), Text(i.notiz)],
        if (_fehler != null) ...[const SizedBox(height: 10), Text(_fehler!, style: const TextStyle(color: kDanger, fontSize: 13))],
        const SizedBox(height: 18),
        FilledButton.icon(
          onPressed: () => unawaited(vorsorgeErledigtOeffnen(context, id: widget.id)),
          icon: const Icon(Icons.check),
          label: const Text('Erledigt eintragen'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => unawaited(vorsorgeEditorOeffnen(context, subjektId: a.subjektId, bestehend: a)),
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Bearbeiten'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _loeschen,
          icon: const Icon(Icons.delete_outline, color: kDanger),
          label: const Text('Eintrag löschen', style: TextStyle(color: kDanger)),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        ),
      ],
    );
  }
}
