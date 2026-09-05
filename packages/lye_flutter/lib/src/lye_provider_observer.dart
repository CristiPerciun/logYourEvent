import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lye_core/lye_core.dart';

/// Records Riverpod state transitions as `state.*` events.
///
/// What is recorded: the provider name, the runtime type of the value and,
/// for `AsyncValue`, its phase (`loading`, `data`, `error`). What is never
/// recorded: the value itself. Even a digest of the value is off by default,
/// because a digest of a small enumerable state can be brute-forced back.
///
/// Register with `ProviderScope(observers: [LyeProviderObserver(recorder)])`.
base class LyeProviderObserver extends ProviderObserver {
  LyeProviderObserver(
    this.recorder, {
    this.include,
    this.recordAdds = true,
    this.recordDisposes = false,
    this.recordUpdates = true,
  });

  final LyeRecorder recorder;

  /// Filter on the provider name; null records every provider.
  final bool Function(String providerName)? include;
  final bool recordAdds;
  final bool recordDisposes;
  final bool recordUpdates;

  static String nameOf(ProviderObserverContext context) {
    final provider = context.provider;
    return provider.name ?? provider.runtimeType.toString();
  }

  static String phaseOf(Object? value) {
    if (value is AsyncValue<Object?>) {
      if (value.isLoading) return 'loading';
      if (value.hasError) return 'error';
      return 'data';
    }
    return 'value';
  }

  static String typeOf(Object? value) {
    if (value is AsyncValue<Object?>) {
      final inner = value.hasValue ? value.value : null;
      return inner == null ? 'AsyncValue' : 'AsyncValue<${inner.runtimeType}>';
    }
    return value == null ? 'null' : value.runtimeType.toString();
  }

  bool _accepts(String name) => include == null || include!(name);

  void _record(
    String action,
    ProviderObserverContext context,
    Map<String, Object?> attrs, {
    LyeOutcome outcome = LyeOutcome.none,
  }) {
    final name = nameOf(context);
    if (!_accepts(name)) return;
    unawaited(
      recorder.record(
        LyeDraft(
          category: LyeCategory.state,
          action: action,
          outcome: outcome,
          component: name,
          attrs: attrs,
        ),
      ),
    );
  }

  @override
  void didAddProvider(ProviderObserverContext context, Object? value) {
    if (!recordAdds) return;
    _record(LyeActions.stateAdd, context, <String, Object?>{
      'type': typeOf(value),
      'phase': phaseOf(value),
    });
  }

  @override
  void didUpdateProvider(
    ProviderObserverContext context,
    Object? previousValue,
    Object? newValue,
  ) {
    if (!recordUpdates) return;
    _record(LyeActions.stateUpdate, context, <String, Object?>{
      'type': typeOf(newValue),
      'from': phaseOf(previousValue),
      'to': phaseOf(newValue),
    });
  }

  @override
  void didDisposeProvider(ProviderObserverContext context) {
    if (!recordDisposes) return;
    _record(LyeActions.stateDispose, context, const <String, Object?>{});
  }

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    final name = nameOf(context);
    if (!_accepts(name)) return;
    unawaited(
      recorder.record(
        LyeDraft.error(
          error,
          action: LyeActions.stateFail,
          category: LyeCategory.state,
          component: name,
        ),
      ),
    );
  }
}
