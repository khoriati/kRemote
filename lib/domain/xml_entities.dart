/// Decodifica entidades XML/HTML em texto vindo de descrições UPnP, do
/// `device-info` do Roku etc. (`43&quot; FHD` → `43" FHD`).
String decodeXmlEntities(String s) {
  // Repete porque há fontes que escapam duas vezes (`&amp;quot;`).
  var cur = s;
  for (var i = 0; i < 3 && cur.contains('&'); i++) {
    final next = _decodeOnce(cur);
    if (next == cur) break;
    cur = next;
  }
  return cur;
}

String _decodeOnce(String s) {
  return s.replaceAllMapped(RegExp(r'&(#x[0-9A-Fa-f]+|#\d+|[A-Za-z]+);'), (m) {
    final e = m.group(1)!;
    if (e.startsWith('#x')) return _char(int.tryParse(e.substring(2), radix: 16)) ?? m.group(0)!;
    if (e.startsWith('#')) return _char(int.tryParse(e.substring(1))) ?? m.group(0)!;
    return const {'quot': '"', 'amp': '&', 'lt': '<', 'gt': '>', 'apos': "'", 'nbsp': ' '}[e] ?? m.group(0)!;
  });
}

String? _char(int? code) => code == null || code < 0 || code > 0x10FFFF ? null : String.fromCharCode(code);
