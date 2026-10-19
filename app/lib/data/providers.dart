import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import 'api/http_client.dart';

final httpClientProvider = Provider<http.Client>((ref) {
  final client = neuerHttpClient();
  ref.onDispose(client.close);
  return client;
});
