import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../constants.dart';

/// QR-Code auf hellem Grund (gut scanbar). Die Grafik entsteht in der App, nichts geht an Dritte.
class QrAnzeige extends StatelessWidget {
  final String daten;
  final String beschreibung;
  final double groesse;
  const QrAnzeige({super.key, required this.daten, required this.beschreibung, this.groesse = 220});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final seite = c.maxWidth.isFinite ? (c.maxWidth < groesse ? c.maxWidth : groesse) : groesse;
      return Center(
        child: Container(
          decoration: BoxDecoration(color: kTextStrong, borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.all(10),
          child: QrImageView(
            data: daten,
            size: seite - 20,
            padding: EdgeInsets.zero,
            backgroundColor: kTextStrong,
            errorCorrectionLevel: QrErrorCorrectLevel.M,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: kBg),
            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: kBg),
            semanticsLabel: beschreibung,
          ),
        ),
      );
    },
  );
}
