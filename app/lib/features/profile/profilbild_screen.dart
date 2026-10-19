// "Profilbild ändern" (Mockup docs/mockups/avatare.html): Reiter Platzhalter | Eigenes Foto, Vorschau, Übernehmen, Entfernen.
// Platzhalter sind zehn Zeichnungen auf der Personenfarbe. Ein eigenes Foto wird in der App quadratisch zugeschnitten, auf höchstens
// 512 x 512 Pixel verkleinert und neu kodiert (dabei entfallen EXIF/Standort); hochgeladen wird nur das kleine Ergebnis.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../constants.dart';
import '../../data/auth/auth_state.dart';
import '../../data/avatar/avatar_vorlagen.dart';
import '../../data/avatar/bild_aufbereiten.dart';
import '../../data/avatar/bild_datei.dart';
import '../../data/lists/members.dart';
import '../../ui/widgets.dart';
import '../../widgets/benutzer_avatar.dart';
import '../auth/auth_widgets.dart';

class ProfilbildScreen extends ConsumerStatefulWidget {
  const ProfilbildScreen({super.key});

  @override
  ConsumerState<ProfilbildScreen> createState() => _ProfilbildScreenState();
}

class _ProfilbildScreenState extends ConsumerState<ProfilbildScreen> with AktionsZustand<ProfilbildScreen> {
  int _reiter = 0;
  String? _vorlage;
  AufbereitetesBild? _foto;
  String? _fotoName;

  @override
  void initState() {
    super.initState();
    final a = ref.read(authProvider).user?.avatar;
    if (a != null && !a.istFoto) _vorlage = a.vorlage;
  }

  Future<void> _fotoWaehlen() async {
    final waehler = ref.read(bildDateiWaehlerProvider);
    await ausfuehren(() async {
      final datei = await waehler();
      if (datei == null) return; // abgebrochen: kein Fehler
      try {
        final bytes = await bildDateiLesen(datei);
        final bild = await bildAufbereiten(bytes);
        if (!mounted) return;
        setState(() {
          _foto = bild;
          _fotoName = datei.name;
        });
      } on BildFehler catch (e) {
        throw EingabeFehler(e.meldung);
      }
    });
  }

  Future<void> _uebernehmen() async {
    final api = ref.read(apiProvider);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final foto = _reiter == 1 ? _foto : null;
    final vorlage = _reiter == 0 ? _vorlage : null;
    if (foto == null && vorlage == null) return;
    final ok = await ausfuehren(() async {
      if (foto != null) {
        await api.avatarFotoHochladen(foto.bytes, foto.mime);
      } else {
        await api.avatarVorlageSetzen(vorlage!);
      }
    });
    if (!ok) return;
    await _danach(nav, messenger, 'Profilbild gespeichert.');
  }

  Future<void> _entfernen() async {
    final api = ref.read(apiProvider);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final ok = await ausfuehren(() => api.avatarEntfernen());
    if (!ok) return;
    await _danach(nav, messenger, 'Profilbild entfernt. Es erscheinen wieder deine Initialen.');
  }

