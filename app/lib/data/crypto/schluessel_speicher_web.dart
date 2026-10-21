// Web: Die Bytes werden mit AES-GCM (256 Bit) verschlüsselt in IndexedDB abgelegt. Der Wrapper-Schlüssel entsteht per WebCrypto als NICHT
// EXPORTIERBARER CryptoKey und liegt (als Objekt, nicht als Bytes) ebenfalls in IndexedDB: JavaScript kann ihn benutzen, aber nicht auslesen.
// Der Eintragsname geht als zusätzliche Daten (AAD) in die Verschlüsselung ein, damit Einträge nicht vertauscht werden können.
// Grenze: Schadcode in der Seite (XSS) könnte den Wrapper-Schlüssel benutzen; Schutz davor bietet nur die strikte CSP.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'bytes.dart';
import 'schluessel_speicher.dart';

SchluesselSpeicher schluesselSpeicherErzeugen() => WebSchluesselSpeicher();

class WebSchluesselSpeicher implements SchluesselSpeicher {
  static const _dbName = 'lx-fampad-e2ee';
  static const _speicher = 'kv';
  static const _wrapName = '__wrap';
  static const _eintrag = 'e:';

  Future<web.IDBDatabase>? _db;

  web.SubtleCrypto get _subtle {
    if (!web.window.isSecureContext) throw StateError('Sicherer Kontext (HTTPS) nötig.');
    return web.window.crypto.subtle;
  }

  Future<web.IDBDatabase> _oeffnen() => _db ??= () {
    final c = Completer<web.IDBDatabase>();
    final req = web.window.indexedDB.open(_dbName, 1);
    req.onupgradeneeded = ((web.Event _) {
      (req.result! as web.IDBDatabase).createObjectStore(_speicher);
    }).toJS;
    req.onsuccess = ((web.Event _) => c.complete(req.result! as web.IDBDatabase)).toJS;
    req.onerror = ((web.Event _) => c.completeError(StateError('IndexedDB nicht verfügbar.'))).toJS;
    req.onblocked = ((web.Event _) => c.completeError(StateError('IndexedDB blockiert.'))).toJS;
    return c.future;
  }();

  Future<JSAny?> _anfrage(web.IDBRequest r) {
    final c = Completer<JSAny?>();
    r.onsuccess = ((web.Event _) => c.complete(r.result)).toJS;
    r.onerror = ((web.Event _) => c.completeError(StateError('IndexedDB-Fehler.'))).toJS;
    return c.future;
  }

  /// Führt [aktion] in einer Transaktion aus und wartet, bis sie festgeschrieben ist.
  Future<T> _transaktion<T>(bool schreiben, Future<T> Function(web.IDBObjectStore store) aktion) async {
    final db = await _oeffnen();
    final tx = db.transaction(_speicher.toJS, schreiben ? 'readwrite' : 'readonly');
    final fertig = Completer<void>();
    tx.oncomplete = ((web.Event _) => fertig.complete()).toJS;
    tx.onerror = ((web.Event _) => fertig.isCompleted ? null : fertig.completeError(StateError('IndexedDB-Fehler.'))).toJS;
    tx.onabort = ((web.Event _) => fertig.isCompleted ? null : fertig.completeError(StateError('IndexedDB abgebrochen.'))).toJS;
    // Schlägt die Aktion fehl, wird die Transaktion abgebrochen und ihr Abschluss-Future entschärft (sonst bliebe ein unbehandelter Fehler zurück)
    final T ergebnis;
    try {
      ergebnis = await aktion(tx.objectStore(_speicher));
    } on Object {
      try {
        tx.abort();
      } on Object {
        // schon beendet
      }
      unawaited(fertig.future.then<void>((_) {}, onError: (_) {}));
      rethrow;
    }
    await fertig.future;
    return ergebnis;
  }

  /// Wrapper-Schlüssel holen oder (einmalig, auch bei zwei gleichzeitigen Tabs) anlegen.
  Future<web.CryptoKey> _wrapSchluessel() async {
    final vorhanden = await _transaktion(false, (s) => _anfrage(s.get(_wrapName.toJS)));
    if (vorhanden != null && !vorhanden.isUndefined) return vorhanden as web.CryptoKey;
    final algorithmus = {'name': 'AES-GCM', 'length': 256}.jsify()!;
    final kandidat = (await _subtle.generateKey(algorithmus, false, <JSString>['encrypt'.toJS, 'decrypt'.toJS].toJS).toDart)! as web.CryptoKey;
    return _transaktion(true, (s) async {
      final inzwischen = await _anfrage(s.get(_wrapName.toJS));
      if (inzwischen != null && !inzwischen.isUndefined) return inzwischen as web.CryptoKey;
      await _anfrage(s.put(kandidat, _wrapName.toJS));
      return kandidat;
    });
  }

  JSAny _alg(Uint8List iv, String name) => {'name': 'AES-GCM', 'iv': iv, 'additionalData': utf8Bytes(name)}.jsify()!;

  /// Ergebnis der Abfrage (je Sitzung höchstens einmal abgefragt und gemerkt) und ob `persist()` in dieser Sitzung schon gefragt wurde.
  Future<SpeicherDauer>? _abfrage;
  Future<SpeicherDauer>? _anforderung;

