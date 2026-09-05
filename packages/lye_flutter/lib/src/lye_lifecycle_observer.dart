import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:lye_core/lye_core.dart';

/// Records application lifecycle and locale changes.
///
/// Register with `WidgetsBinding.instance.addObserver(observer)`; call
/// [dispose] to remove it.
class LyeLifecycleObserver with WidgetsBindingObserver {
  LyeLifecycleObserver(this.recorder);

  final LyeRecorder recorder;
  bool _installed = false;

  void install() {
    if (_installed) return;
    WidgetsBinding.instance.addObserver(this);
    _installed = true;
  }

  void dispose() {
    if (!_installed) return;
    WidgetsBinding.instance.removeObserver(this);
    _installed = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final String? action;
    switch (state) {
      case AppLifecycleState.resumed:
        action = LyeActions.appResume;
      case AppLifecycleState.paused:
        action = LyeActions.appPause;
      case AppLifecycleState.detached:
        action = LyeActions.appDetach;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
        action = null;
    }
    if (action == null) return;
    unawaited(
      recorder.point(LyeCategory.lifecycle, action, outcome: LyeOutcome.ok),
    );
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    unawaited(
      recorder.point(
        LyeCategory.lifecycle,
        LyeActions.appLocaleChange,
        outcome: LyeOutcome.ok,
        attrs: <String, Object?>{
          'languages': <String>[
            for (final l in locales ?? const <Locale>[]) l.languageCode,
          ],
        },
      ),
    );
  }
}
