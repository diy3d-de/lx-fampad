// Plattform der Profil-Seiten: Push und das Widget "Heute" gibt es nur in der Android-App. Als Provider, damit Tests die Web-Fassung prüfen können
// (kIsWeb ist in flutter_test immer false).
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

final profilWebProvider = Provider<bool>((_) => kIsWeb);
