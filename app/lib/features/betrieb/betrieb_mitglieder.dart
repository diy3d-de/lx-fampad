// Betrieb, Paket 2a: Seite "Mitglieder und Geräte" (nur Betreiber). Mitglieder mit Rolle, Ampel, letzter Anmeldung, Wegen zum Schlüssel und Geräten (Name,
// Plattform, App-Version, zuletzt gesehen, gemeldeter Schlüsselstand); gesperrte Konten mit "Entsperren". Aktionen nur über vorhandene Wege:
// "Passwort zurücksetzen" öffnet den bekannten Admin-Ablauf (Familie verwalten), "Andere Geräte abmelden" gilt für die EIGENEN Geräte (vorhandene Routen
// GET /devices und DELETE /devices/:id, mit Rückfrage). Zeigt nie E-Mail, Schlüssel, Sicherungen oder Netzadressen, und nie einen Servertext.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/fampad_api.dart';
import '../../data/auth/auth_state.dart';
import '../../data/betrieb/betrieb_modelle.dart';
import '../../data/betrieb/betrieb_state.dart';
import '../../ui/widgets.dart';
import '../admin/admin_screen.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';
import 'betrieb_anzeige.dart';

class BetriebMitgliederSeite extends ConsumerStatefulWidget {
  /// Lädt die Liste (mit Step-up-Abfrage).
  final Future<void> Function() neuLaden;
  const BetriebMitgliederSeite({super.key, required this.neuLaden});

  @override
  ConsumerState<BetriebMitgliederSeite> createState() => _BetriebMitgliederSeiteState();
}

class _BetriebMitgliederSeiteState extends ConsumerState<BetriebMitgliederSeite> with AktionsZustand<BetriebMitgliederSeite> {
  Future<void> _entsperren(BetriebMitglied m) async {
    final geklappt = await ausfuehren(() async {
      await mitStepUp(context, ref, () => ref.read(betriebMitgliederProvider.notifier).entsperren(m.id));
    });
    if (geklappt && mounted) zeigeHinweis(context, 'Konto von ${m.name} entsperrt.');
  }

  Future<void> _andereGeraeteAbmelden() async {
    final ja = await showDialog<bool>(
      useRootNavigator: false,
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Andere Geräte abmelden?'),
        content: const Text(
          'Alle deine anderen Geräte werden abgemeldet und müssen sich neu anmelden. Dieses Gerät bleibt angemeldet. '
          'Dein Schlüssel für die Chats bleibt auf den Geräten erhalten.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Abbrechen')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), style: TextButton.styleFrom(foregroundColor: kDanger), child: const Text('Abmelden')),
        ],
      ),
    );
    if (ja != true || !mounted) return;
    final geklappt = await ausfuehren(() async {
      final FampadApi api = ref.read(apiProvider);
      final liste = await api.geraete();
      for (final g in liste) {
        if (!g.current) await api.geraetAbmelden(g.id);
      }
      await widget.neuLaden();
    });
    if (geklappt && mounted) zeigeHinweis(context, 'Andere Geräte abgemeldet.');
  }

  void _passwortZuruecksetzen() {
    // der bekannte Admin-Ablauf (Familie verwalten > Mitglieder > Passwort zurücksetzen), samt Step-up und Link
    unawaited(Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => const AdminScreen())));
  }

  @override
  Widget build(BuildContext context) {
    final z = ref.watch(betriebMitgliederProvider);
    final istAdmin = ref.watch(authProvider.select((s) => s.istAdmin));
    final jetzt = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const MonoLabel('Mitglieder und Geräte'),
        const SizedBox(height: 8),
        if (z.fehler != null) ...[MeldungsBox(fehlerText(z.fehler!)), const SizedBox(height: 12)],
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (!z.geladen && z.fehler == null)
          z.laedt
              ? const MeldungsBox('Die Mitglieder werden geladen …', fehler: false)
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Gerätenamen und Anmeldungen brauchen eine frische Bestätigung.', style: TextStyle(fontSize: 13, color: kTextMuted)),
                    const SizedBox(height: 8),
                    ZweitKnopf(text: 'Bestätigen und anzeigen', icon: Icons.verified_user_outlined, onPressed: () => unawaited(widget.neuLaden())),
                  ],
                ),
        if (z.geladen && z.mitglieder.isEmpty) const Text('Keine Mitglieder.', style: TextStyle(color: kTextMuted)),
        for (final m in z.mitglieder) ...[
          _MitgliedKarte(
            m: m,
            jetzt: jetzt,
            beschaeftigt: laeuft,
            passwortZuruecksetzen: istAdmin && !m.ich ? _passwortZuruecksetzen : null,
            andereGeraeteAbmelden: m.ich && m.geraete.length > 1 ? _andereGeraeteAbmelden : null,
            entsperren: m.gesperrtSekunden != null ? () => unawaited(_entsperren(m)) : null,
          ),
          const SizedBox(height: 12),
        ],
        const Text(
          '„Passwort zurücksetzen“ öffnet den Ablauf unter Familie verwalten: ein Einmal-Link, der zweite Faktor bleibt Pflicht, die Person bekommt einen Hinweis. '
          'Der Schlüsselstand eines Geräts wird vom Gerät selbst gemeldet (kein Beweis). Es gibt hier keine Schlüssel, Sicherungen oder Netzadressen zu sehen.',
          style: TextStyle(fontSize: 12, color: kTextMuted),
        ),
      ],
    );
  }
}

