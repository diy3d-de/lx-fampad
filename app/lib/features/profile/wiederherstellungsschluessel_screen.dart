// Wiederherstellungsschlüssel einmalig anzeigen, dann VERDECKEN und vollständig eintippen lassen (Probe: Der Schlüssel darf während der Kontrolle nicht mehr
// zu sehen sein, sonst prüft sie nichts) und erst dann die Sicherung beim Server ablegen. "Später sichern" bleibt möglich; die Sicherung gilt dann als
// "offen" (Profil > Verschlüsselung zeigt es sichtbar an). Bildschirmfoto-Schutz (FLAG_SECURE) und Zwischenablage nur auf Klick wie bei den Wiederherstellungscodes.
import 'dart:typed_data' show Uint8List;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/bytes.dart';
import '../../data/crypto/notfallblatt.dart';
import '../../data/crypto/code32.dart';
import '../../data/crypto/e2ee_state.dart';
import '../../data/crypto/wiederherstellung.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart';
import '../auth/step_up.dart';

class WiederherstellungsschluesselScreen extends ConsumerStatefulWidget {
  final Einrichtung einrichtung;

  /// true: neuer Schlüssel für einen schon eingerichteten Personenschlüssel (ersetzt die bisherige Sicherung).
  final bool ersatz;
  const WiederherstellungsschluesselScreen({super.key, required this.einrichtung, this.ersatz = false});

  @override
  ConsumerState<WiederherstellungsschluesselScreen> createState() => _WiederherstellungsschluesselScreenState();
}

class _WiederherstellungsschluesselScreenState extends ConsumerState<WiederherstellungsschluesselScreen> with AktionsZustand<WiederherstellungsschluesselScreen> {
  late final List<String> _gruppen = Wiederherstellung.gruppen(widget.einrichtung.wiederherstellungsschluessel);
  final _eingabe = TextEditingController();

  /// true: der Schlüssel ist sichtbar; false: verdeckt, Probe durch Eintippen.
  bool _zeigen = true;

  @override
  void initState() {
    super.initState();
    _eingabe.addListener(_geaendert);
  }

  void _geaendert() => setState(() {});

  @override
  void dispose() {
    // der Schlüssel war nur für diese Anzeige im Arbeitsspeicher
    loescheBytes(widget.einrichtung.wiederherstellungsschluessel);
    _eingabe.removeListener(_geaendert);
    _eingabe.clear(); // die eingetippte Kopie des Schlüssels nicht im Controller liegen lassen
    _eingabe.dispose();
    super.dispose();
  }

  bool get _richtig => Wiederherstellung.stimmt(widget.einrichtung.wiederherstellungsschluessel, _eingabe.text);

  /// Hat die Person schon etwas in der Länge eines Schlüssels eingetippt, das nicht stimmt? (Erst dann, damit nicht beim Tippen gemeckert wird.)
  bool get _falsch => !_richtig && Code32.normalisieren(_eingabe.text).length >= kCodeZeichen;

  void _verdecken() => setState(() {
    _zeigen = false;
    _eingabe.clear();
  });

  void _nochmalAnsehen() => setState(() {
    _zeigen = true;
    _eingabe.clear();
  });

  Future<void> _fertig() async {
    final ok = await ausfuehren(() async {
      final ergebnis = await mitStepUp(context, ref, () async {
        await ref.read(e2eeProvider.notifier).sicherungAblegen(widget.einrichtung);
        return true;
      });
      if (ergebnis != true) throw const EingabeFehler('Die Sicherung wurde nicht abgelegt. Bestätige mit Passkey oder Code, um sie zu speichern.');
    });
    if (ok && mounted) {
      zeigeHinweis(context, 'Wiederherstellungsschlüssel liegt jetzt als Sicherung beim Server.');
      Navigator.of(context).pop();
    }
  }

  /// Notfallblatt (PDF mit Schlüssel und Kurzanleitung) speichern: nur auf Klick, nur solange der Schlüssel hier sichtbar ist; der Schlüssel landet in keinem Log.
  Future<void> _notfallblatt() async {
    final name = ref.read(authProvider).user?.displayName ?? '';
    final speichern = ref.read(notfallblattSpeichernProvider);
    Uint8List? pdf;
    try {
      pdf = notfallblattPdf(gruppen: _gruppen, name: name);
      final gespeichert = await speichern(kNotfallblattDateiname, pdf);
      if (gespeichert && mounted) {
        // im Web meldet der Browser weder Ziel noch Abbruch: nur "angestoßen", nicht "gespeichert"
        zeigeHinweis(
          context,
          kIsWeb
              ? 'Der Browser lädt das Notfallblatt herunter. Schau in deinen Downloads nach, drucke es aus, lege es sicher ab und lösche danach die Datei.'
              : 'Notfallblatt gespeichert. Drucke es aus, lege es sicher ab und lösche danach die Datei.',
        );
      }
    } on Object {
      if (mounted) zeigeHinweis(context, 'Das Notfallblatt ließ sich nicht speichern. Schreibe den Schlüssel stattdessen ab.');
    } finally {
      pdf?.fillRange(0, pdf.length, 0); // die Kopie im Arbeitsspeicher überschreiben
    }
  }

