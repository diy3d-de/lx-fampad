// Betrieb, Paket 2a (Übersicht): Familienampel der Schlüssel-Ampel ("Stichtag-bereit: alle grün") und Warnstatus mit dem Schalter "Warnungen".
// Zeigt nur Zustände und feste Texte der App (nie ein Servertext, nie Schlüsselmaterial). Eine fehlende oder nicht lesbare Antwort (älterer Server) ergibt
// einen ruhigen Hinweis, keinen Fehlerkasten über der Seite.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/betrieb/betrieb_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'betrieb_anzeige.dart';

/// Ist der Server älter und kennt die Route nicht (404), oder ist sie nicht erreichbar? Dann "nicht verfügbar" statt einer Fehlermeldung.
String _nichtVerfuegbarText(Object fehler) => fehler is ApiException && fehler.status == 404
    ? 'Dieser Server kennt das noch nicht (älterer Stand).'
    : 'Gerade nicht abrufbar. Mit „Prüfung neu starten“ erneut versuchen.';

class FamilienAmpelKarte extends ConsumerWidget {
  /// Wechselt zur Seite "Mitglieder" (Einzelheiten je Person).
  final VoidCallback oeffneMitglieder;
  const FamilienAmpelKarte({super.key, required this.oeffneMitglieder});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(betriebSchluesselProvider);
    final s = z.wert;
    final Widget inhalt;
    if (s == null) {
      inhalt = Text(z.fehler != null ? _nichtVerfuegbarText(z.fehler!) : 'Die Schlüssel-Ampel wird geladen …', style: const TextStyle(color: kTextMuted, fontSize: 13));
    } else {
      final farbe = ampelFarbe(s.gesamt);
      inhalt = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            liveRegion: true,
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusPill('● ${ampelText(s.gesamt)}', color: farbe),
                Text('${s.gruen} grün · ${s.gelb} gelb · ${s.rot} rot', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(familienAmpelText(s), style: TextStyle(fontWeight: FontWeight.w600, color: s.bereit ? kTerminal : kText)),
          if (s.personen.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final p in s.personen)
                  Semantics(
                    container: true,
                    label: '${p.name}: ${ampelText(p.ampel)}',
                    excludeSemantics: true,
                    child: StatusPill('${p.name} · ${ampelText(p.ampel)}', color: ampelFarbe(p.ampel)),
                  ),
              ],
            ),
          ],
          if (z.fehler != null) ...[
            const SizedBox(height: 8),
            const Text('Letzter Abruf gescheitert, angezeigt wird der letzte Stand.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
          const SizedBox(height: 4),
          TextButton(onPressed: oeffneMitglieder, style: TextButton.styleFrom(minimumSize: const Size(44, 44)), child: const Text('Einzelheiten je Person')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('// schlüssel-ampel'),
        const SizedBox(height: 8),
        LxCard(padding: const EdgeInsets.all(14), child: inhalt),
        const SizedBox(height: 4),
        const Text(
          'Grün: mindestens zwei unabhängige Wege zum Schlüssel (Gerät mit Schlüssel, Passwort-Sicherung, Wiederherstellungsschlüssel). Der Stichtag gilt erst, wenn alle grün sind.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}

class WarnungenKarte extends ConsumerStatefulWidget {
  const WarnungenKarte({super.key});

  @override
  ConsumerState<WarnungenKarte> createState() => _WarnungenKarteState();
}

class _WarnungenKarteState extends ConsumerState<WarnungenKarte> with AktionsZustand<WarnungenKarte> {
  Future<void> _umschalten(bool an) async {
    await ausfuehren(() async {
      await mitStepUp(context, ref, () => ref.read(betriebWarnungenProvider.notifier).setzen(an));
    });
  }

  @override
  Widget build(BuildContext context) {
    final z = ref.watch(betriebWarnungenProvider);
    final w = z.wert;
    final jetzt = DateTime.now();
    final Widget inhalt;
    if (w == null) {
      inhalt = Text(z.fehler != null ? _nichtVerfuegbarText(z.fehler!) : 'Der Warnstatus wird geladen …', style: const TextStyle(color: kTextMuted, fontSize: 13));
    } else {
      inhalt = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: w.an,
            onChanged: laeuft ? null : (v) => unawaited(_umschalten(v)),
            title: const Text('Warnungen an dich', style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: const Text('Push ohne Inhalt: „Betrieb: Hinweis – öffne Betrieb“', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
          ),
          if (fehler != null) ...[const SizedBox(height: 8), MeldungsBox(fehler!)],
          if (!w.pushDa) ...[
            const SizedBox(height: 8),
            const Text('Push ist auf dem Server nicht eingerichtet: es kommt kein Hinweis aufs Gerät, die Warnungen stehen nur hier.', style: TextStyle(fontSize: 12, color: kWarn)),
          ],
          const SizedBox(height: 8),
          const Divider(height: 1, color: kBorderSoft),
          const SizedBox(height: 8),
          if (w.aktiv.isEmpty)
            Text(
              w.gepruefteAm == null ? 'Noch nicht geprüft.' : 'Keine aktive Warnung (geprüft ${zeitText(w.gepruefteAm!, jetzt)}).',
              style: const TextStyle(color: kTerminal, fontSize: 13),
            )
          else
            for (final a in w.aktiv)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Semantics(
                  container: true,
                  label: 'Warnung: ${warnArtText(a.art)}${a.seit == null ? '' : ', seit ${zeitText(a.seit!, jetzt)}'}',
                  excludeSemantics: true,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(padding: EdgeInsets.only(top: 5), child: Icon(Icons.circle, size: 9, color: kWarn)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(warnArtText(a.art), style: const TextStyle(fontWeight: FontWeight.w600)),
                            if (a.seit != null) Text('seit ${zeitText(a.seit!, jetzt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          if (!w.an) ...[
            const SizedBox(height: 4),
            const Text('Aus: der Server prüft weiter, schickt dir aber keinen Hinweis.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('// warnungen'),
        const SizedBox(height: 8),
        LxCard(padding: const EdgeInsets.all(14), child: inhalt),
        const SizedBox(height: 4),
        const Text(
          'Der Server prüft alle 5 Minuten: Zertifikat, Sicherung, Datenbank, Push, Speicherplatz, Fehlanmeldungen und die Schlüssel-Ampel. Je Art höchstens alle 6 Stunden ein Hinweis, nur an dich.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}