class _MitgliedKarte extends StatelessWidget {
  final BetriebMitglied m;
  final DateTime jetzt;
  final bool beschaeftigt;
  final VoidCallback? passwortZuruecksetzen;
  final VoidCallback? andereGeraeteAbmelden;
  final VoidCallback? entsperren;
  const _MitgliedKarte({required this.m, required this.jetzt, required this.beschaeftigt, this.passwortZuruecksetzen, this.andereGeraeteAbmelden, this.entsperren});

  @override
  Widget build(BuildContext context) {
    final s = m.schluessel;
    final anmeldung = [
      if (m.passkeys > 0) m.passkeys == 1 ? 'Passkey' : '${m.passkeys} Passkeys',
      if (m.passwort) 'Passwort',
      if (m.totp) 'Authenticator',
    ].join(' · ');
    final geraeteText = m.geraete.isEmpty ? 'keine Geräte' : (m.geraete.length == 1 ? '1 Gerät' : '${m.geraete.length} Geräte');
    return Semantics(
      container: true,
      label: '${m.name}, ${m.rolle.label}, Schlüssel-Ampel ${ampelText(s.ampel)}, $geraeteText',
      child: LxCard(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.name + (m.ich ? ' (du)' : ''), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          ...rollenPillen(m.rolle, m.familienrolle),
                          if (m.betreiber) const RollenPille('betreiber', farbe: kAccent),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill(ampelText(s.ampel), color: ampelFarbe(s.ampel)),
              ],
            ),
            const SizedBox(height: 8),
            Text(ampelErklaerung(s), style: const TextStyle(fontSize: 13, color: kTextMuted)),
            const SizedBox(height: 4),
            Text(
              'zuletzt angemeldet: ${m.letzteAnmeldung == null ? '–' : zeitText(m.letzteAnmeldung!, jetzt)}${anmeldung.isEmpty ? '' : ' · $anmeldung'}',
              style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted),
            ),
            if (m.geraeteZurueck > 0) ...[
              const SizedBox(height: 8),
              StatusPill(m.geraeteZurueck == 1 ? '1 Gerät auf älterer Version' : '${m.geraeteZurueck} Geräte auf älterer Version', color: kWarn),
            ],
            if (s.hatSchluessel) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _Weg(text: 'Gerät', da: s.wege.geraet),
                  _Weg(text: 'Passwort-Sicherung', da: s.wege.passwortSicherung),
                  _Weg(text: 'Wiederherstellung', da: s.wege.wiederherstellung),
                ],
              ),
              if (s.altesPasswortVerfahren || s.archiv > 0) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    if (s.altesPasswortVerfahren) const StatusPill('altes Passwort-Verfahren', color: kWarn),
                    if (s.archiv > 0) StatusPill(s.archiv == 1 ? '1 archivierte Sicherung' : '${s.archiv} archivierte Sicherungen', color: kTextMuted),
                  ],
                ),
              ],
            ],
            if (m.gesperrtSekunden != null) ...[
              const SizedBox(height: 10),
              // Wrap statt Row: bei großer Schrift rutscht der Knopf in die nächste Zeile, nichts läuft über
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  StatusPill('gesperrt · ${sperreText(m.gesperrtSekunden!)}', color: kDanger),
                  TextButton(onPressed: beschaeftigt ? null : entsperren, style: TextButton.styleFrom(minimumSize: const Size(44, 44)), child: const Text('Entsperren')),
                ],
              ),
            ],
            const SizedBox(height: 10),
            const Divider(height: 1, color: kBorderSoft),
            const SizedBox(height: 8),
            MonoLabel(geraeteText),
            for (final g in m.geraete) _GeraetZeile(g: g, jetzt: jetzt),
            if (s.ereignisse.isNotEmpty) ...[
              const SizedBox(height: 10),
              const MonoLabel('Letzte Schlüsselereignisse'),
              const SizedBox(height: 4),
              for (final e in s.ereignisse)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${schluesselEreignisText(e.art)} · ${zeitText(e.zeit, jetzt)}', style: const TextStyle(fontSize: 13)),
                ),
            ],
            if (passwortZuruecksetzen != null || andereGeraeteAbmelden != null) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (passwortZuruecksetzen != null) _AktionsKnopf(text: 'Passwort zurücksetzen', icon: Icons.password, onPressed: beschaeftigt ? null : passwortZuruecksetzen),
                  if (andereGeraeteAbmelden != null) _AktionsKnopf(text: 'Andere Geräte abmelden', icon: Icons.logout, onPressed: beschaeftigt ? null : andereGeraeteAbmelden),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Weg extends StatelessWidget {
  final String text;
  final bool da;
  const _Weg({required this.text, required this.da});

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '$text: ${da ? 'vorhanden' : 'fehlt'}',
    excludeSemantics: true,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(da ? Icons.check_circle_outline : Icons.remove_circle_outline, size: 16, color: da ? kTerminal : kTextMuted),
        const SizedBox(width: 4),
        Text(text, style: TextStyle(fontSize: 13, color: da ? kText : kTextMuted)),
      ],
    ),
  );
}

