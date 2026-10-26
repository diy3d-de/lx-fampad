// Oberfläche der Chat-Verschlüsselung: Hinweis zum Einrichten, Warnung bei Schlüsselwechsel einer Person, Bestätigung der Mitglieder mit Aufforderung zum Vergleich des
// Sicherheitscodes (Pflicht beim Hinzufügen zu einer Konversation) und die Meldungen zu Fehlern der Verschlüsselung. Texte duzen, sagen nie "E2EE".
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../data/auth/auth_state.dart';
import '../../data/chat/chat_krypto.dart';
import '../../data/chat/chat_krypto_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../ui/widgets.dart';
import '../profile/verschluesselung_screen.dart';

/// Wie weit diese Person und dieses Gerät für verschlüsselte Chats bereit sind.
enum ChatKryptoZustand {
  /// Schlüssel eingerichtet und mit diesem Gerät verbunden.
  bereit,

  /// Noch kein Schlüssel eingerichtet: ohne ihn kein Lesen und Schreiben.
  einrichten,

  /// Schlüssel beim Server, aber nicht auf diesem Gerät.
  verbinden,

  /// Der Schlüssel dieses Geräts passt nicht zum Konto.
  abweichend,

  /// Noch nicht geprüft (lädt) oder offline: nichts blockieren (der Ausgang hält Nachrichten zurück, bis es geht).
  unbekannt,
}

ChatKryptoZustand chatKryptoZustand(E2eeState s) => switch (s.status) {
  E2eeStatus.bereit => ChatKryptoZustand.bereit,
  E2eeStatus.keinSchluessel => ChatKryptoZustand.einrichten,
  E2eeStatus.geraetNichtVerbunden => ChatKryptoZustand.verbinden,
  E2eeStatus.abweichend => ChatKryptoZustand.abweichend,
  _ => ChatKryptoZustand.unbekannt,
};

extension ChatKryptoZustandX on ChatKryptoZustand {
  /// Darf die Person schreiben (und neue Chats anlegen)?
  bool get darfSchreiben => this == ChatKryptoZustand.bereit || this == ChatKryptoZustand.unbekannt;
}

/// Hinweis im Chat-Bereich, solange die Nachrichten-Schutz nicht bereit ist; führt zu Profil › Sicherheit › Nachrichten-Schutz.
class VerschluesselungHinweis extends ConsumerWidget {
  /// Als Karte über der Liste (true) oder als schlanke Zeile statt der Eingabe (false).
  final bool gross;
  const VerschluesselungHinweis({super.key, this.gross = true});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final zustand = chatKryptoZustand(ref.watch(e2eeProvider));
    if (zustand.darfSchreiben) return const SizedBox.shrink();
    final (titel, text, knopf) = switch (zustand) {
      ChatKryptoZustand.einrichten => (
        'Nachrichten-Schutz einrichten',
        'Deine Chats sind Ende-zu-Ende verschlüsselt. Richte deinen Schlüssel ein (und sichere ihn), dann kannst du Nachrichten lesen und schreiben.',
        'Einrichten',
      ),
      ChatKryptoZustand.verbinden => (
        'Gerät verbinden',
        'Dein Schlüssel liegt noch nicht auf diesem Gerät. Verbinde es mit einem anderen Gerät oder mit deinem Wiederherstellungsschlüssel.',
        'Verbinden',
      ),
      _ => (
        'Schlüssel prüfen',
        'Der Schlüssel auf diesem Gerät passt nicht zu deinem Konto. Prüfe den Nachrichten-Schutz in deinem Profil.',
        'Prüfen',
      ),
    };
    return Container(
      margin: gross ? const EdgeInsets.fromLTRB(16, 8, 16, 4) : const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      decoration: BoxDecoration(color: kSurface, border: Border.all(color: kWarn.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.lock_outline, size: 18, color: kWarn),
              const SizedBox(width: 8),
              Expanded(child: Semantics(header: true, child: Text(titel, style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)))),
            ],
          ),
          const SizedBox(height: 4),
          Text(text, style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted)),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const VerschluesselungScreen())),
              child: Text(knopf),
            ),
          ),
        ],
      ),
    );
  }
}

