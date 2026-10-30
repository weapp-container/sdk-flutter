import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container/weapp_container.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';

class LeasePlatform extends WeappContainerPlatform {
  final source = StreamController<Map<String, Object?>>.broadcast(sync: true);
  Completer<void>? foregroundGate;
  Completer<void>? uncoverGate;
  Completer<void>? detachGate;
  final methods = <String>[];
  @override
  Stream<Map<String, Object?>> get events => source.stream;
  @override
  Future<void> initialize() async {}
  @override
  Future<T?> invoke<T>(String method, Map<String, Object?> args) async {
    methods.add(method);
    if (method == 'create') return {'id': 1} as T;
    if (method == 'attach') return {'textureId': 123} as T;
    if (method == 'setForeground') {
      final gate = foregroundGate;
      foregroundGate = null;
      await gate?.future;
    }
    if (method == 'setPreviewOccluded' && args['occluded'] == false) {
      final gate = uncoverGate;
      uncoverGate = null;
      await gate?.future;
    }
    if (method == 'detach') {
      final gate = detachGate;
      detachGate = null;
      await gate?.future;
    }
    return null;
  }
}

Widget leaseView(
  WeappContainerController controller,
  List<Object> errors, {
  Key? key,
  bool occluded = false,
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 300,
        height: 400,
        child: WeappContainerView(
          key: key,
          controller: controller,
          occluded: occluded,
          onError: (error, stack) => errors.add(error),
        ),
      ),
    );

Future<void> flushLease(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) await tester.pump();
}

final _leaseOwners = <WeappContainerController>[];
Future<WeappContainerController> leaseController(
  WidgetTester tester, {
  bool atomicHostLayout = false,
}) async {
  final creating = WeappContainerController.create(
    storageKey: null,
    atomicHostLayout: atomicHostLayout,
  );
  await tester.pump();
  final controller = await creating;
  _leaseOwners.add(controller);
  return controller;
}

void leaseTestWidgets(String name, WidgetTesterCallback callback) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final originalOnError = FlutterError.onError;
    final originalDebugPrint = debugPrint;
    try {
      await callback(tester);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      for (final controller in _leaseOwners) {
        if (!controller.isClosed) await tester.runAsync(controller.close);
      }
      _leaseOwners.clear();
      debugDefaultTargetPlatformOverride = null;
      FlutterError.onError = originalOnError;
      debugPrint = originalDebugPrint;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LeasePlatform platform;
  late WeappContainerController controller;
  setUp(() async {
    platform = LeasePlatform();
    WeappContainerPlatform.instance = platform;
  });
  tearDown(() async {
    await platform.source.close();
    debugDefaultTargetPlatformOverride = null;
  });
  leaseTestWidgets(
    'retired View foreground failure cannot become replacement View preview failure on the same controller',
    (tester) async {
      controller = await leaseController(tester);
      final diagnosticFallback = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null &&
            message.startsWith('weapp_container.retired_view ')) {
          diagnosticFallback.add(message);
        } else {
          originalDebugPrint(message, wrapWidth: wrapWidth);
        }
      };
      final pending = Completer<void>();
      platform.foregroundGate = pending;
      final oldErrors = <Object>[], currentErrors = <Object>[];
      await tester.pumpWidget(
        leaseView(controller, oldErrors, key: const ValueKey('old')),
      );
      await flushLease(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      await tester.pumpWidget(
        leaseView(controller, currentErrors, key: const ValueKey('new')),
      );
      await flushLease(tester);
      pending.completeError(
        PlatformException(
          code: 'ERR_CANCELLED',
          message: 'private pending error',
        ),
      );
      await flushLease(tester);
      expect(
        oldErrors,
        isEmpty,
        reason:
            'same controller is insufficient; the submitting View lease was retired',
      );
      expect(currentErrors, isEmpty);
      expect(diagnosticFallback, hasLength(1));
      expect(
        diagnosticFallback.single,
        isNot(contains('private pending error')),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
    },
  );
  leaseTestWidgets(
    'active View ERR_CANCELLED is still reported with no later-state recovery inference',
    (tester) async {
      controller = await leaseController(tester);
      final pending = Completer<void>();
      platform.foregroundGate = pending;
      final errors = <Object>[];
      await tester.pumpWidget(leaseView(controller, errors));
      await flushLease(tester);
      pending.completeError(
        PlatformException(code: 'ERR_CANCELLED', message: 'active failure'),
      );
      await flushLease(tester);
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'ERR_CANCELLED',
        ),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
    },
  );
}