  /// Profil und Mitgliederliste neu laden (neue Bildversion), dann zurück. Scheitert nur das Neuladen, ist das Bild trotzdem gespeichert.
  Future<void> _danach(NavigatorState nav, ScaffoldMessengerState messenger, String hinweis) async {
    await ref.read(authProvider.notifier).neuLaden();
    ref.invalidate(mitgliederProvider);
    if (nav.mounted) nav.pop();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(hinweis)));
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider.select((s) => s.user));
    final farbe = user?.colorIndex ?? 0;
    final name = user?.displayName ?? '?';
    final aktuell = user?.avatar;
    final vorschauVorlage = _reiter == 0 ? avatarVorlage(_vorlage) : null;
    final vorschauFoto = _reiter == 1 ? _foto : null;
    final kannUebernehmen = !laeuft && (_reiter == 0 ? _vorlage != null : _foto != null);
    return AuthSeite(
      label: '// profil',
      titel: 'Profilbild ändern',
      maxBreite: kMaxContentWidth,
      kinder: [
        LxCard(
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kAccent, width: 2)),
                child: Semantics(
                  label: 'Vorschau deines Profilbilds',
                  image: true,
                  child: vorschauFoto != null
                      ? PersonAvatar(name: name, colorIndex: farbe, size: 88, bild: MemoryImage(vorschauFoto.bytes))
                      : vorschauVorlage != null
                      ? PersonAvatar(name: name, colorIndex: farbe, size: 88, bild: AssetImage(vorschauVorlage.asset), bildAufFarbe: true)
                      : BenutzerAvatar(user: user, size: 88),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const MonoLabel('// vorschau', color: kTextMuted),
                    const SizedBox(height: 4),
                    Text(name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kTextStrong)),
                    const SizedBox(height: 2),
                    Text(
                      vorschauFoto != null
                          ? 'eigenes Foto'
                          : vorschauVorlage != null
                          ? vorschauVorlage.name
                          : (aktuell == null ? 'noch kein Bild' : 'aktuelles Bild'),
                      style: const TextStyle(fontFamily: kFontMono, fontSize: 12, color: kTextMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Reiter(aktiv: _reiter, onWechsel: (i) => setState(() => _reiter = i)),
        const SizedBox(height: 16),
        if (fehler != null) ...[MeldungsBox(fehler!), const SizedBox(height: 12)],
        if (_reiter == 0)
          for (final g in AvatarGruppe.values) ...[
            MonoLabel('// ${g.label.toLowerCase()}', color: kTextMuted),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final v in kAvatarVorlagen.where((v) => v.gruppe == g))
                  _VorlagenKnopf(
                    vorlage: v,
                    colorIndex: farbe,
                    name: name,
                    gewaehlt: _vorlage == v.id,
                    onTap: laeuft ? null : () => setState(() => _vorlage = v.id),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ]
        else ...[
          LxCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Icon(Icons.upload_file_outlined, size: 40, color: kAccent),
                const SizedBox(height: 8),
                Text(
                  _foto == null ? 'Foto auswählen' : (_fotoName ?? 'Foto'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w600, color: kTextStrong),
                ),
                const SizedBox(height: 4),
                Text(
                  _foto == null
                      ? 'Das Bild wird rund zugeschnitten und verkleinert (höchstens 10 MB). Standortdaten im Foto werden dabei entfernt.'
                      : 'Zugeschnitten auf ${_foto!.kante} x ${_foto!.kante} Pixel (${(_foto!.bytes.length / 1024).round()} KB). Standortdaten sind entfernt.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: kTextMuted),
                ),
                const SizedBox(height: 12),
                ZweitKnopf(
                  text: _foto == null ? 'Foto auswählen' : 'Anderes Foto wählen',
                  icon: Icons.photo_library_outlined,
                  onPressed: laeuft ? null : _fotoWaehlen,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        HauptKnopf(text: 'Übernehmen', icon: Icons.check, laeuft: laeuft, onPressed: kannUebernehmen ? _uebernehmen : null),
        const SizedBox(height: 8),
        if (aktuell != null)
          OutlinedButton.icon(
            onPressed: laeuft ? null : _entfernen,
            style: OutlinedButton.styleFrom(foregroundColor: kDanger, side: const BorderSide(color: kDanger), minimumSize: const Size.fromHeight(48)),
            icon: const Icon(Icons.delete_outline),
            label: const Text('Bild entfernen'),
          ),
        LinkKnopf('Abbrechen', onPressed: laeuft ? null : () => Navigator.of(context).maybePop()),
      ],
    );
  }
}

/// Zwei Reiter (Mockup): Platzhalter | Eigenes Foto. Je mindestens 48 px hoch.
class _Reiter extends StatelessWidget {
  final int aktiv;
  final ValueChanged<int> onWechsel;
  const _Reiter({required this.aktiv, required this.onWechsel});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(color: kBgElevated, border: Border.all(color: kBorder), borderRadius: BorderRadius.circular(12)),
    child: Row(
      children: [
        for (final (i, text) in const ['Platzhalter', 'Eigenes Foto'].indexed)
          Expanded(
            child: Semantics(
              button: true,
              selected: aktiv == i,
              label: i == 0 ? 'Platzhalter wählen' : 'Eigenes Foto hochladen',
              excludeSemantics: true,
              child: Material(
                color: aktiv == i ? kAccent : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: () => onWechsel(i),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48),
                    child: Center(
                      child: Text(
                        text,
                        textAlign: TextAlign.center,
                        style: TextStyle(fontFamily: kFontMono, fontWeight: FontWeight.w600, fontSize: 13, color: aktiv == i ? kOnAccent : kTextMuted),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _VorlagenKnopf extends StatelessWidget {
  final AvatarVorlage vorlage;
  final int colorIndex;
  final String name;
  final bool gewaehlt;
  final VoidCallback? onTap;
  const _VorlagenKnopf({required this.vorlage, required this.colorIndex, required this.name, required this.gewaehlt, required this.onTap});

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: gewaehlt,
    label: 'Platzhalter ${vorlage.gruppe.label}: ${vorlage.name}',
    excludeSemantics: true,
    child: Tooltip(
      message: vorlage.name,
      child: InkResponse(
        onTap: onTap,
        radius: 40,
        child: Container(
          width: 68,
          height: 68,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: gewaehlt ? kAccent : Colors.transparent, width: 2),
          ),
          child: PersonAvatar(name: name, colorIndex: colorIndex, size: 62, bild: AssetImage(vorlage.asset), bildAufFarbe: true),
        ),
      ),
    ),
  );
}
