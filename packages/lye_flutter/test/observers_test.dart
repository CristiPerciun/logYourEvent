import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lye_core/lye_core.dart';
import 'package:lye_flutter/lye_flutter.dart';

import 'support.dart';

final counterProvider = NotifierProvider<CounterNotifier, int>(
  CounterNotifier.new,
  name: 'counterProvider',
);

class CounterNotifier extends Notifier<int> {
  @override
  int build() => 0;

  void increment() => state++;
}

final failingProvider = Provider<int>(
  (Ref ref) => throw StateError('boom for ion@example.md'),
  name: 'failingProvider',
);

void main() {
  group('LyeNavigatorObserver', () {
    testWidgets(
      'records push and pop with route names and updates the context',
      (WidgetTester tester) async {
        final recorder = testRecorder();
        final observer = LyeNavigatorObserver(recorder);
        final navigatorKey = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            navigatorObservers: <NavigatorObserver>[observer],
            initialRoute: '/dashboard',
            routes: <String, WidgetBuilder>{
              '/dashboard': (_) => const Scaffold(body: Text('dashboard')),
              '/ropa': (_) => const Scaffold(body: Text('ropa')),
            },
          ),
        );
        unawaited(navigatorKey.currentState!.pushNamed('/ropa'));
        await tester.pumpAndSettle();
        expect(recorder.context.snapshot.route, '/ropa');
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(recorder.context.snapshot.route, '/dashboard');

        final events = await allEvents(recorder);
        expect(events.map((LyeEvent e) => '${e.action}:${e.route}'), <String>[
          'nav.push:/dashboard',
          'nav.push:/ropa',
          'nav.pop:/dashboard',
        ]);
        expect(events[1].attrs, contains('"previous":"/dashboard"'));
        expect(
          events.every((LyeEvent e) => e.category == LyeCategory.navigation),
          isTrue,
        );
      },
    );
  });

  group('LyeProviderObserver', () {
    testWidgets('records adds, updates and failures without values', (
      WidgetTester tester,
    ) async {
      final recorder = testRecorder();
      final observer = LyeProviderObserver(
        recorder,
        include: (String name) => !name.startsWith('_'),
      );
      await tester.pumpWidget(
        ProviderScope(
          observers: <ProviderObserver>[observer],
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              final count = ref.watch(counterProvider);
              return MaterialApp(
                home: Scaffold(
                  body: Column(
                    children: <Widget>[
                      Text('count $count'),
                      TextButton(
                        onPressed: () =>
                            ref.read(counterProvider.notifier).increment(),
                        child: const Text('inc'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      );
      await tester.tap(find.text('inc'));
      await tester.pump();

      final container = ProviderScope.containerOf(
        tester.element(find.byType(Consumer)),
      );
      // Riverpod 3 wraps the failure in a ProviderException; the observer
      // still receives the original error.
      expect(() => container.read(failingProvider), throwsA(anything));
      await tester.pump();

      final events = await allEvents(recorder);
      final byAction = <String, List<LyeEvent>>{};
      for (final e in events) {
        byAction.putIfAbsent(e.action, () => <LyeEvent>[]).add(e);
      }
      expect(
        byAction[LyeActions.stateAdd]!.map((LyeEvent e) => e.component),
        contains('counterProvider'),
      );
      final update = byAction[LyeActions.stateUpdate]!.firstWhere(
        (LyeEvent e) => e.component == 'counterProvider',
      );
      expect(update.attrs, '{"from":"value","to":"value","type":"int"}');
      final failure = byAction[LyeActions.stateFail]!.single;
      expect(failure.component, 'failingProvider');
      expect(failure.errorClass, anyOf('StateError', 'ProviderException'));
      expect(failure.canonical, isNot(contains('example.md')));
      for (final e in events) {
        expect(
          e.attrs,
          isNot(contains('count')),
          reason: 'values never enter the trace',
        );
      }
    });
  });

  group('LyePointerTracker', () {
    testWidgets(
      'attributes taps to the innermost LyeTrackable and records intents',
      (WidgetTester tester) async {
        final recorder = testRecorder();
        final tracker = LyePointerTracker(recorder)..install();
        addTearDown(tracker.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  LyeTrackable(
                    'ropa.toolbar',
                    child: Row(
                      children: <Widget>[
                        LyeTrackable(
                          'ropa.save_button',
                          intent: 'ropa.entry.save',
                          child: ElevatedButton(
                            onPressed: () {},
                            child: const Text('Salvează'),
                          ),
                        ),
                        ElevatedButton(
                          onPressed: () {},
                          child: const Text('Anulează'),
                        ),
                      ],
                    ),
                  ),
                  ElevatedButton(
                    onPressed: () {},
                    child: const Text('untagged'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.tap(find.text('Salvează'));
        await tester.tap(find.text('Anulează'));
        await tester.tap(find.text('untagged'));
        await tester.pump();

        final events = await allEvents(recorder);
        expect(
          events.length,
          2,
          reason: 'untagged taps are not recorded by default',
        );
        expect(events[0].action, LyeActions.uiIntent);
        expect(events[0].component, 'ropa.save_button');
        expect(events[0].operation, 'ropa.entry.save');
        expect(events[1].action, LyeActions.uiTap);
        expect(
          events[1].component,
          'ropa.toolbar',
          reason: 'falls back to the enclosing tag',
        );
        expect(events[0].attrs, contains('"kind":"touch"'));
        for (final e in events) {
          expect(
            e.canonical,
            isNot(contains('Salvează')),
            reason: 'screen text never enters the trace',
          );
        }
      },
    );

    testWidgets('can record untagged taps and raw pointer events when asked', (
      WidgetTester tester,
    ) async {
      final recorder = testRecorder();
      final tracker = LyePointerTracker(
        recorder,
        recordUntagged: true,
        recordRawPointer: true,
      )..install();
      addTearDown(tracker.dispose);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('hello'))),
        ),
      );
      await tester.tap(find.text('hello'));
      await tester.pump();
      final events = await allEvents(recorder);
      expect(events.map((LyeEvent e) => e.action), <String>[
        LyeActions.uiPointerDown,
        LyeActions.uiPointerUp,
        LyeActions.uiTap,
      ]);
      expect(events.last.component, '');
    });
  });

  group('LyeErrorHooks', () {
    testWidgets('records framework errors and chains to the previous handler', (
      WidgetTester tester,
    ) async {
      final recorder = testRecorder();
      var previousCalled = 0;
      final original = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) => previousCalled++;
      final hooks = LyeErrorHooks.install(recorder, platformDispatcher: false);
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: ArgumentError('bad value for ion@example.md'),
          library: 'lye test',
        ),
      );
      hooks.uninstall();
      FlutterError.onError = original;

      expect(previousCalled, 1);
      final events = await allEvents(recorder);
      expect(events.single.action, LyeActions.errorUnhandled);
      expect(events.single.errorClass, 'ArgumentError');
      expect(events.single.attrs, contains('"library":"lye test"'));
      expect(events.single.canonical, isNot(contains('example.md')));
    });
  });

  group('LyeLifecycleObserver', () {
    testWidgets('records lifecycle and locale changes', (
      WidgetTester tester,
    ) async {
      final recorder = testRecorder();
      final observer = LyeLifecycleObserver(recorder)..install();
      addTearDown(observer.dispose);
      await tester.pumpWidget(const SizedBox());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      observer.didChangeLocales(const <Locale>[
        Locale('ro', 'MD'),
        Locale('ru'),
      ]);
      final events = await allEvents(recorder);
      expect(events.map((LyeEvent e) => e.action), <String>[
        LyeActions.appPause,
        LyeActions.appResume,
        LyeActions.appLocaleChange,
      ]);
      expect(events.last.attrs, '{"languages":["ro","ru"]}');
    });
  });

  test('LyeFlutterPlatform maps the target platform', () {
    expect(LyeFlutterPlatform.current, isA<LyePlatform>());
  });
}
