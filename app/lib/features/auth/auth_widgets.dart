// Gemeinsame Bausteine der Anmelde-, Konto- und Admin-Screens: Seitenrahmen im Mockup-Stil, Fehler-/Hinweisboxen,
// Knopf mit Ladeanzeige, Bildschirmfoto-Schutz und Hilfen zum Ausführen von Aktionen mit einheitlicher Fehlerbehandlung.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/api/api_error.dart';
import '../../data/auth/auth_state.dart';
import '../../data/crypto/crypto_fehler.dart';
import '../../data/passkey_service.dart';
import '../../ui/widgets.dart';

/// Rahmen eines Vollbild-Screens: Hintergrund mit Schimmer, Kopfzeile mit Zurück-Pfeil, scrollbarer Inhalt (Breite begrenzt).
class AuthSeite extends StatelessWidget {
  final String? titel;
  final String? label;
  final List<Widget> kinder;
  final bool zurueck;
  final double maxBreite;
  final Widget? fussleiste;
  final List<Widget> aktionen;

  const AuthSeite({
    super.key,
    this.titel,
    this.label,
    required this.kinder,
    this.zurueck = true,
    this.maxBreite = 480,
    this.fussleiste,
    this.aktionen = const [],
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: kBg,
    body: LxBackground(
      // Material (transparent) unter dem Hintergrund: ListTile, Switch usw. malen ihre Tinte darauf
      child: Material(
        type: MaterialType.transparency,
        child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxBreite),
            child: Column(
              children: [
                if (zurueck || aktionen.isNotEmpty)
                  Row(
                    children: [
                      if (zurueck)
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
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (label != null) ...[MonoLabel(label!), const SizedBox(height: 4)],
                        if (titel != null) _SeitenTitel(titel!, maxBreite: maxBreite - 48),
                        if (titel != null) const SizedBox(height: 16),
                        ...kinder,
                      ],
                    ),
                  ),
                ),
                if (fussleiste != null) Padding(padding: const EdgeInsets.fromLTRB(24, 0, 24, 16), child: fussleiste),
              ],
            ),
          ),
        ),
      ),
      ),
    ),
  );
}

/// Seitentitel: 26 px; ein einzelnes langes Wort (z. B. "Wiederherstellungscodes") würde auf 360 px mitten im Wort umbrechen,
/// deshalb wird die Schrift gerade so weit verkleinert (mindestens 18 px), dass das längste Wort in eine Zeile passt.
class _SeitenTitel extends StatelessWidget {
  final String text;
  final double maxBreite;
  const _SeitenTitel(this.text, {required this.maxBreite});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final breite = box.maxWidth.isFinite ? box.maxWidth : maxBreite;
      final skala = MediaQuery.textScalerOf(context);
      final laengstes = text.split(RegExp(r'\s+')).fold<String>('', (a, w) => w.length > a.length ? w : a);
      // gemessen wird mit demselben Stil wie beim Zeichnen (Schriftfamilie des Themes, sonst wäre die Messung zu schmal)
      TextStyle stilFuer(double groesse) =>
          DefaultTextStyle.of(context).style.merge(TextStyle(fontSize: groesse, fontWeight: FontWeight.w800, letterSpacing: -0.65, color: kTextStrong));
      var groesse = 26.0;
      while (groesse > 18) {
        final p = TextPainter(text: TextSpan(text: laengstes, style: stilFuer(groesse)), textDirection: TextDirection.ltr, textScaler: skala)..layout();
        final passt = p.width * 1.02 <= breite; // kleine Reserve für Rundung
        p.dispose();
        if (passt) break;
        groesse -= 1;
      }
      return Text(text, style: stilFuer(groesse));
    },
  );
}

/// Markenkopf wie im Login-Mockup: Kachel "lx", Name, Untertitel.
class MarkenKopf extends StatelessWidget {
  const MarkenKopf({super.key});

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Container(
        width: 72,
        height: 72,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: kBorder),
          gradient: RadialGradient(
            center: const Alignment(-0.4, -0.6),
            radius: 1.0,
            colors: [kNeural.withValues(alpha: 0.7), kAccent.withValues(alpha: 0.25)],
          ),
          color: kSurface,
        ),
        child: const Text('lx', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: kAccent, letterSpacing: -0.8)),
      ),
      const SizedBox(height: 14),
      const Text.rich(
        TextSpan(
          children: [
            TextSpan(text: 'lx', style: TextStyle(color: kAccent)),
            TextSpan(text: '-fampad'),
          ],
        ),
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: kTextStrong),
      ),
      const SizedBox(height: 6),
      const Text('// eure familie. euer server.', style: TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted)),
    ],
  );
}

