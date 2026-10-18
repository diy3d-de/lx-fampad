import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'app.dart';
import 'constants.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pruefeBasisAdressen();
  await initializeDateFormatting('de_DE');
  runApp(const ProviderScope(child: FamilienzentraleApp()));
}
