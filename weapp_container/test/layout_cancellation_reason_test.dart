import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container/src/view_diagnostic.dart';

WeappViewDiagnostic diagnostic(Object error) => WeappViewDiagnostic(
      operation: WeappViewOperation.hostLayout,
      viewLease: 2,
      operationSequence: 3,
      retired: false,
      error: error,
    );

void main() {
  final fixture = jsonDecode(
      File('test/fixtures/ios-layout-cancellation-v1.json')
          .readAsStringSync()) as Map<String, dynamic>;
  final contracts = fixture['contracts'] as List<dynamic>;
  for (final raw in contracts) {
    final contract = raw as Map<String, dynamic>;
    final error = contract['error'] as Map<String, dynamic>;
    test('exact Swift gate wire cancellation: ${contract['reason']}', () {
      final result = diagnostic(PlatformException(
        code: error['code'] as String,
        message: error['message'] as String,
        details: error['details'],
      ));
      expect(result.code, 'ERR_CANCELLED');
      expect(result.nativeReason, contract['reason']);
      expect(result.retired, false);
      expect(result.toMap(), {
        'schemaVersion': 1,
        'operation': 'hostLayout',
        'viewLease': '2',
        'operationSequence': '3',
        'retired': false,
        'code': 'ERR_CANCELLED',
        'nativeReason': contract['reason'],
      });
    });
  }
  test('invalid typed envelope cannot downgrade to known Android message', () {
    final reason = contracts.first['reason'];
    final invalid = <Object?>[
      {},
      {'schemaVersion': 1},
      {'reason': reason},
      {'schemaVersion': true, 'reason': reason},
      {'schemaVersion': 1.0, 'reason': reason},
      {'schemaVersion': '1', 'reason': reason},
      {'schemaVersion': 2, 'reason': reason},
      {'schemaVersion': 1, 'reason': null},
      {'schemaVersion': 1, 'reason': 1},
      {'schemaVersion': 1, 'reason': 'unclassified'},
      {'schemaVersion': 1, 'reason': 'layout-native-owner-retired'},
      {'schemaVersion': 1, 'reason': 'layout-measurement-made-up'},
      {'schemaVersion': 1, 'reason': '$reason\nprivate-raw-data'},
      {'schemaVersion': 1, 'reason': reason, 'private': 'private-raw-data'},
      {'schemaVersion': 1, 'reason': reason, 9: 'private-raw-data'},
      [1, reason],
      'private-raw-data',
    ];
    for (final value in invalid) {
      final result = diagnostic(PlatformException(
        code: 'ERR_CANCELLED',
        message: 'no pending native layout observation',
        details: value,
      ));
      expect(result.nativeReason, 'unclassified', reason: '$value');
      expect(result.toString(), isNot(contains('private-raw-data')));
    }
  });
  test('typed reason requires cancellation code and is independent of message',
      () {
    final reason = contracts.first['reason'];
    for (final code in ['ERR_ENGINE', 'ERR_NOT_READY', 'ERR_TIMEOUT']) {
      final result = diagnostic(PlatformException(
        code: code,
        message: 'private-raw-data',
        details: {'schemaVersion': 1, 'reason': reason},
      ));
      expect(result.nativeReason, 'unclassified');
      expect(result.toString(), isNot(contains('private-raw-data')));
    }
    final result = diagnostic(PlatformException(
      code: 'ERR_CANCELLED',
      message: 'private-raw-data',
      details: {'schemaVersion': 1, 'reason': reason},
    ));
    expect(result.nativeReason, reason);
    expect(result.toString(), isNot(contains('private-raw-data')));
  });
  test('null details preserve old Android exact-message fallback', () {
    for (final message in [
      'no pending native layout observation',
      'ERR_CANCELLED: no pending native layout observation',
    ]) {
      expect(
          diagnostic(PlatformException(code: 'ERR_CANCELLED', message: message))
              .nativeReason,
          'layout-no-pending-observation');
    }
    expect(
        diagnostic(PlatformException(
          code: 'ERR_CANCELLED',
          message:
              'Native layout measurement was superseded or its owner retired',
        )).nativeReason,
        'unclassified');
  });
}
