// Betrieb, Paket 2b, Seite "Einstellungen": Wartungsmodus (an/aus, optional mit automatischem Ende), Familienhinweis (Text mit optionalem Ablauf) und die
// Konfiguration des Servers (nur lesend: Schalter und Limits, nie Geheimnisse). Schreiben braucht ein frisches Step-up; Konfiguration ändert sich nur per SSH.
// Alle Texte sind feste Wörter der App; vom Server kommen nur Werte (Schalter, Zahlen, Zeiten) und der Hinweistext des Betreibers selbst.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/betrieb/betrieb_einstellungen_state.dart';
import '../../data/betrieb/betrieb_state.dart' show BetriebTeilZustand;
import '../../data/betrieb/familien_stand.dart';
import '../../ui/widgets.dart';
import '../../widgets/familien_hinweis_banner.dart' show endeText;
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'betrieb_konfig_anzeige.dart';

/// Ist der Server älter und kennt die Route nicht (404), oder ist sie nicht erreichbar? Dann "nicht verfügbar" statt einer Fehlermeldung.
String _nichtVerfuegbarText(Object fehler) =>
    fehler is ApiException && fehler.status == 404 ? 'Dieser Server kennt das noch nicht (älterer Stand).' : 'Gerade nicht abrufbar. Mit „Prüfung neu starten“ erneut versuchen.';

