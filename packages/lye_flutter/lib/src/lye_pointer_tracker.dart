import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:lye_core/lye_core.dart';

import 'lye_trackable.dart';

/// Records taps (and optionally raw pointer events) with the innermost
/// [LyeTag] found on the hit-test path.
///
/// It listens on the global pointer route of the gesture binding, so no
/// widget needs to be wrapped except the controls worth naming. Positions
/// are bucketed to 16 logical pixels: enough to tell "top bar" from "table",
/// useless for reconstructing text entry.
class LyePointerTracker {
  LyePointerTracker(
    this.recorder, {
    this.recordUntagged = false,
    this.recordRawPointer = false,
    this.tapTimeout = const Duration(milliseconds: 500),
    this.tapSlop = 24.0,
  });

  final LyeRecorder recorder;

  /// Whether taps that hit no [LyeTrackable] are recorded (without component).
  final bool recordUntagged;

  /// Whether `ui.pointer_down` / `ui.pointer_up` are recorded too.
  final bool recordRawPointer;
  final Duration tapTimeout;
  final double tapSlop;

  final Map<int, _Down> _downs = <int, _Down>{};
  bool _installed = false;

  bool get isInstalled => _installed;

  /// Starts listening. Idempotent.
  void install() {
    if (_installed) return;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_handle);
    _installed = true;
  }

  /// Stops listening.
  void dispose() {
    if (!_installed) return;
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_handle);
    _installed = false;
    _downs.clear();
  }

  void _handle(PointerEvent event) {
    if (event is PointerDownEvent) {
      final tag = resolveTag(event);
      _downs[event.pointer] = _Down(event.position, event.timeStamp, tag);
      if (recordRawPointer) _recordRaw(LyeActions.uiPointerDown, event, tag);
      return;
    }
    if (event is PointerUpEvent) {
      final down = _downs.remove(event.pointer);
      if (recordRawPointer) {
        _recordRaw(LyeActions.uiPointerUp, event, down?.tag);
      }
      if (down == null) return;
      final elapsed = event.timeStamp - down.timeStamp;
      final moved = (event.position - down.position).distance;
      if (elapsed > tapTimeout || moved > tapSlop) return;
      _recordTap(event, down.tag);
      return;
    }
    if (event is PointerCancelEvent) {
      _downs.remove(event.pointer);
    }
  }

  /// Innermost [LyeTag] under [event], or null.
  static LyeTag? resolveTag(PointerEvent event) {
    final result = HitTestResult();
    WidgetsBinding.instance.hitTestInView(result, event.position, event.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMetaData && target.metaData is LyeTag) {
        return target.metaData as LyeTag;
      }
    }
    return null;
  }

  static String _kindOf(PointerEvent event) {
    switch (event.kind) {
      case PointerDeviceKind.touch:
        return 'touch';
      case PointerDeviceKind.mouse:
        return 'mouse';
      case PointerDeviceKind.stylus:
      case PointerDeviceKind.invertedStylus:
        return 'stylus';
      case PointerDeviceKind.trackpad:
        return 'trackpad';
      case PointerDeviceKind.unknown:
        return 'unknown';
    }
  }

  static Map<String, Object?> _positionAttrs(PointerEvent event) =>
      <String, Object?>{
        'kind': _kindOf(event),
        'x': (event.position.dx / 16).floor() * 16,
        'y': (event.position.dy / 16).floor() * 16,
      };

  void _recordRaw(String action, PointerEvent event, LyeTag? tag) {
    unawaited(
      recorder.record(
        LyeDraft(
          category: LyeCategory.interaction,
          action: action,
          component: tag?.id,
          attrs: _positionAttrs(event),
        ),
      ),
    );
  }

  void _recordTap(PointerEvent event, LyeTag? tag) {
    if (tag == null && !recordUntagged) return;
    unawaited(
      recorder.record(
        LyeDraft(
          category: LyeCategory.interaction,
          action: tag?.intent == null ? LyeActions.uiTap : LyeActions.uiIntent,
          outcome: LyeOutcome.none,
          operation: tag?.intent,
          component: tag?.id,
          attrs: _positionAttrs(event),
        ),
      ),
    );
  }
}

class _Down {
  _Down(this.position, this.timeStamp, this.tag);

  final Offset position;
  final Duration timeStamp;
  final LyeTag? tag;
}
