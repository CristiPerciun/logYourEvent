import 'package:meta/meta.dart';

import '../model/enums.dart';
import '../privacy/text_sanitizer.dart';

/// Maps categories to retention classes (§6.6 of the architecture
/// document). Products may override the mapping; the class travels with the
/// event so the purge job never has to know the policy that produced it.
@immutable
class RetentionPolicy {
  const RetentionPolicy({
    this.access = const <LyeCategory>{
      LyeCategory.auth,
      LyeCategory.rpc,
      LyeCategory.export,
    },
    this.security = const <LyeCategory>{LyeCategory.security},
  });

  /// Categories kept 12 months.
  final Set<LyeCategory> access;

  /// Categories kept 24 months.
  final Set<LyeCategory> security;

  static const RetentionPolicy standard = RetentionPolicy();

  LyeRetention classify(LyeCategory category) {
    if (security.contains(category)) return LyeRetention.security;
    if (access.contains(category)) return LyeRetention.access;
    return LyeRetention.application;
  }
}

/// Static identity of a recorder.
@immutable
class LyeConfig {
  LyeConfig({
    required this.origin,
    required this.platform,
    required this.appId,
    required this.appVersion,
    required this.nodeId,
    this.retention = RetentionPolicy.standard,
    this.maxFieldLength = LyeText.defaultMaxLength,
  }) {
    if (appId.isEmpty || appVersion.isEmpty || nodeId.isEmpty) {
      throw ArgumentError('appId, appVersion and nodeId are required');
    }
    if (nodeId.contains('/')) {
      throw ArgumentError.value(nodeId, 'nodeId', 'must not contain "/"');
    }
  }

  final LyeOrigin origin;
  final LyePlatform platform;

  /// Stable application identifier (`console_flutter`, `cos_server`).
  final String appId;

  /// `version+build`.
  final String appVersion;

  /// Installation identifier on a client, instance identifier on a server.
  /// Random, stable across restarts, never derived from personal data.
  final String nodeId;
  final RetentionPolicy retention;
  final int maxFieldLength;

  /// Value of the `app` column.
  String get app => '$appId@$appVersion';
}