class BetriebEinstellungenSeite extends ConsumerWidget {
  const BetriebEinstellungenSeite({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stand = ref.watch(betriebEinstellungenProvider);
    final konfig = ref.watch(betriebKonfigurationProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _WartungKarte(zustand: stand),
        const SizedBox(height: 20),
        _HinweisKarte(zustand: stand),
        const SizedBox(height: 20),
        const MonoLabel('// konfiguration'),
        const SizedBox(height: 8),
        if (konfig.wert == null)
          Text(konfig.fehler != null ? _nichtVerfuegbarText(konfig.fehler!) : 'Die Konfiguration wird geladen …', style: const TextStyle(color: kTextMuted, fontSize: 13))
        else
          for (final g in konfig.wert!.gruppen) ...[_KonfigGruppe(gruppe: g), const SizedBox(height: 12)],
        const Text(
          'Die Konfiguration steht in der Datei /etc/lx-fampad/env auf dem Server und ändert sich nur per SSH (mit Neustart). Hier siehst du nur sichere Ausschnitte: nie Schlüssel, Token oder Passwörter.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Wartungsmodus

/// Auswahl des automatischen Endes beim Einschalten (Stunden). Die Wartung hat immer ein Ende (höchstens 72 Stunden): ein vergessener Modus sperrt nie auf Dauer.
const _wartungDauern = <(String, int)>[('1 Std.', 1), ('4 Std.', 4), ('24 Std.', 24), ('72 Std.', 72)];

class _WartungKarte extends ConsumerStatefulWidget {
  final BetriebTeilZustand<FamilienStand> zustand;
  const _WartungKarte({required this.zustand});

  @override
  ConsumerState<_WartungKarte> createState() => _WartungKarteState();
}

class _WartungKarteState extends ConsumerState<_WartungKarte> with AktionsZustand<_WartungKarte> {
  int _stunden = 4;

  Future<void> _einschalten() async {
    final bestaetigt = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Wartungsmodus einschalten?'),
        scrollable: true,
        content: const Text(
          'Solange er läuft, können alle Mitglieder nichts mehr abgleichen und sich nicht neu anmelden. Änderungen bleiben auf den Geräten und gehen danach raus. '
          'Er endet nach der gewählten Dauer von selbst. Du selbst bleibst angemeldet und kannst ihn hier früher ausschalten.',
          style: TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Einschalten')),
        ],
      ),
    );
    if (bestaetigt != true || !mounted) return;
    // die Dauer geht an den Server, der das Ende mit seiner Uhr ausrechnet (die Uhr des Geräts zählt nicht)
    final dauer = Duration(hours: _stunden);
    await ausfuehren(() async {
      await mitStepUp(context, ref, () => ref.read(betriebEinstellungenProvider.notifier).wartungSetzen(true, dauer: dauer));
    });
  }

  Future<void> _ausschalten() async {
    await ausfuehren(() async {
      await mitStepUp(context, ref, () => ref.read(betriebEinstellungenProvider.notifier).wartungSetzen(false));
    });
  }

  @override
  Widget build(BuildContext context) {
    final z = widget.zustand;
    final w = z.wert?.wartung;
    final jetzt = DateTime.now();
    final Widget inhalt;
    if (w == null) {
      inhalt = Text(z.fehler != null ? _nichtVerfuegbarText(z.fehler!) : 'Der Stand wird geladen …', style: const TextStyle(color: kTextMuted, fontSize: 13));
    } else {
      inhalt = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                StatusPill(w.aktiv ? '● Wartung läuft' : '● aus', color: w.aktiv ? kWarn : kTextMuted),
                if (w.aktiv && w.seit != null) Text('seit ${endeText(w.seit!, jetzt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                if (w.aktiv) Text(w.bis == null ? 'ohne Ende' : 'bis ${endeText(w.bis!, jetzt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            w.aktiv
                ? 'Die App zeigt allen einen Wartungs-Hinweis. Abgleich, Schreiben und neue Anmeldungen sind gesperrt; Lesen und bestehende Anmeldungen laufen weiter.'
                : 'Sperrt vorübergehend Abgleich, Schreiben und neue Anmeldungen, zum Beispiel für ein Update. Lesen und bestehende Anmeldungen laufen weiter.',
            style: const TextStyle(fontSize: 13, height: 1.4, color: kTextMuted),
          ),
          if (fehler != null) ...[const SizedBox(height: 8), MeldungsBox(fehler!)],
          const SizedBox(height: 12),
          if (w.aktiv)
            HauptKnopf(text: 'Wartung beenden', icon: Icons.check_circle_outline, laeuft: laeuft, onPressed: laeuft ? null : () => unawaited(_ausschalten()))
          else ...[
            const MonoLabel('// automatisches ende', color: kTextMuted),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (text, std) in _wartungDauern)
                  ChoiceChip(label: Text(text), selected: _stunden == std, onSelected: laeuft ? null : (_) => setState(() => _stunden = std)),
              ],
            ),
            const SizedBox(height: 12),
            ZweitKnopf(text: 'Wartung einschalten', icon: Icons.build_outlined, onPressed: laeuft ? null : () => unawaited(_einschalten())),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('// wartungsmodus'),
        const SizedBox(height: 8),
        LxCard(padding: const EdgeInsets.all(14), child: inhalt),
        const SizedBox(height: 4),
        const Text(
          'Fällt die Anmeldung aus, schaltet der Server-Notausgang ihn ab: node dist/cli/operator.js maintenance off.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Familienhinweis

/// Auswahl des Ablaufs (Tage; null = bis zum Löschen).
const _hinweisDauern = <(String, int?)>[('Ohne Ablauf', null), ('1 Tag', 1), ('7 Tage', 7), ('30 Tage', 30)];

class _HinweisKarte extends ConsumerStatefulWidget {
  final BetriebTeilZustand<FamilienStand> zustand;
  const _HinweisKarte({required this.zustand});

  @override
  ConsumerState<_HinweisKarte> createState() => _HinweisKarteState();
}

class _HinweisKarteState extends ConsumerState<_HinweisKarte> with AktionsZustand<_HinweisKarte> {
  final _text = TextEditingController();
  int? _tage;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _senden() async {
    final text = _text.text.trim();
    if (text.isEmpty) {
      setState(() => fehler = 'Bitte gib einen Text ein.');
      return;
    }
    final ablauf = _tage == null ? null : Duration(days: _tage!);
    final ok = await ausfuehren(() async {
      await mitStepUp(context, ref, () => ref.read(betriebEinstellungenProvider.notifier).hinweisSetzen(text, ablauf: ablauf));
    });
    if (ok && mounted) _text.clear();
  }

  Future<void> _loeschen() async {
    await ausfuehren(() async {
      await mitStepUp(context, ref, () => ref.read(betriebEinstellungenProvider.notifier).hinweisSetzen(null));
    });
  }

  @override
  Widget build(BuildContext context) {
    final z = widget.zustand;
    final aktuell = z.wert?.hinweis;
    final jetzt = DateTime.now();
    final Widget inhalt;
    if (z.wert == null) {
      inhalt = Text(z.fehler != null ? _nichtVerfuegbarText(z.fehler!) : 'Der Stand wird geladen …', style: const TextStyle(color: kTextMuted, fontSize: 13));
    } else {
      inhalt = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (aktuell != null) ...[
            Semantics(
              liveRegion: true,
              child: Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const StatusPill('● sichtbar', color: kTerminal),
                  Text(aktuell.ablauf == null ? 'ohne Ablauf' : 'bis ${endeText(aktuell.ablauf!, jetzt)}', style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(aktuell.text, style: const TextStyle(fontSize: 14, height: 1.4)),
            const SizedBox(height: 12),
            const Divider(height: 1, color: kBorderSoft),
            const SizedBox(height: 12),
          ] else ...[
            const Text('Zurzeit ist kein Hinweis gesetzt.', style: TextStyle(fontSize: 13, color: kTextMuted)),
            const SizedBox(height: 12),
          ],
          TextField(
            controller: _text,
            enabled: !laeuft,
            minLines: 2,
            maxLines: 4,
            maxLength: kHinweisMaxZeichen,
            textInputAction: TextInputAction.done,
            keyboardType: TextInputType.text,
            // eine Zeile: Umbrüche und Tabulatoren lehnt der Server ab
            inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[\n\r\t]'))],
            decoration: InputDecoration(labelText: aktuell == null ? 'Neuer Hinweis' : 'Neuer Hinweis (ersetzt den jetzigen)', alignLabelWithHint: true),
          ),
          const SizedBox(height: 8),
          const MonoLabel('// ablauf', color: kTextMuted),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (text, tage) in _hinweisDauern) ChoiceChip(label: Text(text), selected: _tage == tage, onSelected: laeuft ? null : (_) => setState(() => _tage = tage)),
            ],
          ),
          if (fehler != null) ...[const SizedBox(height: 8), MeldungsBox(fehler!)],
          const SizedBox(height: 12),
          HauptKnopf(text: 'Hinweis senden', icon: Icons.campaign_outlined, laeuft: laeuft, onPressed: laeuft ? null : () => unawaited(_senden())),
          if (aktuell != null) ...[
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Hinweis löschen', icon: Icons.delete_outline, onPressed: laeuft ? null : () => unawaited(_loeschen())),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('// familienhinweis'),
        const SizedBox(height: 8),
        LxCard(padding: const EdgeInsets.all(14), child: inhalt),
        const SizedBox(height: 4),
        const Text(
          'Der Hinweis erscheint als Banner bei allen Mitgliedern (reiner Text, höchstens 280 Zeichen). Jede Person kann ihn auf ihrem Gerät wegklicken; ein neuer Hinweis erscheint wieder.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}

// ------------------------------------------------------------------ Konfiguration

class _KonfigGruppe extends StatelessWidget {
  final KonfigGruppe gruppe;
  const _KonfigGruppe({required this.gruppe});

  @override
  Widget build(BuildContext context) {
    if (gruppe.werte.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MonoLabel(konfigGruppeText(gruppe.id), color: kTextMuted),
        const SizedBox(height: 6),
        LxCard(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Column(
            children: [
              for (var i = 0; i < gruppe.werte.length; i++) ...[if (i > 0) const Divider(height: 1, color: kBorderSoft), _KonfigZeile(wert: gruppe.werte[i])],
            ],
          ),
        ),
      ],
    );
  }
}

class _KonfigZeile extends StatelessWidget {
  final KonfigWert wert;
  const _KonfigZeile({required this.wert});

  @override
  Widget build(BuildContext context) {
    final v = wert.wert;
    final text = konfigWertText(wert);
    final name = konfigNameText(wert.key);
    return Semantics(
      container: true,
      label: '$name: $text',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (name != wert.key) ...[
                      const SizedBox(height: 2),
                      Text(wert.key, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // begrenzt (lange Werte brechen um, statt die Zeile zu sprengen)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 150),
                child: v is bool
                    ? StatusPill(text, color: v ? kTerminal : kTextMuted)
                    : Text(text, textAlign: TextAlign.end, style: TextStyle(fontFamily: kFontMono, fontSize: 13, color: v == null ? kTextMuted : kText)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
