// Bausteine der Wetter-Seite für Vorhersage und amtliche Warnungen des Deutschen Wetterdienstes (Daten kommen vom eigenen Server):
// Warnkarten, Tagesliste mit Spannbalken, Stundenband (24 Stunden), Regenwahrscheinlichkeit. Alles ruhig: ohne Vorhersage oder mit veraltetem Stand steht ein
// kurzer Hinweis statt einer Fehlerfläche; ein veralteter Stand wird nie als aktuell gezeigt. Symbole nur aus den Material-Icons, Farben nur über Konstanten.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/wetter/vorhersage_logik.dart';
import '../../data/wetter/vorhersage_modelle.dart';
import '../../data/wetter/vorhersage_state.dart';
import '../../ui/widgets.dart';

IconData wetterSymbolIcon(WetterSymbol s) => switch (s) {
  WetterSymbol.sonne => Icons.wb_sunny_outlined,
  WetterSymbol.nacht => Icons.nightlight_outlined,
  WetterSymbol.teils => Icons.wb_cloudy_outlined,
  WetterSymbol.teilsNacht => Icons.wb_cloudy_outlined,
  WetterSymbol.wolken => Icons.cloud_outlined,
  WetterSymbol.nebel => Icons.foggy,
  WetterSymbol.wind => Icons.air,
  WetterSymbol.regen => Icons.water_drop_outlined,
  WetterSymbol.schneeregen => Icons.cloudy_snowing,
  WetterSymbol.schnee => Icons.ac_unit,
  WetterSymbol.hagel => Icons.grain,
  WetterSymbol.gewitter => Icons.thunderstorm_outlined,
  WetterSymbol.unbekannt => Icons.help_outline,
};

Color wetterSymbolFarbe(WetterSymbol s) => switch (s) {
  WetterSymbol.sonne => kWarn,
  WetterSymbol.regen || WetterSymbol.schneeregen || WetterSymbol.hagel => kWetterRegen,
  WetterSymbol.schnee => kWetterKalt,
  WetterSymbol.gewitter => kWarnViolett,
  _ => kTextMuted,
};

IconData warnArtIcon(WarnArt a) => switch (a) {
  WarnArt.gewitter => Icons.thunderstorm_outlined,
  WarnArt.wind => Icons.air,
  WarnArt.regen => Icons.water_drop_outlined,
  WarnArt.schnee => Icons.ac_unit,
  WarnArt.glaette => Icons.ac_unit,
  WarnArt.frost => Icons.thermostat,
  WarnArt.hitze => Icons.wb_sunny_outlined,
  WarnArt.nebel => Icons.foggy,
  WarnArt.uv => Icons.wb_sunny_outlined,
  WarnArt.tauwetter => Icons.water_drop_outlined,
  WarnArt.sonst => Icons.warning_amber_rounded,
};

