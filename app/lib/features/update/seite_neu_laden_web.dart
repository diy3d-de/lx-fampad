import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Lädt die Seite neu (window.location.reload), damit der Browser die neue Version holt.
/// Ohne eval und ohne Zusatzpaket, passend zur strengen CSP.
void seiteNeuLaden() {
  final location = globalContext.getProperty<JSObject>('location'.toJS);
  location.callMethod('reload'.toJS);
}
