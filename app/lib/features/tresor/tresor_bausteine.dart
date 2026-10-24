// Tresor (Abschnitt 6m), gemeinsame Bausteine der Seiten: `TresorSeite` (Bildschirmschutz auf Android, Eingaben setzen die Auto-Sperre zurück, Unterseiten schließen sich mit der Sperre),
// Weg zum Entsperren (erneute Bestätigung der Person), Hinweiskarte, Zeitangabe.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart' show systemChannelProvider;
import '../../data/tresor/tresor_sperre.dart';
import '../../data/tresor/tresor_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart' show AuthSeite;
import '../auth/step_up.dart';

/// Marke in den Argumenten der Route einer Tresor-Unterseite: so erkennt die Sperre, welche Seiten sie schließen muss.
const String kTresorUnterseite = 'tresor-unterseite';

/// Route einer Unterseite des Tresors (Eintrag ansehen, Editor); sie schließt sich, sobald der Tresor sperrt.
Route<T> tresorUnterseiteRoute<T>(WidgetBuilder builder) => MaterialPageRoute<T>(builder: builder, settings: const RouteSettings(arguments: kTresorUnterseite));

/// Bestätigt die Person erneut, bevor der Tresor aufgeht (Standard: derselbe Dialog wie bei anderen sensiblen Aktionen, also Passkey oder Code, immer mit Rückfrage beim Server).
/// Kein eigenes Passwort und keine PIN: es wird nichts gespeichert. Tests ersetzen den Weg.
final tresorBestaetigenProvider = Provider<Future<bool> Function(BuildContext context)>((ref) {
  return (context) async => await showDialog<bool>(useRootNavigator: false, context: context, barrierDismissible: false, builder: (_) => const StepUpDialog()) == true;
});

/// Fragt die Person und entsperrt bei Erfolg.
Future<bool> tresorEntsperren(BuildContext context, WidgetRef ref) async {
  if (!ref.read(tresorDarfProvider)) return false;
  final ok = await ref.read(tresorBestaetigenProvider)(context);
  if (!ok || !ref.context.mounted) return false;
  ref.read(tresorSperreProvider.notifier).entsperren();
  return true;
}

/// Jede Seite des Tresors steht hierin.
class TresorSeite extends ConsumerStatefulWidget {
  final Widget child;

  /// Unterseite: schließt sich, wenn der Tresor sperrt.
  final bool unterseite;

  /// Bildschirmfotos sperren (Android, FLAG_SECURE); in der Desktop-Shell nur, solange der Bereich zu sehen ist.
  final bool schutz;
  const TresorSeite({super.key, required this.child, this.unterseite = false, this.schutz = true});

  @override
  ConsumerState<TresorSeite> createState() => _TresorSeiteState();
}

class _TresorSeiteState extends ConsumerState<TresorSeite> {
  late final _kanal = ref.read(systemChannelProvider);
  late final _sperre = ref.read(tresorSperreProvider.notifier);
  var _geschuetzt = false;

  @override
  void initState() {
    super.initState();
    _schutzAnpassen();
  }

  @override
  void didUpdateWidget(TresorSeite alt) {
    super.didUpdateWidget(alt);
    _schutzAnpassen();
  }

  void _schutzAnpassen() {
    if (widget.schutz == _geschuetzt) return;
    _geschuetzt = widget.schutz;
    unawaited(_geschuetzt ? _kanal.schuetzen() : _kanal.freigeben());
  }

  @override
  void dispose() {
    if (_geschuetzt) unawaited(_kanal.freigeben());
    super.dispose();
  }

  void _schliessen() {
    if (!mounted) return;
    // alle Tresor-Unterseiten und alles, was darauf liegt (Rückfragen, Blätter); PopScope-Sperren eines Editors gelten hier nicht: der Inhalt geht mit der Sperre bewusst verloren
    Navigator.of(context).popUntil((r) => r is PageRoute && r.settings.arguments != kTresorUnterseite);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.unterseite) {
      ref.listen(tresorSperreProvider.select((s) => s.entsperrt), (alt, neu) {
        if (!neu) scheduleMicrotask(_schliessen);
      });
    }
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, _) {
        _sperre.aktivitaet();
        return KeyEventResult.ignored;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _sperre.aktivitaet(),
        onPointerMove: (_) => _sperre.aktivitaet(),
        onPointerSignal: (_) => _sperre.aktivitaet(),
        child: widget.child,
      ),
    );
  }
}

/// Ruhige Hinweiskarte (Titel + Text), wie im Mockup.
class TresorHinweis extends StatelessWidget {
  final String titel;
  final String text;
  final IconData icon;
  final Color farbe;
  const TresorHinweis({super.key, required this.titel, required this.text, this.icon = Icons.info_outline, this.farbe = kAccent});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$titel. $text',
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: farbe.withValues(alpha: 0.08), border: Border.all(color: farbe.withValues(alpha: 0.35)), borderRadius: BorderRadius.circular(12)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: farbe),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(titel, style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)),
                const SizedBox(height: 2),
                Text(text, style: const TextStyle(color: kTextMuted, height: 1.4, fontSize: 13)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// "14:05" (Uhrzeit auf dem Gerät).
String tresorUhrzeit(DateTime t) {
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// "12.09.2026, 14:05" für den Zeitpunkt der letzten Änderung (Millisekunden seit 1970); null bei 0 (unbekannt).
String? tresorGeaendertText(int ms) {
  if (ms <= 0) return null;
  final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}.${t.year}, ${tresorUhrzeit(t)}';
}

/// Symbol je Kategorie.
IconData tresorKategorieIcon(String wire) => switch (wire) {
  'notfall' => Icons.medical_services_outlined,
  'dokumente' => Icons.description_outlined,
  'zugang' => Icons.key_outlined,
  'haushalt' => Icons.home_outlined,
  _ => Icons.folder_outlined,
};

/// Farbe je Kategorie über die Token der App (keine eigenen Hex-Werte).
Color tresorKategorieFarbe(String wire) => switch (wire) {
  'notfall' => kDanger,
  'zugang' => kWarn,
  'haushalt' => kTerminal,
  'dokumente' => kAccent,
  _ => kNeural,
};

/// Untertitel der Kategorien (Beispiele, kein Inhalt).
String tresorKategorieBeispiele(String wire) => switch (wire) {
  'notfall' => 'Allergien, Blutgruppe, Ärzte',
  'dokumente' => 'Ausweise, Policen, Verträge (Felder und Notizen, Anhänge folgen)',
  'zugang' => 'Alarmcode, Konten, Zählernummern',
  'haushalt' => 'WLAN, Router, Wartungsverträge',
  _ => 'Deine eigene Gruppe',
};

/// Neutrale Seite für alle, die den Tresor nicht sehen dürfen (Kinder, Rollenwechsel zur Laufzeit): kein Hinweis auf Inhalt oder Existenz.
class TresorNichtVerfuegbar extends StatelessWidget {
  final bool eingebettet;
  const TresorNichtVerfuegbar({super.key, required this.eingebettet});

  @override
  Widget build(BuildContext context) {
    const inhalt = Padding(padding: EdgeInsets.all(24), child: EmptyState(icon: Icons.lock_outline, title: 'Nicht verfügbar', hint: 'Diesen Bereich gibt es für dich nicht.'));
    if (eingebettet) return const Material(type: MaterialType.transparency, child: Center(child: inhalt));
    return const AuthSeite(titel: 'Nicht verfügbar', maxBreite: kMaxContentWidth, kinder: [inhalt]);
  }
}
