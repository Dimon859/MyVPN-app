// MyVPN: публичный Telegram-канал как подписка.
// Адрес канала (t.me/имя) превращается в веб-версию с последними постами (t.me/s/имя),
// а из её страницы вытаскиваются все ссылки на серверы.

final _myTgUrl = RegExp(r'^https?://(?:www\.)?(?:t\.me|telegram\.me)/(?:s/)?([A-Za-z][A-Za-z0-9_]{3,})/?(?:[?#].*)?$');

/// Адрес канала → адрес его веб-версии с постами; остальные адреса без изменений.
String myTelegramUrl(String url) {
  final m = _myTgUrl.firstMatch(url.trim());
  return m == null ? url : 'https://t.me/s/${m.group(1)}';
}

bool myIsTelegramUrl(String url) => _myTgUrl.hasMatch(url.trim());

final _myLink = RegExp(r'(?:vless|vmess|trojan|ss|hysteria2|hy2|tuic)://[^\s<>"]+');

/// Ссылки на серверы со страницы канала (по одной на строку), или null, если это не страница Telegram.
String? myTelegramLinks(String text) {
  if (!text.contains('tgme_widget_message') && !text.contains('tgme_channel')) return null;
  var t = text
      .replaceAll(RegExp(r'<wbr\s*/?>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');
  t = t
      .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => String.fromCharCode(int.parse(m[1]!)))
      .replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)))
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
  final links = <String>{};
  for (final m in _myLink.allMatches(t)) {
    // хвост из знаков препинания после ссылки в тексте поста
    links.add(m[0]!.replaceFirst(RegExp(r'[.,;)\]]+$'), ''));
  }
  return links.join('\n');
}
