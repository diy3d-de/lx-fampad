// Übertragungen der Dateiablage (Abschnitt 6n): Liste der Uploads und Downloads mit Fortschritt, Abbrechen, Wiederholen, Entfernen und "Erledigte entfernen". Der Fortschritt steht NUR hier (die
// Kopfzeile der App bleibt unverändert). Uploads setzen sich fort: nach einem Abbruch der Verbindung oder einem Neustart geht es an derselben Stelle weiter; im Web muss die Datei nach dem Neuladen
// des Browsers noch einmal gewählt werden. Tresor-Anhänge (Art `anhang`) gehören zum Tresor und stehen hier nie. Fehler nur als feste Texte (`transferFehlerText`), nie mit Dateinamen im Hinweis.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_waehler.dart';
import '../../data/dateien/transfer_dienst.dart';
import '../../data/dateien/transfer_modelle.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart' show zeigeHinweis;
import 'dateien_bausteine.dart';

/// Text zum Zustand einer Übertragung.
String transferStatusText(TransferZeile z) => switch (z.zustandTyp) {
  TransferZustand.wartet => z.fehlerCode != null ? transferFehlerText(z.fehlerCode) : 'Wartet',
  TransferZustand.laeuft => '${z.artTyp.hoch ? 'Lädt hoch' : 'Lädt herunter'} · ${(z.fortschritt * 100).floor()} %',
  TransferZustand.abschliessen => 'Wird abgeschlossen',
  TransferZustand.fertig => 'Fertig',
  TransferZustand.fehler => transferFehlerText(z.fehlerCode),
  TransferZustand.abgebrochen => 'Abgebrochen',
  TransferZustand.dateiNoetig => 'Bitte wähle die Datei noch einmal.',
};

/// Die Übertragungen der Dateiablage (ohne Tresor-Anhänge).
final dateiTransfersProvider = Provider<List<TransferZeile>>((ref) => [for (final z in ref.watch(transferListeProvider).value ?? const <TransferZeile>[]) if (z.artTyp != TransferArt.anhang) z]);

class UebertragungenScreen extends ConsumerWidget {
  const UebertragungenScreen({super.key});

  static Route<void> route() => MaterialPageRoute<void>(builder: (_) => const UebertragungenScreen());

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liste = ref.watch(dateiTransfersProvider);
    final hatErledigte = liste.any((z) => z.zustandTyp == TransferZustand.fertig || z.zustandTyp == TransferZustand.abgebrochen);
    return DateiRahmen(
      label: '// dateien',
      titel: 'Übertragungen',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (liste.isEmpty)
            const LxCard(child: Text('Keine Übertragungen. Hier siehst du, was gerade hoch- oder heruntergeladen wird.', style: TextStyle(color: kTextMuted, height: 1.4)))
          else ...[
            for (final z in liste) _TransferZeile(z),
            if (hatErledigte) Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => unawaited(ref.read(transferDienstProvider).erledigteEntfernen()), icon: const Icon(Icons.clear_all), label: const Text('Erledigte entfernen'))),
          ],
          const SizedBox(height: 12),
          const DateiHinweis(icon: Icons.sync, titel: 'Setzt sich fort', text: 'Bricht die Verbindung ab oder wird die App beendet, geht der Upload an derselben Stelle weiter. Im Browser musst du die Datei nach dem Neuladen der Seite noch einmal wählen.'),
        ],
      ),
    );
  }
}

class _TransferZeile extends ConsumerWidget {
  final TransferZeile z;
  const _TransferZeile(this.z);

  Future<void> _dateiWaehlen(BuildContext context, WidgetRef ref) async {
    final a = await ref.read(dateiWaehlerProvider)(nurBilder: false);
    if (a.dateien.isEmpty) {
      if (context.mounted && a.nichtLesbar > 0) zeigeHinweis(context, 'Die Datei ließ sich nicht öffnen.');
      return;
    }
    for (final d in a.dateien.skip(1)) {
      unawaited(d.quelle.schliessen());
    }
    await ref.read(transferDienstProvider).quelleLiefern(z.id, a.dateien.first.quelle);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dienst = ref.read(transferDienstProvider);
    final status = transferStatusText(z);
    final zustand = z.zustandTyp;
    final aktiv = zustand == TransferZustand.laeuft || zustand == TransferZustand.abschliessen || zustand == TransferZustand.wartet;
    final fehler = zustand == TransferZustand.fehler;
    final farbe = fehler ? kDanger : (zustand == TransferZustand.fertig ? kTerminal : kTextMuted);
    final art = z.artTyp;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        container: true,
        label: '${art == TransferArt.runter ? 'Download' : (art == TransferArt.fassung ? 'Neue Fassung' : 'Upload')}: ${z.name}. $status. ${groesseText(z.groesse)}',
        child: LxCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ExcludeSemantics(child: Icon(art.hoch ? Icons.upload_outlined : Icons.download_outlined, size: 18, color: kAccent)),
                  const SizedBox(width: 8),
                  Expanded(child: Text(z.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                ],
              ),
              const SizedBox(height: 4),
              Text('${art == TransferArt.fassung ? 'Neue Fassung · ' : ''}${groesseText(z.groesse)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              if (aktiv) ...[
                const SizedBox(height: 8),
                ExcludeSemantics(child: ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: zustand == TransferZustand.wartet ? null : z.fortschritt, minHeight: 6, color: kAccent, backgroundColor: kBorder))),
              ],
              const SizedBox(height: 6),
              Text(status, style: TextStyle(fontSize: 12, color: farbe, height: 1.3)),
              Wrap(
                children: [
                  if (aktiv) TextButton.icon(onPressed: () => unawaited(dienst.abbrechen(z.id)), icon: const Icon(Icons.close, size: 18), label: const Text('Abbrechen')),
                  if (zustand == TransferZustand.dateiNoetig) TextButton.icon(onPressed: () => unawaited(_dateiWaehlen(context, ref)), icon: const Icon(Icons.attach_file, size: 18), label: const Text('Datei wählen')),
                  if (fehler || (zustand == TransferZustand.abgebrochen && z.art != 'runter')) TextButton.icon(onPressed: () => unawaited(dienst.wiederholen(z.id)), icon: const Icon(Icons.refresh, size: 18), label: const Text('Wiederholen')),
                  if (!aktiv) TextButton.icon(onPressed: () => unawaited(dienst.entfernen(z.id)), icon: const Icon(Icons.delete_outline, size: 18), label: const Text('Entfernen')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
