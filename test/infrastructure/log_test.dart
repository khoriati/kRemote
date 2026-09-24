import 'package:flutter_test/flutter_test.dart';
import 'package:kremote/infrastructure/net/log.dart';

void main() {
  test('KLog mantém buffer circular e gera dump copiável', () async {
    KLog.clear();
    var notified = 0;
    final sub = KLog.changes.listen((_) => notified++);
    for (var i = 0; i < KLog.maxEntries + 10; i++) {
      KLog.d('t', 'm$i');
    }
    await Future<void>.delayed(Duration.zero);
    expect(KLog.entries.length, KLog.maxEntries);
    expect(KLog.entries.first.message, 'm10');
    expect(KLog.dump(), contains('[t] m509'));
    expect(KLog.entries.first.format(), matches(RegExp(r'^\d\d:\d\d:\d\d\.\d{3} \[t\] m10$')));
    expect(notified, greaterThan(0));
    await sub.cancel();
    KLog.clear();
    expect(KLog.entries, isEmpty);
  });
}