  Future<void> _spaeter() async {
    final ja = await showDialog<bool>(useRootNavigator: false,
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Später sichern?'),
        content: const Text(
          'Ohne bestätigten Wiederherstellungsschlüssel verlierst du deinen Schlüssel und deinen Chat-Verlauf, wenn du alle Geräte verlierst, und niemand kann ihn dir zurückgeben. '
          'Deine Absicherung bleibt auf der Startseite und unter Profil › Verschlüsselung auf „offen“, bis du den Schlüssel bestätigt hast.',
        ),
        scrollable: true,
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Zurück')),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Später')),
        ],
      ),
    );
    if (ja == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false, // erst nach der Bestätigung oder dem ausdrücklichen "Später"
    child: BildschirmSchutz(
      child: AuthSeite(
        zurueck: false,
        label: '// einmalig',
        titel: 'Wiederherstellungsschlüssel',
        kinder: [
          Text(
            widget.ersatz
                ? 'Dein bisheriger Wiederherstellungsschlüssel wird durch diesen ersetzt, sobald du ihn bestätigt hast.'
                : 'Mit diesem Schlüssel stellst du deinen Verschlüsselungsschlüssel wieder her, wenn du alle Geräte verlierst. '
                      'Er wird nur jetzt angezeigt. Wer ihn kennt, kann deine Inhalte lesen: bewahre ihn sicher auf, am besten ausgedruckt oder im Passwortmanager.',
            style: const TextStyle(fontSize: 14, height: 1.5, color: kTextMuted),
          ),
          const SizedBox(height: 16),
          if (_zeigen) ...[
            Semantics(
              label: 'Wiederherstellungsschlüssel in $kCodeGruppen Gruppen: ${_gruppen.map((g) => g.split('').join(' ')).join(', ')}',
              child: LxCard(
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (var i = 0; i < _gruppen.length; i++)
                      Container(
                        constraints: const BoxConstraints(minHeight: 44, minWidth: 84),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(10)),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${i + 1}', style: const TextStyle(fontFamily: kFontMono, fontSize: 10, color: kTextFaint)),
                            Text(_gruppen[i], style: const TextStyle(fontFamily: kFontMono, fontSize: 18, letterSpacing: 1.5, color: kAccent)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            ZweitKnopf(
              text: 'Schlüssel kopieren',
              icon: Icons.copy,
              onPressed: () => inZwischenablage(
                context,
                Wiederherstellung.anzeigen(widget.einrichtung.wiederherstellungsschluessel),
                'Schlüssel kopiert. Lege ihn sicher ab und lösche ihn aus der Zwischenablage.',
                geheim: true,
              ),
            ),
            const SizedBox(height: 8),
            ZweitKnopf(text: 'Notfallblatt speichern (PDF)', icon: Icons.picture_as_pdf_outlined, onPressed: laeuft ? null : _notfallblatt),
            const SizedBox(height: 4),
            const Text(
              'Das Notfallblatt enthält den Schlüssel und eine Kurzanleitung zum Ausdrucken. Speichere es nur dort, wo du es danach drucken und löschen kannst.',
              style: TextStyle(fontSize: 12, height: 1.4, color: kTextMuted),
            ),
            const SizedBox(height: 16),
            const Text(
              'Schreibe ihn auf, drucke das Notfallblatt oder lege ihn im Passwortmanager ab. Im nächsten Schritt wird er verdeckt, und du tippst ihn vollständig ab: So weißt du, dass er stimmt.',
              style: TextStyle(fontSize: 14, height: 1.4, color: kText),
            ),
            const SizedBox(height: 12),
            HauptKnopf(text: 'Ich habe ihn notiert, weiter', icon: Icons.visibility_off_outlined, onPressed: laeuft ? null : _verdecken),
          ] else ...[
            const MonoLabel('// kontrolle'),
            const SizedBox(height: 8),
            Semantics(
              label: 'Der Schlüssel ist verdeckt',
              child: LxCard(
                child: Row(
                  children: [
                    Icon(Icons.visibility_off_outlined, color: kTextMuted),
                    SizedBox(width: 12),
                    Expanded(child: Text('Der Schlüssel ist jetzt verdeckt.', style: TextStyle(fontSize: 14, color: kText))),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Tippe den ganzen Schlüssel aus deiner Notiz ab (Groß-/Kleinschreibung, Leerzeichen und Bindestriche sind egal). Nicht einfügen: Schreibe oder tippe ihn aus deiner Notiz ab.',
              style: TextStyle(fontSize: 14, height: 1.4, color: kText),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _eingabe,
              enabled: !laeuft,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              minLines: 3,
              maxLines: 5,
              keyboardType: TextInputType.multiline,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: kFontMono, fontSize: 16, letterSpacing: 1.5, color: kAccent),
              decoration: const InputDecoration(labelText: 'Wiederherstellungsschlüssel'),
            ),
            if (_falsch) ...[
              const SizedBox(height: 8),
              const Text('Das stimmt noch nicht mit dem Schlüssel überein. Prüfe deine Notiz.', style: TextStyle(fontSize: 13, color: kDanger)),
            ],
            const SizedBox(height: 8),
            HauptKnopf(text: 'Stimmt, jetzt sichern', laeuft: laeuft, onPressed: _richtig ? _fertig : null),
            const SizedBox(height: 4),
            LinkKnopf('Schlüssel nochmal ansehen', icon: Icons.visibility_outlined, onPressed: laeuft ? null : _nochmalAnsehen),
          ],
          if (fehler != null) ...[const SizedBox(height: 8), MeldungsBox(fehler!)],
          const SizedBox(height: 4),
          LinkKnopf('Später sichern', onPressed: laeuft ? null : _spaeter),
        ],
      ),
    ),
  );
}
