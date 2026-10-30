import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container/weapp_container.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';
import 'controller_test.dart'
    show
        FakePlatform,
        atomicController,
        atomicTestWidgets,
        atomicObservation,
        atomicGeometry,
        atomicState,
        flushChrome;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePlatform platform;
  setUp(() {
    platform = FakePlatform();
    WeappContainerPlatform.instance = platform;
  });
  tearDown(() => platform.source.close());
  for (final proof in ['superseded', 'notSuperseded', 'unavailable']) {
    atomicTestWidgets('layout delivery preserves this exact proof: $proof',
        (tester) async {
      final controller = await atomicController(tester);
      final observation = atomicObservation();
      platform.cancelLayout = true;
      platform.currentState = proof == 'superseded'
          ? atomicState(pending: '11')
          : atomicState(pending: '10', accepted: '9');
      if (proof == 'unavailable')
        platform.stateFailure =
            PlatformException(code: 'ERR_STATE_UNAVAILABLE');
      final failures = <WeappViewFailure>[],
          diagnostics = <WeappViewDiagnostic>[],
          legacy = <Object>[];
      platform.emit(controller.id,
          {'type': 'hostLayoutObservation', 'observation': observation});
      await tester.pumpWidget(Directionality(
          textDirection: TextDirection.ltr,
          child: SizedBox(
              width: 390,
              height: 700,
              child: WeappContainerView(
                  controller: controller,
                  hostChrome: atomicGeometry(),
                  hostLayoutObservation: observation,
                  onDiagnostic: diagnostics.add,
                  onFailure: failures.add,
                  onError: (error, _) => legacy.add(error)))));
      await flushChrome(tester);
      expect(legacy, isEmpty);
      if (proof == 'superseded') {
        expect(failures, isEmpty);
        expect(
            diagnostics
                .where((d) => d.operation == WeappViewOperation.hostLayout),
            hasLength(1));
      } else {
        expect(failures, hasLength(1));
        final failure = failures.single;
        expect(failure.diagnostic.operation, WeappViewOperation.hostLayout);
        expect(failure.diagnostic, same(diagnostics.last));
        expect(
            failure.error,
            isA<PlatformException>()
                .having((e) => e.code, 'code', 'ERR_CANCELLED'));
        expect(
            failure.proofOutcome,
            proof == 'unavailable'
                ? WeappViewFailureProof.unavailable
                : WeappViewFailureProof.notSuperseded);
        if (proof == 'unavailable') {
          expect(
              diagnostics.first.operation, WeappViewOperation.hostLayoutProof);
          expect(diagnostics.first.code, 'ERR_STATE_UNAVAILABLE');
          expect(diagnostics.last.code, 'ERR_CANCELLED');
        }
      }
    });
  }
}
