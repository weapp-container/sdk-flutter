import 'dart:async';
import 'dart:collection';

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
  List<WeappViewFailure> failures,
  List<Object> legacy,
  void Function(WeappViewDiagnostic) diagnostic, {
  Key? key,
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 300,
        height: 400,
        child: WeappContainerView(
          key: key,
          controller: controller,
          onDiagnostic: diagnostic,
          onFailure: failures.add,
          onError: (error, _) => legacy.add(error),
        ),
      ),
    );

class ThrowingReasonDetails extends MapBase<String, Object?> {
  @override
  Object? operator [](Object? key) => null;
  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('private');
  @override
  void clear() => throw UnsupportedError('private');
  @override
  Iterable<String> get keys => throw StateError('private diagnostic details');
  @override
  Object? remove(Object? key) => throw UnsupportedError('private');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late LeasePlatform platform;
  setUp(() {
    platform = LeasePlatform();
    WeappContainerPlatform.instance = platform;
  });
  tearDown(() async {
    await platform.source.close();
    debugDefaultTargetPlatformOverride = null;
  });
  for (final throws in [false, true]) {
    leaseTestWidgets(
      'active failure carries the same original diagnostic; observer throws=$throws',
      (tester) async {
        final controller = await leaseController(tester);
        final gate = Completer<void>();
        platform.foregroundGate = gate;
        final failures = <WeappViewFailure>[],
            legacy = <Object>[],
            diagnostics = <WeappViewDiagnostic>[];
        await tester.pumpWidget(
          view(controller, failures, legacy, (d) {
            diagnostics.add(d);
            if (throws) throw StateError('private observer error');
          }),
        );
        await flushLease(tester);
        final original = PlatformException(
          code: 'ERR_CANCELLED',
          message: 'private original',
        );
        final stack = StackTrace.fromString('original native stack');
        gate.completeError(original, stack);
        await flushLease(tester);
        expect(failures, hasLength(1));
        expect(legacy, isEmpty);
        final failure = failures.single;
        expect(failure.error, same(original));
        expect(failure.stackTrace, same(stack));
        expect(failure.diagnostic, same(diagnostics.single));
        expect(failure.diagnostic.operation, WeappViewOperation.foreground);
        expect(failure.diagnostic.retired, false);
        expect(failure.disposition, 'active-error');
        expect(failure.proofOutcome, WeappViewFailureProof.notRequested);
        await tester.pumpWidget(const SizedBox.shrink());
        await flushLease(tester);
      },
    );
  }
  leaseTestWidgets(
    'diagnostic projection failure preserves exact attempt and readable error code',
    (tester) async {
      final controller = await leaseController(tester);
      final gate = Completer<void>();
      platform.foregroundGate = gate;
      final failures = <WeappViewFailure>[],
          legacy = <Object>[],
          diagnostics = <WeappViewDiagnostic>[];
      await tester
          .pumpWidget(view(controller, failures, legacy, diagnostics.add));
      await flushLease(tester);
      final original = PlatformException(
          code: 'ERR_CANCELLED', details: ThrowingReasonDetails());
      final stack = StackTrace.fromString('private original stack');
      gate.completeError(original, stack);
      await flushLease(tester);
      expect(failures, hasLength(1));
      expect(legacy, isEmpty);
      expect(diagnostics, isEmpty);
      expect(failures.single.error, same(original));
      expect(failures.single.stackTrace, same(stack));
      expect(
          failures.single.diagnostic.operation, WeappViewOperation.foreground);
      expect(failures.single.diagnostic.code, 'ERR_CANCELLED');
      expect(failures.single.diagnostic.nativeReason, 'unclassified');
      expect(failures.single.diagnostic.retired, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
    },
  );

  leaseTestWidgets(
    'retired completion never invokes the active failure handler',
    (tester) async {
      final controller = await leaseController(tester);
      final gate = Completer<void>();
      platform.foregroundGate = gate;
      final failures = <WeappViewFailure>[],
          legacy = <Object>[],
          diagnostics = <WeappViewDiagnostic>[];
      await tester.pumpWidget(
        view(controller, failures, legacy, diagnostics.add),
      );
      await flushLease(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      gate.completeError(PlatformException(code: 'ERR_CANCELLED'));
      await flushLease(tester);
      expect(failures, isEmpty);
      expect(legacy, isEmpty);
      expect(diagnostics.single.retired, true);
    },
  );
}
