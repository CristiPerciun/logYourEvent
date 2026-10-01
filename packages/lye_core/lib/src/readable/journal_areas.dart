import 'package:meta/meta.dart';

import '../model/enums.dart';
import 'readable_journal.dart';

/// One area of a product and how to recognise its events (0.3.0).
///
/// An event belongs to the area when its endpoint is one of [endpoints]
/// (`license` for `license.setAutoRenew`), its action starts with one of
/// [actions] (`invitation.` for `invitation.created`) or the page it happened
/// on starts with one of [routes] (`/billing`).
@immutable
class LyeAreaRule {
  const LyeAreaRule(
    this.area, {
    this.endpoints = const <String>[],
    this.actions = const <String>[],
    this.routes = const <String>[],
  });

  final String area;
  final List<String> endpoints;
  final List<String> actions;
  final List<String> routes;
}

/// The first column of a journal for people: in which part of the product a
/// step happened (0.3.0).
///
/// What a person did is easier to follow by area — the licence, the
/// invoices, the documents — than by technical family. The areas are the
/// consumer's; the library only decides the order of the questions, from
/// the most precise to the least:
/// 1. the endpoint of a call — a call made from the invoices page to the
///    licence endpoint is about the licence;
/// 2. the action — `auth.login` is access wherever it happened;
/// 3. the page — a tap belongs to the page it was made on.
///
/// Within each question the rules are tried in order, so a narrower route
/// (`/settings/license`) goes before a wider one (`/settings`).
@immutable
class LyeJournalAreas {
  const LyeJournalAreas(this.rules, {required this.fallback});

  final List<LyeAreaRule> rules;

  /// The area of a step no rule recognises.
  final String fallback;

  String of(LyeJournalStep step) {
    final endpoint = endpointOf(step);
    if (endpoint != null) {
      for (final rule in rules) {
        if (rule.endpoints.contains(endpoint)) return rule.area;
      }
    }
    final action = step.event.action;
    for (final rule in rules) {
      for (final prefix in rule.actions) {
        if (action.startsWith(prefix)) return rule.area;
      }
    }
    final route = pageOf(step);
    if (route != null) {
      for (final rule in rules) {
        for (final prefix in rule.routes) {
          if (_routeStartsWith(route, prefix)) return rule.area;
        }
      }
    }
    return fallback;
  }

  /// The endpoint a step is about: the `endpoint` attribute of a call, or
  /// the first segment of an `rpc.<endpoint>.<method>` operation — which is
  /// also how the server names the call behind an audit event.
  static String? endpointOf(LyeJournalStep step) {
    final attr = step.attrs['endpoint'];
    if (attr is String && attr.isNotEmpty) return attr;
    final operation = step.event.operation;
    if (operation.startsWith('rpc.')) {
      final rest = operation.substring(4);
      final dot = rest.indexOf('.');
      return dot <= 0 ? null : rest.substring(0, dot);
    }
    return null;
  }

  /// The page a step happened on: the route of a console event. On the
  /// server the route column holds `endpoint.method`, which is not a page.
  static String? pageOf(LyeJournalStep step) {
    final e = step.event;
    if (e.origin != LyeOrigin.client) return null;
    return e.route.startsWith('/') ? e.route : null;
  }

  /// `/settings` covers `/settings` and `/settings/license`, not
  /// `/settingsx`.
  static bool _routeStartsWith(String route, String prefix) {
    if (!route.startsWith(prefix)) return false;
    if (route.length == prefix.length || prefix.endsWith('/')) return true;
    return route[prefix.length] == '/';
  }
}
