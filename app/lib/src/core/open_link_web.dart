import 'package:web/web.dart' as web;

/// Open [url] in a new tab. True, because a browser always can.
bool openLink(String url) {
  web.window.open(url, '_blank', 'noopener');
  return true;
}
