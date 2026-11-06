import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container/src/host_layout.dart';

Map<String, Object?> observation(String sequence, {bool empty = true}) => {
      'schemaVersion': 1,
      'ownerId': '7',
      'surfaceGeneration': '5',
      'observationId': sequence,
      'windowMetrics': {
        'windowWidth': 390,
        'windowHeight': 700,
        'pixelRatio': 2.75,
        'screenWidth': 390,
        'screenHeight': 850,
        'statusBarHeight': 24.0,
        'screenTop': 68.0,
        'deviceOrientation': 'portrait',
      },
      // The native Rust serializer omits None rather than requiring JSON null.
      if (!empty) 'sessionId': 'session',
      if (!empty) 'pageId': 2,
    };

Map<String, Object?> state({bool empty = true}) => {
      'schemaVersion': 1,
      'ownerId': '7',
      'hostSurface': {'ownerId': '7', 'surfaceGeneration': '5'},
      'status': empty ? 'empty' : 'ready',
      'sessionId': empty ? null : 'session',
      'page': empty ? null : {'id': 2},
      'executionHealth': empty
          ? null
          : {
              'schemaVersion': 1,
              'requiresRestart': false,
              'appServiceFault': null,
              'viewFault': null,
              'navigationFault': null,
            },
      'acceptedPackIdentity': empty ? null : {'root': 'accepted'},
      'acceptedLayout': null,
      'pendingHostLayout': observation('11', empty: empty),
    };

