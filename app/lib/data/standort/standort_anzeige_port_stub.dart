// Web (kein dart:io, kein Plugin): keine lokalen Standort-Benachrichtigungen.
import 'standort_hinweis.dart';

StandortAnzeigePort standortAnzeigePortErzeugen() => const KeineStandortAnzeige();
