import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container/weapp_container.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';

class FakePlatform extends WeappContainerPlatform {
  final source = StreamController<Map<String, Object?>>.broadcast(sync: true);
  final requests = <(String, Map<String, Object?>)>[];
  int nextId = 0;
  bool failClose = false;
  Completer<void>? detach;
  bool initialized = false;
  bool cancelChrome = false;
  Map<String, Object?> currentState = {
    'sessionId': 'session',
    'page': {'id': 2}
  };
  @override
  Stream<Map<String, Object?>> get events => source.stream;
  @override
  Future<void> initialize() async {
    initialized = true;
  }

  @override
  Future<T?> invoke<T>(String method, Map<String, Object?> args) async {
    if (!initialized) throw StateError("Transport used before initialization");
    requests.add((method, args));
    if (method == 'hostChrome' && cancelChrome)
      throw PlatformException(
          code: 'ERR_CANCELLED', message: 'stale page geometry');
    if (method == 'state') return currentState as T;
    if (method == 'create') return {'id': ++nextId} as T;
    if (method == 'inspectPackChrome') {
      return {'schemaVersion': 1, 'navigationStyle': 'custom', 'title': '测试'}
          as T;
    }
    if (method == 'prepareHostChrome') {
      final value = Map<String, Object?>.from(args)
        ..remove('id')
        ..remove('coordinateSpace');
      return value as T;
    }
    if (method == 'prepareView')
      return {
        'pack': {
          'devReload': {'protocolVersion': '1.0'}
        }
      } as T;
    if (method == 'applyDevPack')
      return {
        'reloadKind': 'inPlace',
        'state': {'sessionId': 'same'}
      } as T;
    if (method == 'devState')
      return {
        'state': {'sessionId': 'same'},
        'pages': [
          {
            'data': {'count': 9}
          }
        ]
      } as T;
    if (method == 'attach') return {'textureId': 7} as T;
    if (method == 'detach') await detach?.future;
    if (method == 'close' && failClose)
      throw PlatformException(
          code: 'ERR_RENDER', message: 'Retirement requires retry');
    return null;
  }

  void emit(int id, Map<String, Object?> event) =>
      source.add({'id': id, 'event': event});
}

