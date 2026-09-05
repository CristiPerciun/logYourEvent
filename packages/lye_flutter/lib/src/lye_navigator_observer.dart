import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:lye_core/lye_core.dart';

/// Records navigation as `nav.*` events and keeps the recorder's current
/// route up to date, so every later event carries the screen it happened on.
///
/// Register it in `GoRouter(observers: [...])` or
/// `MaterialApp(navigatorObservers: [...])`. The route name is
/// `RouteSettings.name` (go_router fills it with the path pattern), or the
/// route's type when unnamed; path parameters are identifiers, never text.
class LyeNavigatorObserver extends NavigatorObserver {
  LyeNavigatorObserver(this.recorder, {this.updateContextRoute = true});

  final LyeRecorder recorder;

  /// Whether to write the current route into `recorder.context`.
  final bool updateContextRoute;

  static String nameOf(Route<dynamic>? route) {
    if (route == null) return '';
    final name = route.settings.name;
    if (name != null && name.isNotEmpty) return name;
    return route.runtimeType.toString();
  }

  static String _kindOf(Route<dynamic> route) {
    if (route is PageRoute) return 'page';
    if (route is PopupRoute) return 'popup';
    return 'other';
  }

  void _record(
    String action,
    Route<dynamic> route,
    Route<dynamic>? previous, {
    String? current,
  }) {
    final target = current ?? nameOf(route);
    if (updateContextRoute) {
      recorder.context.update(route: target);
    }
    unawaited(
      recorder.record(
        LyeDraft(
          category: LyeCategory.navigation,
          action: action,
          outcome: LyeOutcome.ok,
          route: target,
          attrs: <String, Object?>{
            'kind': _kindOf(route),
            'route': nameOf(route),
            if (previous != null) 'previous': nameOf(previous),
          },
        ),
      ),
    );
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record(LyeActions.navPush, route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // After a pop the user is back on the previous route.
    _record(
      LyeActions.navPop,
      route,
      previousRoute,
      current: nameOf(previousRoute),
    );
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null) return;
    _record(LyeActions.navReplace, newRoute, oldRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _record(
      LyeActions.navRemove,
      route,
      previousRoute,
      current: nameOf(previousRoute),
    );
  }
}
