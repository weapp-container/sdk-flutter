import 'dart:convert';

import 'package:flutter/services.dart';

import 'controller.dart';

/// The actual awaited View operation; never inferred from later native health.
enum WeappViewOperation {
  claim,
  foreground,
  chromeQueue,
  chromeReady,
  hostLayout,
  hostLayoutProof,
  hostChrome,
  nativeChrome,
  cover,
  uncover,
  metricsQueue,
  attachTexture,
  resizeTexture,
  detachPlatformView,
  detachTexture,
  input,
}

/// An allowlisted diagnostic. It contains no raw error message, details, stack,
/// geometry payload, credential, path, URI or application data.
class WeappViewDiagnostic {
  WeappViewDiagnostic({
    required this.operation,
    required this.viewLease,
    required this.operationSequence,
    required this.retired,
    required Object error,
  })  : code = _code(error),
        nativeReason = _reason(error);

  final WeappViewOperation operation;
  final int viewLease;
  final int operationSequence;
  final bool retired;
  final String? code;
  final String nativeReason;

  static String? _code(Object error) {
    final value = error is PlatformException
        ? error.code
        : error is WeappHostError
            ? error.code
            : null;
    return value != null && RegExp(r'^ERR_[A-Z0-9_]{1,48}$').hasMatch(value)
        ? value
        : null;
  }

  static String _reason(Object error) {
    if (error is! PlatformException) return 'unclassified';
    const known = {
      'no pending native layout observation': 'layout-no-pending-observation',
      'layout does not match the exact native observation and page owner':
          'layout-observation-superseded',
      'host layout surface owner changed': 'layout-surface-owner-changed',
      'stale complete host layout revision': 'layout-stale-revision',
      'Chrome owner retired before native measurement':
          'layout-native-owner-retired',
    };
    if (_code(error) != 'ERR_CANCELLED') return 'unclassified';
    for (final item in known.entries) {
      if (error.message == item.key ||
          error.message == '${error.code}: ${item.key}') return item.value;
    }
    return 'unclassified';
  }

  Map<String, Object?> toMap() => {
        'schemaVersion': 1,
        'operation': operation.name,
        'viewLease': viewLease.toString(),
        'operationSequence': operationSequence.toString(),
        'retired': retired,
        'code': code,
        'nativeReason': nativeReason,
      };

  @override
  String toString() => jsonEncode(toMap());
}
