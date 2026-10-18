/// Ob [v] die Form "x.y.z" hat.
bool isVersion(String v) => RegExp(r'^\d+\.\d+\.\d+$').hasMatch(v);

/// Vergleicht zwei Versionen der Form "x.y.z": negativ, wenn a < b, 0 bei gleich, positiv, wenn a > b.
int compareVersions(String a, String b) {
  final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}