/// Eine amtliche Warnung als Karte (Wetter-Seite): Stufe als Text und Farbe, Titel, Zeitraum, gekürzter Text.
class WarnungKarte extends StatelessWidget {
  final WetterWarnung warnung;
  final DateTime jetzt;
  const WarnungKarte({super.key, required this.warnung, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final farbe = warnFarbe(warnung.stufe);
    final zeitraum = warnZeitraum(warnung, jetzt);
    return Semantics(
      container: true,
      label: 'Amtliche Warnung des Deutschen Wetterdienstes, Stufe ${warnung.stufe} von 4, ${stufeName(warnung.stufe)}: ${warnung.titel}, $zeitraum. ${warnung.text}',
      excludeSemantics: true,
      child: Material(
        color: farbe.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: farbe.withValues(alpha: 0.55))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MonoLabel('DWD-Warnung · Stufe ${warnung.stufe}', color: farbe),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(warnArtIcon(warnung.art), size: 20, color: farbe),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text('${stufeName(warnung.stufe)}: ${warnung.titel}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: kTextStrong)),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(zeitraum, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted)),
                if (warnung.text.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(warnung.text, style: const TextStyle(fontSize: 13, color: kText)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Amtliche Warnungen auf der Wetter-Seite: alle geltenden Stufen aus einem frischen Stand; sonst nichts (bzw. ein leiser Hinweis bei altem Stand).
class WetterWarnungenAbschnitt extends ConsumerWidget {
  const WetterWarnungenAbschnitt({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dto = ref.watch(vorhersageProvider.select((s) => s.dto));
    final teil = dto?.warnungen;
    if (dto == null || !dto.verfuegbar || teil == null) return const SizedBox.shrink();
    final jetzt = DateTime.now();
    if (warnungenVeraltet(teil, jetzt)) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: Text('Amtliche Warnungen sind gerade nicht aktuell. Bitte beachte die Hinweise des Deutschen Wetterdienstes.', style: TextStyle(fontSize: 12, color: kTextMuted)),
      );
    }
    final liste = geltendeWarnungen(teil, jetzt);
    if (liste.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < liste.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            WarnungKarte(warnung: liste[i], jetzt: jetzt),
          ],
        ],
      ),
    );
  }
}

/// Vorhersage-Abschnitt: Tagesliste, Stundenband, Regenwahrscheinlichkeit, Quellenangabe. Ohne Daten ein ruhiger Hinweis (oder nichts, wenn der Server keine Vorhersage anbietet).
class WetterVorhersageAbschnitt extends ConsumerWidget {
  const WetterVorhersageAbschnitt({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final st = ref.watch(vorhersageProvider);
    final dto = st.dto;
    final teil = dto?.vorhersage;
    final jetzt = DateTime.now();
    if (dto != null && !dto.verfuegbar) return const SizedBox.shrink();
    if (teil == null) {
      // noch nichts geladen oder nicht verfügbar: ruhig, keine Fehlerfläche
      if (dto == null && st.laedt) return const SizedBox.shrink();
      return const Padding(
        padding: EdgeInsets.only(bottom: 16),
        child: LxCard(
          child: Text('Die Vorhersage ist gerade nicht verfügbar.', style: TextStyle(fontSize: 13, color: kTextMuted)),
        ),
      );
    }
    final tage = kommendeTage(teil.tage, jetzt);
    if (tage.isEmpty) return const SizedBox.shrink();
    final veraltet = vorhersageVeraltet(teil, jetzt);
    final stunden = veraltet ? const <VorhersageStunde>[] : naechsteStunden(teil.stunden, jetzt);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (veraltet)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                'Die Vorhersage ist veraltet (${vorhersageStand(teil, jetzt)}) und wird beim nächsten erfolgreichen Abruf erneuert.',
                style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kWarn),
              ),
            ),
          WetterTageKarte(tage: tage, jetzt: jetzt, stand: vorhersageStand(teil, jetzt), veraltet: veraltet),
          if (stunden.isNotEmpty) ...[const SizedBox(height: 16), WetterStundenBand(stunden: stunden)],
          if (!veraltet && tage.any((t) => t.regenProzent != null)) ...[const SizedBox(height: 16), WetterRegenWahrscheinlichkeit(tage: tage, jetzt: jetzt)],
          const SizedBox(height: 8),
          Text('Quelle: ${dto!.quelle}', style: const TextStyle(fontSize: 12, color: kTextMuted)),
        ],
      ),
    );
  }
}

/// Tagesliste: Tag, Symbol, Spannbalken Min bis Max, darunter Regen und Wind.
class WetterTageKarte extends StatelessWidget {
  final List<VorhersageTag> tage;
  final DateTime jetzt;
  final String stand;
  final bool veraltet;
  const WetterTageKarte({super.key, required this.tage, required this.jetzt, required this.stand, required this.veraltet});

  @override
  Widget build(BuildContext context) {
    final skalaMin = tage.map((t) => t.min).reduce((a, b) => a < b ? a : b);
    final skalaMax = tage.map((t) => t.max).reduce((a, b) => a > b ? a : b);
    return LxCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: MonoLabel('Nächste Tage')),
              Text(stand, style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: veraltet ? kWarn : kTextMuted)),
            ],
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < tage.length; i++) ...[
            if (i > 0) const Divider(height: 18, color: kBorderSoft),
            _TagZeile(tag: tage[i], jetzt: jetzt, skalaMin: skalaMin, skalaMax: skalaMax),
          ],
        ],
      ),
    );
  }
}

class _TagZeile extends StatelessWidget {
  final VorhersageTag tag;
  final DateTime jetzt;
  final double skalaMin;
  final double skalaMax;
  const _TagZeile({required this.tag, required this.jetzt, required this.skalaMin, required this.skalaMax});

