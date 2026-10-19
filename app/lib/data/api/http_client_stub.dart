import 'package:http/http.dart' as http;

/// Web (und alles ohne dart:io): der Browser-Client; Verbindungsfehler sind dort nicht von späteren Fehlern zu unterscheiden.
http.Client neuerHttpClient() => http.Client();
