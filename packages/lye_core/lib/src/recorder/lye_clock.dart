/// Source of time for the recorder. Injectable so tests are deterministic
/// and so a server can substitute a monotonic or NTP-disciplined clock.
abstract class LyeClock {
  DateTime now();
}

/// Wall clock in UTC.
class SystemClock implements LyeClock {
  const SystemClock();

  @override
  DateTime now() => DateTime.now().toUtc();
}

/// Manually advanced clock for tests.
class FixedClock implements LyeClock {
  FixedClock(DateTime start) : _now = start.toUtc();

  DateTime _now;

  @override
  DateTime now() => _now;

  void advance(Duration by) {
    _now = _now.add(by);
  }

  set current(DateTime value) {
    _now = value.toUtc();
  }
}
