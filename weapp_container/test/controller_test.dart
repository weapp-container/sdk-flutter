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
  bool identitySwitching = false;
  Completer<void>? detach;
  bool initialized = false;
  bool cancelChrome = false;
  bool cancelLayout = false;
  Completer<void>? layoutGate;
  Completer<void>? stateGate;
  Completer<void>? closeGate;
  Object? stateFailure;
  Map<String, Object?> currentState = {
    'sessionId': 'session',
    'page': {'id': 2},
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
    if (method == 'hostApiResource') {
      if (identitySwitching)
        throw PlatformException(code: 'ERR_IDENTITY_SWITCHING');
      return {
        'bytes': [0, 128, 255],
        'totalBytes': 1048579
      } as T;
    }
    if (method == 'hostChrome' && cancelChrome)
      throw PlatformException(
        code: 'ERR_CANCELLED',
        message: 'stale page geometry',
      );
    if (method == 'hostLayout') {
      await layoutGate?.future;
      if (cancelLayout) {
        throw PlatformException(
          code: 'ERR_CANCELLED',
          message: 'fixture native observation superseded',
        );
      }
    }
    if (method == 'state') {
      await stateGate?.future;
      if (stateFailure != null) throw stateFailure!;
      return currentState as T;
    }
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
    if (method == 'prepareHostLayout') {
      final observation = args['observation'] as Map;
      return {
        'schemaVersion': 1,
        'ownerId': observation['ownerId'],
        'surfaceGeneration': observation['surfaceGeneration'],
        'observationId': observation['observationId'],
        'layoutRevision': args['layoutRevision'],
        'windowMetrics': observation['windowMetrics'],
        'chrome': args['chrome'],
      } as T;
    }
    if (method == 'command') {
      final payload = args['payload'] as Map;
      final operation = args['operation'];
      return {
        'schemaVersion': 1,
        'ownerId': payload['ownerId'] ?? '9007199254740993',
        'attemptId': payload['attemptId'] ?? '18446744073709551614',
        'status': operation == 'beginDevPackAttempt' ? 'prepared' : 'accepted',
        'acceptedPackIdentity': {
          'root': 'verified-root',
          'acceptedPackRevision': '9007199254740994',
          'sessionId': 'native',
        },
      } as T;
    }
    if (method == 'prepareView')
      return {
        'pack': {
          'devReload': {'protocolVersion': '1.0'},
        },
      } as T;
    if (method == 'applyDevPack')
      return {
        'reloadKind': 'inPlace',
        'state': {'sessionId': 'same'},
      } as T;
    if (method == 'devState')
      return {
        'state': {'sessionId': 'same'},
        'pages': [
          {
            'data': {'count': 9},
          },
        ],
      } as T;
    if (method == 'attach') return {'textureId': 7} as T;
    if (method == 'detach') await detach?.future;
    if (method == 'close') await closeGate?.future;
    if (method == 'close' && failClose)
      throw PlatformException(
        code: 'ERR_RENDER',
        message: 'Retirement requires retry',
      );
    return null;
  }

  void emit(int id, Map<String, Object?> event) =>
      source.add({'id': id, 'event': event});
}

Map<String, Object?> atomicObservation({
  String owner = '7',
  String surface = '5',
  String sequence = '10',
}) =>
    {
      'schemaVersion': 1,
      'ownerId': owner,
      'surfaceGeneration': surface,
      'observationId': sequence,
      'sessionId': 'same-session',
      'pageId': 2,
      'windowMetrics': {'windowWidth': 390, 'windowHeight': 700},
    };

Map<String, Object?> atomicGeometry({int revision = 17}) => {
      'schemaVersion': 1,
      'revision': revision,
      'sessionId': 'same-session',
      'pageId': 2,
      'contentRect': {'left': 0, 'top': 44, 'width': 390, 'height': 700},
      'menuButtonRect': {
        'left': 294,
        'right': 382,
        'top': 6,
        'bottom': 38,
        'width': 88,
        'height': 32,
      },
    };

Map<String, Object?> atomicState({
  String owner = '7',
  String surface = '5',
  String? pending = '11',
  String? accepted,
  String revision = '18',
}) =>
    {
      'schemaVersion': 1,
      'status': 'ready',
      'sessionId': 'same-session',
      'page': {'id': 2},
      'ownerId': owner,
      'hostSurface': {'ownerId': owner, 'surfaceGeneration': surface},
      'executionHealth': {
        'schemaVersion': 1,
        'requiresRestart': false,
        'appServiceFault': null,
        'viewFault': null,
        'navigationFault': null,
      },
      'pendingHostLayout': pending == null
          ? null
          : atomicObservation(
              owner: owner, surface: surface, sequence: pending),
      'acceptedLayout': accepted == null
          ? null
          : {
              ...atomicObservation(
                owner: owner,
                surface: surface,
                sequence: accepted,
              ),
              'layoutRevision': revision,
              'chrome': atomicGeometry(revision: int.tryParse(revision) ?? 17),
            },
    };

Widget atomicView(
  WeappContainerController controller,
  Map<String, Object?> observation,
  Map<String, Object?> geometry,
  List<Object> errors,
  List<int> acknowledgements, {
  bool occluded = false,
  bool prepareOnly = false,
  Map<String, Object?>? nativeChrome,
  bool emitObservation = true,
}) {
  // Real native views publish an observation before Flutter can answer it.
  // Queue tests can explicitly retain a consumed/stale observation instead.
  if (emitObservation) {
    (WeappContainerPlatform.instance as FakePlatform).emit(controller.id, {
      'type': 'hostLayoutObservation',
      'observation': observation,
    });
  }
  return Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox(
      width: 390,
      height: 700,
      child: WeappContainerView(
        controller: controller,
        hostLayoutObservation: observation,
        hostChrome: geometry,
        occluded: occluded,
        prepareOnly: prepareOnly,
        nativeChrome: nativeChrome,
        onError: (error, _) => errors.add(error),
        onHostChromeApplied: acknowledgements.add,
      ),
    ),
  );
}

Future<void> flushChrome(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
  }
}

final atomicOwners = <WeappContainerController>[];

