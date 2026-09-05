import 'dart:io';
import 'dart:math';

import 'package:lye_core/lye_core.dart';

int _nextSeed = 100;

LyeRecorder testRecorder({
  required LyeStore store,
  FixedClock? clock,
  LyeOrigin origin = LyeOrigin.client,
  String nodeId = 'browser-1',
  String? epoch,
}) {
  return LyeRecorder(
    config: LyeConfig(
      origin: origin,
      platform: origin == LyeOrigin.client
          ? LyePlatform.web
          : LyePlatform.linux,
      appId: origin == LyeOrigin.client ? 'console_flutter' : 'cos_server',
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
      ),
    );
    clock?.advance(const Duration(seconds: 1));
  }
  return events;
}

Future<Directory> tempDir(String label) =>
    Directory.systemTemp.createTemp('lye_srv_${label}_');

const String actorA = '55555555-5555-5555-5555-555555555555';
const String actorB = '66666666-6666-6666-6666-666666666666';
const String partnerA = '11111111-1111-1111-1111-111111111111';
const String tenantA = '22222222-2222-2222-2222-222222222222';
