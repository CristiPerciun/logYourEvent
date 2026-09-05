/// Log Your Event (LYE) — Flutter adapters.
///
/// Observers and hooks that turn what the console does into drafts for a
/// `LyeRecorder`: navigation, Riverpod state transitions, taps on tagged
/// widgets, unhandled errors, lifecycle changes, plus the HTTP shipper that
/// moves batches to the server. No widget here keeps state of its own:
/// everything flows into the recorder, in line with the Riverpod-only rule
/// of the console.
library;

export 'src/http_batch_shipper.dart';
export 'src/lye_error_hooks.dart';
export 'src/lye_flutter_platform.dart';
export 'src/lye_lifecycle_observer.dart';
export 'src/lye_navigator_observer.dart';
export 'src/lye_pointer_tracker.dart';
export 'src/lye_provider_observer.dart';
export 'src/lye_trackable.dart';