/// Fehler-/Hinweisbox (Meldung in Klartext, nie Interna).
class MeldungsBox extends StatelessWidget {
  final String text;
  final bool fehler;
  const MeldungsBox(this.text, {super.key, this.fehler = true});

  @override
  Widget build(BuildContext context) {
    final farbe = fehler ? kDanger : kAccent;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: farbe.withValues(alpha: 0.08),
          border: Border.all(color: farbe.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(fehler ? Icons.error_outline : Icons.info_outline, size: 18, color: farbe),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4, color: kText))),
          ],
        ),
      ),
    );
  }
}

/// Trennzeile "── oder mit passwort ──".
class MonoTrenner extends StatelessWidget {
  final String text;
  const MonoTrenner(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const Expanded(child: Divider()),
      Flexible(
        flex: 3,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: MonoLabel(text, color: kTextMuted)),
      ),
      const Expanded(child: Divider()),
    ],
  );
}

/// Hauptknopf mit Ladeanzeige (deaktiviert während der Arbeit).
class HauptKnopf extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback? onPressed;
  final bool laeuft;
  const HauptKnopf({super.key, required this.text, this.icon, required this.onPressed, this.laeuft = false});

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(minimumSize: const Size.fromHeight(52));
    if (laeuft) {
      return FilledButton(
        onPressed: null,
        style: style,
        child: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    if (icon == null) return FilledButton(onPressed: onPressed, style: style, child: Text(text, textAlign: TextAlign.center));
    return FilledButton.icon(onPressed: onPressed, style: style, icon: Icon(icon), label: Text(text, textAlign: TextAlign.center));
  }
}

/// Zweitknopf (Rand).
class ZweitKnopf extends StatelessWidget {
  final String text;
  final IconData? icon;
  final VoidCallback? onPressed;
  const ZweitKnopf({super.key, required this.text, this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final style = OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48));
    return icon == null
        ? OutlinedButton(onPressed: onPressed, style: style, child: Text(text, textAlign: TextAlign.center))
        : OutlinedButton.icon(onPressed: onPressed, style: style, icon: Icon(icon), label: Text(text, textAlign: TextAlign.center));
  }
}

/// Textknopf in Mono/gedämpft für Nebenwege ("← zurück").
class LinkKnopf extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  final IconData? icon;
  const LinkKnopf(this.text, {super.key, required this.onPressed, this.icon});

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(minimumSize: const Size(48, 48), padding: const EdgeInsets.symmetric(horizontal: 12)),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[Icon(icon, size: 18), const SizedBox(width: 8)],
        Flexible(child: Text(text, textAlign: TextAlign.center)),
      ],
    ),
  );
}

/// Feld für 6-stellige Codes (TOTP, PIN) im Mono-Stil des Mockups.
class CodeFeld extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final int laenge;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final bool verdeckt;
  const CodeFeld({
    super.key,
    required this.controller,
    required this.label,
    this.laenge = 6,
    this.autofocus = false,
    this.onSubmitted,
    this.verdeckt = false,
  });

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    autofocus: autofocus,
    obscureText: verdeckt,
    keyboardType: TextInputType.number,
    textInputAction: TextInputAction.done,
    autofillHints: verdeckt ? null : const [AutofillHints.oneTimeCode],
    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(laenge)],
    textAlign: TextAlign.center,
    style: const TextStyle(fontFamily: kFontMono, fontSize: 24, letterSpacing: 6, color: kAccent),
    onSubmitted: onSubmitted,
    decoration: InputDecoration(labelText: label, counterText: ''),
  );
}

/// Pille für Rollen/Status (Mono, farbig).
class RollenPille extends StatelessWidget {
  final String text;
  final Color farbe;
  const RollenPille(this.text, {super.key, this.farbe = kNeural});

