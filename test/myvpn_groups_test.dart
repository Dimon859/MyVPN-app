// MyVPN: разделы в списке серверов
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';

MyServer _s(String name) => (name: name, info: '', json: const <String, dynamic>{});

void main() {
  test('серверы собираются в разделы по имени', () {
    final groups = myGroupServers([
      _s('Автовыбор [1]'),
      _s('Автовыбор [2]'),
      _s('[WI-FI] – Автовыбор США'),
      _s('🇩🇪 DE | Berlin [1.1]'),
      _s('🇩🇪 DE | Berlin [2.1]'),
      _s('Автовыбор [3]'),
      _s('X (2)'),
      _s('X'),
    ]);
    expect([for (final g in groups) g.name], ['Автовыбор', '[WI-FI] – Автовыбор США', '🇩🇪 DE | Berlin', 'X']);
    expect([for (final g in groups) g.servers.length], [3, 1, 2, 2]);
  });
}
