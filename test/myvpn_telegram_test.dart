// MyVPN: Telegram-канал как подписка
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/utils/myvpn_telegram.dart';

void main() {
  test('адрес канала → веб-версия', () {
    expect(myTelegramUrl('https://t.me/freeconfigs'), 'https://t.me/s/freeconfigs');
    expect(myTelegramUrl('https://t.me/s/freeconfigs'), 'https://t.me/s/freeconfigs');
    expect(myTelegramUrl('https://telegram.me/free_vpn/'), 'https://t.me/s/free_vpn');
    expect(myTelegramUrl('https://example.com/sub'), 'https://example.com/sub');
    expect(myTelegramUrl('https://t.me/s/abc/123'), 'https://t.me/s/abc/123');
  });

  test('ссылки со страницы канала', () {
    const html = '''
<div class="tgme_widget_message_text">Новые сервера:<br/>
<code>vless://uuid@1.2.3.4:443?security=reality&amp;sni=ya.ru&amp;type=tcp#%F0%9F%87%A9%F0%9F%87%AA DE</code><br>
hy2://pass@5.6.7.8:8443?obfs=salamander&amp;obfs-password=x#NL.
<a href="https://t.me/x">канал</a> vless://uuid@1.2.3.4:443?security=reality&amp;sni=ya.ru&amp;type=tcp#%F0%9F%87%A9%F0%9F%87%AA DE
</div>''';
    final links = myTelegramLinks(html)!.split('\n');
    expect(links, [
      'vless://uuid@1.2.3.4:443?security=reality&sni=ya.ru&type=tcp#%F0%9F%87%A9%F0%9F%87%AA',
      'hy2://pass@5.6.7.8:8443?obfs=salamander&obfs-password=x#NL',
    ]);
  });

  test('обычная подписка не трогается', () {
    expect(myTelegramLinks('vless://a@b:1#x'), isNull);
  });
}