void main() {
  test('actual Rust empty wire proves a strictly newer pre-session observation',
      () {
    final submitted = observation('10');
    expect(submitted.containsKey('sessionId'), isFalse);
    expect(submitted.containsKey('pageId'), isFalse);
    expect(supersededHostLayout(submitted, '17', state()), isTrue);
  });

  test('empty optional fields accept omission, explicit null and mixed wire',
      () {
    for (final field in [null, 'sessionId', 'pageId', 'both']) {
      final submitted = observation('10');
      final current = state();
      final pending = current['pendingHostLayout'] as Map;
      if (field == 'sessionId' || field == 'both') {
        submitted['sessionId'] = null;
        pending['sessionId'] = null;
      }
      if (field == 'pageId' || field == 'both') {
        submitted['pageId'] = null;
        pending['pageId'] = null;
      }
      expect(supersededHostLayout(submitted, '17', current), isTrue);
    }
  });

  test('typed empty requires every explicit top-level null field', () {
    for (final key in [
      'executionHealth',
      'sessionId',
      'page',
      'acceptedPackIdentity',
      'acceptedLayout'
    ]) {
      final missing = state()..remove(key);
      expect(supersededHostLayout(observation('10'), '17', missing), isFalse,
          reason: 'missing $key cannot prove an empty native owner');
      final present = state()..[key] = {'unexpected': true};
      expect(supersededHostLayout(observation('10'), '17', present), isFalse);
    }
    final activeWithoutHealth = state(empty: false)..['executionHealth'] = null;
    expect(
        supersededHostLayout(
            observation('10', empty: false), '17', activeWithoutHealth),
        isFalse);
    final contradictory = state()
      ..['executionHealth'] = state(empty: false)['executionHealth'];
    expect(
        supersededHostLayout(observation('10'), '17', contradictory), isFalse);
  });

  test('empty pending and submitted options cannot name an active guest', () {
    for (final field in ['sessionId', 'pageId']) {
      final submitted = observation('10')..[field] = 'guest';
      expect(supersededHostLayout(submitted, '17', state()), isFalse);
      final current = state();
      (current['pendingHostLayout'] as Map)[field] = 'guest';
      expect(supersededHostLayout(observation('10'), '17', current), isFalse);
    }
  });

  test('unknown, stale and foreign empty observations stay errors', () {
    for (final sequence in ['10', '9', '011', '18446744073709551616']) {
      final current = state()..['pendingHostLayout'] = observation(sequence);
      expect(supersededHostLayout(observation('10'), '17', current), isFalse);
    }
    for (final field in ['ownerId', 'surfaceGeneration', 'schemaVersion']) {
      final current = state();
      (current['pendingHostLayout'] as Map)[field] =
          field == 'schemaVersion' ? 2 : '8';
      expect(supersededHostLayout(observation('10'), '17', current), isFalse);
    }
    expect(
        supersededHostLayout(
            observation('10'), '17', state()..['pendingHostLayout'] = null),
        isFalse);
  });

  test('empty supersession requires complete finite native metrics', () {
    for (final metric in [
      'windowWidth',
      'windowHeight',
      'pixelRatio',
      'screenWidth',
      'screenHeight',
      'statusBarHeight',
      'screenTop',
      'deviceOrientation'
    ]) {
      final current = state();
      final pending = current['pendingHostLayout'] as Map;
      (pending['windowMetrics'] as Map).remove(metric);
      expect(supersededHostLayout(observation('10'), '17', current), isFalse);
    }
  });

  test('active owner still requires healthy typed execution state', () {
    final submitted = observation('10', empty: false);
    expect(supersededHostLayout(submitted, '17', state(empty: false)), isTrue);
    for (final field in [
      'appServiceFault',
      'viewFault',
      'navigationFault',
      'requiresRestart'
    ]) {
      final current = state(empty: false);
      (current['executionHealth'] as Map)[field] =
          field == 'requiresRestart' ? true : {'code': 'ERR_TIMEOUT'};
      expect(supersededHostLayout(submitted, '17', current), isFalse);
    }
    for (final status in ['closing', 'closed', 'unknown', null]) {
      final current = state(empty: false);
      if (status == null) {
        current.remove('status');
      } else {
        current['status'] = status;
      }
      expect(supersededHostLayout(submitted, '17', current), isFalse);
    }
  });

  test(
    'versioned local layout survives identity proof and validates geometry',
    () {
      Map<String, Object?> metrics() => {
        'windowWidth': 390,
        'windowHeight': 700,
        'hostLayout': {
          'version': 1,
          'safeInsets': <String, Object?>{'top': 0, 'right': 84, 'bottom': 34, 'left': 0},
          'verticalBarEdge': 'right',
          'reservedRegions': [
            {
              'id': 'occlusion:0',
              'kind': 'occlusion',
              'x': 306,
              'y': 0,
              'width': 84,
              'height': 174,
            },
          ],
        },
      };
      expect(validHostLayoutExtension(metrics()), isTrue);
      expect(
        validHostLayoutExtension({'windowWidth': 390, 'windowHeight': 700}),
        isTrue,
      );
      final submitted = observation('10');
      (submitted['windowMetrics'] as Map)['hostLayout'] =
          metrics()['hostLayout'];
      final current = state();
      final pendingMetrics =
          (current['pendingHostLayout'] as Map)['windowMetrics'] as Map;
      pendingMetrics['hostLayout'] = metrics()['hostLayout'];
      expect(supersededHostLayout(submitted, '17', current), isTrue);
      // A newer owner identity may omit the optional extension: omission clears
      // it, rather than making the queue retain the previous surface layout.
      pendingMetrics.remove('hostLayout');
      expect(supersededHostLayout(submitted, '17', current), isTrue);
      for (final field in [
        'version',
        'safeInsets',
        'verticalBarEdge',
        'reservedRegions',
      ]) {
        final invalid = metrics();
        (invalid['hostLayout'] as Map).remove(field);
        expect(validHostLayoutExtension(invalid), isFalse, reason: field);
        pendingMetrics['hostLayout'] = invalid['hostLayout'];
        expect(supersededHostLayout(submitted, '17', current), isFalse);
      }
      for (final value in [-1, double.nan, double.infinity, 391]) {
        final invalid = metrics();
        ((invalid['hostLayout'] as Map)['safeInsets'] as Map)['right'] = value;
        expect(validHostLayoutExtension(invalid), isFalse);
      }
      for (final field in ['id', 'kind', 'x', 'width']) {
        final invalid = metrics();
        final region =
            ((invalid['hostLayout'] as Map)['reservedRegions'] as List).first
                as Map;
        region[field] = {
          'id': '',
          'kind': 'unknown',
          'x': -1,
          'width': 500,
        }[field];
        expect(validHostLayoutExtension(invalid), isFalse);
      }
    },
  );
}