  /// Nur `persisted()`: fragt nie den Nutzer. Ohne dauerhafte Ablage darf der Browser die Schlüssel bei Speicherknappheit löschen.
  @override
  Future<SpeicherDauer> dauerhaftigkeit() => _abfrage ??= () async {
    try {
      final ok = (await web.window.navigator.storage.persisted().toDart).toDart;
      return ok ? SpeicherDauer.gewaehrt : SpeicherDauer.verweigert;
    } on Object {
      return SpeicherDauer.unbekannt;
    }
  }();

  /// `persist()` nach einer Aktion der Person, höchstens einmal je Sitzung; das Ergebnis ersetzt die gemerkte Abfrage.
  @override
  Future<SpeicherDauer> dauerhaftAnfordern() => _anforderung ??= () async {
    try {
      final ok = (await web.window.navigator.storage.persist().toDart).toDart;
      final ergebnis = ok ? SpeicherDauer.gewaehrt : SpeicherDauer.verweigert;
      _abfrage = Future.value(ergebnis);
      return ergebnis;
    } on Object {
      return SpeicherDauer.unbekannt;
    }
  }();

  /// null nur, wenn der Eintrag nicht existiert. IndexedDB-Fehler sind vorübergehend (der Eintrag bleibt), eine fehlgeschlagene
  /// Entschlüsselung (Eintrag oder Wrapper-Schlüssel beschädigt/vertauscht) ist dauerhaft.
  @override
  Future<Uint8List?> lesen(String name) async {
    final JSAny? roh;
    final web.CryptoKey key;
    try {
      roh = await _transaktion(false, (s) => _anfrage(s.get('$_eintrag$name'.toJS)));
      if (roh == null || roh.isUndefined) return null;
      key = await _wrapSchluessel();
    } on Object {
      throw const SchluesselSpeicherFehler('IndexedDB nicht lesbar', dauerhaft: false);
    }
    try {
      final obj = roh as JSObject;
      final iv = (obj.getProperty('iv'.toJS)! as JSUint8Array).toDart;
      final ct = obj.getProperty('ct'.toJS)! as JSArrayBuffer;
      // ein verschobener Eintrag (Quarantäne) behält den Namen, unter dem er verschlüsselt wurde
      final aad = obj.getProperty<JSAny?>('aad'.toJS);
      final klar = (await _subtle.decrypt(_alg(iv, aad.isA<JSString>() ? (aad! as JSString).toDart : name), key, ct).toDart)! as JSArrayBuffer;
      return Uint8List.fromList(klar.toDart.asUint8List());
    } on Object {
      throw const SchluesselSpeicherFehler('Schlüsseleintrag nicht entschlüsselbar', dauerhaft: true);
    }
  }

  @override
  Future<void> schreiben(String name, Uint8List bytes) async {
    final iv = Uint8List(12);
    web.window.crypto.getRandomValues(iv.toJS);
    final key = await _wrapSchluessel();
    final ct = (await _subtle.encrypt(_alg(iv, name), key, bytes.toJS).toDart)! as JSArrayBuffer;
    final wert = {'iv': iv, 'ct': ct}.jsify()!;
    await _transaktion(true, (s) => _anfrage(s.put(wert, '$_eintrag$name'.toJS)));
  }

  /// Verschiebt den verschlüsselten Eintrag unverändert (ohne Entschlüsselung) und merkt sich den ursprünglichen Namen für die spätere Entschlüsselung.
  @override
  Future<bool> verschiebe(String von, String nach) async {
    try {
      return await _transaktion(true, (s) async {
        final roh = await _anfrage(s.get('$_eintrag$von'.toJS));
        if (roh == null || roh.isUndefined) return false;
        final obj = roh as JSObject;
        final alt = obj.getProperty<JSAny?>('aad'.toJS);
        final neu = JSObject()
          ..setProperty('iv'.toJS, obj.getProperty<JSAny?>('iv'.toJS))
          ..setProperty('ct'.toJS, obj.getProperty<JSAny?>('ct'.toJS))
          ..setProperty('aad'.toJS, alt.isA<JSString>() ? alt : von.toJS);
        await _anfrage(s.put(neu, '$_eintrag$nach'.toJS));
        await _anfrage(s.delete('$_eintrag$von'.toJS));
        return true;
      });
    } on Object {
      return false;
    }
  }

  @override
  Future<List<String>> namenMitPraefix(String praefix) async {
    final keys = await _transaktion(false, (s) => _anfrage(s.getAllKeys()));
    final liste = (keys! as JSArray<JSAny?>).toDart;
    return [
      for (final k in liste)
        if (k != null && k.isA<JSString>() && (k as JSString).toDart.startsWith('$_eintrag$praefix')) k.toDart.substring(_eintrag.length),
    ];
  }

  @override
  Future<void> loeschen(String name) => _transaktion(true, (s) => _anfrage(s.delete('$_eintrag$name'.toJS)));

  @override
  Future<void> loescheMitPraefix(String praefix) async {
    final keys = await _transaktion(false, (s) => _anfrage(s.getAllKeys()));
    final liste = (keys! as JSArray<JSAny?>).toDart;
    final loeschen = [
      for (final k in liste)
        if (k != null && k.isA<JSString>() && (k as JSString).toDart.startsWith('$_eintrag$praefix')) k,
    ];
    await _transaktion(true, (s) async {
      for (final k in loeschen) {
        await _anfrage(s.delete(k));
      }
    });
  }
}
