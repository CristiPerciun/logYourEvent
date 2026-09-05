import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:lye_core/lye_core.dart';

/// Routes framework and platform errors into the recorder as
/// `error.unhandled`, chaining to the handlers that were installed before.
///
/// Only the exception type and a digest of its message are recorded, plus
/// the Flutter library that reported it. Messages and stack traces stay in
/// Sentry, which has its own scrubbing; LYE records that something failed,
/// where and when, in the same chain as the actions around it.
class LyeErrorHooks {
  LyeErrorHooks._(
    this.recorder,
    this._previousFlutterHandler,
    this._previousPlatformHandler,
  );

  final LyeRecorder recorder;
  final FlutterExceptionHandler? _previousFlutterHandler;
  final ui.ErrorCallback? _previousPlatformHandler;

  /// Installs both hooks. Keep the returned object to [uninstall] in tests.
  static LyeErrorHooks install(
    LyeRecorder recorder, {
    bool platformDispatcher = true,
  }) {
    final hooks = LyeErrorHooks._(
      recorder,
      FlutterError.onError,
      platformDispatcher ? ui.PlatformDispatcher.instance.onError : null,
    );
    FlutterError.onError = hooks._onFlutterError;
    if (platformDispatcher) {
      ui.PlatformDispatcher.instance.onError = hooks._onPlatformError;
    }
    return hooks;
  }

  /// Restores the previous handlers.
  void uninstall() {
    FlutterError.onError = _previousFlutterHandler;
    if (_previousPlatformHandler != null ||
        ui.PlatformDispatcher.instance.onError == _onPlatformError) {
      ui.PlatformDispatcher.instance.onError = _previousPlatformHandler;
    }
  }

  void _onFlutterError(FlutterErrorDetails details) {
    unawaited(
      recorder.record(
        LyeDraft.error(
          details.exception,
          action: LyeActions.errorUnhandled,
          attrs: <String, Object?>{
            'source': 'flutter',
            if (details.library != null) 'library': details.library,
            'silent': details.silent,
          },
          retention: LyeRetention.application,
        ),
      ),
    );
    _previousFlutterHandler?.call(details);
  }

  bool _onPlatformError(Object error, StackTrace stack) {
    unawaited(
      recorder.record(
        LyeDraft.error(
          error,
          action: LyeActions.errorUnhandled,
          attrs: const <String, Object?>{'source': 'platform'},
        ),
      ),
    );
    final previous = _previousPlatformHandler;
    if (previous != null) return previous(error, stack);
    return false;
  }
}
