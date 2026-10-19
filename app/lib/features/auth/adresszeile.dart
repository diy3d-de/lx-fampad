// Einladungslink in der Adresszeile (nur Web): Das Token steht im Fragment (#/einladung/<token>). Es wird gelesen und
// SOFORT mit history.replaceState aus der Adresszeile entfernt (Verlauf, Lesezeichen, Screenshots, Referrer).
// Auf anderen Plattformen gibt es keine Adresszeile; dort kommen Links über den Android-Intent (system_channel.dart).
export 'adresszeile_stub.dart' if (dart.library.js_interop) 'adresszeile_web.dart';
