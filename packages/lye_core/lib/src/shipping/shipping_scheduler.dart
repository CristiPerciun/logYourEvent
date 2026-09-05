import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import '../model/enums.dart';
import '../model/lye_actions.dart';
import '../model/lye_draft.dart';
import '../model/lye_event.dart';
import '../recorder/lye_clock.dart';
import '../recorder/lye_recorder.dart';
import 'lye_batch.dart';

/// Answer of the receiving side.
@immutable
class ShipResult {
  const ShipResult.accepted() : accepted = true, retryable = false, reason = '';

  /// A transient failure (network, 5xx): keep the events, try later.
  const ShipResult.failed(this.reason) : accepted = false, retryable = true;

  /// A definitive refusal (4xx, broken chain): retrying cannot help.
  const ShipResult.rejected(this.reason) : accepted = false, retryable = false;

  final bool accepted;
  final bool retryable;
  final String reason;
}

/// Transport of batches. `lye_flutter` provides an HTTP implementation;
/// tests use an in-memory one.
abstract class BatchShipper {
  Future<ShipResult> ship(LyeBatch batch);
}

/// Outcome of one [ShippingScheduler.flush].
enum FlushOutcome { shipped, nothingToShip, deferred, failed, rejected, busy }

/// Moves pending events from the recorder's store to a [BatchShipper].
///
/// Flushes when [flushThreshold] events accumulate or every [interval];
/// on transport failure it backs off exponentially with jitter up to
/// [maxBackoff]; on a definitive rejection it stops shipping that stream,
/// records `lye.ship.rejected` once, and waits for [resetAfterRejection].
/// Events are marked shipped only after the receiver accepted them, so a
/// crash between the two leaves them pending, never lost.
class ShippingScheduler {
  ShippingScheduler({
    required this.recorder,
    required this.shipper,
    this.maxBatchSize = 200,
    this.flushThreshold = 50,
    this.interval = const Duration(seconds: 5),
    this.minBackoff = const Duration(seconds: 2),
    this.maxBackoff = const Duration(minutes: 5),
    LyeClock? clock,
    Random? random,
  }) : clock = clock ?? recorder.clock,
       _random = random ?? Random();

  final LyeRecorder recorder;
  final BatchShipper shipper;
  final int maxBatchSize;
  final int flushThreshold;
  final Duration interval;
  final Duration minBackoff;
  final Duration maxBackoff;
  final LyeClock clock;
  final Random _random;

  Timer? _timer;
  StreamSubscription<LyeEvent>? _subscription;
  bool _flushing = false;
  bool _rejected = false;
  int _sinceLastFlush = 0;
  Duration? _backoff;
  DateTime? _pausedUntil;
  int _shipped = 0;
  int _failedAttempts = 0;

  /// Events accepted by the receiver since start.
  int get shippedCount => _shipped;

  /// Transport failures since start.
  int get failedAttempts => _failedAttempts;

  /// Whether a definitive rejection stopped the scheduler.
  bool get isRejected => _rejected;

  /// Current backoff, null when the last attempt succeeded.
  Duration? get backoff => _backoff;

  /// Starts listening to the recorder and the periodic timer.
  void start() {
    _subscription ??= recorder.events.listen((LyeEvent _) {
      _sinceLastFlush++;
      if (_sinceLastFlush >= flushThreshold) {
        unawaited(flush());
      }
    });
    _timer ??= Timer.periodic(interval, (_) => unawaited(flush()));
  }

  /// Stops the timer and the subscription. Pending events stay in the store.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Allows shipping again after a definitive rejection (for instance after
  /// the app restarted with a new epoch).
  void resetAfterRejection() {
    _rejected = false;
    _backoff = null;
    _pausedUntil = null;
  }

  /// Ships everything pending, one batch at a time.
  Future<FlushOutcome> flush() async {
    if (_flushing) return FlushOutcome.busy;
    if (_rejected) return FlushOutcome.rejected;
    final pausedUntil = _pausedUntil;
    if (pausedUntil != null && clock.now().isBefore(pausedUntil)) {
      return FlushOutcome.deferred;
    }
    _flushing = true;
    try {
      var shippedSomething = false;
      while (true) {
        final pending = await recorder.store.readPending(
          recorder.streamId,
          limit: maxBatchSize,
        );
        if (pending.isEmpty) {
          _sinceLastFlush = 0;
          return shippedSomething
              ? FlushOutcome.shipped
              : FlushOutcome.nothingToShip;
        }
        final batch = LyeBatch.fromEvents(pending);
        ShipResult result;
        try {
          result = await shipper.ship(batch);
        } catch (error) {
          result = ShipResult.failed(error.runtimeType.toString());
        }
        if (result.accepted) {
          await recorder.store.markShipped(
            recorder.streamId,
            batch.eventIds,
            clock.now(),
          );
          _shipped += batch.count;
          _backoff = null;
          _pausedUntil = null;
          shippedSomething = true;
          if (pending.length < maxBatchSize) {
            _sinceLastFlush = 0;
            return FlushOutcome.shipped;
          }
          continue;
        }
        if (result.retryable) {
          _failedAttempts++;
          _scheduleBackoff();
          return FlushOutcome.failed;
        }
        _rejected = true;
        await recorder.record(
          LyeDraft(
            category: LyeCategory.system,
            action: LyeActions.shipRejected,
            outcome: LyeOutcome.fail,
            attrs: <String, Object?>{
              'from_seq': batch.fromSeq,
              'to_seq': batch.toSeq,
              'reason': result.reason,
            },
          ),
        );
        return FlushOutcome.rejected;
      }
    } finally {
      _flushing = false;
    }
  }

  void _scheduleBackoff() {
    final previous = _backoff;
    var next = previous == null ? minBackoff : previous * 2;
    if (next > maxBackoff) next = maxBackoff;
    _backoff = next;
    // Full jitter: wait a random fraction of the backoff, never zero.
    final jitterMs = 1 + _random.nextInt(next.inMilliseconds);
    _pausedUntil = clock.now().add(Duration(milliseconds: jitterMs));
  }
}
