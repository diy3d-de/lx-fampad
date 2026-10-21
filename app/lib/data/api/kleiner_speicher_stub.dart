/// Außerhalb des Browsers gibt es keinen solchen Speicher (Android nutzt den Keystore-Speicher des TokenStore).
String? kleinerSpeicherLesen(String key) => null;
void kleinerSpeicherSchreiben(String key, String value) {}
