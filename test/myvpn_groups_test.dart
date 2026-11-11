// MyVPN: разделы, поиск и фильтры в списке серверов
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/widget/myvpn_profile_extras.dart';

MyServer _s(String name, {String type = 'vless', String server = '1.1.1.1'}) =>
    myServerFrom({'type': type, 'tag': name, 'server': server, 'server_port': 443});

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

  test('флаг страны', () {
    expect(myFlagOf('🇩🇪 DE | Berlin'), '🇩🇪');
    expect(myFlagOf('Автовыбор'), '');
  });

  test('поиск и фильтры', () {
    final list = [
      _s('🇩🇪 DE | Berlin', server: 'de.example'),
      _s('🇳🇱 NL | Amsterdam', type: 'hysteria2'),
      _s('🇩🇪 DE | Frankfurt', type: 'hysteria2'),
    ];
    expect(myFilterServers(list, query: 'berl').length, 1);
    expect(myFilterServers(list, query: 'de.exa').length, 1);
    expect(myFilterServers(list, type: 'hysteria2').length, 2);
    expect(myFilterServers(list, flag: '🇩🇪').length, 2);
    expect(myFilterServers(list, type: 'hysteria2', flag: '🇩🇪').single.name, '🇩🇪 DE | Frankfurt');
    expect(list[1].udp, isTrue);
    expect(list[0].udp, isFalse);
  });
}
