// Bewusste Reparatur des sicheren Speichers (Android): Mit resetOnError: false heilt sich der Speicher bei verlorenem Keystore-Schlüssel nicht mehr von selbst
// (siehe data/crypto/sicherer_speicher.dart). Dieser Knopf erscheint unter der Fehlermeldung "Gerätespeicher defekt" (MeldungsBox) und im Defektbild der Verschlüsselung.
// Nur auf Klick, nie automatisch, und nur, wenn eine Probe den Speicher nachweislich als defekt zeigt. Die Rückfrage erklärt ehrlich, was verloren geht, und verlangt ein
// getipptes Wort (wie "Gerät abgeben"). Danach wird sauber abgemeldet und neu angefangen.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/sicherer_speicher.dart';
import '../profile/wort_bestaetigung.dart';

/// Ablauf "Gerätespeicher zurücksetzen": Probe, Rückfrage mit Wort, Zurücksetzen, abmelden. Meldet jedes Ergebnis über [meldung] (Hinweis oder Fehler).
/// Gibt true zurück, wenn der Speicher zurückgesetzt wurde.
Future<bool> geraeteSpeicherZuruecksetzen(
  BuildContext context,
  WidgetRef ref, {
  required void Function(String text) meldung,
}) async {
  final speicher = ref.read(geraeteSpeicherProvider);
  final auth = ref.read(authProvider.notifier);
  final angemeldet = ref.read(authProvider).status == AuthStatus.angemeldet;
  final gesichert = geraetAbgabeLage(ref.read(e2eeProvider)) == GeraetAbgabeLage.moeglich;

  // nur bei nachweislich dauerhaftem Defekt (zwei Proben nacheinander scheitern): ein vorübergehender Aussetzer bleibt unberührt
  final defekt = await speicher.nachweislichDefekt();
  if (!context.mounted) return false;
  if (!defekt) {
    meldung('Der Gerätespeicher antwortet wieder. Es wurde nichts zurückgesetzt; versuche es noch einmal.');
    return false;
  }
  final ja = await wortBestaetigen(
    context,
    titel: 'Gerätespeicher zurücksetzen?',
    text:
        'Der sichere Speicher dieses Geräts (Android-Schlüsselspeicher) ist dauerhaft defekt: Die App kann dort nichts mehr lesen oder ablegen. '
        'Beim Zurücksetzen wird alles gelöscht, was die App darin hält: deine Anmeldung, dein Schlüssel auf diesem Gerät (er ist ohnehin nicht mehr lesbar) '
        'und die gemerkten Schlüssel der Familie. Dein Konto und deine Chats auf dem Server bleiben. '
        'Danach meldest du dich neu an und verbindest dieses Gerät mit deinem Wiederherstellungsschlüssel, deiner Passwort-Sicherung oder von einem anderen Gerät mit deinem Schlüssel.',
    haken: [
      if (!gesichert)
        'Ich weiß: Ohne bestätigte Sicherung (Wiederherstellungsschlüssel oder Passwort-Sicherung) und ohne ein anderes Gerät mit meinem Schlüssel kommt mein Chat-Verlauf nicht zurück.',
    ],
    wort: 'zurücksetzen',
    knopf: 'Zurücksetzen',
  );
  if (!ja) return false;
  try {
    await speicher.zuruecksetzen();
  } on Object {
    meldung('Das Zurücksetzen hat nicht geklappt. Lösche die App-Daten in den Android-Einstellungen (Apps › lx-fampad › Speicher).');
    return false;
  }
  // sauber neu anfangen: Sitzung (auf dem Server, soweit erreichbar) und lokale Daten weg, die App zeigt die Anmeldung
  try {
    await auth.abmelden(nurLokal: !angemeldet);
  } on Object {
    // der Speicher ist zurückgesetzt; die Anmeldung erscheint beim nächsten Start in jedem Fall
  }
  meldung('Der Gerätespeicher ist zurückgesetzt. Melde dich neu an${angemeldet ? ' und verbinde dieses Gerät wieder mit deinem Schlüssel' : ''}.');
  return true;
}

/// Knopf "Gerätespeicher zurücksetzen" (nur Android; im Web gibt es diesen Speicher nicht).
class GeraeteSpeicherKnopf extends ConsumerStatefulWidget {
  const GeraeteSpeicherKnopf({super.key});

  @override
  ConsumerState<GeraeteSpeicherKnopf> createState() => _GeraeteSpeicherKnopfState();
}

class _GeraeteSpeicherKnopfState extends ConsumerState<GeraeteSpeicherKnopf> {
  bool _laeuft = false;

  Future<void> _klick() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _laeuft = true);
    try {
      await geraeteSpeicherZuruecksetzen(
        context,
        ref,
        meldung: (t) => messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(duration: const Duration(seconds: 10), content: Text(t))),
      );
    } finally {
      if (mounted) setState(() => _laeuft = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: OutlinedButton.icon(
        onPressed: _laeuft ? null : _klick,
        style: OutlinedButton.styleFrom(foregroundColor: kDanger, side: const BorderSide(color: kDanger), minimumSize: const Size.fromHeight(48)),
        icon: const Icon(Icons.build_circle_outlined),
        label: const Text('Gerätespeicher zurücksetzen', textAlign: TextAlign.center),
      ),
    );
  }
}
