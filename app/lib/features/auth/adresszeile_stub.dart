/// Ergebnis beim Lesen der Adresszeile: `null` = kein Einladungslink; sonst das Token (oder `token == null` bei ungültiger Form).
typedef AdresszeilenLink = ({String? token});

AdresszeilenLink? einladungAusAdresszeileNehmen() => null;

void aufEinladungInAdresszeileHoeren(void Function(AdresszeilenLink link) beiLink) {}
