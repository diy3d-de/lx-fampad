// Plattformen mit dart:io (Android; Tests auf dem Desktop): Port mit dem Plugin. Im Web gilt erinnerung_port_stub.dart.
import 'erinnerung_port.dart';
import 'erinnerung_port_android.dart';

ErinnerungPort erinnerungPortErzeugen() => AndroidErinnerungPort();
