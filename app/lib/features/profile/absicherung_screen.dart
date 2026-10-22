// "Bin ich abgesichert?" (P1): die Ampel der eigenen Person als Zeile im Profil, als Karte auf der Startseite (nur wenn es etwas zu tun gibt) und als Seite mit den drei Wegen
// zum Schlüssel (Gerät, Passwort-Sicherung, Wiederherstellungsschlüssel) und dem nächsten Schritt. Rechnung und Ehrlichkeit: data/crypto/absicherung.dart (grün nur mit
// bestätigter Sicherung, unbekannt nie grün, immer mit Wort). Farben nur über Konstanten.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/crypto/absicherung.dart';
import '../../data/crypto/absicherung_state.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import 'profile_screen.dart' show EinstellungsZeile;
import 'pw_sicherung_screen.dart';
import 'verschluesselung_screen.dart';
import 'wiederherstellungsschluessel_screen.dart';

/// Farbe der Ampel (unbekannt: neutral, nie grün).
Color absicherungFarbe(AbsicherungAmpel a) => switch (a) {
  AbsicherungAmpel.gruen => kTerminal,
  AbsicherungAmpel.gelb => kWarn,
  AbsicherungAmpel.rot => kDanger,
  AbsicherungAmpel.unbekannt => kTextMuted,
};

/// Die Pille mit Wort (nie allein durch Farbe).
class AbsicherungPille extends StatelessWidget {
  final AbsicherungsStatus status;
  const AbsicherungPille(this.status, {super.key});

  @override
  Widget build(BuildContext context) => StatusPill('● ${status.wort}', color: absicherungFarbe(status.ampel));
}

/// Öffnet die Seite, auf der die Person den Schritt erledigt. Fehler beim Vorbereiten (z. B. Schlüsselspeicher) werden als Hinweis gezeigt, nie als Ausnahme.
Future<void> absicherungSchrittOeffnen(BuildContext context, WidgetRef ref, AbsicherungSchritt schritt) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final e2ee = ref.read(e2eeProvider.notifier);
  Future<void> seite(Widget w) => nav.push<void>(MaterialPageRoute(builder: (_) => w));
  try {
    switch (schritt) {
      case AbsicherungSchritt.einrichten || AbsicherungSchritt.geraetVerbinden || AbsicherungSchritt.geraetNeuVerbinden:
        // dort stehen die Wege mit allen Erklärungen (Einrichten, Verbinden, neu verbinden)
        await seite(const VerschluesselungScreen());
      case AbsicherungSchritt.passwortSicherung || AbsicherungSchritt.passwortSicherungErneuern:
        await seite(const PwSicherungScreen());
      case AbsicherungSchritt.wiederherstellungsschluessel:
        final ersatz = ref.read(e2eeProvider).hatSicherung;
        final einrichtung = await e2ee.neuerWiederherstellungsschluessel();
        await seite(WiederherstellungsschluesselScreen(einrichtung: einrichtung, ersatz: ersatz));
    }
  } on Object catch (e) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(fehlerText(e))));
  }
  // nach der Rückkehr den Stand neu laden (die Ampel rechnet daraus)
  unawaited(e2ee.laden());
}

/// Profil: die Ampel immer sichtbar, mit Wort und einem Satz; ein Tipp öffnet die Seite.
class AbsicherungsZeile extends ConsumerWidget {
  final VoidCallback onTap;
  const AbsicherungsZeile({super.key, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(absicherungProvider);
    return Semantics(
      label: 'Bin ich abgesichert? ${a.wort}',
      child: EinstellungsZeile(
        icon: Icons.health_and_safety_outlined,
        titel: 'Bin ich abgesichert?',
        untertitel: a.ampel == AbsicherungAmpel.unbekannt ? 'stand wird geprüft' : '${a.wege} von 3 wegen zum schlüssel',
        status: StatusPill('● ${a.antwort}', color: absicherungFarbe(a.ampel)),
        onTap: onTap,
      ),
    );
  }
}

/// Startseite: nur wenn es etwas zu tun gibt (gelb, rot oder ein nicht verbundenes Gerät). Bei grün und unbekannt bleibt die Startseite ruhig.
class AbsicherungsKarte extends ConsumerWidget {
  const AbsicherungsKarte({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final a = ref.watch(absicherungProvider);
    final naechster = a.naechster;
    if (a.ampel == AbsicherungAmpel.unbekannt || naechster == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Semantics(
        container: true,
        label: 'Absicherung deines Schlüssels: ${a.wort}. ${a.erklaerung}',
        child: LxCard(
          onTap: () => _seite(context),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [const MonoLabel('// absicherung'), AbsicherungPille(a)],
              ),
              const SizedBox(height: 8),
              Text(a.erklaerung, style: const TextStyle(fontSize: 14, height: 1.4, color: kText)),
              const SizedBox(height: 12),
              HauptKnopf(text: schrittText(naechster), onPressed: () => unawaited(absicherungSchrittOeffnen(context, ref, naechster))),
              const SizedBox(height: 4),
              Align(alignment: Alignment.centerLeft, child: LinkKnopf('Einzelheiten', onPressed: () => _seite(context))),
            ],
          ),
        ),
      ),
    );
  }

  void _seite(BuildContext context) => unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const AbsicherungScreen())));
}

/// Die Seite: Ampel, die drei Wege, nächste Schritte.
class AbsicherungScreen extends ConsumerStatefulWidget {
  const AbsicherungScreen({super.key});

