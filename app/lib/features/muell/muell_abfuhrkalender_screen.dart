// Seite "Abfuhrkalender" (nur Admin): Status je Jahr (geladen mit Anzahl der Termine, "noch nicht verfügbar", "Quelle nicht erreichbar"), letzte und
// nächste Prüfung und "Jetzt nach neuer Datei suchen". Die Quelle (Link mit Schlüssel) steht nur in der Server-Konfiguration: es gibt bewusst
// kein Eingabefeld dafür in der App, und die App zeigt nie die Adresse oder Fehlertexte der Quelle.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/models.dart' show Role;
import '../../data/auth/auth_state.dart';
import '../../data/muell/muell_logik.dart';
import '../../data/muell/muell_modelle.dart';
import '../../data/muell/muell_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'muell_pruefen.dart';

class MuellAbfuhrkalenderScreen extends ConsumerWidget {
  const MuellAbfuhrkalenderScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final z = ref.watch(muellProvider);
    final rolle = ref.watch(authProvider.select((s) => s.user?.role));
    final jetzt = ref.watch(muellUhrProvider)();
    final heuteJahr = muellHeute(jetzt).year; // Jahr der Familienzone, nicht des Geräts
    if (rolle != Role.admin) {
      return const AuthSeite(label: '// müll', titel: 'Abfuhrkalender', kinder: [MeldungsBox('Diese Seite ist nur für Admins.', fehler: false)]);
    }
    final dto = z.dto;
    final p = dto?.pruefung ?? const MuellPruefung();
    // alle bekannten Jahre, dazu das laufende und das nächste (auch wenn noch nie geprüft)
    final jahre = {...?dto?.jahre.map((j) => j.jahr), heuteJahr, heuteJahr + 1}.toList()..sort();
    return AuthSeite(
      label: '// müll',
      titel: 'Abfuhrkalender',
      maxBreite: kMaxContentWidth,
      kinder: [
        LxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const MonoLabel('// quelle'),
              const SizedBox(height: 6),
              Text(dto != null && dto.ort.isNotEmpty ? dto.ort : 'Abfallkalender', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              const Text('Der Link (ICS) steht nur in der Server-Konfiguration und wird dort geändert.', style: TextStyle(fontSize: 13, color: kTextMuted)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MonoLabel('// jahre'),
              const SizedBox(height: 8),
              for (final j in jahre) _JahrZeile(jahr: j, daten: dto?.jahr(j)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        LxCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const MonoLabel('// automatische prüfung'),
              const SizedBox(height: 8),
              _Kv('Zeitraum', 'ab 1. Dezember, wöchentlich'),
              _Kv('Nächste Prüfung', p.naechste == null ? 'beim nächsten Takt' : (p.naechste!.isAfter(jetzt) ? muellZeitpunkt(p.naechste!) : 'fällig, beim nächsten Takt')),
              _Kv('Letzte Prüfung', p.letzte == null ? '—' : muellZeitpunkt(p.letzte!)),
              _Kv('Ab Januar', 'nur bei fehlenden Daten'),
            ],
          ),
        ),
        const SizedBox(height: 16),
        const MuellPruefenBlock(),
        const SizedBox(height: 12),
        const Text('Sobald das nächste Jahr gefunden ist, bekommen Eltern und Admins einen Hinweis „Abfuhrtermine 20XX sind da“.', style: TextStyle(fontSize: 12, color: kTextMuted)),
      ],
    );
  }
}

class _Kv extends StatelessWidget {
  final String k;
  final String v;
  const _Kv(this.k, this.v);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      spacing: 12,
      children: [
        Text(k, style: const TextStyle(fontSize: 13, color: kTextMuted)),
        Text(v, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kText)),
      ],
    ),
  );
}

class _JahrZeile extends StatelessWidget {
  final int jahr;
  final MuellJahr? daten;
  const _JahrZeile({required this.jahr, required this.daten});

  @override
  Widget build(BuildContext context) {
    final d = daten;
    final (text, farbe) = switch (d?.status) {
      MuellJahrStatus.geladen => ('geladen', kTerminal),
      MuellJahrStatus.nichtVerfuegbar => ('noch nicht verfügbar', kWarn),
      MuellJahrStatus.fehler => ('Quelle nicht erreichbar', kDanger),
      null => ('noch nicht geprüft', kTextMuted),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Semantics(
        container: true,
        label: '$jahr: $text${d?.status == MuellJahrStatus.geladen ? ', ${d!.anzahlTermine} Termine' : ''}',
        excludeSemantics: true,
        child: Row(
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: '$jahr', style: const TextStyle(fontWeight: FontWeight.w800, color: kTextStrong)),
                  if (d?.status == MuellJahrStatus.geladen) TextSpan(text: ' · ${d!.anzahlTermine} Termine', style: const TextStyle(color: kTextMuted)),
                ]),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(child: StatusPill(text, color: farbe)),
          ],
        ),
      ),
    );
  }
}
