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

  /// A failed optional projection must preserve a readable original code,
  /// without evaluating message/details again or replacing the original error.
  WeappViewDiagnostic.unavailable({
    required this.operation,
    required this.viewLease,
    required this.operationSequence,
    required this.retired,
    required Object error,
  })  : code = _availableCode(error),
        nativeReason = 'unclassified';

  static String? _availableCode(Object error) {
    try {
      return _code(error);
    } catch (_) {
      return null;
    }
  }

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
    final details = error.details;
    if (details != null) {
      // A malformed supplied envelope never downgrades to message inference.
      const typedReasons = {
        'layout-measurement-task-cancelled',
        'layout-measurement-engine-detached',
        'layout-measurement-engine-initializing',
        'layout-measurement-entry-closing',
        'layout-measurement-view-retiring',
        'layout-measurement-lifetime-changed',
        'layout-measurement-entry-removed',
        'layout-measurement-restart-receipt-mismatch',
        'layout-measurement-observation-superseded',
      };
      if (details is Map &&
          details.length == 2 &&
          details.containsKey('schemaVersion') &&
          details['schemaVersion'] is int &&
          details['schemaVersion'] == 1 &&
          details.containsKey('reason') &&
          details['reason'] is String &&
          typedReasons.contains(details['reason'])) {
        return details['reason'] as String;
      }
      return 'unclassified';
    }
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

/// The original active error and the exact immutable operation that delivered it.
/// This handler value is never serialized; only [diagnostic] has a safe wire form.
/// A diagnostic observer may fail without replacing this original error.
class WeappViewFailure {
  WeappViewFailure({
    required this.error,
    required this.stackTrace,
    required this.diagnostic,
    this.proofOutcome = WeappViewFailureProof.notRequested,
  });

  final Object error;
  final StackTrace stackTrace;
  final WeappViewDiagnostic diagnostic;
  final WeappViewFailureProof proofOutcome;
  String get disposition => 'active-error';
}

/// Outcome of this operation's own cancellation proof, never a later health read.
enum WeappViewFailureProof { notRequested, unavailable, notSuperseded }
