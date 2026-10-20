// Plattform ohne dart:io und ohne Browser (z. B. reine Dart-Tests): nur Arbeitsspeicher.
import 'schluessel_speicher.dart';

SchluesselSpeicher schluesselSpeicherErzeugen() => MemorySchluesselSpeicher();
