// Bewusste Reparatur des sicheren Speichers (Android): Mit resetOnError: false heilt sich der Speicher bei verlorenem Keystore-Schlüssel nicht mehr von selbst
// (siehe data/crypto/sicherer_speicher.dart). Dieser Knopf erscheint unter der Fehlermeldung "Gerätespeicher defekt" (MeldungsBox) und im Defektbild der Verschlüsselung.
// Nur auf Klick, nie automatisch, und nur, wenn eine Probe den Speicher nachweislich als defekt zeigt (und noch einmal direkt vor dem Löschen). Die Rückfrage nennt alles,
// was verloren geht, und verlangt ein getipptes Wort (wie "Gerät abgeben"). Danach wird abgemeldet und zum Neustart der App aufgefordert: Das Plugin teilt seine
// Instanz (Schlüsselableitung und Einstellungen sind im laufenden Prozess zwischengespeichert), erst ein Neustart baut den Speicher sauber neu auf.
// Der EINZIGE Aufruf von GeraeteSpeicher.zuruecksetzen steht hier (Wächtertest in schluessel_matrix_test.dart).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/sicherer_speicher.dart';
import '../../data/sync_state.dart';
import '../profile/wort_bestaetigung.dart';

/// Ablauf "Gerätespeicher zurücksetzen": Probe, Abgleich (falls noch möglich), Rückfrage mit Wort und Haken, erneute Probe, Zurücksetzen, Probe danach, abmelden.
/// Meldet jedes Ergebnis über [meldung] (Hinweis oder Fehler). Gibt true zurück, wenn der Speicher zurückgesetzt wurde (die App muss danach neu gestartet werden).
Future<bool> geraeteSpeicherZuruecksetzen(
  BuildContext context,
  WidgetRef ref, {
  required void Function(String text) meldung,
}) async {
  final speicher = ref.read(geraeteSpeicherProvider);
  final auth = ref.read(authProvider.notifier);
  final store = ref.read(syncStoreProvider);
  final sync = ref.read(syncProvider.notifier);
  final angemeldet = ref.read(authProvider).status == AuthStatus.angemeldet;
  final e2ee = ref.read(e2eeProvider);
  final gesichert = geraetAbgabeLage(e2ee) == GeraetAbgabeLage.moeglich;
  final fruehere = e2ee.fruehereSchluessel;

  // nur bei nachweislich dauerhaftem Defekt (drei Proben, mindestens ein Fehler wie ein kaputter Schlüssel): ein Aussetzer bleibt unberührt
  if (!await speicher.nachweislichDefekt()) {
    if (context.mounted) meldung('Der Gerätespeicher antwortet wieder oder der Fehler sieht nicht nach einem dauerhaften Defekt aus. Es wurde nichts zurückgesetzt; versuche es noch einmal.');
    return false;
  }

  // Liefert der Speicher noch Tokens (die laufende Sitzung hält sie im Arbeitsspeicher), vorher einmal abgleichen: ungesendete Änderungen gehen sonst verloren
  var offen = 0;
  var abgelehnt = 0;
  try {
    if (angemeldet && await store.offeneAnzahl() > 0) {
      await sync.synchronisieren(manuell: true).timeout(const Duration(seconds: 15), onTimeout: () {});
    }
    offen = await store.offeneAnzahl();
    abgelehnt = await store.abgelehnteAnzahl();
  } on Object {
    // der Ausgang ließ sich nicht lesen: die Rückfrage nennt alle lokalen Daten trotzdem
  }
  if (!context.mounted) return false;

  final ja = await wortBestaetigen(
    context,
    titel: 'Gerätespeicher zurücksetzen?',
    text:
        'Der sichere Speicher dieses Geräts (Android-Schlüsselspeicher) ist dauerhaft defekt: Die App kann dort nichts mehr lesen oder ablegen. '
        'Beim Zurücksetzen geht auf DIESEM Gerät alles verloren, was die App lokal hält: deine Anmeldung, dein Schlüssel auf diesem Gerät (er ist ohnehin nicht mehr lesbar), '
        'die gemerkten Schlüssel der Familie, alle lokalen Daten (die lokale Datenbank mit Terminen, Listen, Aufgaben und Chats), die Einstellungen und der Ausgang. '
        'Dein Konto und alles auf dem Server bleiben. Danach schließt du die App ganz, öffnest sie neu, meldest dich an und verbindest dieses Gerät mit deinem Wiederherstellungsschlüssel, '
        'deiner Passwort-Sicherung oder von einem anderen Gerät mit deinem Schlüssel.',
    haken: [
      if (offen > 0)
        'Ich weiß: ${offen == 1 ? '1 noch nicht gesendete Änderung (z. B. eine Nachricht) geht' : '$offen noch nicht gesendete Änderungen (z. B. Nachrichten) gehen'} verloren.',
      if (abgelehnt > 0)
        'Ich weiß: ${abgelehnt == 1 ? '1 nicht gesendete Nachricht (Änderung) mit Fehler geht' : '$abgelehnt nicht gesendete Nachrichten (Änderungen) mit Fehler gehen'} verloren (vom Server abgelehnt).',
      if (fruehere > 0)
        fruehere == 1
            ? 'Auf diesem Gerät liegt noch 1 früherer Schlüssel, der nur hier existiert. Er wird ebenfalls gelöscht.'
            : 'Auf diesem Gerät liegen noch $fruehere frühere Schlüssel, die nur hier existieren. Sie werden ebenfalls gelöscht.',
      if (!gesichert)
        'Ich weiß: Ohne bestätigte Sicherung (Wiederherstellungsschlüssel oder Passwort-Sicherung) und ohne ein anderes Gerät mit meinem Schlüssel kommt mein Chat-Verlauf nicht zurück.',
    ],
    wort: 'zurücksetzen',
    knopf: 'Zurücksetzen',
  );
  if (!ja) return false;

  // Der Speicher kann sich während der Rückfrage erholt haben (Keystore war nur gesperrt): dann bleibt alles, wie es ist
  if (!await speicher.nachweislichDefekt()) {
    meldung('Der Gerätespeicher funktioniert inzwischen wieder. Es wurde nichts gelöscht; versuche es noch einmal.');
    return false;
  }
  try {
    await speicher.zuruecksetzen();
  } on Object {
    meldung('Das Zurücksetzen hat nicht geklappt. Lösche die App-Daten in den Android-Einstellungen (Apps › lx-fampad › Speicher).');
    return false;
  }
  // Hat es schon geholfen? Das Plugin teilt seine Instanz im laufenden Prozess und hält Schlüssel und Einstellungen zwischengespeichert: Erst ein Neustart der App baut
  // den Speicher sicher neu auf. Meldet er danach weiter Fehler, hilft nur das Löschen der App-Daten.
  final nochDefekt = await speicher.nachweislichDefekt();
  // sauber neu anfangen: Sitzung (auf dem Server, soweit erreichbar) und lokale Daten weg; das Ergebnis wird ausgewertet, nichts still ignoriert
  final hinweise = <String>[
    if (nochDefekt) 'Der Speicher meldet noch Fehler, bis die App neu gestartet ist. Hilft der Neustart nicht, lösche die App-Daten in den Android-Einstellungen.',
  ];
  try {
    final e = await auth.abmelden(nurLokal: !angemeldet);
    if (angemeldet && !e.serverAbgemeldet) {
      hinweise.add('Der Server war nicht erreichbar: Die Sitzung dort bleibt bis zum Ablauf gültig; beende sie später unter „Angemeldete Geräte“.');
    }
    if (!e.lokalSauber) {
      hinweise.add('Die lokalen Daten ließen sich nicht vollständig löschen: Lösche zusätzlich die App-Daten in den Android-Einstellungen.');
    }
  } on Object {
    hinweise.add('Das Abmelden hat nicht geklappt: Lösche zusätzlich die App-Daten in den Android-Einstellungen.');
  }
  meldung(
    [
      'Der Gerätespeicher ist zurückgesetzt. Schließe die App jetzt ganz (aus der Liste der letzten Apps entfernen) und öffne sie neu; dann meldest du dich an${angemeldet ? ' und verbindest dieses Gerät wieder mit deinem Schlüssel' : ''}.',
      ...hinweise,
    ].join(' '),
  );
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
          ..showSnackBar(SnackBar(duration: const Duration(seconds: 15), content: Text(t))),
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
