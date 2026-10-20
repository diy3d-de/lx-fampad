// Plattformen mit dart:io (Android; Tests auf dem Desktop): Anzeige mit dem Plugin. Im Web gilt standort_anzeige_port_stub.dart.
import 'standort_anzeige_port_android.dart';
import 'standort_hinweis.dart';

StandortAnzeigePort standortAnzeigePortErzeugen() => AndroidStandortAnzeige();