  @override
  Widget build(BuildContext context) {
    final balken = spannBalken(tag, skalaMin, skalaMax);
    final detail = tagDetailText(tag);
    return Semantics(
      container: true,
      label: tagSemantik(tag, jetzt),
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 62,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(tagName(tag.datum, jetzt), style: const TextStyle(fontWeight: FontWeight.w700, color: kTextStrong)),
                  ),
                ),
                Icon(wetterSymbolIcon(tag.symbol), size: 22, color: wetterSymbolFarbe(tag.symbol)),
                const SizedBox(width: 10),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, c) => SizedBox(
                      height: 8,
                      child: Stack(
                        children: [
                          Container(decoration: BoxDecoration(color: kBorderSoft, borderRadius: BorderRadius.circular(4))),
                          Positioned(
                            left: c.maxWidth * balken.links,
                            width: c.maxWidth * balken.breite,
                            top: 0,
                            bottom: 0,
                            child: Container(decoration: BoxDecoration(color: kAccent, borderRadius: BorderRadius.circular(4))),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 74,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text('${gradText(tag.min)} / ${gradText(tag.max)}', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 14, color: kText)),
                  ),
                ),
              ],
            ),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(detail, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Stundenband der nächsten 24 Stunden: Uhrzeit, Symbol, Temperatur, Regen; waagerecht scrollbar.
class WetterStundenBand extends StatelessWidget {
  final List<VorhersageStunde> stunden;
  const WetterStundenBand({super.key, required this.stunden});

  @override
  Widget build(BuildContext context) {
    return LxCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: MonoLabel('Nächste 24 Stunden')),
          const SizedBox(height: 10),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final s in stunden) _StundeSpalte(s: s)]),
          ),
        ],
      ),
    );
  }
}

class _StundeSpalte extends StatelessWidget {
  final VorhersageStunde s;
  const _StundeSpalte({required this.s});

  @override
  Widget build(BuildContext context) {
    final regen = s.regenMm >= 0.05 ? mmText(s.regenMm) : '';
    final wind = s.windKmh == null ? '' : '${s.windKmh}';
    return Semantics(
      container: true,
      label: '${s.zeit.hour} Uhr, ${s.symbol.text}, ${s.temperatur.round()} Grad${regen.isEmpty ? '' : ', Regen $regen'}${s.windKmh == null ? '' : ', Wind ${s.windKmh} Kilometer pro Stunde'}',
      excludeSemantics: true,
      child: Container(
        width: 56,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Column(
          children: [
            Text('${s.zeit.hour.toString().padLeft(2, '0')} Uhr', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
            const SizedBox(height: 6),
            Icon(wetterSymbolIcon(s.symbol), size: 22, color: wetterSymbolFarbe(s.symbol)),
            const SizedBox(height: 6),
            Text(gradText(s.temperatur), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 14, fontWeight: FontWeight.w700, color: kTextStrong)),
            const SizedBox(height: 4),
            Text(regen.isEmpty ? '–' : regen.replaceAll(' mm', ''), style: TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: regen.isEmpty ? kTextMuted : kWetterRegen)),
            if (wind.isNotEmpty) Text(wind, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
          ],
        ),
      ),
    );
  }
}

/// Regenwahrscheinlichkeit je Tag als Balken (Anteil der Höhe = Prozent), Tagesname darunter.
class WetterRegenWahrscheinlichkeit extends StatelessWidget {
  final List<VorhersageTag> tage;
  final DateTime jetzt;
  const WetterRegenWahrscheinlichkeit({super.key, required this.tage, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final text = tage.where((t) => t.regenProzent != null).map((t) => '${tagName(t.datum, jetzt)} ${t.regenProzent} Prozent').join(', ');
    return Semantics(
      container: true,
      label: 'Regenwahrscheinlichkeit: $text',
      excludeSemantics: true,
      child: LxCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const MonoLabel('Regenwahrscheinlichkeit'),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (final t in tage)
                  Expanded(
                    child: Column(
                      children: [
                        Text(t.regenProzent == null ? '–' : '${t.regenProzent}', style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kText)),
                        const SizedBox(height: 3),
                        Container(
                          height: 4 + 44 * ((t.regenProzent ?? 0).clamp(0, 100) / 100),
                          margin: const EdgeInsets.symmetric(horizontal: 4),
                          decoration: BoxDecoration(color: kWetterRegen.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(3)),
                        ),
                        const SizedBox(height: 4),
                        FittedBox(fit: BoxFit.scaleDown, child: Text(wochentagKurz(t.datum), style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted))),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
