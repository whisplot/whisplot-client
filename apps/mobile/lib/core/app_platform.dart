import 'package:flutter/foundation.dart';

bool get isDesktopPlatform => switch (defaultTargetPlatform) {
  TargetPlatform.macOS ||
  TargetPlatform.windows ||
  TargetPlatform.linux => true,
  _ => false,
};
