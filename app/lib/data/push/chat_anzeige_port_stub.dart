// Web (kein dart:io, kein Plugin): keine lokalen Chat-Benachrichtigungen.
import 'chat_benachrichtiger.dart';

ChatAnzeigePort chatAnzeigePortErzeugen() => const KeineChatAnzeige();