/// Warnung im Chat, wenn eine Person der Konversation einen neuen Schlüssel hat, den du noch nicht bestätigt hast. Neue Nachrichten erreichen sie erst danach.
class SchluesselWechselHinweis extends ConsumerWidget {
  /// Die Personen der Konversation (leer beim Familienchat: alle Warnungen zählen).
  final Set<String> personen;
  const SchluesselWechselHinweis({super.key, required this.personen});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final e = ref.watch(e2eeProvider);
    final betroffen = [for (final w in e.warnungen) if (personen.isEmpty || personen.contains(w.userId)) w.userId];
    if (betroffen.isEmpty) return const SizedBox.shrink();
    final namen = [for (final id in betroffen) e.mitglieder.where((m) => m.id == id).firstOrNull?.displayName ?? 'Eine Person'];
    final wer = namen.length == 1 ? namen.first : '${namen.take(2).join(' und ')}${namen.length > 2 ? ' u. a.' : ''}';
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        decoration: BoxDecoration(color: kSurface, border: Border.all(color: kDanger.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 20, color: kDanger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Der Schlüssel von $wer hat sich geändert. Neue Nachrichten erreichen ${namen.length == 1 ? 'die Person' : 'diese Personen'} erst, wenn du den neuen Schlüssel bestätigt hast.',
                style: const TextStyle(fontSize: 13, height: 1.35, color: kText),
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const VerschluesselungScreen())),
              child: const Text('Prüfen'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ergebnis der Bestätigung: ob der Verlauf mit den neuen Mitgliedern geteilt werden soll.
class MitgliederBestaetigung {
  final bool verlaufTeilen;
  const MitgliederBestaetigung({required this.verlaufTeilen});
}

/// Zeigt die Mitglieder eines Chats (Namen, Schlüsselversion) und fordert zum Vergleich des Familien-Sicherheitscodes auf, bevor Personen hinzugefügt werden.
/// Pflicht beim Anlegen einer Konversation und beim Hinzufügen von Personen: ein untergeschobener Schlüssel fällt nur durch den Vergleich außerhalb der App auf.
/// [personen] sind die künftigen Mitglieder ohne dich, [neu] die neu hinzukommenden (Hinweis), [entfernt] die Entfernten (Hinweis).
Future<MitgliederBestaetigung?> mitgliederBestaetigen(
  BuildContext context, {
  required String titel,
  required List<String> personen,
  Set<String> neu = const {},
  Set<String> entfernt = const {},
  bool verlaufFrage = false,
  String knopf = 'Weiter',
}) => showDialog<MitgliederBestaetigung>(useRootNavigator: false,
  context: context,
  builder: (_) => _MitgliederDialog(titel: titel, personen: personen, neu: neu, entfernt: entfernt, verlaufFrage: verlaufFrage, knopf: knopf),
);

class _MitgliederDialog extends ConsumerStatefulWidget {
  final String titel;
  final List<String> personen;
  final Set<String> neu;
  final Set<String> entfernt;
  final bool verlaufFrage;
  final String knopf;
  const _MitgliederDialog({required this.titel, required this.personen, required this.neu, required this.entfernt, required this.verlaufFrage, required this.knopf});

  @override
  ConsumerState<_MitgliederDialog> createState() => _MitgliederDialogState();
}

class _MitgliederDialogState extends ConsumerState<_MitgliederDialog> {
  bool _verlauf = false;

  @override
  Widget build(BuildContext context) {
    final e = ref.watch(e2eeProvider);
    UserDto? von(String id) => e.mitglieder.where((m) => m.id == id).firstOrNull;
    final ichId = ref.watch(authProvider.select((s) => s.user?.id));
    final eigen = e.mitglieder.where((m) => m.schluessel != null && m.id == ichId).firstOrNull;
    return AlertDialog(
      backgroundColor: kSurface,
      scrollable: true,
      title: Text(widget.titel),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const MonoLabel('Mitglieder'),
          const SizedBox(height: 6),
          if (eigen != null) _Zeile(name: '${eigen.displayName} (du)', farbe: eigen.colorIndex, version: eigen.schluessel?.version),
          for (final id in widget.personen)
            _Zeile(
              name: von(id)?.displayName ?? 'Unbekannt',
              farbe: von(id)?.colorIndex ?? 0,
              version: von(id)?.schluessel?.version,
              neu: widget.neu.contains(id),
            ),
          if (widget.entfernt.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Entfernt: ${[for (final id in widget.entfernt) von(id)?.displayName ?? 'Unbekannt'].join(', ')}. Sie können neue Nachrichten nicht mehr lesen; Nachrichten, die sie schon haben, bleiben bei ihnen.',
              style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
            ),
          ],
          const SizedBox(height: 12),
          const MonoLabel('Sicherheitscode'),
          const SizedBox(height: 6),
          Semantics(
            label: 'Sicherheitscode der Familie: ${e.sicherheitscode}',
            child: SelectableText(e.sicherheitscode.isEmpty ? '–' : e.sicherheitscode, style: const TextStyle(fontFamily: kFontMono, fontSize: 15, height: 1.5, color: kAccent)),
          ),
          const SizedBox(height: 6),
          const Text(
            'Vergleiche diesen Code mit den anderen, zum Beispiel am Telefon oder beim nächsten Treffen. Stimmt er bei allen überein, hat niemand Schlüssel untergeschoben. '
            'Ändert sich der Code einer Person später, warnt dich die App.',
            style: TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
          ),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48), padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
            onPressed: () => Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const VerschluesselungScreen())),
            child: const Text('Codes je Person ansehen'),
          ),
          if (widget.verlaufFrage && widget.neu.isNotEmpty)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _verlauf,
              onChanged: (v) => setState(() => _verlauf = v ?? false),
              title: const Text('Bisherigen Verlauf mit den Neuen teilen', style: TextStyle(fontSize: 14)),
              subtitle: const Text('Ohne Haken sehen sie nur neue Nachrichten.', style: TextStyle(fontSize: 12, color: kTextMuted)),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.of(context).pop(MitgliederBestaetigung(verlaufTeilen: _verlauf)), child: Text(widget.knopf)),
      ],
    );
  }
}

