import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Prüft die Ed25519-Signatur des Update-Manifests. Geprüft wird genau der String `payload` (UTF-8-Bytes), so wie
/// er im Manifest steht: Das Manifest wird nie neu serialisiert, damit die Signatur nicht an Leerzeichen oder
/// Feldreihenfolge scheitert oder, schlimmer, eine zweite Lesart des Inhalts zulässt.
abstract class ManifestVerifier {
  Future<bool> verify({required String payload, required String signature});
}

/// Lehnt jedes Manifest ab (Standard, solange kein Schlüssel hinterlegt ist, und für Tests).
class RejectingManifestVerifier implements ManifestVerifier {
  const RejectingManifestVerifier();

  @override
  Future<bool> verify({required String payload, required String signature}) async => false;
}

/// Ed25519 mit fest eingebautem öffentlichen Schlüssel (32 Byte). Die Signatur steht Base64-kodiert (64 Byte) im Manifest.
class Ed25519ManifestVerifier implements ManifestVerifier {
  final List<int> publicKey;
  Ed25519ManifestVerifier(this.publicKey);

  /// Schlüssel als Base64-Text (siehe `kUpdatePublicKey` in constants.dart).
  factory Ed25519ManifestVerifier.base64(String publicKeyBase64) => Ed25519ManifestVerifier(base64Decode(publicKeyBase64));

  @override
  Future<bool> verify({required String payload, required String signature}) async {
    if (publicKey.length != 32) return false;
    final List<int> sig;
    try {
      sig = base64Decode(signature);
    } on FormatException {
      return false;
    }
    if (sig.length != 64) return false;
    return Ed25519().verify(
      utf8.encode(payload),
      signature: Signature(sig, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
    );
  }
}
