import 'package:lye_core/lye_core.dart';

/// Token bucket per key (actor, node, address).
///
/// Ingest is cheap to abuse: a client that loops on a rejected batch or a
/// script that floods the endpoint must not fill the store or the disk.
class RateLimiter {
  RateLimiter({
    this.capacity = 60,
    this.refillPerMinute = 60,
    this.maxKeys = 10000,
    LyeClock? clock,
  }) : clock = clock ?? const SystemClock();

  final int capacity;
  final int refillPerMinute;
  final int maxKeys;
  final LyeClock clock;

  final Map<String, _Bucket> _buckets = <String, _Bucket>{};

  /// Consumes one token for [key]; false when the bucket is empty.
  bool tryAcquire(String key) {
    final now = clock.now();
    final bucket = _buckets.putIfAbsent(key, () {
      if (_buckets.length >= maxKeys) {
        // Drop the least recently touched bucket rather than growing forever.
        String? oldest;
        DateTime? oldestTime;
        for (final entry in _buckets.entries) {
          if (oldestTime == null || entry.value.touched.isBefore(oldestTime)) {
            oldest = entry.key;
            oldestTime = entry.value.touched;
          }
        }
        if (oldest != null) _buckets.remove(oldest);
      }
      return _Bucket(capacity.toDouble(), now);
    });
    final elapsedMs = now.difference(bucket.touched).inMilliseconds;
    bucket.tokens = (bucket.tokens + elapsedMs * refillPerMinute / 60000.0)
        .clamp(0.0, capacity.toDouble());
    bucket.touched = now;
    if (bucket.tokens < 1) return false;
    bucket.tokens -= 1;
    return true;
  }

  /// Tokens currently available for [key] (diagnostics).
  double tokensFor(String key) => _buckets[key]?.tokens ?? capacity.toDouble();
}

class _Bucket {
  _Bucket(this.tokens, this.touched);

  double tokens;
  DateTime touched;
}