void atomicTestWidgets(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    try {
      await body(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await flushChrome(tester);
      for (final controller in atomicOwners) {
        if (!controller.isClosed) await tester.runAsync(controller.close);
      }
      atomicOwners.clear();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<WeappContainerController> atomicController(WidgetTester tester) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  final creating = WeappContainerController.create(
    storageKey: null,
    atomicHostLayout: true,
  );
  await tester.pump();
  final controller = await creating;
  atomicOwners.add(controller);
  return controller;
}

Future<void> closeAtomic(
  WidgetTester tester,
  WeappContainerController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await flushChrome(tester);
  await tester.runAsync(controller.close);
  expect(tester.takeException(), isNull);
}

void main() {
  test('snapshot transport retains the owner captured before asynchronous work',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final application = <String, Object?>{
      'hostAppId': 'host',
      'tenantId': 'tenant',
      'publisherId': 'publisher',
      'appId': 'app',
      'environment': 'release',
      'version': 'v2',
      'packRoot': 'verified-root'
    };
    final account = <String, Object?>{
      'principalId': 'old-user',
      'epoch': '18446744073709551614'
    };
    platform.currentState = {
      'sessionId': 'old-native-owner',
      'hostServicesState': {'application': application, 'account': account}
    };
    final captured =
        WeappHostSnapshotContext.fromState(await controller.state());
    account['principalId'] = 'new-user';
    account['epoch'] = '18446744073709551615';
    platform.currentState['sessionId'] = 'new-native-owner';
    await controller.updateHostServiceSnapshots({
      'wx.getBatteryInfo': {'level': 50}
    }, context: captured);
    final payload = platform.requests.last.$2;
    expect(payload['context'], {
      'application': application,
      'account': {'principalId': 'old-user', 'epoch': '18446744073709551614'},
      'sessionId': 'old-native-owner'
    });
    expect((payload['context'] as Map).containsKey('callId'), isFalse);
    await controller.updateHostServiceSnapshots({
      'wx.getBatteryInfo': {'level': 60}
    });
    expect(platform.requests.last.$2.containsKey('context'), isFalse);
    await controller.close();
  });
  test(
      'API resource transport preserves native context and revoked-owner errors',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final context = <String, Object?>{
      'application': {
        'hostAppId': 'host',
        'tenantId': 'tenant',
        'publisherId': 'publisher',
        'appId': 'app',
        'environment': 'release',
        'version': 'v2',
        'packRoot': 'verified-root'
      },
      'account': {'principalId': 'user', 'epoch': '18446744073709551615'},
      'sessionId': 'native-incarnation',
      'callId': 'native-call',
      'api': 'object:InnerAudioContext.src',
      'deadlineNs': '18446744073709551614',
      'cancelToken': 'native-cancel',
      'componentTarget': {
        'pageId': '9007199254740993',
        'nodeId': 'audio',
        'ownerScopeId': null
      },
    };
    Map<String, Object?>? observed;
    await controller.registerApiHandler('object:InnerAudioContext.src',
        (call) async {
      observed = await controller.readHostApiResource(call.context!,
          offset: 1048576, length: 3);
      return <String, Object?>{};
    });
    platform.emit(controller.id, {
      'type': 'hostCall',
      'callId': 'transport-call',
      'method': 'object:InnerAudioContext.src',
      'payload': {'value': 'assets/a.bin'},
      'context': context
    });
    await Future<void>.delayed(Duration.zero);
    expect(observed, {
      'bytes': [0, 128, 255],
      'totalBytes': 1048579
    });
    expect(
        platform.requests
            .singleWhere((request) => request.$1 == 'hostApiResource')
            .$2,
        {
          'id': controller.id,
          'context': context,
          'offset': 1048576,
          'length': 3
        });
    platform.emit(controller.id, {
      'type': 'accountSwitch',
      'receipt': {'phase': 'revoking'}
    });
    platform.identitySwitching = true;
    await expectLater(
        controller.readHostApiResource(context, length: 1),
        throwsA(isA<PlatformException>()
            .having((e) => e.code, 'code', 'ERR_IDENTITY_SWITCHING')));
    await controller.close();
  });
  test(
      'account cleanup awaits every resource and ignores superseded completion',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final first = Completer<void>(), second = Completer<void>();
    final cancelled = <String>[];
    controller.registerAccountCleanupHandler((operation, cancellation) async {
      unawaited(
          cancellation.whenCancelled.then((_) => cancelled.add(operation)));
      if (operation == 'first')
        await first.future;
      else
        await second.future;
    });
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'first'});
    await Future<void>.delayed(Duration.zero);
    expect(
        platform.requests.where((entry) =>
            entry.$1 == 'completeAccountCleanup' &&
            entry.$2['retired'] != true),
        isEmpty);
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'second'});
    await Future<void>.delayed(Duration.zero);
    first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(cancelled, contains('first'));
    expect(
        platform.requests.where((entry) =>
            entry.$1 == 'completeAccountCleanup' &&
            entry.$2['retired'] != true),
        isEmpty);
    second.complete();
    await Future<void>.delayed(Duration.zero);
    final replies = platform.requests
        .where((entry) =>
            entry.$1 == 'completeAccountCleanup' && entry.$2['retired'] != true)
        .toList();
    expect(replies, hasLength(1));
    expect(replies.single.$2['operationId'], 'second');
    expect(
        platform.requests
            .where((entry) => entry.$2['retired'] == true)
            .single
            .$2['operationId'],
        'first');
    await controller.close();
    await platform.source.close();
  });
  test(
      'account cleanup failure reports blocked operation after other resources settle',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final resource = Completer<void>();
    final unregister = controller.registerAccountCleanupHandler(
        (_, __) => throw StateError('camera retirement failed'));
    controller.registerAccountCleanupHandler((_, __) => resource.future);
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'cleanup'});
    await Future<void>.delayed(Duration.zero);
    expect(
        platform.requests.where((entry) =>
            entry.$1 == 'completeAccountCleanup' &&
            entry.$2['retired'] != true),
        isEmpty);
    resource.complete();
    await Future<void>.delayed(Duration.zero);
    final reply = platform.requests.singleWhere((entry) =>
        entry.$1 == 'completeAccountCleanup' && entry.$2['retired'] != true);
    expect((reply.$2['error'] as Map)['message'],
        contains('camera retirement failed'));
    unregister();
    await controller.close();
    await platform.source.close();
  });
  test(
      'latest cleanup waits a cancelled old terminal and skips queued stale operations',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final old = Completer<void>(), latest = Completer<void>();
    final started = <String>[];
    controller.registerAccountCleanupHandler((operation, _) {
      started.add(operation);
      return operation == 'old' ? old.future : latest.future;
    });
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'old'});
    await Future<void>.delayed(Duration.zero);
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'skipped'});
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'latest'});
    latest.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, ['old']);
    expect(
        platform.requests.where((entry) =>
            entry.$1 == 'completeAccountCleanup' &&
            entry.$2['retired'] != true),
        isEmpty);
    old.complete();
    await Future<void>.delayed(Duration.zero);
    expect(started, ['old', 'latest']);
    final reply = platform.requests.singleWhere((entry) =>
        entry.$1 == 'completeAccountCleanup' && entry.$2['retired'] != true);
    expect(reply.$2['operationId'], 'latest');
    expect(
        platform.requests
            .where((entry) => entry.$2['retired'] == true)
            .map((entry) => entry.$2['operationId']),
        ['old', 'skipped']);
    await controller.close();
    await platform.source.close();
  });
  test('a failed superseded hook must end before retry and queued close',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final old = Completer<void>();
    final started = <String>[];
    controller.registerAccountCleanupHandler((operation, _) {
      started.add(operation);
      return operation == 'old' ? old.future : Future<void>.value();
    });
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'old'});
    await Future<void>.delayed(Duration.zero);
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'retry'});
    await Future<void>.delayed(Duration.zero);
    expect(started, ['old']);
    old.completeError(StateError('old resource retirement failed'));
    await Future<void>.delayed(Duration.zero);
    expect(started, ['old', 'retry']);
    final reply = platform.requests.singleWhere((entry) =>
        entry.$1 == 'completeAccountCleanup' && entry.$2['retired'] != true);
    expect(reply.$2['operationId'], 'retry');
    expect(reply.$2.containsKey('error'), isFalse);
    final pending = Completer<void>();
    controller.registerAccountCleanupHandler((operation, _) =>
        operation == 'pending' ? pending.future : Future<void>.value());
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'pending'});
    await Future<void>.delayed(Duration.zero);
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'queued'});
    final closing = controller.close();
    await Future<void>.delayed(Duration.zero);
    expect(platform.requests.where((entry) => entry.$1 == 'close'), isEmpty);
    pending.complete();
    await closing;
    expect(started, isNot(contains('queued')));
    await platform.source.close();
  });
  test(
      'native cancellation waits real hook terminals and replies to a request received during close',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final native = Completer<void>();
    late WeappCancellationToken token;
    controller.registerAccountCleanupHandler((operation, cancellation) {
      token = cancellation;
      return operation == 'pending' ? native.future : Future<void>.value();
    });
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'pending'});
    await Future<void>.delayed(Duration.zero);
    platform.emit(controller.id,
        {'type': 'accountCleanupCancelled', 'operationId': 'other'});
    expect(token.isCancelled, isFalse);
    platform.emit(controller.id,
        {'type': 'accountCleanupCancelled', 'operationId': 'pending'});
    expect(token.isCancelled, isTrue);
    final closing = controller.close();
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'late'});
    await Future<void>.delayed(Duration.zero);
    expect(
        platform.requests
            .where((entry) => entry.$1 == 'completeAccountCleanup'),
        isEmpty);
    native.complete();
    await closing;
    await Future<void>.delayed(Duration.zero);
    expect(
        platform.requests
            .where((entry) => entry.$1 == 'completeAccountCleanup')
            .map((entry) => [entry.$2['operationId'], entry.$2['retired']]),
        [
          ['pending', true],
          ['late', true]
        ]);
    await platform.source.close();
  });
  test('close waits for old cleanup then drains resources before native close',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final old = Completer<void>(), retire = Completer<void>();
    final operations = <String>[], tokens = <WeappCancellationToken>[];
    controller.registerAccountCleanupHandler((operation, token) {
      operations.add(operation);
      tokens.add(token);
      return operation == 'switch' ? old.future : retire.future;
    });
    platform.emit(controller.id,
        {'type': 'accountCleanupRequired', 'operationId': 'switch'});
    await Future<void>.delayed(Duration.zero);
    final closing = controller.close();
    await Future<void>.delayed(Duration.zero);
    expect(tokens.single.isCancelled, isTrue);
    expect(operations, ['switch']);
    expect(platform.requests.where((entry) => entry.$1 == 'close'), isEmpty);
    old.complete();
    await Future<void>.delayed(Duration.zero);
    expect(operations, ['switch', 'close:${controller.id}']);
    expect(
        platform.requests.where((entry) =>
            entry.$1 == 'completeAccountCleanup' &&
            entry.$2['retired'] != true),
        isEmpty);
    retire.complete();
    await closing;
    expect(
        platform.requests.where((entry) => entry.$1 == 'close'), hasLength(1));
    await platform.source.close();
  });
  test('failed custom close waits for every resource and remains retryable',
      () async {
    final platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
    final controller = await WeappContainerController.create(storageKey: null);
    final pending = Completer<void>();
    var fail = true;
    controller.registerAccountCleanupHandler((_, __) {
      if (fail) throw StateError('device busy');
    });
    controller.registerAccountCleanupHandler((_, __) => pending.future);
    final closing = controller.close();
    var settled = false;
    unawaited(closing.then((_) {
      settled = true;
    }, onError: (Object _) {
      settled = true;
    }));
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    pending.complete();
    await expectLater(closing, throwsStateError);
    expect(platform.requests.where((entry) => entry.$1 == 'close'), isEmpty);
    await expectLater(controller.state(), throwsStateError);
    fail = false;
    await controller.close();
    expect(controller.isClosed, isTrue);
    await platform.source.close();
  });

  late FakePlatform platform;
  setUp(() {
    platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
  });
  tearDown(() async {
    await platform.source.close();
  });
  test(
      'native device install requires explicit Wi-Fi options and forwards Linux identity',
      () async {
    final controller = await WeappContainerController.create(storageKey: null);
    await controller.installNativeDeviceApis();
    final defaults = platform.requests.last.$2;
    expect(defaults['enableWifi'], isFalse);
    expect(defaults.containsKey('wifiConfiguration'), isFalse);
    expect(defaults.containsKey('nfcConfiguration'), isFalse);
    expect(defaults['linuxDesktopId'], '');
    expect(defaults['linuxBluetoothExclusive'], isFalse);
    await controller.installNativeDeviceApis(
        bluetooth: false,
        nfc: true,
        enableWifi: true,
        linuxDesktopId: 'dev.example.Host',
        linuxBluetoothExclusive: true,
        nfcConfiguration: const WeappNfcConfiguration(isoDep: true, nfcV: true),
        wifiConfiguration: const WeappWifiConfiguration(
            connectToNetworks: true, readCurrentNetwork: false));
    final explicit = platform.requests.last.$2;
    expect(explicit['bluetooth'], isFalse);
    expect(explicit['nfc'], isTrue);
    expect(explicit['enableWifi'], isTrue);
    expect(explicit['linuxDesktopId'], 'dev.example.Host');
    expect(explicit['linuxBluetoothExclusive'], isTrue);
    expect(explicit['nfcConfiguration'], {
      'ndef': true,
      'isoDep': true,
      'mifareUltralight': false,
      'nfcF': false,
      'nfcV': true
    });
    expect(explicit['wifiConfiguration'],
        {'connectToNetworks': true, 'readCurrentNetwork': false});
    await controller.close();
  });
  test('supersession query is read-only and freezes the submitted observation',
      () async {
    final controller = await WeappContainerController.create(
      storageKey: null,
      atomicHostLayout: true,
    );
    try {
      final submitted = atomicObservation()..['observationId'] = '10';
      final gate = Completer<void>();
      platform.stateGate = gate;
      platform.currentState = atomicState();
      final baseline = platform.requests.length;
      final checking = controller.wasHostLayoutSuperseded(
        observation: submitted,
        layoutRevision: '17',
      );
      submitted['observationId'] = '11';
      gate.complete();
      expect(await checking, isTrue);
      expect(
          platform.requests.skip(baseline).map((entry) => entry.$1), ['state']);
      expect(platform.requests.last.$2, {'id': controller.id});
    } finally {
      await controller.close();
    }
  });
  test('supersession query preserves unknown, faulted and unavailable states',
      () async {
    final controller = await WeappContainerController.create(
      storageKey: null,
      atomicHostLayout: true,
    );
    try {
      platform.currentState = atomicState(pending: null);
      expect(
        await controller.wasHostLayoutSuperseded(
            observation: atomicObservation(), layoutRevision: '17'),
        isFalse,
      );
      for (final domain in [
        'appServiceFault',
        'viewFault',
        'navigationFault'
      ]) {
        platform.currentState = atomicState();
        (platform.currentState['executionHealth'] as Map)[domain] = {
          'code': 'ERR_TIMEOUT',
        };
        expect(
          await controller.wasHostLayoutSuperseded(
              observation: atomicObservation(), layoutRevision: '17'),
          isFalse,
        );
      }
      platform.stateFailure = PlatformException(
        code: 'ERR_NATIVE_STATE',
        message: 'original read-only owner query failure',
      );
      await expectLater(
        controller.wasHostLayoutSuperseded(
            observation: atomicObservation(), layoutRevision: '17'),
        throwsA(isA<PlatformException>()
            .having((error) => error.code, 'code', 'ERR_NATIVE_STATE')),
      );
      expect(
          platform.requests.where((entry) => entry.$1 == 'observeHostLayout'),
          isEmpty);
      expect(
          platform.requests.where((entry) => entry.$1 == 'command'), isEmpty);
    } finally {
      await controller.close();
    }
  });
  test(
    'measured-view preflight keeps host registration before guest startup',
    () async {
      final controller = await WeappContainerController.create(
        storageKey: null,
      );
      final capabilities = await controller.prepareView();
      expect((capabilities['pack'] as Map)['devReload'], {
        'protocolVersion': '1.0',
      });
      expect(platform.requests.last.$1, 'prepareView');
      expect(platform.requests.last.$2, {'id': controller.id});
      expect(platform.requests.where((item) => item.$1 == 'load'), isEmpty);
      await controller.registerHostMethod('host.beforeLoad', (_) => null);
      expect(platform.requests.last.$1, 'registerHostMethod');
      await controller.close();
    },
  );
  test(
    'chrome preflight, measured geometry and tabs use explicit native commands',
    () async {
      final controller = await WeappContainerController.create(
        storageKey: 'retained',
      );
      final chrome = await controller.inspectPackChrome(
        '/verified/pack',
        route: 'pages/custom/index',
      );
      expect(chrome['navigationStyle'], 'custom');
      expect(
        platform.requests.where((r) => r.$1 == 'load' || r.$1 == 'prepareView'),
        isEmpty,
      );
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
          'height': 32,
        },
      };
      final prospective = await controller.prepareHostChrome(geometry);
      expect(prospective, geometry);
      expect(platform.requests.where((r) => r.$1 == 'hostChrome'), isEmpty);
      await controller.applyDevPack(
        '/verified/restart',
        initialHostChrome: prospective,
      );
      expect(platform.requests.last.$2['initialHostChrome'], geometry);
      await controller.updateHostChrome(geometry);
      expect(platform.requests.last.$1, 'hostChrome');
      expect(platform.requests.last.$2, {
        'id': controller.id,
        ...geometry,
        'coordinateSpace': 'flutterClient',
      });
      await controller.setPreviewOccluded(true);
      await controller.setPreviewOccluded(false);
      expect(platform.requests.where((r) => r.$1 == 'setForeground'), isEmpty);
      await controller.switchTab('pages/settings/index');
      expect(platform.requests.last.$1, 'switchTab');
      expect(platform.requests.last.$2, {
        'id': controller.id,
        'route': 'pages/settings/index',
      });
      await controller.close();
    },
  );

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
                  controller: controller, occluded: occluded),
            ),
          );
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
        true,
      );
      expect(
        covered.where((r) => r.$1 == 'input' || r.$1 == 'setForeground'),
        isEmpty,
      );
      await tester.pumpWidget(view(false));
      await tester.pump();
      await tester.pump();
      expect(
        platform.requests
            .where((r) => r.$1 == 'setPreviewOccluded')
            .last
            .$2['occluded'],
        false,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(controller.close);
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets('late page geometry cancellation does not fault the new page', (
    tester,
  ) async {
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
        'height': 32,
      },
    };
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 390,
          height: 700,
          child: WeappContainerView(
            controller: controller,
            hostChrome: geometry,
            onError: (error, _) => failures.add(error),
          ),
        ),
      ),
    );
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
        const geometry = <String, Object?>{'schemaVersion': 1, 'revision': 4};
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
                {'text': 'Guest tab'},
              ],
            },
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
                  nativeChrome: native,
                ),
              ),
            );
        await tester.pumpWidget(view());
        await tester.pump();
        await tester.pump();
        expect(platform.requests.where((r) => r.$1 == 'attach'), hasLength(1));
        expect(
          platform.requests.where((r) => r.$1 == 'hostChrome'),
          hasLength(1),
        );
        expect(
          platform.requests.where((r) => r.$1 == 'nativeChrome'),
          hasLength(1),
        );
        final accepted = platform.requests.lastWhere(
          (r) => r.$1 == 'nativeChrome',
        );
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
        expect(
          (accepted.$2['accessibilityLabels'] as Map)['more'],
          'More',
          reason: 'A queued descriptor must not borrow caller-owned maps',
        );
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
      },
    );
  }
  test(
      'GPU opt-in reaches the native owner and development updates preserve result identity',
      () async {
    final controller = await WeappContainerController.create(
      storageKey: 'project:one',
      gpuRequired: true,
      devDiagnostics: true,
    );
    expect(platform.requests.last.$1, 'create');
    expect(platform.requests.last.$2, {
      'storageKey': 'project:one',
      'gpuRequired': true,
      'devDiagnostics': true,
    });
    final result = await controller.applyDevPack(
      '/verified/generation/2',
      route: 'pages/home/index',
    );
    expect(result['reloadKind'], 'inPlace');
    expect((result['state'] as Map)['sessionId'], 'same');
    expect(platform.requests.last.$1, 'applyDevPack');
    expect(platform.requests.last.$2, {
      'id': controller.id,
      'packPath': '/verified/generation/2',
      'route': 'pages/home/index',
      'options': <String, Object?>{},
    });
    await expectLater(
      controller.registerHostMethod('late', (_) => null),
      throwsStateError,
    );
    final inspected = await controller.devState();
    expect(((inspected['pages'] as List).single as Map)['data'], {'count': 9});
    await controller.clearDevStorage();
    expect(platform.requests.last.$1, 'clearDevStorage');
    expect(platform.requests.last.$2, {'id': controller.id});
    await controller.close();
  });

  test(
    'atomic layout and durable attempts preserve opaque decimal identities',
    () async {
      final controller = await WeappContainerController.create(
        storageKey: null,
        atomicHostLayout: true,
      );
      expect(platform.requests.last.$2['hostLayout'], {
        'protocolVersion': '1.0',
        'atomic': true,
      });
      final observation = <String, Object?>{
        'schemaVersion': 1,
        'ownerId': '9007199254740993',
        'surfaceGeneration': '18446744073709551614',
        'observationId': '9007199254740995',
        'windowMetrics': {'windowWidth': 390, 'windowHeight': 700},
      };
      final events = <String>[];
      final subscription = controller.events.listen(
        (event) => events.add(event.type),
      );
      platform.emit(controller.id, {
        'type': 'hostLayoutObservation',
        'observation': observation,
      });
      platform.emit(controller.id, {
        'type': 'navigationLayout',
        'request': {'ticket': 'navigation-1'},
      });
      platform.emit(controller.id, {
        'type': 'devPackAttempt',
        'receipt': {'attemptId': '9007199254740999'},
      });
      await Future<void>.delayed(Duration.zero);
      expect(controller.pendingHostLayout, observation);
      expect(events, [
        'hostLayoutObservation',
        'navigationLayout',
        'devPackAttempt',
      ]);
      const geometry = <String, Object?>{'schemaVersion': 1, 'revision': 1};
      final prepared = await controller.prepareHostLayout(
        observation: observation,
        chrome: geometry,
        layoutRevision: '9007199254740996',
      );
      expect(prepared['layoutRevision'], '9007199254740996');
      expect(prepared['observationId'], observation['observationId']);
      final proof = <String, Object?>{
        'schemaVersion': 1,
        'ownerId': '9007199254740993',
        'attemptId': '18446744073709551614',
        'targetRoot': List.filled(64, 'a').join(),
        'expectedAccepted': <String, Object?>{
          'root': List.filled(64, 'b').join(),
          'acceptedPackRevision': '9007199254740994',
          'sessionId': 'accepted-session',
        },
      };
      final measuring = controller.prepareHostLayout(
        observation: observation,
        chrome: geometry,
        layoutRevision: '9007199254740997',
        restartAttempt: proof,
      );
      (proof['expectedAccepted'] as Map)['sessionId'] = 'caller-mutated';
      await measuring;
      final sentProof = platform.requests.last.$2['restartAttempt'] as Map;
      expect(sentProof['attemptId'], '18446744073709551614');
      expect((sentProof['expectedAccepted'] as Map)['sessionId'],
          'accepted-session');
      await controller.updateHostLayout(
        observation: observation,
        chrome: geometry,
        layoutRevision: '9007199254740996',
      );
      expect(platform.requests.last.$1, 'hostLayout');
      expect(platform.requests.last.$2.containsKey('restartAttempt'), false);
      expect(platform.requests.last.$2['observation'], observation);
      final receipt = await controller.beginDevPackAttempt(
        '/verified/pack',
        operation: 'load',
        expectedAccepted: null,
      );
      expect(platform.requests.last.$2['payload'], {
        'operation': 'load',
        'packPath': '/verified/pack',
        'expectedAccepted': null,
        'options': <String, Object?>{},
      });
      await controller.applyDevPackAttempt(
        receipt,
        expectedAccepted: null,
        initialHostLayout: prepared,
      );
      expect(
        (platform.requests.last.$2['payload'] as Map)['attemptId'],
        '18446744073709551614',
      );
      await controller.queryDevPackAttempt(receipt);
      expect(
        (platform.requests.last.$2['payload'] as Map)['ownerId'],
        '9007199254740993',
      );
      expect(
        platform.requests.where(
          (r) => r.$1 == 'hostChrome' || r.$1 == 'prepareHostChrome',
        ),
        isEmpty,
      );
      await subscription.cancel();
      await controller.close();
    },
  );

  testWidgets('identical rectangles answer each full native observation', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final creating = WeappContainerController.create(
      storageKey: null,
      atomicHostLayout: true,
    );
    await tester.pump();
    final controller = await creating;
    final observation = <String, Object?>{
      'schemaVersion': 1,
      'ownerId': '1',
      'surfaceGeneration': '1',
      'observationId': '1',
      'windowMetrics': {'windowWidth': 390, 'windowHeight': 700},
    };
    Widget view() {
      platform.emit(controller.id, {
        'type': 'hostLayoutObservation',
        'observation': observation,
      });
      return Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox(
          width: 390,
          height: 700,
          child: WeappContainerView(
            controller: controller,
            hostLayoutObservation: Map.of(observation),
            hostChrome: const {'schemaVersion': 1, 'revision': 1},
          ),
        ),
      );
    }

    await tester.pumpWidget(view());
    await tester.pump();
    await tester.pump();
    expect(platform.requests.where((r) => r.$1 == 'hostLayout'), hasLength(1));
    observation['observationId'] = '2';
    await tester.pumpWidget(view());
    await tester.pump();
    await tester.pump();
    final layouts =
        platform.requests.where((r) => r.$1 == 'hostLayout').toList();
    expect(layouts, hasLength(2));
    expect((layouts.first.$2['observation'] as Map)['observationId'], '1');
    expect((layouts.last.$2['observation'] as Map)['observationId'], '2');
    expect(platform.requests.where((r) => r.$1 == 'hostChrome'), isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.runAsync(controller.close);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final scenario in <(String, Map<String, Object?>)>[
    ('pending newer same-page observation', atomicState()),
    (
      'accepted newer same-page observation',
      atomicState(pending: null, accepted: '11'),
    ),
    (
      'accepted newer layout on identical observation',
      atomicState(pending: null, accepted: '10', revision: '18'),
    ),
    (
      'same owner native surface advanced with newer observation',
      atomicState(surface: '6'),
    ),
    (
      'greater than 2^53 observations remain distinct',
      atomicState(pending: '9007199254740994'),
    ),
    (
      'maximum u64 observation is valid',
      atomicState(pending: '18446744073709551615'),
    ),
  ]) {
    atomicTestWidgets(
      'atomic cancellation reconciles ${scenario.$1} without ACK or unocclusion',
      (tester) async {
        final controller = await atomicController(tester);
        final errors = <Object>[], acknowledgements = <int>[];
        final observation = atomicObservation(
          sequence: scenario.$1.contains('2^53') ? '9007199254740993' : '10',
        );
        final geometry = atomicGeometry();
        await tester.pumpWidget(
          atomicView(
            controller,
            observation,
            geometry,
            errors,
            acknowledgements,
            occluded: true,
            prepareOnly: true,
          ),
        );
        await flushChrome(tester);
        expect(
          platform.requests
              .where((r) => r.$1 == 'setPreviewOccluded')
              .last
              .$2['occluded'],
          true,
        );
        final baseline = platform.requests.length;
        platform.cancelLayout = true;
        platform.currentState = scenario.$2;
        await tester.pumpWidget(
          atomicView(
            controller,
            observation,
            geometry,
            errors,
            acknowledgements,
          ),
        );
        await flushChrome(tester);
        expect(
          platform.requests.skip(baseline).where((r) => r.$1 == 'hostLayout'),
          hasLength(1),
        );
        expect(
          platform.requests.skip(baseline).where((r) => r.$1 == 'state'),
          hasLength(1),
        );
        expect(errors, isEmpty);
        expect(acknowledgements, isEmpty);
        expect(
          platform.requests
              .skip(baseline)
              .where((r) => r.$1 == 'setPreviewOccluded'),
          isEmpty,
          reason:
              'cancelled geometry must not restore preview input/presentation',
        );
        platform.cancelLayout = false;
        final next = atomicObservation(
          surface: (scenario.$2['hostSurface'] as Map)['surfaceGeneration']
              as String,
          sequence: scenario.$1.contains('2^53') ? '9007199254740994' : '11',
        );
        await tester.pumpWidget(
          atomicView(
            controller,
            next,
            atomicGeometry(revision: 19),
            errors,
            acknowledgements,
          ),
        );
        await flushChrome(tester);
        expect(errors, isEmpty);
        expect(acknowledgements, [19]);
        expect(
          platform.requests
              .skip(baseline)
              .where((r) => r.$1 == 'setPreviewOccluded')
              .single
              .$2['occluded'],
          false,
        );
        await closeAtomic(tester, controller);
      },
    );
  }

  final invalidAtomicStates = <(String, Map<String, Object?>)>[
    ('unknown cancellation without native proof', atomicState(pending: null)),
    (
      'same observation and same layout revision',
      atomicState(pending: '10', accepted: '10', revision: '17'),
    ),
    (
      'older observation',
      atomicState(pending: '9', accepted: '9', revision: '16'),
    ),
    ('wrong state owner', atomicState(owner: '8')),
    ('older native surface', atomicState(surface: '4')),
    (
      'overflow pending observation',
      atomicState(pending: '18446744073709551616'),
    ),
    ('noncanonical pending observation', atomicState(pending: '011')),
    (
      'numeric pending observation',
      atomicState()
        ..['pendingHostLayout'] = {...atomicObservation(), 'observationId': 11},
    ),
    (
      'overflow accepted layout revision despite newer observation',
      atomicState(
        pending: null,
        accepted: '11',
        revision: '18446744073709551616',
      ),
    ),
    (
      'noncanonical accepted layout revision despite newer observation',
      atomicState(pending: null, accepted: '11', revision: '018'),
    ),
    (
      'overflow same-observation accepted revision',
      atomicState(
        pending: null,
        accepted: '10',
        revision: '18446744073709551616',
      ),
    ),
    ('missing health', atomicState()..remove('executionHealth')),
    (
      'wrong health schema',
      atomicState()
        ..['executionHealth'] = {'schemaVersion': 2, 'requiresRestart': false},
    ),
    (
      'restart required',
      atomicState()
        ..['executionHealth'] = {'schemaVersion': 1, 'requiresRestart': true},
    ),
    for (final domain in ['appServiceFault', 'viewFault', 'navigationFault'])
      (
        '$domain present',
        atomicState()
          ..['executionHealth'] = {
            'schemaVersion': 1,
            'requiresRestart': false,
            domain: {'code': 'ERR_TIMEOUT'},
          },
      ),
    ('wrong state schema', atomicState()..['schemaVersion'] = 2),
  ];
  for (final field in ['ownerId', 'surfaceGeneration', 'schemaVersion']) {
    final state = atomicState();
    (state['pendingHostLayout'] as Map)[field] =
        field == 'schemaVersion' ? 2 : '8';
    invalidAtomicStates.add(('wrong pending $field', state));
  }
  for (final field in ['ownerId', 'surfaceGeneration']) {
    final state = atomicState();
    (state['hostSurface'] as Map)[field] = field == 'ownerId' ? '8' : '04';
    invalidAtomicStates.add(('invalid current surface $field', state));
  }
  for (final field in ['ownerId', 'surfaceGeneration', 'schemaVersion']) {
    final state = atomicState(pending: null, accepted: '11');
    (state['acceptedLayout'] as Map)[field] =
        field == 'schemaVersion' ? 2 : '8';
    invalidAtomicStates.add(('wrong accepted $field', state));
  }
  for (final scenario in invalidAtomicStates) {
    atomicTestWidgets('atomic cancellation preserves error for ${scenario.$1}',
        (
      tester,
    ) async {
      final controller = await atomicController(tester);
      platform.cancelLayout = true;
      platform.currentState = scenario.$2;
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(
        atomicView(
          controller,
          atomicObservation(),
          atomicGeometry(),
          errors,
          acknowledgements,
        ),
      );
      await flushChrome(tester);
      expect(
        errors,
        hasLength(1),
        reason:
            'ambiguous/unhealthy/stale native state cannot make ERR_CANCELLED harmless',
      );
      expect(
        errors.single,
        isA<PlatformException>().having((e) => e.code, 'code', 'ERR_CANCELLED'),
      );
      expect(acknowledgements, isEmpty);
      expect(
        platform.requests.where((r) => r.$1 == 'setPreviewOccluded'),
        isEmpty,
      );
      await closeAtomic(tester, controller);
    });
  }

  for (final field in ['ownerId', 'surfaceGeneration', 'observationId']) {
    for (final bad in ['01', '18446744073709551616']) {
      atomicTestWidgets(
          'atomic cancellation rejects invalid attempted $field=$bad',
          (tester) async {
        final controller = await atomicController(tester);
        final observation = atomicObservation();
        observation[field] = bad;
        platform.currentState = atomicState(
          owner: field == 'ownerId' ? bad : '7',
          surface: field == 'surfaceGeneration' ? bad : '5',
        );
        platform.cancelLayout = true;
        final errors = <Object>[], acknowledgements = <int>[];
        await tester.pumpWidget(atomicView(controller, observation,
            atomicGeometry(), errors, acknowledgements));
        await flushChrome(tester);
        expect(errors, hasLength(1));
        expect(
            errors.single,
            isA<PlatformException>()
                .having((e) => e.code, 'code', 'ERR_CANCELLED'));
        expect(acknowledgements, isEmpty);
        await closeAtomic(tester, controller);
      });
    }
  }

  atomicTestWidgets(
      'atomic successful stale revision cannot ACK or unocclude a newer observation',
      (tester) async {
    final controller = await atomicController(tester);
    final errors = <Object>[], acknowledgements = <int>[];
    final geometry = atomicGeometry();
    await tester.pumpWidget(atomicView(
        controller, atomicObservation(), geometry, errors, acknowledgements,
        occluded: true, prepareOnly: true));
    await flushChrome(tester);
    final first = Completer<void>(), latest = Completer<void>();
    platform.layoutGate = first;
    final baseline = platform.requests.length;
    await tester.pumpWidget(atomicView(
        controller, atomicObservation(), geometry, errors, acknowledgements));
    await flushChrome(tester);
    expect(platform.requests.skip(baseline).where((r) => r.$1 == 'hostLayout'),
        hasLength(1));
    platform.layoutGate = latest;
    await tester.pumpWidget(atomicView(controller,
        atomicObservation(sequence: '11'), geometry, errors, acknowledgements));
    await flushChrome(tester);
    first.complete();
    await flushChrome(tester);
    final layouts = platform.requests
        .skip(baseline)
        .where((r) => r.$1 == 'hostLayout')
        .toList();
    expect(layouts, hasLength(2));
    expect((layouts.first.$2['observation'] as Map)['observationId'], '10');
    expect((layouts.last.$2['observation'] as Map)['observationId'], '11');
    expect(layouts.map((r) => r.$2['layoutRevision']), ['17', '17']);
    expect(acknowledgements, isEmpty);
    expect(
        platform.requests
            .skip(baseline)
            .where((r) => r.$1 == 'setPreviewOccluded'),
        isEmpty);
    latest.complete();
    await flushChrome(tester);
    expect(acknowledgements, [17]);
    expect(
        platform.requests
            .skip(baseline)
            .where((r) => r.$1 == 'setPreviewOccluded')
            .single
            .$2['occluded'],
        false);
    expect(errors, isEmpty);
    await closeAtomic(tester, controller);
  });

  atomicTestWidgets(
      'atomic ACK checks the full surface tuple even when revision and observation ID match',
      (tester) async {
    final controller = await atomicController(tester);
    final errors = <Object>[], acknowledgements = <int>[];
    final geometry = atomicGeometry();
    await tester.pumpWidget(atomicView(
        controller, atomicObservation(), geometry, errors, acknowledgements,
        occluded: true, prepareOnly: true));
    await flushChrome(tester);
    final first = Completer<void>(), replacement = Completer<void>();
    platform.layoutGate = first;
    final baseline = platform.requests.length;
    await tester.pumpWidget(atomicView(
        controller, atomicObservation(), geometry, errors, acknowledgements));
    await flushChrome(tester);
    platform.layoutGate = replacement;
    await tester.pumpWidget(atomicView(controller,
        atomicObservation(surface: '6'), geometry, errors, acknowledgements));
    await flushChrome(tester);
    first.complete();
    await flushChrome(tester);
    expect(acknowledgements, isEmpty);
    expect(
        platform.requests
            .skip(baseline)
            .where((r) => r.$1 == 'setPreviewOccluded'),
        isEmpty);
    await tester.pumpWidget(atomicView(
        controller,
        atomicObservation(surface: '6', sequence: '11'),
        geometry,
        errors,
        acknowledgements));
    replacement.complete();
    await flushChrome(tester);
    expect(acknowledgements, [17]);
    expect(
        platform.requests
            .skip(baseline)
            .where((r) => r.$1 == 'setPreviewOccluded')
            .single
            .$2['occluded'],
        false);
    expect(errors, isEmpty);
    await closeAtomic(tester, controller);
  });

  atomicTestWidgets(
      'Windows same native signature survives a superseded geometry wait and applies exactly once',
      (tester) async {
    final controller = await atomicController(tester);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final errors = <Object>[], acknowledgements = <int>[];
    final geometry = atomicGeometry();
    final native = <String, Object?>{
      'schemaVersion': 1,
      'title': '本地窗口',
      'accessibilityLabels': {'more': '更多', 'close': '关闭小程序'}
    };
    await tester.pumpWidget(atomicView(
        controller, atomicObservation(), geometry, errors, acknowledgements,
        occluded: true, prepareOnly: true));
    await flushChrome(tester);
    final first = Completer<void>(), latest = Completer<void>();
    platform.layoutGate = first;
    final baseline = platform.requests.length;
    await tester.pumpWidget(atomicView(
        controller, atomicObservation(), geometry, errors, acknowledgements,
        nativeChrome: native));
    await flushChrome(tester);
    platform.layoutGate = latest;
    await tester.pumpWidget(atomicView(controller,
        atomicObservation(sequence: '11'), geometry, errors, acknowledgements,
        nativeChrome: {
          ...native,
          'accessibilityLabels': {'more': '更多', 'close': '关闭小程序'}
        }));
    await flushChrome(tester);
    first.complete();
    await flushChrome(tester);
    expect(acknowledgements, isEmpty);
    expect(
        platform.requests.skip(baseline).where((r) => r.$1 == 'nativeChrome'),
        hasLength(1),
        reason: 'metadata advances independently of stale geometry');
    expect(
        platform.requests
            .skip(baseline)
            .where((r) => r.$1 == 'setPreviewOccluded'),
        isEmpty);
    latest.complete();
    await flushChrome(tester);
    final applied = platform.requests
        .skip(baseline)
        .where((r) => r.$1 == 'nativeChrome')
        .single;
    expect(applied.$2, {'id': controller.id, ...native});
    expect(acknowledgements, [17]);
    final operations =
        platform.requests.skip(baseline).map((r) => r.$1).toList();
    expect(operations.indexOf('nativeChrome'),
        lessThan(operations.indexOf('setPreviewOccluded')));
    expect(
        platform.requests
            .skip(baseline)
            .where((r) => r.$1 == 'setPreviewOccluded')
            .single
            .$2['occluded'],
        false);
    expect(errors, isEmpty);
    await closeAtomic(tester, controller);
  });

  atomicTestWidgets(
    'atomic queued observation and nested chrome snapshots resist external mutation',
    (tester) async {
      final controller = await atomicController(tester);
      final errors = <Object>[], acknowledgements = <int>[];
      final observation = atomicObservation(), geometry = atomicGeometry();
      platform.layoutGate = Completer<void>();
      await tester.pumpWidget(
        atomicView(controller, observation, geometry, errors, acknowledgements),
      );
      await flushChrome(tester);
      final request =
          platform.requests.singleWhere((r) => r.$1 == 'hostLayout').$2;
      observation['ownerId'] = 'mutated';
      observation['observationId'] = '99';
      (observation['windowMetrics'] as Map)['windowWidth'] = 1;
      geometry['sessionId'] = 'mutated';
      (geometry['contentRect'] as Map)['width'] = 1;
      (geometry['menuButtonRect'] as Map)['left'] = 1;
      expect((request['observation'] as Map)['ownerId'], '7');
      expect((request['observation'] as Map)['observationId'], '10');
      expect(
        ((request['observation'] as Map)['windowMetrics']
            as Map)['windowWidth'],
        390,
      );
      expect((request['chrome'] as Map)['sessionId'], 'same-session');
      expect(((request['chrome'] as Map)['contentRect'] as Map)['width'], 390);
      expect(
        ((request['chrome'] as Map)['menuButtonRect'] as Map)['left'],
        294,
      );
      platform.layoutGate!.complete();
      await flushChrome(tester);
      expect(errors, isEmpty);
      await closeAtomic(tester, controller);
    },
  );

  atomicTestWidgets(
    'consumed preflight observation cannot run queued geometry after view readiness',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      final observation = atomicObservation();
      platform.emit(controller.id, {
        'type': 'hostLayoutObservation',
        'observation': observation,
      });
      final retired = Completer<void>();
      final previousOwner = Object();
      await controller.claimView(previousOwner);
      controller.releaseView(previousOwner, retired.future);
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(
          controller, observation, atomicGeometry(), errors, acknowledgements));
      platform.emit(controller.id, {
        'type': 'hostLayoutAccepted',
        'acceptedLayout': {
          ...observation,
          'layoutRevision': '17',
          'chrome': atomicGeometry(),
        },
      });
      retired.complete();
      await flushChrome(tester);
      expect(controller.pendingHostLayout, isNull);
      expect(platform.requests.where((r) => r.$1 == 'hostLayout'), isEmpty);
      expect(acknowledgements, isEmpty);
      expect(errors, isEmpty);
    },
  );

  atomicTestWidgets(
    'prepare-only transition invalidates geometry queued before view readiness',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      final observation = atomicObservation();
      platform.emit(controller.id, {
        'type': 'hostLayoutObservation',
        'observation': observation,
      });
      final retired = Completer<void>();
      final previousOwner = Object();
      await controller.claimView(previousOwner);
      controller.releaseView(previousOwner, retired.future);
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(
          controller, observation, atomicGeometry(), errors, acknowledgements));
      await tester.pumpWidget(atomicView(
          controller, observation, atomicGeometry(), errors, acknowledgements,
          prepareOnly: true));
      retired.complete();
      await flushChrome(tester);
      expect(platform.requests.where((r) => r.$1 == 'hostLayout'), isEmpty);
      expect(acknowledgements, isEmpty);
      expect(errors, isEmpty);
    },
  );

  atomicTestWidgets(
    'consumed startup geometry still applies metadata without ACK or restoring occlusion',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final observation = atomicObservation();
      platform.emit(controller.id, {
        'type': 'hostLayoutObservation',
        'observation': observation,
      });
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(
          controller, observation, atomicGeometry(), errors, acknowledgements,
          occluded: true, prepareOnly: true));
      await flushChrome(tester);
      platform.emit(controller.id, {
        'type': 'hostLayoutAccepted',
        'acceptedLayout': {
          ...observation,
          'layoutRevision': '17',
          'chrome': atomicGeometry(),
        },
      });
      final baseline = platform.requests.length;
      final native = {
        'schemaVersion': 1,
        'revision': 17,
        'title': 'Loaded project',
        'accessibilityLabels': {'more': 'More', 'close': 'Close'},
      };
      await tester.pumpWidget(atomicView(controller, observation,
          atomicGeometry(revision: 18), errors, acknowledgements,
          nativeChrome: native, emitObservation: false));
      await flushChrome(tester);
      final requests = platform.requests.skip(baseline).toList();
      expect(requests.where((r) => r.$1 == 'hostLayout'), isEmpty);
      expect(requests.where((r) => r.$1 == 'setPreviewOccluded'), isEmpty);
      expect(requests.where((r) => r.$1 == 'nativeChrome').single.$2,
          {'id': controller.id, ...native});
      expect(acknowledgements, isEmpty);
      expect(errors, isEmpty);
    },
  );

  atomicTestWidgets(
    'native observation can supersede a successful reply before widget rebuild',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      final errors = <Object>[], acknowledgements = <int>[];
      final gate = Completer<void>();
      platform.layoutGate = gate;
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements));
      await flushChrome(tester);
      platform.emit(controller.id, {
        'type': 'hostLayoutObservation',
        'observation': atomicObservation(sequence: '11'),
      });
      gate.complete();
      await flushChrome(tester);
      expect(acknowledgements, isEmpty);
      expect(errors, isEmpty);
      expect(
          platform.requests.where((r) => r.$1 == 'hostLayout'), hasLength(1));
    },
  );

  atomicTestWidgets(
    'metadata update while view readiness waits preserves the only desired geometry',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final retired = Completer<void>();
      final previousOwner = Object();
      await controller.claimView(previousOwner);
      controller.releaseView(previousOwner, retired.future);
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements,
          nativeChrome: {
            'title': 'Project',
            'accessibilityLabels': {'more': 'More'}
          }));
      final latestMetadata = {
        'title': '项目',
        'accessibilityLabels': {'more': '更多'}
      };
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements,
          nativeChrome: latestMetadata));
      retired.complete();
      await flushChrome(tester);
      expect(
          platform.requests.where((r) => r.$1 == 'hostLayout'), hasLength(1));
      expect(platform.requests.where((r) => r.$1 == 'nativeChrome').single.$2,
          {'id': controller.id, ...latestMetadata});
      expect(acknowledgements, [17]);
      expect(errors, isEmpty);
    },
  );

  atomicTestWidgets(
    'readiness queue coalesces replaced immutable geometry into the latest observation',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      final retired = Completer<void>();
      final previousOwner = Object();
      await controller.claimView(previousOwner);
      controller.releaseView(previousOwner, retired.future);
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements));
      await tester.pumpWidget(atomicView(
          controller,
          atomicObservation(sequence: '11'),
          atomicGeometry(revision: 18),
          errors,
          acknowledgements));
      retired.complete();
      await flushChrome(tester);
      final request =
          platform.requests.singleWhere((r) => r.$1 == 'hostLayout');
      expect((request.$2['observation'] as Map)['observationId'], '11');
      expect(request.$2['layoutRevision'], '18');
      expect(acknowledgements, [18]);
      expect(errors, isEmpty);
    },
  );

  atomicTestWidgets(
    'unavailable cancellation proof preserves the original error and metadata progress',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      platform.cancelLayout = true;
      platform.stateFailure = PlatformException(code: 'ERR_STATE_UNAVAILABLE');
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements,
          nativeChrome: {'title': 'Latest title'}));
      await flushChrome(tester);
      expect(errors, hasLength(1));
      expect(
          errors.single,
          isA<PlatformException>()
              .having((error) => error.code, 'code', 'ERR_CANCELLED')
              .having((error) => error.message, 'message',
                  'fixture native observation superseded'));
      expect(
          platform.requests.where((r) => r.$1 == 'nativeChrome'), hasLength(1));
      expect(acknowledgements, isEmpty);
    },
  );

  atomicTestWidgets(
    'controller close intent retires an in-flight success without ACK or metadata',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final layout = Completer<void>(), closing = Completer<void>();
      platform.layoutGate = layout;
      platform.closeGate = closing;
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements,
          nativeChrome: {'title': 'Unsent title'}));
      await flushChrome(tester);
      final close = tester.runAsync(controller.close);
      expect(controller.isClosed, isFalse);
      expect(controller.closeRequested, isTrue);
      layout.complete();
      await flushChrome(tester);
      expect(acknowledgements, isEmpty);
      expect(platform.requests.where((r) => r.$1 == 'nativeChrome'), isEmpty);
      expect(errors, isEmpty);
      closing.complete();
      await flushChrome(tester);
      await close;
    },
  );

  atomicTestWidgets(
    'close releases a hung read-only proof and ignores its late failure',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final state = Completer<void>(), closing = Completer<void>();
      platform.cancelLayout = true;
      platform.stateGate = state;
      platform.closeGate = closing;
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements,
          nativeChrome: {'title': 'Unsent title'}));
      await flushChrome(tester);
      expect(platform.requests.where((r) => r.$1 == 'state'), hasLength(1));
      final close = tester.runAsync(controller.close);
      await flushChrome(tester);
      expect(errors, isEmpty);
      expect(acknowledgements, isEmpty);
      expect(platform.requests.where((r) => r.$1 == 'nativeChrome'), isEmpty);
      platform.stateFailure = PlatformException(code: 'ERR_LATE_STATE');
      state.complete();
      closing.complete();
      await flushChrome(tester);
      await close;
      await flushChrome(tester);
      expect(errors, isEmpty);
    },
  );

  atomicTestWidgets(
    'committed accepted geometry restores a tool overlay on metadata-only change',
    (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final observation = atomicObservation(), geometry = atomicGeometry();
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(
          controller, observation, geometry, errors, acknowledgements,
          occluded: true, prepareOnly: true));
      await flushChrome(tester);
      await tester.pumpWidget(atomicView(
          controller, observation, geometry, errors, acknowledgements));
      await flushChrome(tester);
      expect(acknowledgements, [17]);
      platform.emit(controller.id, {
        'type': 'hostLayoutAccepted',
        'acceptedLayout': {
          ...observation,
          'layoutRevision': '17',
          'chrome': geometry,
        },
      });
      await tester.pumpWidget(atomicView(
          controller, observation, geometry, errors, acknowledgements,
          occluded: true, emitObservation: false));
      await flushChrome(tester);
      final baseline = platform.requests.length;
      await tester.pumpWidget(atomicView(
          controller, observation, geometry, errors, acknowledgements,
          emitObservation: false,
          nativeChrome: {
            'title': '新标题',
            'accessibilityLabels': {'more': '更多'}
          }));
      await flushChrome(tester);
      final requests = platform.requests.skip(baseline);
      expect(requests.where((r) => r.$1 == 'hostLayout'), isEmpty);
      expect(requests.where((r) => r.$1 == 'observeHostLayout'), isEmpty);
      expect(requests.where((r) => r.$1 == 'nativeChrome'), hasLength(1));
      expect(
          requests
              .where((r) => r.$1 == 'setPreviewOccluded')
              .single
              .$2['occluded'],
          false);
      expect(acknowledgements, [17],
          reason: 'metadata never ACKs another layout');
      expect(errors, isEmpty);
    },
  );

  test(
      'native layout receipts retain independent immutable full owner identities',
      () async {
    final controller = await WeappContainerController.create(
        storageKey: null, atomicHostLayout: true);
    try {
      final observation = atomicObservation();
      platform.emit(controller.id,
          {'type': 'hostLayoutObservation', 'observation': observation});
      (observation['windowMetrics'] as Map)['windowWidth'] = 1;
      final queried = controller.pendingHostLayout!;
      expect((queried['windowMetrics'] as Map)['windowWidth'], 390);
      (queried['windowMetrics'] as Map)['windowWidth'] = 2;
      expect(
          (controller.pendingHostLayout!['windowMetrics']
              as Map)['windowWidth'],
          390);
      platform.emit(controller.id, {
        'type': 'hostLayoutAccepted',
        'acceptedLayout': {
          ...atomicObservation(owner: '8'),
          'layoutRevision': '17',
          'chrome': atomicGeometry()
        },
      });
      expect(controller.pendingHostLayout, isNotNull,
          reason: 'foreign owner cannot consume this observation');
      platform.emit(controller.id, {
        'type': 'hostLayoutAccepted',
        'acceptedLayout': {
          ...atomicObservation(),
          'windowMetrics': {'windowWidth': 1, 'windowHeight': 700},
          'layoutRevision': '17',
          'chrome': atomicGeometry()
        },
      });
      expect(controller.pendingHostLayout, isNotNull,
          reason: 'different metrics cannot consume the frozen observation');
      final accepted = {
        ...atomicObservation(),
        'layoutRevision': '17',
        'chrome': atomicGeometry()
      };
      platform.emit(controller.id,
          {'type': 'hostLayoutAccepted', 'acceptedLayout': accepted});
      expect(controller.pendingHostLayout, isNull);
      (accepted['chrome'] as Map)['revision'] = 99;
      expect((controller.acceptedHostLayout!['chrome'] as Map)['revision'], 17);
      (controller.acceptedHostLayout!['chrome'] as Map)['revision'] = 100;
      expect((controller.acceptedHostLayout!['chrome'] as Map)['revision'], 17);
    } finally {
      await controller.close();
    }
  });

  for (final field in [
    'schemaVersion',
    'ownerId',
    'surfaceGeneration',
    'observationId',
    'sessionId',
    'pageId',
    'windowMetrics'
  ]) {
    atomicTestWidgets(
        'queued geometry requires current native $field before dispatch',
        (tester) async {
      final controller = await atomicController(tester);
      final platform = WeappContainerPlatform.instance as FakePlatform;
      final retired = Completer<void>();
      final previousOwner = Object();
      await controller.claimView(previousOwner);
      controller.releaseView(previousOwner, retired.future);
      final errors = <Object>[], acknowledgements = <int>[];
      await tester.pumpWidget(atomicView(controller, atomicObservation(),
          atomicGeometry(), errors, acknowledgements));
      final changed = atomicObservation();
      changed[field] = switch (field) {
        'schemaVersion' => 2,
        'pageId' => 3,
        'windowMetrics' => {'windowWidth': 391, 'windowHeight': 700},
        _ => 'changed-' + field,
      };
      platform.emit(controller.id,
          {'type': 'hostLayoutObservation', 'observation': changed});
      retired.complete();
      await flushChrome(tester);
      expect(platform.requests.where((r) => r.$1 == 'hostLayout'), isEmpty);
      expect(acknowledgements, isEmpty);
      expect(errors, isEmpty);
    });
  }

  atomicTestWidgets(
      'a foreign accepted receipt cannot restore an already covered preview',
      (tester) async {
    final controller = await atomicController(tester);
    final platform = WeappContainerPlatform.instance as FakePlatform;
    final observation = atomicObservation(), geometry = atomicGeometry();
    final errors = <Object>[], acknowledgements = <int>[];
    await tester.pumpWidget(atomicView(
        controller, observation, geometry, errors, acknowledgements));
    await flushChrome(tester);
    expect(acknowledgements, [17]);
    platform.emit(controller.id, {
      'type': 'hostLayoutAccepted',
      'acceptedLayout': {
        ...observation,
        'layoutRevision': '17',
        'chrome': geometry
      }
    });
    await tester.pumpWidget(atomicView(
        controller, observation, geometry, errors, acknowledgements,
        occluded: true, emitObservation: false));
    await flushChrome(tester);
    platform.emit(controller.id, {
      'type': 'hostLayoutAccepted',
      'acceptedLayout': {
        ...observation,
        'ownerId': '8',
        'layoutRevision': '17',
        'chrome': geometry
      }
    });
    final baseline = platform.requests.length;
    await tester.pumpWidget(atomicView(
        controller, observation, geometry, errors, acknowledgements,
        emitObservation: false));
    await flushChrome(tester);
    expect(
        platform.requests
            .skip(baseline)
            .where((r) => r.$1 == 'hostLayout' || r.$1 == 'setPreviewOccluded'),
        isEmpty);
    expect(acknowledgements, [17]);
    expect(errors, isEmpty);
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
      'payload': '中文 🧊',
    });
    expect(received.payload, '中文 🧊');
    platform.emit(controller.id, {
      'type': 'hostCallCancelled',
      'callId': 'g1-1',
    });
    await received.cancellation.whenCancelled;
    response.complete('late');
    await Future<void>.delayed(Duration.zero);
    expect(
      platform.requests.where((item) => item.$1 == 'completeHostCall'),
      isEmpty,
    );
    await controller.close();
  });
  test('async host result preserves JSON null and completes once', () async {
    final controller = await WeappContainerController.create(
      storageKey: 'account:catalog',
    );
    await controller.registerHostMethod('host.null', (_) async => null);
    platform.emit(controller.id + 1, {
      'type': 'hostCall',
      'callId': 'other',
      'method': 'host.null',
    });
    platform.emit(controller.id, {
      'type': 'hostCall',
      'callId': 'mine',
      'method': 'host.null',
    });
    await Future<void>.delayed(Duration.zero);
    final replies = platform.requests
        .where((item) => item.$1 == 'completeHostCall')
        .toList();
    expect(replies, hasLength(1));
    expect(replies.single.$2, {
      'id': controller.id,
      'callId': 'mine',
      'result': null,
    });
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
              child: WeappContainerView(controller: controller),
            ),
          );
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
    },
  );
  testWidgets('desktop input is owned by the deepest embedded view', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });
    final creating = WeappContainerController.create(storageKey: null);
    await tester.pump();
    final controller = await creating;
    final scrolling = ScrollController();
    addTearDown(scrolling.dispose);
    await tester.pumpWidget(
      Directionality(
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
                    child: WeappContainerView(controller: controller),
                  ),
                  const SizedBox(height: 1000),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final inside = tester.getCenter(find.byKey(const ValueKey('embedded')));
    await tester.sendEventToBinding(
      PointerScrollEvent(position: inside, scrollDelta: const Offset(0, 60)),
    );
    await tester.pump();
    expect(
      scrolling.offset,
      0,
      reason: 'One wheel must not scroll both SDK and parent',
    );
    final inputs = platform.requests.where((r) => r.$1 == 'input').toList();
    expect(inputs, hasLength(1));
    expect((inputs.single.$2['events'] as List).single['type'], 'wheel');
    await tester.dragFrom(inside, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(
      scrolling.offset,
      0,
      reason: 'A contact starting inside the SDK belongs to it',
    );
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
    expect(
      sent('tap'),
      hasLength(1),
      reason: 'Cancellation must not activate a tap',
    );
    final first = await tester.startGesture(inside, pointer: 11);
    final second = await tester.startGesture(
      inside + const Offset(10, 0),
      pointer: 12,
    );
    await second.up();
    await first.up();
    await tester.pump();
    expect(
      sent('tap'),
      hasLength(1),
      reason: 'Multiple contacts must not activate a tap',
    );
    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(20, 40),
        scrollDelta: Offset(0, 60),
      ),
    );
    await tester.pump();
    expect(
      scrolling.offset,
      60,
      reason: 'The host still owns input outside the SDK',
    );
    await tester.runAsync(() => controller.close());
    final sentBeforeClose =
        platform.requests.where((r) => r.$1 == 'input').length;
    await tester.dragFrom(inside, const Offset(0, -60));
    await tester.pumpAndSettle();
    expect(
      scrolling.offset,
      greaterThan(60),
      reason: 'A closed view must not capture host gestures',
    );
    expect(
      platform.requests.where((r) => r.$1 == 'input'),
      hasLength(sentBeforeClose),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });
}
