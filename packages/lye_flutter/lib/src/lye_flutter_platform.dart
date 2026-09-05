import 'package:flutter/foundation.dart';
import 'package:lye_core/lye_core.dart';

/// Maps the Flutter target to the `platform` column.
abstract final class LyeFlutterPlatform {
  static LyePlatform get current {
    if (kIsWeb) return LyePlatform.web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return LyePlatform.android;
      case TargetPlatform.iOS:
        return LyePlatform.ios;
      case TargetPlatform.windows:
        return LyePlatform.windows;
      case TargetPlatform.macOS:
        return LyePlatform.macos;
      case TargetPlatform.linux:
        return LyePlatform.linux;
      case TargetPlatform.fuchsia:
        return LyePlatform.unknown;
    }
  }
}
