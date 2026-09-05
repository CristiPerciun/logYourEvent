import 'dart:io';
import 'dart:math';

import 'package:lye_core/lye_core.dart';

int _nextSeed = 7;

LyeRecorder testRecorder({
  required LyeStore store,
  FixedClock? clock,
  LyeOrigin origin = LyeOrigin.client,
  String nodeId = 'node-a',
  String? epoch,
}) {
  return LyeRecorder(
    config: LyeConfig(
      origin: origin,
      platform: LyePlatform.vm,
      appId: 'test_app',
      appVersion: '1.0.0+1',
      nodeId: nodeId,
    ),
    store: store,
    clock: clock ?? FixedClock(DateTime.utc(2026, 9, 5, 9)),
    random: Random(_nextSeed++),
    epoch: epoch,
  );
}

Future<List<LyeEvent>> recordMany(
  LyeRecorder recorder,
  int count, {
  FixedClock? clock,
}) async {
  final events = <LyeEvent>[];
  for (var i = 0; i < count; i++) {
    events.add(
      await recorder.point(
        LyeCategory.interaction,
        LyeActions.uiTap,
        component: 'button-$i',
        attrs: <String, Object?>{'index': i},
      ),
    );
    clock?.advance(const Duration(seconds: 1));
  }
  return events;
}

Future<Directory> tempDir(String label) =>
    Directory.systemTemp.createTemp('lye_${label}_');