class _Zeile extends StatelessWidget {
  final String name;
  final int farbe;
  final int? version;
  final bool neu;
  const _Zeile({required this.name, required this.farbe, required this.version, this.neu = false});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        PersonAvatar(name: name, colorIndex: farbe, size: 28),
        const SizedBox(width: 10),
        Expanded(child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis)),
        if (neu) const Padding(padding: EdgeInsets.only(right: 6), child: Text('neu', style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kAccent))),
        Text(version == null ? 'ohne Schlüssel' : 'schlüssel v$version', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
      ],
    ),
  );
}

/// Meldung zu einem Fehler beim Anlegen oder Ändern eines verschlüsselten Chats (null: kein bekannter Fall).
String? kryptoFehlerText(Object e, List<UserDto> mitglieder) {
  if (e is SchluesselFehlt) {
    final namen = [for (final id in e.personen) mitglieder.where((m) => m.id == id).firstOrNull?.displayName ?? 'Eine Person'];
    return namen.length == 1
        ? '${namen.first} hat den Nachrichten-Schutz noch nicht eingerichtet oder den neuen Schlüssel noch nicht bestätigt bekommen. Erst danach geht es.'
        : '${namen.join(', ')} haben den Nachrichten-Schutz noch nicht eingerichtet oder ihren Schlüssel noch nicht bestätigt bekommen. Erst danach geht es.';
  }
  if (e is VerschluesselungNichtBereit) return e.meldung;
  return null;
}

/// Für die Auswahl einer Person: Grund, warum sie nicht (oder nur eingeschränkt) in einen verschlüsselten Chat kann; null: kein Hindernis oder unbekannt.
String? personKryptoHindernis(E2eeState s, String userId) {
  if (s.mitglieder.isEmpty) return null; // Stand unbekannt (offline): nichts behaupten
  final m = s.mitglieder.where((x) => x.id == userId).firstOrNull;
  if (m == null || m.schluessel == null) return 'Nachrichten-Schutz noch nicht eingerichtet';
  if (s.warnungen.any((w) => w.userId == userId)) return 'Schlüssel nicht bestätigt';
  return null;
}

/// Frage im Chat, wenn jemand zur Konversation hinzugekommen ist, ohne dass dieses Gerät den Schlüssel dafür weitergegeben hat ("X wurde zu Y hinzugefügt –
/// Schlüssel teilen?"). Der Schlüssel geht nie automatisch an Neue: sonst kämen Personen über ein neues Konto oder eine geänderte Teilnehmerliste ungefragt hinein.
class AufnahmeHinweis extends ConsumerWidget {
  final String konversationId;
  final String chatName;
  const AufnahmeHinweis({super.key, required this.konversationId, required this.chatName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(chatKryptoProvider);
    final neu = ref.read(chatKryptoProvider.notifier).aufnahmen[konversationId];
    if (neu == null || neu.isEmpty) return const SizedBox.shrink();
    final e = ref.watch(e2eeProvider);
    final namen = [for (final id in neu) e.mitglieder.where((m) => m.id == id).firstOrNull?.displayName ?? 'Eine Person'];
    final wer = namen.length == 1 ? namen.first : '${namen.take(2).join(' und ')}${namen.length > 2 ? ' u. a.' : ''}';
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        decoration: BoxDecoration(color: kSurface, border: Border.all(color: kWarn.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(12)),
        child: Row(
          children: [
            const Icon(Icons.group_add_outlined, size: 20, color: kWarn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$wer ${namen.length == 1 ? 'wurde' : 'wurden'} zu „$chatName“ hinzugefügt. Schlüssel teilen? Nur wenn du die ${namen.length == 1 ? 'Person' : 'Personen'} erwartest.',
                style: const TextStyle(fontSize: 13, height: 1.35, color: kText),
              ),
            ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () async {
                    final ok = await ref.read(chatKryptoProvider.notifier).aufnahmeBestaetigen(konversationId);
                    if (!ok && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Das geht gerade nicht. Versuche es gleich noch einmal.')));
                    }
                  },
                  child: const Text('Teilen'),
                ),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: () => ref.read(chatKryptoProvider.notifier).aufnahmeSpaeter(konversationId),
                  child: const Text('Später'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
