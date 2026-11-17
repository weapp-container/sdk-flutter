import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container/weapp_container.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';

import 'view_lease_boundary_test.dart'
    show LeasePlatform, flushLease, leaseTestWidgets, leaseController;

Widget view(
  WeappContainerController controller,
  List<Object> errors,
  List<WeappViewDiagnostic> diagnostics, {
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
          onDiagnostic: diagnostics.add,
          onError: (error, stack) => errors.add(error),
        ),
      ),
    );

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
    'old lease cancellation remains attributed after same controller remount',
    (tester) async {
      controller = await leaseController(tester);
      final gate = Completer<void>();
      platform.foregroundGate = gate;
      final oldErrors = <Object>[], errors = <Object>[];
      final oldDiagnostics = <WeappViewDiagnostic>[],
          diagnostics = <WeappViewDiagnostic>[];
      await tester.pumpWidget(
        view(controller, oldErrors, oldDiagnostics, key: const ValueKey('old')),
      );
      await flushLease(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      await tester.pumpWidget(
        view(controller, errors, diagnostics, key: const ValueKey('new')),
      );
      await flushLease(tester);
      gate.completeError(
        PlatformException(
          code: 'ERR_CANCELLED',
          message: 'private://credential',
          details: {'secret': 'private-value'},
        ),
      );
      await flushLease(tester);
      expect(oldErrors, isEmpty);
      expect(errors, isEmpty);
      expect(oldDiagnostics, hasLength(1));
      expect(oldDiagnostics.single.operation, WeappViewOperation.foreground);
      expect(oldDiagnostics.single.retired, isTrue);
      expect(oldDiagnostics.single.code, 'ERR_CANCELLED');
      expect(
        jsonEncode(oldDiagnostics.single.toMap()),
        isNot(contains('credential')),
      );
      expect(
        jsonEncode(oldDiagnostics.single.toMap()),
        isNot(contains('private-value')),
      );
      expect(diagnostics, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
    },
  );
  leaseTestWidgets(
    'active chrome uncover cancellation has its actual operation and remains an error',
    (tester) async {
      controller = await leaseController(tester);
      final errors = <Object>[], diagnostics = <WeappViewDiagnostic>[];
      await tester.pumpWidget(
        view(controller, errors, diagnostics, occluded: true),
      );
      await flushLease(tester);
      final gate = Completer<void>();
      platform.uncoverGate = gate;
      await tester.pumpWidget(view(controller, errors, diagnostics));
      await flushLease(tester);
      expect(platform.uncoverGate, isNull, reason: platform.methods.toString());
      gate.completeError(
        PlatformException(
          code: 'ERR_CANCELLED',
          message: 'active uncover failed',
        ),
      );
      await flushLease(tester);
      expect(errors, hasLength(1));
      expect(diagnostics, hasLength(1));
      expect(diagnostics.single.operation, WeappViewOperation.uncover);
      expect(diagnostics.single.retired, isFalse);
      expect(diagnostics.single.nativeReason, 'unclassified');
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
    },
  );
  leaseTestWidgets(
    'failed old retirement stays failed and blocks the new active claim',
    (tester) async {
      controller = await leaseController(tester);
      final gate = Completer<void>();
      final oldErrors = <Object>[], errors = <Object>[];
      final oldDiagnostics = <WeappViewDiagnostic>[],
          diagnostics = <WeappViewDiagnostic>[];
      await tester.pumpWidget(
        view(controller, oldErrors, oldDiagnostics, key: const ValueKey('old')),
      );
      await flushLease(tester);
      platform.detachGate = gate;
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      await tester.pumpWidget(
        view(controller, errors, diagnostics, key: const ValueKey('new')),
      );
      await flushLease(tester);
      expect(platform.detachGate, isNull, reason: platform.methods.toString());
      gate.completeError(
        PlatformException(code: 'ERR_TEXTURE', message: 'failed cleanup'),
      );
      await flushLease(tester);
      expect(oldErrors, isEmpty);
      expect(
        oldDiagnostics.any(
          (item) =>
              item.operation == WeappViewOperation.detachTexture &&
              item.retired,
        ),
        isTrue,
      );
      expect(errors, isNotEmpty);
      expect(
        diagnostics.any(
          (item) =>
              item.operation == WeappViewOperation.claim &&
              !item.retired &&
              item.code == 'ERR_TEXTURE',
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
    },
  );
  leaseTestWidgets(
    'late native uncover failure survives retired waiter as diagnostic only',
    (tester) async {
      controller = await leaseController(tester);
      final errors = <Object>[], oldErrors = <Object>[];
      final diagnostics = <WeappViewDiagnostic>[],
          oldDiagnostics = <WeappViewDiagnostic>[];
      await tester.pumpWidget(
        view(
          controller,
          oldErrors,
          oldDiagnostics,
          key: const ValueKey('old'),
          occluded: true,
        ),
      );
      await flushLease(tester);
      final gate = Completer<void>();
      platform.uncoverGate = gate;
      await tester.pumpWidget(
        view(controller, oldErrors, oldDiagnostics, key: const ValueKey('old')),
      );
      await flushLease(tester);
      expect(platform.uncoverGate, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      await tester.pumpWidget(
        view(controller, errors, diagnostics, key: const ValueKey('new')),
      );
      await flushLease(tester);
      gate.completeError(
        PlatformException(
          code: 'ERR_CANCELLED',
          message: 'retired private native reply',
        ),
      );
      await flushLease(tester);
      expect(oldErrors, isEmpty);
      expect(errors, isEmpty);
      expect(oldDiagnostics, hasLength(1));
      expect(oldDiagnostics.single.operation, WeappViewOperation.uncover);
      expect(oldDiagnostics.single.retired, isTrue);
      expect(oldDiagnostics.single.toString(), isNot(contains('private')));
      expect(diagnostics, isEmpty);
    },
  );
  leaseTestWidgets(
    'callbacks captured on update remain usable after State disposal',
    (tester) async {
      controller = await leaseController(tester);
      final gate = Completer<void>();
      platform.foregroundGate = gate;
      final errors = <Object>[];
      final original = <WeappViewDiagnostic>[],
          updated = <WeappViewDiagnostic>[];
      await tester.pumpWidget(view(controller, errors, original));
      await flushLease(tester);
      await tester.pumpWidget(view(controller, errors, updated));
      await flushLease(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      gate.completeError(
        PlatformException(code: 'ERR_CANCELLED', message: 'retired foreground'),
      );
      await flushLease(tester);
      expect(errors, isEmpty);
      expect(original, isEmpty);
      expect(updated, hasLength(1));
      expect(updated.single.retired, isTrue);
    },
  );
  test(
      'native reason accepts only exact reviewed strings and never changes recovery',
      () {
    final diagnostic = WeappViewDiagnostic(
      operation: WeappViewOperation.hostLayout,
      viewLease: 1,
      operationSequence: 1,
      retired: false,
      error: PlatformException(
        code: 'ERR_CANCELLED',
        message: 'ERR_CANCELLED: no pending native layout observation',
      ),
    );
    expect(diagnostic.nativeReason, 'layout-no-pending-observation');
    final forged = WeappViewDiagnostic(
      operation: WeappViewOperation.hostLayout,
      viewLease: 1,
      operationSequence: 2,
      retired: false,
      error: PlatformException(
        code: 'ERR_CANCELLED',
        message: 'no pending native layout observation\nprivate-data',
      ),
    );
    expect(forged.nativeReason, 'unclassified');
    expect(forged.toString(), isNot(contains('private-data')));
  });
}
