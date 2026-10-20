// Plattformen mit dart:io (Android; Tests auf dem Desktop): Anzeige mit dem Plugin. Im Web gilt chat_anzeige_port_stub.dart.
import 'chat_anzeige_port_android.dart';
import 'chat_benachrichtiger.dart';

ChatAnzeigePort chatAnzeigePortErzeugen() => AndroidChatAnzeige();
