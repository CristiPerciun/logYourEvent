import 'package:flutter/widgets.dart';

/// Marker carried by [LyeTrackable] and read back from the hit-test path.
@immutable
class LyeTag {
  const LyeTag(this.id, {this.intent});

  /// Stable identifier of the control (`ropa.save_button`). Never a label
  /// with user content.
  final String id;

  /// Optional user intent recorded as `ui.intent` on tap (`ropa.entry.save`).
  final String? intent;

  @override
  bool operator ==(Object other) =>
      other is LyeTag && other.id == id && other.intent == intent;

  @override
  int get hashCode => Object.hash(id, intent);

  @override
  String toString() => 'LyeTag($id)';
}

/// Tags a subtree so taps on it are attributed to a stable identifier.
///
/// The pointer tracker looks for the innermost [LyeTag] on the hit-test path
/// of every tap. Untagged widgets are recorded without a component (or not
/// at all, depending on the tracker configuration): explicit tagging is what
/// keeps the trace meaningful and free of screen text.
class LyeTrackable extends StatelessWidget {
  const LyeTrackable(this.id, {super.key, this.intent, required this.child});

  final String id;
  final String? intent;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MetaData(
      metaData: LyeTag(id, intent: intent),
      behavior: HitTestBehavior.deferToChild,
      child: child,
    );
  }
}
