import 'dart:math';

import 'package:lye_core/lye_core.dart';

int _nextSeed = 900;

LyeRecorder testRecorder() {
  return LyeRecorder(
    config: LyeConfig(
      origin: LyeOrigin.client,
      platform: LyePlatform.vm,
      appId: 'console_test',
      appVersion: '1.0.0+1',
      nodeId: 'test-node',
    ),
    store: MemoryLyeStore(),
    clock: FixedClock(DateTime.utc(2026, 9, 5, 9)),
    random: Random(_nextSeed++),
  );
}

Future<List<LyeEvent>> allEvents(LyeRecorder recorder) async {
  await recorder.flush();
  return recorder.store.readRange(recorder.streamId, fromSeq: 1, toSeq: 10000);
}
