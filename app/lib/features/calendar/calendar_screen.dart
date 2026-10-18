import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../constants.dart';
import '../../ui/widgets.dart';
import '../../widgets/sync_indicator.dart';

/// Kalender: Monatsraster mit Auswahl des Tages. Phase 0: ohne Termine.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  late final DateTime _heute = DateUtils.dateOnly(DateTime.now());
  late DateTime _gewaehlt = _heute;
  late DateTime _monat = DateTime(_heute.year, _heute.month);

  void _verschiebe(int monate) => setState(() => _monat = DateTime(_monat.year, _monat.month + monate));

  @override
  Widget build(BuildContext context) {
    final tageImMonat = DateUtils.getDaysInMonth(_monat.year, _monat.month);
    final versatz = (DateTime(_monat.year, _monat.month).weekday - 1) % 7; // Montag = 0
    final zellen = ((versatz + tageImMonat) / 7).ceil() * 7;
    final monatsname = DateFormat('MMMM yyyy', 'de_DE').format(_monat);
    final tagTitel = DateFormat('EEEE, d. MMM', 'de_DE').format(_gewaehlt).toLowerCase();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      children: [
        const ScreenHeader(title: 'Kalender', actions: [SyncIndicator()]),
        const SizedBox(height: 12),
        Row(
          children: [
            IconButton(tooltip: 'Vorheriger Monat', onPressed: () => _verschiebe(-1), icon: const Icon(Icons.chevron_left)),
            Expanded(
              child: Text(
                monatsname,
                textAlign: TextAlign.center,
                style: const TextStyle(fontFamily: kFontMono, fontSize: 13, color: kTextMuted),
              ),
            ),
            IconButton(tooltip: 'Nächster Monat', onPressed: () => _verschiebe(1), icon: const Icon(Icons.chevron_right)),
          ],
        ),
        Row(
          children: [
            for (final t in const ['mo', 'di', 'mi', 'do', 'fr', 'sa', 'so'])
              Expanded(
                child: Center(
                  child: Text(t, style: const TextStyle(fontFamily: kFontMono, fontSize: 11, color: kTextFaint)),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        GridView(
          // Zellen mindestens 44 px hoch und (bei 360 px Breite) ohne Lücke mindestens 44 px breit
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisSpacing: 4,
            crossAxisSpacing: 0,
            mainAxisExtent: 48,
          ),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            for (var i = 0; i < zellen; i++) _zelle(i - versatz + 1, tageImMonat),
          ],
        ),
        const SizedBox(height: 16),
        MonoLabel('// $tagTitel'),
        const SizedBox(height: 12),
        const LxCard(child: Text('Keine Termine – frei!', style: TextStyle(color: kTextMuted))),
      ],
    );
  }

  Widget _zelle(int n, int tageImMonat) {
    if (n < 1 || n > tageImMonat) return const SizedBox.shrink();
    final tag = DateTime(_monat.year, _monat.month, n);
    return _Tag(
      nummer: n,
      heute: tag == _heute,
      gewaehlt: tag == _gewaehlt,
      onTap: () => setState(() => _gewaehlt = tag),
    );
  }
}

class _Tag extends StatelessWidget {
  final int nummer;
  final bool heute;
  final bool gewaehlt;
  final VoidCallback onTap;
  const _Tag({required this.nummer, required this.heute, required this.gewaehlt, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        selected: gewaehlt,
        label: '$nummer',
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            alignment: Alignment.center,
            margin: const EdgeInsets.symmetric(horizontal: 2),
            decoration: BoxDecoration(
              color: gewaehlt ? kAccentSoft : null,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: heute ? kAccent : (gewaehlt ? kAccent.withValues(alpha: 0.4) : Colors.transparent)),
            ),
            child: Text(
              '$nummer',
              style: TextStyle(fontWeight: gewaehlt ? FontWeight.w700 : FontWeight.w500, color: gewaehlt ? kAccent : kText),
            ),
          ),
        ),
      );
}
