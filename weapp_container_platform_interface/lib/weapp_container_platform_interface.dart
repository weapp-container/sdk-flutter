import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Internal transport shared by all federated native implementations.
/// Payloads contain JSON values; native pointers and image bytes never cross it.
abstract class WeappContainerPlatform {
  static WeappContainerPlatform instance = MethodChannelWeappContainer();
  Stream<Map<String, Object?>> get events;
  Future<void> initialize();
  Future<T?> invoke<T>(String method, Map<String, Object?> arguments);
}

class MethodChannelWeappContainer extends WeappContainerPlatform {
  MethodChannelWeappContainer({
    MethodChannel methods = const MethodChannel('dev.weapp.container/methods'),
    EventChannel events = const EventChannel('dev.weapp.container/events'),
    bool? jsonByteTransport,
  }) : _methods = methods,
       _eventChannel = events,
       _jsonByteTransport =
           jsonByteTransport ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux);
  final MethodChannel _methods;
  final EventChannel _eventChannel;
  // Flutter Linux's FlValue strings use NUL termination. A UTF-8 JSON byte
  // envelope preserves arbitrary JSON strings across that native boundary.
  final bool _jsonByteTransport;
  // A hot reload keeps this value. A hot restart creates a new isolate/epoch.
  static final String _epoch =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  final _events = StreamController<Map<String, Object?>>.broadcast();
  StreamSubscription<Object?>? _subscription;
  Future<void>? _initializing;
  @override
  Stream<Map<String, Object?>> get events => _events.stream;
  @override
  Future<void> initialize() => _initializing ??= _initialize();
  Future<void> _initialize() async {
    _subscription ??= _eventChannel
        .receiveBroadcastStream()
        .map((value) => Map<String, Object?>.from(_decode(value) as Map))
        .listen(_events.add, onError: _events.addError);
    try {
      await invoke<void>('initialize', {'clientEpoch': _epoch});
    } catch (_) {
      _initializing = null;
      rethrow;
    }
  }

  @override
  Future<T?> invoke<T>(String method, Map<String, Object?> arguments) async {
    final result = await _methods.invokeMethod<Object?>(
      method,
      _jsonByteTransport
          ? Uint8List.fromList(utf8.encode(jsonEncode(arguments)))
          : arguments,
    );
    return _decode(result) as T?;
  }

  Object? _decode(Object? value) => _jsonByteTransport && value != null
      ? jsonDecode(utf8.decode(value as Uint8List))
      : value;
}
