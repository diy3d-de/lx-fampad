// Bausteine der Oberfläche der Dateiablage (Abschnitt 6n): Seitenrahmen, Zeilen für Ordner und Dateien, Vorschaubilder, Freigabe-Pille, Kontingent-Anzeige, Brotkrumen, Filter-Chips, Hinweiskarten.
// Alles nur über Design-Konstanten; Touch-Ziele mindestens 44 px, Beschriftungen für die Bedienhilfe. Nie Dateinamen in Benachrichtigungen oder im Log.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/app_database.dart';
import '../../data/dateien/datei_logik.dart';
import '../../data/dateien/datei_modelle.dart';
import '../../data/dateien/datei_state.dart';
import '../../data/dateien/datei_vorschau.dart';
import '../../ui/widgets.dart';

/// Symbol zur Art einer Datei.
IconData dateiIcon(VorschauArt art) => switch (art) {
  VorschauArt.bild => Icons.image_outlined,
  VorschauArt.pdf => Icons.picture_as_pdf_outlined,
  VorschauArt.text => Icons.description_outlined,
  VorschauArt.video => Icons.movie_outlined,
  VorschauArt.audio => Icons.audiotrack_outlined,
  VorschauArt.archiv => Icons.folder_zip_outlined,
  VorschauArt.sonstige => Icons.insert_drive_file_outlined,
};

String stufeText(String audience) =>
    audience == kStufeEltern ? 'Nur Eltern' : 'Familie';

/// Datum und Uhrzeit für Dateien: "12.03.2026, 10:05".
String dateiZeit(DateTime t) {
  final l = t.toLocal();
  String z(int n) => n.toString().padLeft(2, '0');
  return '${z(l.day)}.${z(l.month)}.${l.year}, ${z(l.hour)}:${z(l.minute)}';
}

String dateienAnzahlText(int n) => '$n ${n == 1 ? 'Datei' : 'Dateien'}';