  @override
  Widget build(BuildContext context) => StatusPill(text, color: farbe);
}

/// Hält FLAG_SECURE (Android: kein Bildschirmfoto, keine Vorschau in der App-Übersicht), solange das Widget im Baum ist.
/// Für Screens mit Geheimnissen (TOTP-Secret, Wiederherstellungscodes).
class BildschirmSchutz extends ConsumerStatefulWidget {
  final Widget child;
  const BildschirmSchutz({super.key, required this.child});

  @override
  ConsumerState<BildschirmSchutz> createState() => _BildschirmSchutzState();
}

class _BildschirmSchutzState extends ConsumerState<BildschirmSchutz> {
  late final _kanal = ref.read(systemChannelProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_kanal.schuetzen());
  }

  @override
  void dispose() {
    unawaited(_kanal.freigeben());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Eingabefehler, die schon in der App auffallen (kein Serveraufruf): die Meldung wird unverändert angezeigt.
class EingabeFehler implements Exception {
  final String message;
  const EingabeFehler(this.message);
}

/// Fehlertext für beliebige Fehler: nur bekannte Meldungen, sonst ein allgemeiner Satz (keine Interna).
String fehlerText(Object e) {
  if (e is ApiException) return e.message;
  if (e is PasskeyException) return e.message;
  if (e is EingabeFehler) return e.message;
  if (e is CryptoFehler) return e.meldung;
  return 'Das hat nicht geklappt. Bitte versuche es noch einmal.';
}

/// Führt eine Aktion mit Ladezustand und Fehleranzeige aus. Wird von den Screens als Mixin benutzt.
mixin AktionsZustand<T extends StatefulWidget> on State<T> {
  bool laeuft = false;
  String? fehler;

  /// Führt [aktion] aus; Fehler landen in [fehler]. Ein vom Nutzer selbst abgebrochener Passkey-Dialog ist kein Fehler: nur ein
  /// kurzer Hinweis, kein roter Kasten. Gibt true zurück, wenn die Aktion ohne Fehler endete.
  Future<bool> ausfuehren(Future<void> Function() aktion) async {
    if (!mounted || laeuft) return false;
    setState(() {
      laeuft = true;
      fehler = null;
    });
    try {
      await aktion();
      if (mounted) setState(() => laeuft = false);
      return true;
    } catch (e) {
      if (mounted) {
        if (e is PasskeyException && e.abgebrochen) {
          setState(() => laeuft = false);
          zeigeHinweis(context, e.message);
        } else {
          setState(() {
            laeuft = false;
            fehler = fehlerText(e);
          });
        }
      }
      return false;
    }
  }

  /// Lädt nach einer erfolgreich abgeschlossenen Aktion die Liste neu und meldet dann [erfolg]. Scheitert nur das Neuladen, ist die
  /// Aktion trotzdem gelungen: kein Fehlerkasten, nur ein Zusatz im Hinweis (die Liste lässt sich per Ziehen aktualisieren).
  Future<void> neuLadenMitHinweis(Future<void> Function() laden, {String? erfolg}) async {
    var aktuell = true;
    try {
      await laden();
    } catch (_) {
      aktuell = false;
    }
    if (!mounted) return;
    final text = [?erfolg, if (!aktuell) 'Die Liste konnte nicht aktualisiert werden. Ziehe zum Aktualisieren nach unten.'].join(' ');
    if (text.isNotEmpty) zeigeHinweis(context, text);
  }
}

void zeigeHinweis(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Kopiert Text auf ausdrücklichen Wunsch in die Zwischenablage (nie automatisch). [geheim]: Codes, PIN, Schlüssel und Einladungslinks;
/// Android markiert sie als vertraulich (EXTRA_IS_SENSITIVE: keine Vorschau, kein Eintrag in Zwischenablage-Verläufen).
Future<void> inZwischenablage(BuildContext context, String text, String bestaetigung, {bool geheim = false}) async {
  var erledigt = false;
  if (geheim) {
    final kanal = ProviderScope.containerOf(context, listen: false).read(systemChannelProvider);
    erledigt = await kanal.geheimKopieren(text);
  }
  if (!erledigt) await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) zeigeHinweis(context, bestaetigung);
}
