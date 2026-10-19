// Neue Einladung: Auswahl (Rolle, Gültigkeit, PIN, Freigabe) und die Ergebnisseite mit QR-Code, Link und PIN.
// Token und PIN gibt der Server nur in der Antwort auf das Erzeugen heraus; die Ergebnisseite ist deshalb die einzige Stelle,
// an der sie erscheinen (Android: Bildschirmfoto-Schutz). Die Zwischenablage wird nur auf Klick befüllt.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/qr_anzeige.dart';

/// Wählbare Gültigkeiten (Server: 1 bis 168 Stunden, Standard 24).
const kGueltigkeiten = <(String, int)>[('1 Stunde', 1), ('6 Stunden', 6), ('24 Stunden', 24), ('3 Tage', 72), ('7 Tage', 168)];

String stundenText(int h) {
  for (final (t, s) in kGueltigkeiten) {
    if (s == h) return t;
  }
  return '$h Stunden';
}

class EinladungsWahl {
  final Role rolle;
  final int stunden;
  final bool pin;
  final bool? freigabe;
  const EinladungsWahl(this.rolle, this.stunden, this.pin, this.freigabe);
}

/// Bottom-Sheet "Neue Einladung". [eigeneRolle] bestimmt die wählbaren Rollen (Eltern: nur Kind).
Future<EinladungsWahl?> neueEinladungWaehlen(BuildContext context, Role eigeneRolle) => showModalBottomSheet<EinladungsWahl>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _EinladungsBlatt(eigeneRolle: eigeneRolle),
);

class _EinladungsBlatt extends StatefulWidget {
  final Role eigeneRolle;
  const _EinladungsBlatt({required this.eigeneRolle});

  @override
  State<_EinladungsBlatt> createState() => _EinladungsBlattState();
}

class _EinladungsBlattState extends State<_EinladungsBlatt> {
  late Role _rolle = widget.eigeneRolle.darfEinladen.contains(Role.child) ? Role.child : widget.eigeneRolle.darfEinladen.first;
  int _stunden = 24;
  bool _pin = false;
  bool? _freigabeWahl;

  /// Freigabe durch einen Admin gibt es nur auf ausdrücklichen Wunsch (Standard: aus).
  bool get _freigabe => _freigabeWahl ?? false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const MonoLabel('// neue einladung'),
          const SizedBox(height: 4),
          const Text('Wen möchtest du einladen?', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: kTextStrong)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final r in widget.eigeneRolle.darfEinladen)
                ChoiceChip(
                  label: Text(r.label),
                  selected: _rolle == r,
                  onSelected: (_) => setState(() => _rolle = r),
                ),
            ],
          ),
          if (_rolle == Role.admin) ...[
            const SizedBox(height: 8),
            const Text('Für eine Admin-Einladung musst du dich noch einmal bestätigen.', style: TextStyle(fontSize: 12, color: kTextMuted)),
          ],
          const SizedBox(height: 16),
          const MonoLabel('// gültigkeit', color: kTextMuted),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final (t, h) in kGueltigkeiten) ChoiceChip(label: Text(t), selected: _stunden == h, onSelected: (_) => setState(() => _stunden = h)),
            ],
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _pin,
            onChanged: (v) => setState(() => _pin = v),
            title: const Text('PIN verlangen'),
            subtitle: const Text('Du bekommst eine 6-stellige PIN, die du getrennt weitergibst.'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _freigabe,
            onChanged: (v) => setState(() => _freigabeWahl = v),
            title: const Text('Freigabe durch Admin'),
            subtitle: const Text('Das neue Mitglied kann sich erst nach der Freigabe durch einen Admin anmelden.'),
          ),
          const SizedBox(height: 12),
          HauptKnopf(
            text: 'Einladung erstellen',
            icon: Icons.qr_code_2,
            onPressed: () => Navigator.of(context).pop(EinladungsWahl(_rolle, _stunden, _pin, _freigabe ? true : null)),
          ),
        ],
      ),
    ),
  );
}

/// Ergebnisseite: QR-Code und Link der neuen Einladung, ggf. PIN. Wird nur einmal gezeigt.
class EinladungErstelltSeite extends StatelessWidget {
  final CreatedInvite einladung;
  final Role? rolle;
  final String? fuer;
  const EinladungErstelltSeite({super.key, required this.einladung, this.rolle, this.fuer});

  @override
  Widget build(BuildContext context) {
    final bis = DateFormat('d. MMM yyyy, HH:mm', 'de_DE').format(einladung.expiresAt.toLocal());
    return BildschirmSchutz(
      child: AuthSeite(
        label: '// einladung bereit',
        titel: fuer == null ? 'Einladung erstellt' : 'Zurücksetzen für $fuer',
        kinder: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (rolle != null) RollenPille(rolle!.label),
              RollenPille('gültig bis $bis', farbe: kTextMuted),
              if (einladung.requireApproval) const RollenPille('freigabe nötig', farbe: kWarn),
            ],
          ),
          const SizedBox(height: 16),
          QrAnzeige(daten: einladung.link, beschreibung: 'QR-Code der Einladung'),
          const SizedBox(height: 4),
          const Center(child: Text('Zum Scannen in der App: „Einladung per QR-Code annehmen“', style: TextStyle(fontSize: 12, color: kTextMuted), textAlign: TextAlign.center)),
          const SizedBox(height: 16),
          const MonoLabel('// link', color: kTextMuted),
          const SizedBox(height: 4),
          Semantics(label: 'Einladungslink', child: SelectableText(einladung.link, style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kAccent))),
          const SizedBox(height: 8),
          ZweitKnopf(text: 'Link kopieren', icon: Icons.copy, onPressed: () => inZwischenablage(context, einladung.link, 'Link kopiert.', geheim: true)),
          if (einladung.pin != null) ...[
            const SizedBox(height: 16),
            const MonoLabel('// pin', color: kTextMuted),
            const SizedBox(height: 4),
            Semantics(label: 'PIN der Einladung', child: SelectableText(einladung.pin!, style: const TextStyle(fontFamily: kFontMono, fontSize: 28, letterSpacing: 6, color: kAccent))),
            const SizedBox(height: 4),
            const Text('Gib die PIN getrennt vom Link weiter, z. B. am Telefon.', style: TextStyle(fontSize: 13, color: kTextMuted)),
            const SizedBox(height: 8),
            ZweitKnopf(text: 'PIN kopieren', icon: Icons.copy, onPressed: () => inZwischenablage(context, einladung.pin!, 'PIN kopiert.', geheim: true)),
          ],
          const SizedBox(height: 16),
          const MeldungsBox(
            'Link und PIN werden nur jetzt angezeigt. Später siehst du in der Liste nur den Status der Einladung. Du kannst sie dort verlängern oder widerrufen.',
            fehler: false,
          ),
          const SizedBox(height: 16),
          HauptKnopf(text: 'Fertig', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}
