// Android: FLAG_KEEP_SCREEN_ON über den System-Kanal (MainActivity.kt "setKeepScreenOn"); auf anderen Plattformen ist der Aufruf ein No-op.
import '../system_channel.dart';
import 'bildschirm_wach.dart';

BildschirmWach erzeugeBildschirmWach(SystemChannel kanal) => KanalBildschirmWach(kanal);

class KanalBildschirmWach implements BildschirmWach {
  final SystemChannel _kanal;
  KanalBildschirmWach(this._kanal);

  @override
  Future<void> halten() => _kanal.bildschirmWach(true);

  @override
  Future<void> freigeben() => _kanal.bildschirmWach(false);
}
