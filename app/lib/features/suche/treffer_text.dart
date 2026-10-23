// Text mit hervorgehobenen Suchtreffern (Akzentfarbe und kräftiger, damit der Treffer auch ohne Farbe erkennbar ist).
import 'package:flutter/material.dart';

import '../../constants.dart';
import '../../data/suche/such_logik.dart';

class TrefferText extends StatelessWidget {
  final String text;
  final List<TextBereich> bereiche;
  final TextStyle? stil;
  final int maxLines;
  const TrefferText(this.text, this.bereiche, {super.key, this.stil, this.maxLines = 2});

  @override
  Widget build(BuildContext context) {
    final basis = (stil ?? const TextStyle(fontSize: 15, color: kText)).copyWith(height: 1.3);
    final treffer = basis.copyWith(color: kAccent, fontWeight: FontWeight.w800, backgroundColor: kAccentSoft);
    final teile = <TextSpan>[];
    var pos = 0;
    for (final b in bereiche) {
      final s = b.start.clamp(0, text.length);
      final e = b.ende.clamp(0, text.length);
      if (e <= s || s < pos) continue;
      if (s > pos) teile.add(TextSpan(text: text.substring(pos, s)));
      teile.add(TextSpan(text: text.substring(s, e), style: treffer));
      pos = e;
    }
    if (pos < text.length) teile.add(TextSpan(text: text.substring(pos)));
    return Text.rich(TextSpan(style: basis, children: teile), maxLines: maxLines, overflow: TextOverflow.ellipsis);
  }
}
