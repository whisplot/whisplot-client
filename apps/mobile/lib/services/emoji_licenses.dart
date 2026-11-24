import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

bool _registered = false;

void registerEmojiLicenses() {
  if (_registered) return;
  _registered = true;
  LicenseRegistry.addLicense(() async* {
    for (final entry in const {
      'Twemoji graphics — CC BY 4.0': 'LICENSE-TWEMOJI-GRAPHICS.txt',
      'Twemoji code — MIT': 'LICENSE-TWEMOJI-CODE.txt',
      'Unicode emoji data': 'LICENSE-UNICODE.txt',
      'Unicode CLDR annotations': 'LICENSE-CLDR.txt',
      'Emoji attribution and source versions': 'NOTICE.txt',
    }.entries) {
      yield LicenseEntryWithLineBreaks([
        entry.key,
      ], await rootBundle.loadString('assets/emojis/licenses/${entry.value}'));
    }
  });
}