  @override
  ConsumerState<AbsicherungScreen> createState() => _AbsicherungScreenState();
}

class _AbsicherungScreenState extends ConsumerState<AbsicherungScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(ref.read(e2eeProvider.notifier).laden()));
  }

  static String _tag(DateTime? d) => d == null ? '' : DateFormat('dd.MM.yyyy').format(d.toLocal());

  @override
  Widget build(BuildContext context) {
    final a = ref.watch(absicherungProvider);
    final s = ref.watch(e2eeProvider);
    final hierBereit = s.status == E2eeStatus.bereit;
    final andere = a.geraeteMitSchluessel;
    return AuthSeite(
      label: '// absicherung',
      titel: 'Bin ich abgesichert?',
      maxBreite: kMaxContentWidth,
      kinder: [
        const Text(
          'Dein Schlüssel schützt deine Chats. Geht er verloren, ist dein Chat-Verlauf weg, und niemand kann ihn dir zurückgeben, auch kein Admin. '
          'Du bist abgesichert, wenn dein Schlüssel auf mindestens zwei Wegen erhalten bleibt und eine davon bestätigt ist.',
          style: TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
        ),
        const SizedBox(height: 16),
        Semantics(
          liveRegion: true,
          child: LxCard(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AbsicherungPille(a),
                const SizedBox(height: 8),
                Text(a.erklaerung, style: const TextStyle(fontSize: 14, height: 1.4, color: kText)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        const MonoLabel('// deine wege'),
        const SizedBox(height: 8),
        _Weg(
          da: a.geraetWeg,
          titel: 'Gerät mit deinem Schlüssel',
          text: a.geraetWeg
              ? (hierBereit ? 'dieses Gerät${andere != null && andere > 1 ? ' und ${andere - 1} weitere' : ''}' : 'ein anderes Gerät')
              : 'auf diesem Gerät fehlt dein Schlüssel',
        ),
        if (a.pwVerfuegbar || a.pwWeg)
          _Weg(
            da: a.pwWeg,
            titel: 'Passwort-Sicherung',
            text: a.pwWeg ? 'bestätigt seit ${_tag(a.pwSeit)}' : (s.pwSicherungVeraltet ? 'veraltet, bitte erneuern' : 'nicht angelegt'),
          ),
        _Weg(
          da: a.wiederherstellungWeg,
          titel: 'Wiederherstellungsschlüssel',
          text: a.wiederherstellungWeg ? 'liegt beim Server seit ${_tag(a.wiederherstellungSeit)}' : 'nicht angelegt',
        ),
        const SizedBox(height: 8),
        if (a.ampel == AbsicherungAmpel.unbekannt) ...[
          const MeldungsBox('Der Stand ließ sich gerade nicht laden. Prüfe deine Verbindung und öffne die Seite noch einmal.'),
          const SizedBox(height: 8),
          ZweitKnopf(text: 'Erneut versuchen', icon: Icons.refresh, onPressed: () => unawaited(ref.read(e2eeProvider.notifier).laden())),
        ] else if (a.schritte.isNotEmpty) ...[
          const MonoLabel('// nächste schritte'),
          const SizedBox(height: 8),
          for (var i = 0; i < a.schritte.length; i++) ...[
            if (i == 0)
              HauptKnopf(text: schrittText(a.schritte[i]), onPressed: () => unawaited(absicherungSchrittOeffnen(context, ref, a.schritte[i])))
            else
              ZweitKnopf(text: schrittText(a.schritte[i]), onPressed: () => unawaited(absicherungSchrittOeffnen(context, ref, a.schritte[i]))),
            const SizedBox(height: 4),
            Text(schrittErklaerung(a.schritte[i]), style: const TextStyle(fontSize: 12, height: 1.4, color: kTextMuted)),
            const SizedBox(height: 12),
          ],
        ] else ...[
          const Text('Es ist nichts zu tun. Die App prüft das bei jedem Öffnen neu.', style: TextStyle(fontSize: 14, color: kTerminal)),
        ],
        if (hierBereit && a.wiederherstellungWeg) ...[
          const SizedBox(height: 8),
          const MonoLabel('// notfallblatt'),
          const SizedBox(height: 8),
          const Text(
            'Den Wiederherstellungsschlüssel zeigt die App nur einmal, bei der Einrichtung. Brauchst du ein neues Notfallblatt, erzeuge einen neuen Wiederherstellungsschlüssel: '
            'der bisherige gilt dann nicht mehr.',
            style: TextStyle(fontSize: 13, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 8),
          ZweitKnopf(
            text: 'Neuen Schlüssel und Notfallblatt erzeugen',
            icon: Icons.picture_as_pdf_outlined,
            onPressed: () => unawaited(absicherungSchrittOeffnen(context, ref, AbsicherungSchritt.wiederherstellungsschluessel)),
          ),
        ],
      ],
    );
  }
}

class _Weg extends StatelessWidget {
  final bool da;
  final String titel;
  final String text;
  const _Weg({required this.da, required this.titel, required this.text});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$titel: ${da ? 'vorhanden' : 'fehlt'}, $text',
    child: Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LxCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            children: [
              Icon(da ? Icons.check_circle : Icons.radio_button_unchecked, size: 22, color: da ? kTerminal : kWarn),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(titel, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text(text, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextMuted)),
                  ],
                ),
              ),
              Text(da ? 'ja' : 'offen', style: TextStyle(fontFamily: kFontMono, fontSize: 11, color: da ? kTerminal : kWarn)),
            ],
          ),
        ),
      ),
    ),
  );
}
