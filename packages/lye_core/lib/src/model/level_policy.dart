import 'package:meta/meta.dart';

import 'enums.dart';
import 'lye_actions.dart';

/// Maps an action to the verbosity level at which it is emitted (ADR-010).
///
/// The policy is data, not code: a product can replace it for its own
/// vertical. It answers one question — given a category, an action and an
/// outcome, what is the lowest level of detail that still records this? —
/// and the recorder drops everything above the level in force **before**
/// sealing, so sequence numbers stay contiguous and a gap can never be
/// mistaken for a loss.
@immutable
class LyeLevelPolicy {
  const LyeLevelPolicy({
    this.standardCategories = const <LyeCategory>{
      LyeCategory.lifecycle,
      LyeCategory.navigation,
      LyeCategory.rpc,
      LyeCategory.audit,
      LyeCategory.job,
      LyeCategory.export,
    },
    this.verboseCategories = const <LyeCategory>{
      LyeCategory.interaction,
      LyeCategory.state,
    },
    this.overrides = const <String, LyeLevel>{},
  });

  static const LyeLevelPolicy standard = LyeLevelPolicy();

  /// Categories that belong to the `standard` trail.
  final Set<LyeCategory> standardCategories;

  /// Categories that belong to the `verbose` trail.
  final Set<LyeCategory> verboseCategories;

  /// Per-action exceptions, checked before the categories.
  final Map<String, LyeLevel> overrides;

  /// Actions that are recorded at every level, including when logging is
  /// switched off: they are a legal obligation, not diagnostics (DTA §6.6,
  /// ADR-003). Security, authentication and the library's own housekeeping.
  static bool isAlwaysRecorded(LyeCategory category, String action) {
    return category == LyeCategory.security ||
        category == LyeCategory.auth ||
        action.startsWith('lye.');
  }

  /// Actions that are part of the forensic trail only.
  static const Set<String> forensicActions = <String>{
    LyeActions.fnEnter,
    LyeActions.fnExit,
    LyeActions.uiPointerDown,
    LyeActions.uiPointerUp,
    LyeActions.stateAdd,
    LyeActions.stateUpdate,
    LyeActions.stateDispose,
  };

  /// The level at which this event is emitted.
  LyeLevel levelFor({
    required LyeCategory category,
    required String action,
    LyeOutcome outcome = LyeOutcome.none,
  }) {
    final override = overrides[action];
    if (override != null) return override;
    if (isAlwaysRecorded(category, action)) return LyeLevel.error;
    if (outcome == LyeOutcome.fail || outcome == LyeOutcome.denied) {
      return LyeLevel.error;
    }
    if (category == LyeCategory.error) return LyeLevel.error;
    if (forensicActions.contains(action)) return LyeLevel.forensic;
    if (category == LyeCategory.db) {
      // A scoped transaction is coarse enough for `verbose`; a single
      // statement is not, unless the consumer marks it as mutating or slow
      // with an explicit override.
      return action == LyeActions.dbStatement
          ? LyeLevel.forensic
          : LyeLevel.verbose;
    }
    if (verboseCategories.contains(category)) return LyeLevel.verbose;
    if (standardCategories.contains(category)) return LyeLevel.standard;
    return LyeLevel.standard;
  }

  /// Whether an event is recorded when [inForce] is the active level.
  /// [inForce] null means logging is switched off, and only the actions of
  /// [isAlwaysRecorded] survive.
  bool isRecorded({
    required LyeCategory category,
    required String action,
    LyeOutcome outcome = LyeOutcome.none,
    LyeLevel? inForce,
    LyeLevel? forced,
  }) {
    if (isAlwaysRecorded(category, action)) return true;
    if (inForce == null) return false;
    final level =
        forced ??
        levelFor(category: category, action: action, outcome: outcome);
    return level.isRecordedAt(inForce);
  }

  /// A copy with extra per-action exceptions.
  LyeLevelPolicy withOverrides(Map<String, LyeLevel> extra) => LyeLevelPolicy(
    standardCategories: standardCategories,
    verboseCategories: verboseCategories,
    overrides: <String, LyeLevel>{...overrides, ...extra},
  );
}
