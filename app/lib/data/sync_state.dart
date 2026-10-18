// Zustand des Abgleichs für den Sync-Indikator. Phase 0: Platzhalter ohne Netzwerk;
// die echte Logik (Outbox senden, /api/v1/sync, WebSocket "neue Revision") folgt in Phase 1.
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum SyncStatus {
  /// Noch nicht angemeldet bzw. kein Server verbunden (Phase 0).
  getrennt,
  laeuft,
  synchron,
  fehler,
}

class SyncState {
  final SyncStatus status;
  final int offeneAenderungen;
  final DateTime? letzterAbgleich;
  final String? meldung;

  const SyncState({
    this.status = SyncStatus.getrennt,
    this.offeneAenderungen = 0,
    this.letzterAbgleich,
    this.meldung,
  });

  /// Während eines Abgleichs oder mit offenen Änderungen darf kein App-Update installiert werden.
  bool get beschaeftigt => status == SyncStatus.laeuft || offeneAenderungen > 0;

  SyncState copyWith({SyncStatus? status, int? offeneAenderungen, DateTime? letzterAbgleich, String? meldung}) => SyncState(
        status: status ?? this.status,
        offeneAenderungen: offeneAenderungen ?? this.offeneAenderungen,
        letzterAbgleich: letzterAbgleich ?? this.letzterAbgleich,
        meldung: meldung,
      );
}

class SyncController extends Notifier<SyncState> {
  @override
  SyncState build() => const SyncState();

  /// Stößt einen Abgleich an. Phase 0: meldet nur, dass die Synchronisation noch fehlt.
  Future<void> synchronisieren() async {
    state = state.copyWith(status: SyncStatus.laeuft);
    state = state.copyWith(status: SyncStatus.getrennt, meldung: 'Abgleich folgt in Phase 1');
  }
}

final syncProvider = NotifierProvider<SyncController, SyncState>(SyncController.new);
