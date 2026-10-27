// Hinweiskarte "Erinnerung" oben auf der Startseite der Web-App (mobil und Desktop): zeigt fällig gewordene Erinnerungen (neutraler Text, nie ein Titel;
// Tipp öffnet das Ziel, "Schließen" nimmt den Hinweis weg) und eine ruhige Zeile "Verpasst seit du weg warst" (höchstens 10 der letzten 24 Stunden, ohne
// Benachrichtigung). Ohne Hinweise unsichtbar; auf Android nie gefüllt. Zustand: data/erinnerungen/web_erinnerung_state.dart.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/erinnerungen/erinnerung_dienst.dart';
import '../../data/erinnerungen/web_erinnerung_logik.dart';
import '../../data/erinnerungen/web_erinnerung_port.dart';
import '../../data/erinnerungen/web_erinnerung_state.dart';
import '../../ui/widgets.dart';
import '../auth/auth_widgets.dart' show LinkKnopf;

const _klein = TextStyle(fontFamily: kFontSans, fontFeatures: kZiffern, fontSize: 12, color: kTextMuted);

/// "Heute, 14:30" bzw. "Gestern, 22:00" (Ortszeit des Geräts).
String webErinnerungZeitText(WebEintrag e, DateTime jetzt) {
  final z = e.zeit.toLocal();
  final h = '${z.hour.toString().padLeft(2, '0')}:${z.minute.toString().padLeft(2, '0')}';
  final heute = DateTime(jetzt.year, jetzt.month, jetzt.day);
  final tag = DateTime(z.year, z.month, z.day);
  return heute.difference(tag).inDays == 0 ? 'Heute, $h' : 'Gestern, $h';
}

class WebErinnerungKarte extends ConsumerStatefulWidget {
  const WebErinnerungKarte({super.key});

  @override
  ConsumerState<WebErinnerungKarte> createState() => _WebErinnerungKarteState();
}

class _WebErinnerungKarteState extends ConsumerState<WebErinnerungKarte> {
  bool _verpasstOffen = false;

  void _oeffnen(WebEintrag e) {
    ref.read(webHinweiseProvider.notifier).neuSchliessen(e);
    ref.read(erinnerungDienstProvider).oeffnen(e.payload);
  }

  Future<void> _verpasstErledigt(List<WebEintrag> liste) async {
    final port = ref.read(erinnerungPortProvider);
    if (port is WebErinnerungPort) await port.alsGezeigtMerken(liste, ref.read(erinnerungUhrProvider)());
    if (!mounted) return;
    ref.read(webHinweiseProvider.notifier).setzen(verpasst: const []);
    setState(() => _verpasstOffen = false);
  }

  @override
  Widget build(BuildContext context) {
    final h = ref.watch(webHinweiseProvider);
    if (h.leer) return const SizedBox.shrink();
    final jetzt = ref.read(erinnerungUhrProvider)();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Container(
        decoration: BoxDecoration(color: kAccentSoft, borderRadius: BorderRadius.circular(18), border: Border.all(color: kAccent.withValues(alpha: 0.6))),
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (h.neu.isNotEmpty) ...[
              const MonoLabel('Erinnerung'),
              const SizedBox(height: 6),
              for (final e in h.neu)
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        button: true,
                        label: '${webNeutralerText(e.payload) ?? 'Erinnerung'}. Öffnen',
                        excludeSemantics: true,
                        onTap: () => _oeffnen(e),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => _oeffnen(e),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minHeight: 44),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(webNeutralerText(e.payload) ?? 'Erinnerung', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: kText)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Hinweis schließen',
                      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                      icon: const Icon(Icons.close, size: 20, color: kTextMuted),
                      onPressed: () => ref.read(webHinweiseProvider.notifier).neuSchliessen(e),
                    ),
                  ],
                ),
            ],
            if (h.verpasst.isNotEmpty) ...[
              if (h.neu.isNotEmpty) const SizedBox(height: 8),
              Semantics(
                button: true,
                label: 'Verpasst seit du weg warst: ${h.verpasst.length} ${h.verpasst.length == 1 ? 'Erinnerung' : 'Erinnerungen'}. ${_verpasstOffen ? 'Zuklappen' : 'Ansehen'}',
                excludeSemantics: true,
                onTap: () => setState(() => _verpasstOffen = !_verpasstOffen),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => setState(() => _verpasstOffen = !_verpasstOffen),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Verpasst seit du weg warst: ${h.verpasst.length} ${h.verpasst.length == 1 ? 'Erinnerung' : 'Erinnerungen'}',
                            style: const TextStyle(fontSize: 14, color: kText),
                          ),
                        ),
                        Icon(_verpasstOffen ? Icons.expand_less : Icons.expand_more, color: kTextMuted),
                      ],
                    ),
                  ),
                ),
              ),
              if (_verpasstOffen) ...[
                for (final e in h.verpasst)
                  Semantics(
                    button: true,
                    label: '${webErinnerungZeitText(e, jetzt)}. ${webNeutralerText(e.payload) ?? 'Erinnerung'}. Öffnen',
                    excludeSemantics: true,
                    onTap: () => ref.read(erinnerungDienstProvider).oeffnen(e.payload),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => ref.read(erinnerungDienstProvider).oeffnen(e.payload),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 44),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text('${webErinnerungZeitText(e, jetzt)} · ${webNeutralerText(e.payload) ?? 'Erinnerung'}', style: _klein),
                        ),
                      ),
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: LinkKnopf('Alles gesehen', onPressed: () => unawaited(_verpasstErledigt(h.verpasst))),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
