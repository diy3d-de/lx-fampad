// Stecknadel für die Karte: gezeichneter Tropfen (Spitze unten, genau auf der Position) in der Personenfarbe, im Kopf das kleine runde Profilbild
// (Foto, Platzhalter-Zeichnung oder Initialen über [BenutzerAvatar]). Alles selbst gezeichnet (Canvas), nur Farben aus den Design-Tokens.
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/api/models.dart';
import '../../widgets/benutzer_avatar.dart';

/// Größe der Nadel: mindestens 44 px breit (Touch-Ziel), die Spitze liegt auf der Mitte der Unterkante.
const kPinGroesse = Size(48, 62);

/// Durchmesser des Profilbilds im Kopf der Nadel.
const double kPinBild = 30;

class StandortPin extends StatelessWidget {
  final UserDto? user;
  final String name;
  final int farbIndex;

  /// Ausgewählt (Info wird gezeigt): Rand in Akzentfarbe.
  final bool gewaehlt;

  /// Position nicht mehr aktuell: Nadel blasser.
  final bool veraltet;

  /// Die eigene Nadel (Kontur in Akzentfarbe, damit sie sich abhebt).
  final bool eigene;
  const StandortPin({super.key, required this.user, required this.name, required this.farbIndex, this.gewaehlt = false, this.veraltet = false, this.eigene = false});

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: veraltet ? 0.6 : 1,
    child: SizedBox(
      width: kPinGroesse.width,
      height: kPinGroesse.height,
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: PinMaler(fuellung: personColor(farbIndex), rand: gewaehlt || eigene ? kAccent : kTextStrong, randBreite: gewaehlt ? 3 : 2),
            ),
          ),
          // Kopf: Mittelpunkt des Kreises der Nadel
          Positioned(
            left: (kPinGroesse.width - kPinBild) / 2,
            top: PinMaler.kopfMitteY - kPinBild / 2,
            width: kPinBild,
            height: kPinBild,
            // dunkle Scheibe unter dem Bild: die Initialen haben die Personenfarbe und wären sonst auf der gleichfarbigen Nadel unsichtbar
            child: ClipOval(child: ColoredBox(color: kSurface, child: BenutzerAvatar(user: user, ersatzName: name, size: kPinBild))),
          ),
        ],
      ),
    ),
  );
}

/// Zeichnet den Tropfen: Kreis plus Spitze, die Spitze sitzt auf der Mitte der Unterkante.
class PinMaler extends CustomPainter {
  final Color fuellung;
  final Color rand;
  final double randBreite;
  const PinMaler({required this.fuellung, required this.rand, this.randBreite = 2});

  /// Abstand der Kopfmitte von oben und Radius des Kopfes (für die Platzierung des Bildes).
  static const double kopfMitteY = 24;
  static const double kopfRadius = 21;

  /// Der Umriss des Tropfens (auch für Tests der Spitze).
  static Path umriss(Size size) {
    final mitte = Offset(size.width / 2, kopfMitteY);
    final kopf = Path()..addOval(Rect.fromCircle(center: mitte, radius: kopfRadius));
    final spitze = Path()
      ..moveTo(mitte.dx - kopfRadius * 0.82, mitte.dy + kopfRadius * 0.58)
      ..lineTo(mitte.dx, size.height)
      ..lineTo(mitte.dx + kopfRadius * 0.82, mitte.dy + kopfRadius * 0.58)
      ..close();
    return Path.combine(PathOperation.union, kopf, spitze);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final pfad = umriss(size);
    // dunkle Außenkontur: die Nadel bleibt auf hellem und dunklem Kartenstil gut zu erkennen (weißer Rand allein verschwände auf Hell)
    canvas.drawPath(
      pfad,
      Paint()
        ..color = kBg.withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = randBreite + 2
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawPath(pfad, Paint()..color = fuellung);
    canvas.drawPath(
      pfad,
      Paint()
        ..color = rand
        ..style = PaintingStyle.stroke
        ..strokeWidth = randBreite
        ..strokeJoin = StrokeJoin.round,
    );
    // heller Ring um das Bild, damit Foto und Nadelfarbe sich trennen
    canvas.drawCircle(
      Offset(size.width / 2, kopfMitteY),
      kPinBild / 2 + 1,
      Paint()
        ..color = kTextStrong
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(PinMaler alt) => alt.fuellung != fuellung || alt.rand != rand || alt.randBreite != randBreite;
}
