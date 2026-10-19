// Die zehn Platzhalter-Benutzerbilder (Zeichnungen aus docs/mockups/avatare.html, als transparente PNG in assets/avatare/;
// Quellen und Skripte in tool/avatare/). Den Hintergrund liefert die App je Person aus der Personenfarbe. Die Kennungen
// müssen mit AVATAR_PRESETS in server/src/avatar/image.ts übereinstimmen.

enum AvatarGruppe {
  vater('Vater'),
  mutter('Mutter'),
  kind('Kind');

  final String label;
  const AvatarGruppe(this.label);
}

class AvatarVorlage {
  final String id;
  final AvatarGruppe gruppe;
  final String name;
  final String asset;
  const AvatarVorlage(this.id, this.gruppe, this.name, String datei) : asset = 'assets/avatare/avatar_$datei.png';
}

const kAvatarVorlagen = <AvatarVorlage>[
  AvatarVorlage('V01', AvatarGruppe.vater, 'Kurzhaar, Hemd', 'v01_vater_kurzhaar_hemd'),
  AvatarVorlage('V08', AvatarGruppe.vater, 'Basecap, Hoodie', 'v08_vater_basecap_hoodie'),
  AvatarVorlage('V12', AvatarGruppe.vater, 'Undercut, Sonnenbrille', 'v12_vater_undercut_sonnenbrille'),
  AvatarVorlage('M01', AvatarGruppe.mutter, 'Lange Haare, Ohrringe', 'm01_mutter_lange_haare'),
  AvatarVorlage('M08', AvatarGruppe.mutter, 'Kurzhaarschnitt, Weiß', 'm08_mutter_kurzhaarschnitt'),
  AvatarVorlage('M13', AvatarGruppe.mutter, 'Seitenzopf, Brille', 'm13_mutter_seitenzopf_brille'),
  AvatarVorlage('K07', AvatarGruppe.kind, 'Schulkind, Basecap', 'k07_kind_schulkind_basecap'),
  AvatarVorlage('K08', AvatarGruppe.kind, 'Schulkind, Zöpfchen', 'k08_kind_schulkind_zoepfchen'),
  AvatarVorlage('K12', AvatarGruppe.kind, 'Teenager, Kopfhörer', 'k12_kind_teenager_kopfhoerer'),
  AvatarVorlage('K13', AvatarGruppe.kind, 'Teenager, lange Haare', 'k13_kind_teenager_lange_haare'),
];

/// Die Vorlage zu einer Kennung; null bei unbekannten Kennungen (z. B. einer neueren Server-Version): dann gelten die Initialen.
AvatarVorlage? avatarVorlage(String? id) {
  for (final v in kAvatarVorlagen) {
    if (v.id == id) return v;
  }
  return null;
}
