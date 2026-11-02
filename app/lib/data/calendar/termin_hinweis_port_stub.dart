// Plattformen ohne dart:io (Web): keine Android-Anzeige; der Browser wird in termin_hinweis_dienst.dart bedient.
import 'termin_hinweis_dienst.dart';

TerminHinweisAnzeige terminHinweisAnzeigeErzeugen({void Function(String payload)? beiTipp}) => const KeineTerminHinweisAnzeige();