class _GeraetZeile extends StatelessWidget {
  final BetriebGeraet g;
  final DateTime jetzt;
  const _GeraetZeile({required this.g, required this.jetzt});

  @override
  Widget build(BuildContext context) {
    final info = [plattformText(g.plattform), if (g.appVersion != null) g.appVersion!, 'zuletzt ${g.zuletztGesehen == null ? '–' : zeitText(g.zuletztGesehen!, jetzt)}'].join(' · ');
    return Semantics(
      container: true,
      label: '${g.name}, $info, ${geraetSchluesselText(g.schluessel)}${g.appStand == null ? '' : ', ${appStandText(g.appStand!)}'}',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(info, style: const TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 11, color: kTextMuted)),
                    // nur wer zurückliegt, bekommt eine eigene Marke (sonst wäre jede Zeile bunt)
                    if (g.appStand != null && g.appStand!.zurueck) ...[const SizedBox(height: 4), StatusPill(appStandText(g.appStand!), color: appStandFarbe(g.appStand!))],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: StatusPill(geraetSchluesselText(g.schluessel), color: geraetSchluesselFarbe(g.schluessel)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AktionsKnopf extends StatelessWidget {
  final String text;
  final IconData icon;
  final VoidCallback? onPressed;
  const _AktionsKnopf({required this.text, required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(minimumSize: const Size(44, 48)),
    icon: Icon(icon, size: 18),
    label: Text(text, textAlign: TextAlign.center),
  );
}