/// Rahmen einer Seite der Dateiablage: Hintergrund, Zurück-Pfeil, Titel, Aktionen; der Inhalt scrollt selbst. Im Inhalts-Navigator des Desktop-Layouts genauso wie mobil (Vollseite).
class DateiRahmen extends StatelessWidget {
  final String label;
  final String titel;
  final Widget child;
  final List<Widget> aktionen;
  final Widget? knopf;
  const DateiRahmen({
    super.key,
    required this.label,
    required this.titel,
    required this.child,
    this.aktionen = const [],
    this.knopf,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    floatingActionButton: knopf,
    body: LxBackground(
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: kMaxContentWidth),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Zurück',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const Spacer(),
                      ...aktionen,
                    ],
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 96),
                      children: [
                        MonoLabel(label),
                        const SizedBox(height: 4),
                        Semantics(
                          header: true,
                          child: Text(
                            titel,
                            style: const TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.6,
                              color: kTextStrong,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        child,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Kleine Pille mit Symbol UND Text (nie nur Farbe): Freigabe "Familie" oder "Nur Eltern".
class StufenPille extends StatelessWidget {
  final String audience;
  const StufenPille(this.audience, {super.key});

  @override
  Widget build(BuildContext context) {
    final eltern = audience == kStufeEltern;
    final farbe = eltern ? kWarn : kTerminal;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: farbe.withValues(alpha: 0.10),
        border: Border.all(color: farbe.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            eltern ? Icons.lock_outline : Icons.groups_outlined,
            size: 12,
            color: farbe,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              stufeText(audience),
              style: TextStyle(
                fontFamily: kFontSans, fontFeatures: kZiffern,
                fontSize: 11,
                color: farbe,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Vorschaubild einer Fassung (kleines Bild vom Server, nur im Arbeitsspeicher) oder das Symbol der Dateiart.
class DateiMiniatur extends ConsumerWidget {
  final String? thumbBlobId;
  final VorschauArt art;
  final double kante;
  final BoxFit fit;
  const DateiMiniatur({
    super.key,
    required this.thumbBlobId,
    required this.art,
    this.kante = 44,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final symbol = Icon(dateiIcon(art), size: kante * 0.5, color: kAccent);
    Widget inhalt = symbol;
    final id = thumbBlobId;
    if (id != null) {
      final bytes = ref.watch(vorschauBildProvider(id)).value;
      if (bytes != null) {
        inhalt = Image.memory(
          bytes,
          width: kante,
          height: kante,
          fit: fit,
          gaplessPlayback: true,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => symbol,
        );
      }
    }
    return ExcludeSemantics(
      child: Container(
        width: kante,
        height: kante,
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: kAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: inhalt,
      ),
    );
  }
}

/// Eine Zeile der Liste (Ordner oder Datei): Bild/Symbol, Titel, Untertitel, optional ein Knopf am Ende. Mindestens 64 px hoch, mit Textskalierung wachsend.
class EintragZeile extends StatelessWidget {
  final Widget vorne;
  final String titel;
  final String untertitel;
  final String semantik;
  final Widget? pille;
  final Widget? hinten;
  final VoidCallback onTap;
  const EintragZeile({
    super.key,
    required this.vorne,
    required this.titel,
    required this.untertitel,
    required this.semantik,
    required this.onTap,
    this.pille,
    this.hinten,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              button: true,
              label: semantik,
              excludeSemantics: true,
              onTap: onTap,
              child: InkWell(
                onTap: onTap,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 64),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                    child: Row(
                      children: [
                        vorne,
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                titel,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                untertitel,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: kFontSans, fontFeatures: kZiffern,
                                  fontSize: 11,
                                  color: kTextMuted,
                                ),
                              ),
                              if (pille != null) ...[
                                const SizedBox(height: 4),
                                pille!,
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          ?hinten,
        ],
      ),
    ),
  );
}

/// Filter-Chip (mindestens 44 px hoch zum Antippen).
class DateiChip extends StatelessWidget {
  final String label;
  final bool gewaehlt;
  final VoidCallback onTap;
  final IconData? icon;
  const DateiChip({
    super.key,
    required this.label,
    required this.gewaehlt,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: gewaehlt,
    label: label,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: gewaehlt ? kAccent : kSurface,
              border: Border.all(color: gewaehlt ? kAccent : Colors.transparent),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(
                    icon,
                    size: 14,
                    color: gewaehlt ? kOnAccent : kTextMuted,
                  ),
                  const SizedBox(width: 6),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: gewaehlt ? kOnAccent : kTextMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Brotkrumen: "Dateien › Urlaub › 2026"; jede Stufe ist antippbar (mindestens 44 px). [pfad] ist die Kette von oben bis zum aktuellen Ordner.
class Brotkrumen extends StatelessWidget {
  final List<OrdnerZeile> pfad;
  final ValueChanged<String?> onWaehlen;
  const Brotkrumen({super.key, required this.pfad, required this.onWaehlen});

  @override
  Widget build(BuildContext context) {
    Widget stufe(String text, String? id, bool aktuell) => Semantics(
      container: true,
      button: !aktuell,
      label: aktuell ? 'Aktueller Ordner: $text' : 'Zu $text',
      excludeSemantics: true,
      onTap: aktuell ? null : () => onWaehlen(id),
      child: InkWell(
        onTap: aktuell ? null : () => onWaehlen(id),
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Align(
            widthFactor: 1,
            heightFactor: 1,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Text(
                text,
                style: TextStyle(
                  fontFamily: kFontSans, fontFeatures: kZiffern,
                  fontSize: 12,
                  color: aktuell ? kTextStrong : kAccent,
                  fontWeight: aktuell ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        stufe('Dateien', null, pfad.isEmpty),
        for (var i = 0; i < pfad.length; i++) ...[
          const ExcludeSemantics(
            child: Icon(Icons.chevron_right, size: 16, color: kTextMuted),
          ),
          stufe(pfad[i].name, pfad[i].id, i == pfad.length - 1),
        ],
      ],
    );
  }
}

/// Hinweiskarte mit Symbol; [farbe] nur als Zusatz (der Text sagt alles).
class DateiHinweis extends StatelessWidget {
  final IconData icon;
  final String text;
  final String? titel;
  final Color farbe;
  const DateiHinweis({
    super.key,
    required this.icon,
    required this.text,
    this.titel,
    this.farbe = kAccent,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: [?titel, text].join('. '),
    excludeSemantics: true,
    child: Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: farbe.withValues(alpha: 0.08),
        border: Border.all(color: farbe.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: farbe),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (titel != null)
                  Text(
                    titel!,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: kTextStrong,
                    ),
                  ),
                Text(
                  text,
                  style: const TextStyle(
                    color: kTextMuted,
                    height: 1.4,
                    fontSize: 13,
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

/// Kontingent der Familie: Text "8,4 GB von 10 GB belegt" und ein Balken; ab 90 Prozent gelb, voll rot (die Stufe steht auch im Text). Ohne Zahlen des Servers (offline) nichts.
class KontingentKarte extends ConsumerWidget {
  const KontingentKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final k = ref.watch(kontingentAnzeigeProvider);
    if (k == null) return const SizedBox.shrink();
    final farbe = switch (k.stufe) {
      KontingentStufe.ok => kAccent,
      KontingentStufe.knapp => kWarn,
      KontingentStufe.voll => kDanger,
    };
    final warnung = switch (k.stufe) {
      KontingentStufe.ok => null,
      KontingentStufe.knapp => 'Der Speicher wird knapp.',
      KontingentStufe.voll => 'Der Speicher ist voll. Neue Dateien gehen erst wieder, wenn du etwas löschst.',
    };
    return Semantics(
      container: true,
      label:
          'Speicher der Familie: ${k.text}${warnung == null ? '' : '. $warnung'}',
      excludeSemantics: true,
      child: LxCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              k.text,
              style: const TextStyle(
                fontFamily: kFontSans, fontFeatures: kZiffern,
                fontSize: 12,
                color: kText,
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: k.anteil,
                minHeight: 8,
                color: farbe,
                backgroundColor: kBorder,
              ),
            ),
            if (warnung != null) ...[
              const SizedBox(height: 8),
              Text(warnung, style: TextStyle(fontSize: 12, color: farbe)),
            ],
          ],
        ),
      ),
    );
  }
}
