import 'dart:math';

import 'package:lye_core/lye_core.dart';

/// Seeds are deterministic but distinct per recorder: two recorders sharing a
/// store must not mint the same UUIDs, exactly as two devices never would.
int _nextSeed = 42;

/// Deterministic recorder for tests: fixed clock, seeded random, memory store.
LyeRecorder testRecorder({
  LyeStore? store,
  FixedClock? clock,
  LyeOrigin origin = LyeOrigin.client,
  String nodeId = 'node-a',
  String? epoch,
  Redactor? redactor,
  LyeLevel? level = LyeLevel.forensic,
  LyeLevelPolicy levels = LyeLevelPolicy.standard,
}) {
  return LyeRecorder(
    config: LyeConfig(
      origin: origin,
      platform: LyePlatform.vm,
      appId: 'test_app',
      appVersion: '1.0.0+1',
      nodeId: nodeId,
      levels: levels,
    ),
    store: store ?? MemoryLyeStore(),
    clock: clock ?? FixedClock(DateTime.utc(2026, 9, 5, 9)),
    random: Random(_nextSeed++),
    epoch: epoch,
    redactor: redactor,
    level: level,
  );
}

/// Records [count] simple point events and returns them in order.
Future<List<LyeEvent>> recordMany(LyeRecorder recorder, int count) async {
  final events = <LyeEvent>[];
  for (var i = 0; i < count; i++) {
    events.add(
      (await recorder.point(
        LyeCategory.interaction,
        LyeActions.uiTap,
        component: 'button-$i',
        attrs: <String, Object?>{'index': i},
      ))!,
    );
  }
  return events;
}

/// Rebuilds an event with one string column replaced, keeping the hashes:
/// simulates a row rewritten in a CSV file.
LyeEvent tamperColumn(LyeEvent event, String column, String value) {
  final fields = event.toCsvFields();
  fields[LyeCsvSchema.indexOf(column)] = value;
  return LyeEvent.fromCsvFields(fields);
}

/// Test ergonomics: the recorder returns null when the level in force does
/// not admit a draft, which is the point of ADR-010 but makes every
/// assertion noisy. These wrappers fail loudly instead.
extension MustRecord on LyeRecorder {
  Future<LyeEvent> mustRecord(LyeDraft draft) async {
    final event = await record(draft);
    if (event == null) {
      throw StateError('the level in force dropped ${draft.action}');
    }
    return event;
  }

  Future<LyeEvent> mustStart({
    Map<String, Object?> attrs = const <String, Object?>{},
  }) async {
    final event = await start(attrs: attrs);
    if (event == null) throw StateError('stream start was dropped');
    return event;
  }

  Future<LyeEvent> mustPoint(
    LyeCategory category,
    String action, {
    LyeOutcome outcome = LyeOutcome.none,
    String? operation,
    String? route,
    String? component,
    String? targetType,
    String? targetId,
    String? auditRef,
    LyeLevel? level,
    LyeSubjectType? subjectType,
    String? subjectRef,
    Map<String, Object?> attrs = const <String, Object?>{},
  }) async {
    final event = await point(
      category,
      action,
      outcome: outcome,
      operation: operation,
      route: route,
      component: component,
      targetType: targetType,
      targetId: targetId,
      auditRef: auditRef,
      level: level,
      subjectType: subjectType,
      subjectRef: subjectRef,
      attrs: attrs,
    );
    if (event == null) throw StateError('the level in force dropped $action');
    return event;
  }
}