void main() {
  late FakePlatform platform;
  setUp(() {
    platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
  });
  tearDown(() async {
    await platform.source.close();
  });
  test('measured-view preflight keeps host registration before guest startup',
      () async {
    final controller = await WeappContainerController.create(storageKey: null);
    final capabilities = await controller.prepareView();
    expect(
        (capabilities['pack'] as Map)['devReload'], {'protocolVersion': '1.0'});
    expect(platform.requests.last.$1, 'prepareView');
    expect(platform.requests.last.$2, {'id': controller.id});
    expect(platform.requests.where((item) => item.$1 == 'load'), isEmpty);
    await controller.registerHostMethod('host.beforeLoad', (_) => null);
    expect(platform.requests.last.$1, 'registerHostMethod');
    await controller.close();
  });
  test(
      'chrome preflight, measured geometry and tabs use explicit native commands',
      () async {
    final controller =
        await WeappContainerController.create(storageKey: 'retained');
    final chrome = await controller.inspectPackChrome('/verified/pack',
        route: 'pages/custom/index');
    expect(chrome['navigationStyle'], 'custom');
    expect(
        platform.requests.where((r) => r.$1 == 'load' || r.$1 == 'prepareView'),
        isEmpty);
    const geometry = <String, Object?>{
      'schemaVersion': 1,
      'revision': 4,
      'contentRect': {'left': 0, 'top': 92, 'width': 390, 'height': 700},
      'menuButtonRect': {
        'left': 294,
        'right': 382,
        'top': 52,
        'bottom': 84,
        'width': 88,
        'height': 32
      },
    };
    final prospective = await controller.prepareHostChrome(geometry);
    expect(prospective, geometry);
    expect(platform.requests.where((r) => r.$1 == 'hostChrome'), isEmpty);
    await controller.applyDevPack('/verified/restart',
        initialHostChrome: prospective);
    expect(platform.requests.last.$2['initialHostChrome'], geometry);
    await controller.updateHostChrome(geometry);
    expect(platform.requests.last.$1, 'hostChrome');
    expect(platform.requests.last.$2,
        {'id': controller.id, ...geometry, 'coordinateSpace': 'flutterClient'});
    await controller.setPreviewOccluded(true);
    await controller.setPreviewOccluded(false);
    expect(platform.requests.where((r) => r.$1 == 'setForeground'), isEmpty);
    await controller.switchTab('pages/settings/index');
    expect(platform.requests.last.$1, 'switchTab');
    expect(platform.requests.last.$2,
        {'id': controller.id, 'route': 'pages/settings/index'});
    await controller.close();
  });

  testWidgets(
      'covering developer UI keeps app foreground and blocks Flutter input',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final creating = WeappContainerController.create(storageKey: null);
    await tester.pump();
    final controller = await creating;
    Widget view(bool occluded) => Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
            width: 390,
            height: 700,
            child: WeappContainerView(
                controller: controller, occluded: occluded)));
    await tester.pumpWidget(view(false));
    await tester.pump();
    await tester.pump();
    final before = platform.requests.length;
    await tester.pumpWidget(view(true));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byType(WeappContainerView));
    await tester.pump();
    final covered = platform.requests.skip(before).toList();
    expect(
        covered
            .where((r) => r.$1 == 'setPreviewOccluded')
            .single
            .$2['occluded'],
        true);
    expect(covered.where((r) => r.$1 == 'input' || r.$1 == 'setForeground'),
        isEmpty);
    await tester.pumpWidget(view(false));
    await tester.pump();
    await tester.pump();
    expect(
        platform.requests
            .where((r) => r.$1 == 'setPreviewOccluded')
            .last
            .$2['occluded'],
        false);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(controller.close);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('late page geometry cancellation does not fault the new page',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final creating = WeappContainerController.create(storageKey: null);
    await tester.pump();
    final controller = await creating;
    platform.cancelChrome = true;
    final failures = <Object>[];
    const geometry = <String, Object?>{
      'schemaVersion': 1,
      'revision': 1,
      'sessionId': 'session',
      'pageId': 1,
      'contentRect': {'left': 0, 'top': 44, 'width': 390, 'height': 700},
      'menuButtonRect': {
        'left': 294,
        'right': 382,
        'top': 6,
        'bottom': 38,
        'width': 88,
        'height': 32
      }
    };
    await tester.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
            width: 390,
            height: 700,
            child: WeappContainerView(
                controller: controller,
                hostChrome: geometry,
                onError: (error, _) => failures.add(error)))));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(platform.requests.where((r) => r.$1 == 'state'), isNotEmpty);
    expect(failures, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(controller.close);
    debugDefaultTargetPlatformOverride = null;
  });
  for (final target in [TargetPlatform.windows, TargetPlatform.linux]) {
    testWidgets(
        '$target host label changes preserve guest geometry and surface',
        (tester) async {
      debugDefaultTargetPlatformOverride = target;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final creating = WeappContainerController.create(storageKey: null);
      await tester.pump();
      final controller = await creating;
      const geometry = <String, Object?>{
        'schemaVersion': 1,
        'revision': 4,
      };
      final labels = <String, Object?>{
        'more': 'More',
        'close': 'Close mini-program',
        'back': 'Back',
        'navigation': 'Mini-program navigation',
        'tabs': 'Mini-program tabs',
      };
      final native = <String, Object?>{
        'schemaVersion': 1,
        'revision': 4,
        'accessibilityLabels': labels,
        'chrome': {
          'title': 'Guest title',
          'tabBar': {
            'list': [
              {'text': 'Guest tab'}
            ]
          }
        },
      };
      Widget view() => Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
              width: 390,
              height: 700,
              child: WeappContainerView(
                  controller: controller,
                  hostChrome: geometry,
                  nativeChrome: native)));
      await tester.pumpWidget(view());
      await tester.pump();
      await tester.pump();
      expect(platform.requests.where((r) => r.$1 == 'attach'), hasLength(1));
      expect(
          platform.requests.where((r) => r.$1 == 'hostChrome'), hasLength(1));
      expect(
          platform.requests.where((r) => r.$1 == 'nativeChrome'), hasLength(1));
      final accepted =
          platform.requests.lastWhere((r) => r.$1 == 'nativeChrome');
      final before = platform.requests.length;
      // Deliberately mutate the same map: the SDK captures descriptor values,
      // not caller map identity or geometry revision alone.
      labels.addAll({
        'more': '更多',
        'close': '关闭小程序',
        'back': '返回',
        'navigation': '小程序导航',
        'tabs': '小程序标签栏',
      });
      await tester.pumpWidget(view());
      await tester.pump();
      await tester.pump();
      final updates = platform.requests.skip(before).toList();
      expect(updates.map((r) => r.$1), ['nativeChrome']);
      expect(updates.single.$2['revision'], 4);
      expect(updates.single.$2['accessibilityLabels'], labels);
      expect((accepted.$2['accessibilityLabels'] as Map)['more'], 'More',
          reason: 'A queued descriptor must not borrow caller-owned maps');
      expect(updates.single.$2['chrome'], native['chrome']);
      final unchanged = platform.requests.length;
      await tester.pumpWidget(view());
      await tester.pump();
      expect(platform.requests.length, unchanged);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(controller.close);
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
    });
  }
  test(
      'GPU opt-in reaches the native owner and development updates preserve result identity',
      () async {
    final controller = await WeappContainerController.create(
        storageKey: 'project:one', gpuRequired: true, devDiagnostics: true);
    expect(platform.requests.last.$1, 'create');
    expect(platform.requests.last.$2, {
      'storageKey': 'project:one',
      'gpuRequired': true,
      'devDiagnostics': true
    });
    final result = await controller.applyDevPack('/verified/generation/2',
        route: 'pages/home/index');
    expect(result['reloadKind'], 'inPlace');
    expect((result['state'] as Map)['sessionId'], 'same');
    expect(platform.requests.last.$1, 'applyDevPack');
    expect(platform.requests.last.$2, {
      'id': controller.id,
      'packPath': '/verified/generation/2',
      'route': 'pages/home/index',
      'options': <String, Object?>{}
    });
    await expectLater(
        controller.registerHostMethod('late', (_) => null), throwsStateError);
    final inspected = await controller.devState();
    expect(((inspected['pages'] as List).single as Map)['data'], {'count': 9});
    await controller.clearDevStorage();
    expect(platform.requests.last.$1, 'clearDevStorage');
    expect(platform.requests.last.$2, {'id': controller.id});
    await controller.close();
  });

  test('cancellation wins while asynchronous host work is pending', () async {
    final controller = await WeappContainerController.create(storageKey: null);
    final response = Completer<Object?>();
    late WeappHostCall received;
    await controller.registerHostMethod('host.wait', (call) {
      received = call;
      return response.future;
    });
    platform.emit(controller.id, {
      'type': 'hostCall',
      'callId': 'g1-1',
      'method': 'host.wait',
      'payload': '中文 🧊'
    });
    expect(received.payload, '中文 🧊');
    platform
        .emit(controller.id, {'type': 'hostCallCancelled', 'callId': 'g1-1'});
    await received.cancellation.whenCancelled;
    response.complete('late');
    await Future<void>.delayed(Duration.zero);
    expect(platform.requests.where((item) => item.$1 == 'completeHostCall'),
        isEmpty);
    await controller.close();
  });
  test('async host result preserves JSON null and completes once', () async {
    final controller =
        await WeappContainerController.create(storageKey: 'account:catalog');
    await controller.registerHostMethod('host.null', (_) async => null);
    platform.emit(controller.id + 1,
        {'type': 'hostCall', 'callId': 'other', 'method': 'host.null'});
    platform.emit(controller.id,
        {'type': 'hostCall', 'callId': 'mine', 'method': 'host.null'});
    await Future<void>.delayed(Duration.zero);
    final replies = platform.requests
        .where((item) => item.$1 == 'completeHostCall')
        .toList();
    expect(replies, hasLength(1));
    expect(replies.single.$2,
        {'id': controller.id, 'callId': 'mine', 'result': null});
    await controller.close();
  });
  test('failed native retirement can be explicitly retried', () async {
    final controller = await WeappContainerController.create(storageKey: null);
    platform.failClose = true;
    await expectLater(controller.close(), throwsA(isA<PlatformException>()));
    expect(controller.isClosed, false);
    platform.failClose = false;
    await controller.close();
    await controller.close();
    expect(controller.isClosed, true);
    expect(platform.requests.where((item) => item.$1 == 'close'), hasLength(2));
  });
  test('reattachment waits until previous texture ownership retires', () async {
    final controller = await WeappContainerController.create(storageKey: null);
    final first = Object();
    final second = Object();
    await controller.claimView(first);
    expect(() => controller.claimView(second), throwsStateError);
    final retirement = Completer<void>();
    controller.releaseView(first, retirement.future);
    var ready = false;
    final wait = controller.claimView(second).then((_) {
      ready = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(ready, false);
    retirement.complete();
    await wait;
    expect(ready, true);
    controller.releaseView(second, Future.value());
    await controller.close();
  });
  testWidgets(
      'public widget rapid remount waits for native detach acknowledgment',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    final creating = WeappContainerController.create(storageKey: null);
    await tester.pump();
    final controller = await creating;
    Widget mounted() => Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
            width: 400,
            height: 500,
            child: WeappContainerView(controller: controller)));
    await tester.pumpWidget(mounted());
    await tester.pump();
    await tester.pump();
    expect(platform.requests.where((r) => r.$1 == 'attach'), hasLength(1));
    platform.detach = Completer<void>();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(mounted());
    await tester.pump();
    expect(platform.requests.where((r) => r.$1 == 'attach'), hasLength(1));
    platform.detach!.complete();
    await tester.pump();
    await tester.pump();
    expect(platform.requests.where((r) => r.$1 == 'attach'), hasLength(2));
    await tester.runAsync(() => controller.close());
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
  testWidgets('desktop input is owned by the deepest embedded view',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    final creating = WeappContainerController.create(storageKey: null);
    await tester.pump();
    final controller = await creating;
    final scrolling = ScrollController();
    addTearDown(scrolling.dispose);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 500,
            child: SingleChildScrollView(
                controller: scrolling,
                child: Column(
                  children: [
                    const SizedBox(height: 80),
                    SizedBox(
                        key: const ValueKey('embedded'),
                        width: 300,
                        height: 300,
                        child: WeappContainerView(controller: controller)),
                    const SizedBox(height: 1000),
                  ],
                )),
          )),
    ));
    await tester.pump();
    await tester.pump();
    final inside = tester.getCenter(find.byKey(const ValueKey('embedded')));
    await tester.sendEventToBinding(
        PointerScrollEvent(position: inside, scrollDelta: const Offset(0, 60)));
    await tester.pump();
    expect(scrolling.offset, 0,
        reason: 'One wheel must not scroll both SDK and parent');
    final inputs = platform.requests.where((r) => r.$1 == 'input').toList();
    expect(inputs, hasLength(1));
    expect((inputs.single.$2['events'] as List).single['type'], 'wheel');
    await tester.dragFrom(inside, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(scrolling.offset, 0,
        reason: 'A contact starting inside the SDK belongs to it');
    List<Object?> sent(String type) => platform.requests
        .where((r) => r.$1 == 'input')
        .expand((r) => r.$2['events'] as List)
        .where((event) => event['type'] == type)
        .toList();
    expect(sent('tap'), isEmpty, reason: 'Dragging must not activate a tap');
    await tester.tapAt(inside);
    await tester.pump();
    expect(sent('tap'), hasLength(1));
    final cancelled = await tester.startGesture(inside, pointer: 10);
    await cancelled.cancel();
    await tester.pump();
    expect(sent('touchcancel'), hasLength(1));
    expect(sent('tap'), hasLength(1),
        reason: 'Cancellation must not activate a tap');
    final first = await tester.startGesture(inside, pointer: 11);
    final second =
        await tester.startGesture(inside + const Offset(10, 0), pointer: 12);
    await second.up();
    await first.up();
    await tester.pump();
    expect(sent('tap'), hasLength(1),
        reason: 'Multiple contacts must not activate a tap');
    await tester.sendEventToBinding(const PointerScrollEvent(
        position: Offset(20, 40), scrollDelta: Offset(0, 60)));
    await tester.pump();
    expect(scrolling.offset, 60,
        reason: 'The host still owns input outside the SDK');
    await tester.runAsync(() => controller.close());
    final sentBeforeClose =
        platform.requests.where((r) => r.$1 == 'input').length;
    await tester.dragFrom(inside, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(scrolling.offset, greaterThan(60),
        reason: 'A closed view must not capture host gestures');
    expect(platform.requests.where((r) => r.$1 == 'input'),
        hasLength(sentBeforeClose));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
