import 'dart:async';
import 'package:flutter/services.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';

class WeappContainerEvent {
  WeappContainerEvent(Map<String, Object?> fields)
      : fields = Map.unmodifiable(fields);
  final Map<String, Object?> fields;
  String get type => fields['type'] as String;
  Object? get message => fields['message'];
}

class WeappHostError implements Exception {
  const WeappHostError(this.code, this.message, {this.retryable = false});
  final String code;
  final String message;
  final bool retryable;
  Map<String, Object?> toMap() =>
      {'code': code, 'message': message, 'retryable': retryable};
}

class WeappCancellationToken {
  bool _cancelled = false;
  final _signal = Completer<void>();
  bool get isCancelled => _cancelled;
  Future<void> get whenCancelled => _signal.future;
  void _cancel() {
    if (!_cancelled) {
      _cancelled = true;
      _signal.complete();
    }
  }

  void throwIfCancelled() {
    if (_cancelled)
      throw const WeappHostError('cancelled', 'Host call cancelled');
  }
}

class WeappHostCall {
  WeappHostCall._(
      this.id, this.method, this.payload, this.deadlineNs, this.cancellation);
  final String id;
  final String method;
  final Object? payload;
  final int? deadlineNs;
  final WeappCancellationToken cancellation;
}

typedef WeappHostMethod = FutureOr<Object?> Function(WeappHostCall call);

/// Own a session independently of its widget. Explicitly await close() to persist
/// storage and release native resources. Detaching a widget keeps its JS isolate.
class WeappContainerController {
  WeappContainerController._(this.id, this._platform) {
    _subscription =
        _platform.events.where((value) => value['id'] == id).listen((value) {
      final event =
          WeappContainerEvent(Map<String, Object?>.from(value['event'] as Map));
      if (event.type == 'hostCall') {
        unawaited(_hostCall(event.fields));
      } else if (event.type == 'hostCallCancelled') {
        _calls.remove(event.fields['callId'])?.cancellation._cancel();
      }
      _events.add(event);
    }, onError: _events.addError);
  }
  static Future<WeappContainerController> create(
      {required String? storageKey,
      bool? gpuRequired,
      bool? devDiagnostics}) async {
    if (storageKey != null && storageKey.trim().isEmpty)
      throw ArgumentError.value(
          storageKey, 'storageKey', 'Must be nonblank, or null for memory');
    final platform = WeappContainerPlatform.instance;
    await platform.initialize();
    final result = await platform.invoke<Map>('create', {
      'storageKey': storageKey,
      if (gpuRequired != null) 'gpuRequired': gpuRequired,
      if (devDiagnostics != null) 'devDiagnostics': devDiagnostics,
    });
    return WeappContainerController._(result!['id'] as int, platform);
  }

  final int id;
  final WeappContainerPlatform _platform;
  final _events = StreamController<WeappContainerEvent>.broadcast();
  final _methods = <String, WeappHostMethod>{};
  final _calls = <String, WeappHostCall>{};
  late final StreamSubscription<Map<String, Object?>> _subscription;
  Future<void>? _closing;
  bool _closed = false;
  bool _loadRequested = false;
  Object? _viewOwner;
  Future<void> _retirement = Future.value();
  Stream<WeappContainerEvent> get events => _events.stream;
  bool get isClosed => _closed;

  Future<T?> _invoke<T>(String method,
      [Map<String, Object?> arguments = const {}]) {
    if (_closed || _closing != null)
      return Future.error(StateError('Session is closing or closed'));
    return _platform.invoke<T>(method, {'id': id, ...arguments});
  }

  Future<void> registerHostMethod(String name, WeappHostMethod method) async {
    if (_loadRequested)
      throw StateError('Register host methods before the first load');
    if (name.isEmpty || name.startsWith('wx.'))
      throw ArgumentError.value(name, 'name');
    await _invoke<void>('registerHostMethod', {'name': name});
    _methods[name] = method;
  }

  Future<void> load(String packPath,
      {String? route, Map<String, Object?> options = const {}}) {
    _loadRequested = true;
    return _invoke<void>('load', {
      'packPath': packPath,
      if (route != null) 'route': route,
      'options': options
    });
  }

