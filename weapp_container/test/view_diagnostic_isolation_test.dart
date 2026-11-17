import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container/weapp_container.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';

import 'controller_test.dart' as fixtures;
import 'view_lease_boundary_test.dart'
    show LeasePlatform, flushLease, leaseController, leaseTestWidgets;

class ThrowingDiagnosticCode extends PlatformException {
  ThrowingDiagnosticCode()
      : super(
          code: 'ERR_ENGINE',
          message: 'private-native-message',
          details: {'secret': 'private-native-details'},
        );
  @override
  String get code => throw StateError('private-diagnostic-construction');
}

Widget isolationView(
  WeappContainerController controller, {
  Key? key,
  required void Function(Object, StackTrace) onError,
  required ValueChanged<WeappViewDiagnostic> onDiagnostic,
  bool occluded = false,
  bool prepareOnly = false,
  Map<String, Object?>? observation,
  Map<String, Object?>? geometry,
  ValueChanged<int>? onApplied,
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: SizedBox(
        width: 390,
        height: 700,
        child: WeappContainerView(
          key: key,
          controller: controller,
          occluded: occluded,
          prepareOnly: prepareOnly,
          hostLayoutObservation: observation,
          hostChrome: geometry,
          onHostChromeApplied: onApplied,
          onError: onError,
          onDiagnostic: onDiagnostic,
        ),
      ),
    );

List<String> captureControlledFallback({bool throwOnFallback = false}) {
  final records = <String>[];
  final original = debugPrint;
  debugPrint = (message, {wrapWidth}) {
    if (message != null &&
        message.startsWith('weapp_container.view_diagnostic_failure ')) {
      records.add(message);
      if (throwOnFallback) throw StateError('private-fallback-sink');
    } else {
      original(message, wrapWidth: wrapWidth);
    }
  };
  return records;
}

void verifyFallback(List<String> records, int count) {
  expect(records, hasLength(count));
  for (final record in records) {
    final payload = jsonDecode(
      record.substring('weapp_container.view_diagnostic_failure '.length),
    ) as Map;
    expect(payload.keys.toSet(), {
      'schemaVersion',
      'code',
      'operation',
      'viewLease',
      'operationSequence',
      'retired',
    });
    expect(payload['code'], 'ERR_DIAGNOSTIC_SINK');
    expect(payload['viewLease'], matches(RegExp(r'^[0-9]+$')));
    expect(payload['operationSequence'], matches(RegExp(r'^[0-9]+$')));
    expect(record, isNot(contains('private')));
    expect(record, isNot(contains('original-stack')));
  }
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
  });

  for (final failFallback in [false, true]) {
    leaseTestWidgets(
      'throwing active diagnostic preserves original onError and stack; fallback throws=$failFallback',
      (tester) async {
        final controller = await leaseController(tester);
        final gate = Completer<void>();
        platform.foregroundGate = gate;
        final errors = <(Object, StackTrace)>[];
        final records = captureControlledFallback(
          throwOnFallback: failFallback,
        );
        final failure = PlatformException(
          code: 'ERR_CANCELLED',
          message: 'private-original-message',
          details: {'secret': 'private-original-details'},
        );
        final stack = StackTrace.fromString('private-original-stack');
        await tester.pumpWidget(
          isolationView(
            controller,
            onError: (error, stack) => errors.add((error, stack)),
            onDiagnostic: (_) => throw StateError('private-active-sink'),
          ),
        );
        await flushLease(tester);
        gate.completeError(failure, stack);
        await flushLease(tester);
        expect(errors, hasLength(1));
        expect(identical(errors.single.$1, failure), isTrue);
        expect(errors.single.$2.toString(), stack.toString());
        verifyFallback(records, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  leaseTestWidgets(
    'throwing retired diagnostic never creates an unhandled Future or reaches replacement onError',
    (tester) async {
      final controller = await leaseController(tester);
      final gate = Completer<void>();
      platform.foregroundGate = gate;
      final errors = <Object>[], currentErrors = <Object>[];
      final replacementDiagnostics = <WeappViewDiagnostic>[];
      final records = captureControlledFallback();
      await tester.pumpWidget(
        isolationView(
          controller,
          key: const ValueKey('old'),
          onError: (error, _) => errors.add(error),
          onDiagnostic: (_) => throw StateError('private-retired-sink'),
        ),
      );
      await flushLease(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await flushLease(tester);
      await tester.pumpWidget(
        isolationView(
          controller,
          key: const ValueKey('new'),
          onError: (error, _) => currentErrors.add(error),
          onDiagnostic: replacementDiagnostics.add,
        ),
      );
      await flushLease(tester);
      gate.completeError(
        PlatformException(
          code: 'ERR_CANCELLED',
          message: 'private-retired-native',
        ),
      );
      await flushLease(tester);
      expect(errors, isEmpty);
      expect(currentErrors, isEmpty);
      expect(replacementDiagnostics, isEmpty);
      verifyFallback(records, 1);
      expect(
        jsonDecode(
          records.single.substring(
            'weapp_container.view_diagnostic_failure '.length,
          ),
        )['retired'],
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  leaseTestWidgets(
    'diagnostic construction failure cannot replace the original error object or stack',
    (tester) async {
      final controller = await leaseController(tester);
      final gate = Completer<void>();
      platform.foregroundGate = gate;
      final errors = <(Object, StackTrace)>[];
      var sinkCalls = 0;
      final records = captureControlledFallback();
      final failure = ThrowingDiagnosticCode();
      final stack = StackTrace.fromString('private-original-stack');
      await tester.pumpWidget(
        isolationView(
          controller,
          onError: (error, stack) => errors.add((error, stack)),
          onDiagnostic: (_) {
            sinkCalls++;
          },
        ),
      );
      await flushLease(tester);
      gate.completeError(failure, stack);
      await flushLease(tester);
      expect(errors, hasLength(1));
      expect(identical(errors.single.$1, failure), isTrue);
      expect(errors.single.$2.toString(), stack.toString());
      expect(sinkCalls, 0);
      verifyFallback(records, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final proofFails in [false, true]) {
    leaseTestWidgets(
      'throwing diagnostic does not alter ${proofFails ? 'failed proof original cancellation' : 'proven supersession'} or later recovery',
      (tester) async {
        final native = fixtures.FakePlatform();
        WeappContainerPlatform.instance = native;
        addTearDown(() => native.source.close());
        final controller = await leaseController(
          tester,
          atomicHostLayout: true,
        );
        final errors = <Object>[], acknowledgements = <int>[];
        final operations = <WeappViewOperation>[];
        final records = captureControlledFallback();
        Widget measured(
          Map<String, Object?> observation,
          Map<String, Object?> geometry, {
          bool covered = false,
          bool prepareOnly = false,
        }) {
          native.emit(controller.id, {
            'type': 'hostLayoutObservation',
            'observation': observation,
          });
          return isolationView(
            controller,
            observation: observation,
            geometry: geometry,
            occluded: covered,
            prepareOnly: prepareOnly,
            onError: (error, _) => errors.add(error),
            onApplied: acknowledgements.add,
            onDiagnostic: (diagnostic) {
              operations.add(diagnostic.operation);
              throw StateError('private-proof-sink');
            },
          );
        }

        final observation = fixtures.atomicObservation(),
            geometry = fixtures.atomicGeometry();
        await tester.pumpWidget(
          measured(observation, geometry, covered: true, prepareOnly: true),
        );
        await flushLease(tester);
        final baseline = native.requests.length;
        native.cancelLayout = true;
        native.currentState = fixtures.atomicState();
        if (proofFails)
          native.stateFailure = PlatformException(
            code: 'ERR_ENGINE',
            message: 'private-proof-failure',
          );
        await tester.pumpWidget(measured(observation, geometry));
        await flushLease(tester);
        expect(
          native.requests.skip(baseline).where((item) => item.$1 == 'state'),
          hasLength(1),
        );
        expect(acknowledgements, isEmpty);
        expect(
          native.requests
              .skip(baseline)
              .where((item) => item.$1 == 'setPreviewOccluded'),
          isEmpty,
        );
        if (proofFails) {
          expect(errors, hasLength(1));
          expect(
            errors.single,
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'ERR_CANCELLED',
            ),
          );
          expect(operations, [
            WeappViewOperation.hostLayoutProof,
            WeappViewOperation.hostLayout,
          ]);
        } else {
          expect(errors, isEmpty);
          expect(operations, [WeappViewOperation.hostLayout]);
        }
        verifyFallback(records, proofFails ? 2 : 1);
        native.cancelLayout = false;
        native.stateFailure = null;
        await tester.pumpWidget(
          measured(
            fixtures.atomicObservation(sequence: '11'),
            fixtures.atomicGeometry(revision: 18),
          ),
        );
        await flushLease(tester);
        expect(acknowledgements, [18]);
        expect(
          native.requests
              .skip(baseline)
              .where((item) => item.$1 == 'setPreviewOccluded')
              .single
              .$2['occluded'],
          false,
        );
        expect(errors, hasLength(proofFails ? 1 : 0));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