  /// Apply a verified immutable development pack. A returned startup/frame
  /// result is separate from the native GPU presentation receipt.
  Future<Map<String, Object?>> applyDevPack(String packPath,
      {String? route, Map<String, Object?> options = const {}}) async {
    _loadRequested = true;
    return Map<String, Object?>.from((await _invoke<Map>('applyDevPack', {
      'packPath': packPath,
      if (route != null) 'route': route,
      'options': options,
    }))!);
  }

  Future<Map<String, Object?>> devState() async =>
      Map<String, Object?>.from((await _invoke<Map>('devState'))!);

  /// Clear and flush this project's wx storage; page memory is unchanged.
  Future<void> clearDevStorage() => _invoke<void>('clearDevStorage');

  Future<void> navigate(String route,
          {Map<String, Object?> query = const {}, bool replace = false}) =>
      _invoke<void>(
          'navigate', {'route': route, 'query': query, 'replace': replace});
  Future<void> back() => _invoke<void>('back');
  Future<void> sendMessage(Object? message) =>
      _invoke<void>('sendMessage', {'message': message});
  Future<void> setForeground(bool foreground) =>
      _invoke<void>('setForeground', {'foreground': foreground});
  Future<void> flushStorage() => _invoke<void>('flushStorage');
  Future<Map<String, Object?>> state() async =>
      Map<String, Object?>.from((await _invoke<Map>('state'))!);
  Future<Map<String, Object?>> capabilities() async =>
      Map<String, Object?>.from((await _invoke<Map>('capabilities'))!);
  Future<void> close() {
    if (_closed) return Future.value();
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      await _platform.invoke<void>('close', {'id': id});
      _closed = true;
      for (final call in _calls.values) {
        call.cancellation._cancel();
      }
      _calls.clear();
      await _subscription.cancel();
      await _events.close();
    } catch (_) {
      _closing = null;
      rethrow;
    }
  }

  Future<void> _hostCall(Map<String, Object?> event) async {
    final callId = event['callId'] as String;
    final call = WeappHostCall._(
        callId,
        event['method'] as String,
        event['payload'],
        (event['deadlineNs'] as num?)?.toInt(),
        WeappCancellationToken());
    _calls[callId] = call;
    Map<String, Object?> completion;
    try {
      final method = _methods[call.method];
      if (method == null)
        throw const WeappHostError(
            'unsupported', 'Host method is not registered');
      completion = {'result': await method(call)};
    } catch (error) {
      final failure = error is WeappHostError
          ? error
          : WeappHostError('invalid_request', error.toString());
      completion = {'error': failure.toMap()};
    }
    if (_calls.remove(callId) != call ||
        call.cancellation.isCancelled ||
        _closed ||
        _closing != null) return;
    try {
      await _invoke<void>(
          'completeHostCall', {'callId': callId, ...completion});
    } on PlatformException catch (error, stack) {
      // Native cancellation can win after the Dart handler has completed.
      if (error.code != 'cancelled' &&
          error.code != 'ERR_STALE_CALL' &&
          !_closed) _events.addError(error, stack);
    } catch (error, stack) {
      if (!_closed) _events.addError(error, stack);
    }
  }

  // Package implementation hooks; host applications use WeappContainerView.
  Future<void> claimView(Object owner) {
    if (_viewOwner != null && !identical(_viewOwner, owner))
      throw StateError('A session supports one attached widget');
    _viewOwner = owner;
    return _retirement;
  }

  void releaseView(Object owner, Future<void> retired) {
    if (identical(_viewOwner, owner)) {
      _retirement = retired;
      _viewOwner = null;
    }
  }

  Future<int> attachTexture(Map<String, Object?> metrics) async =>
      (await _invoke<Map>('attach', metrics))!['textureId'] as int;
  Future<void> resizeTexture(Map<String, Object?> metrics) =>
      _invoke<void>('resize', metrics);
  Future<void> detachPlatformView() => _closed
      ? Future.value()
      : _platform.invoke<void>('detachView', {'id': id});
  Future<void> detachTexture() =>
      _closed ? Future.value() : _platform.invoke<void>('detach', {'id': id});
  Future<void> sendInput(List<Map<String, Object?>> events) =>
      _invoke<void>('input', {'events': events});
}
