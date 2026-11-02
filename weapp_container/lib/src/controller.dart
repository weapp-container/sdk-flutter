import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';
import 'host_layout.dart';

class WeappContainerEvent {
  WeappContainerEvent(Map<String, Object?> fields)
      : fields = Map.unmodifiable(fields);
  final Map<String, Object?> fields;
  String get type => fields['type'] as String;
  Object? get message => fields['message'];
}

class WeappHostError implements Exception {
  const WeappHostError(this.code, this.message,
      {this.retryable = false, this.details = const {}});
  final String code;
  final String message;
  final bool retryable;
  final Map<String, Object?> details;
  Map<String, Object?> toMap() => {
        'code': code,
        'message': message,
        'retryable': retryable,
        'details': details
      };
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
  WeappHostCall._(this.id, this.method, this.payload, this.deadlineNsDecimal,
      this.cancellation, this.context, this.cancelToken);
  final String id;
  final String method;
  final Object? payload;

  /// Exact unsigned native monotonic deadline.
  final String? deadlineNsDecimal;
  int? get deadlineNs =>
      deadlineNsDecimal == null ? null : int.tryParse(deadlineNsDecimal!);
  final WeappCancellationToken cancellation;

  /// Original native call identity survives transport ID remapping.
  final Map<String, Object?>? context;
  final String? cancelToken;
}

typedef WeappHostMethod = FutureOr<Object?> Function(WeappHostCall call);
typedef WeappAccountCleanup = FutureOr<void> Function(
    String operationId, WeappCancellationToken cancellation);

/// Capture from native state before asynchronous snapshot work begins.
/// This owner context does not require a pending API call.
class WeappHostSnapshotContext {
  WeappHostSnapshotContext(
      {required Map<String, Object?> application,
      required Map<String, Object?> account,
      required this.sessionId})
      : application = Map.unmodifiable(_copy(application)),
        account = Map.unmodifiable(_copy(account));
  factory WeappHostSnapshotContext.fromState(Map<String, Object?> state) {
    final owner = state['hostServicesState'] as Map;
    return WeappHostSnapshotContext(
        application: Map<String, Object?>.from(owner['application'] as Map),
        account: Map<String, Object?>.from(owner['account'] as Map),
        sessionId: state['sessionId'] as String);
  }
  final Map<String, Object?> application, account;
  final String sessionId;
  static Map<String, Object?> _copy(Map<String, Object?> value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
  Map<String, Object?> toMap() => {
        'application': _copy(application),
        'account': _copy(account),
        'sessionId': sessionId,
      };
}

/// Explicit iOS Wi-Fi capabilities; the OS still verifies signed entitlements.
class WeappWifiConfiguration {
  const WeappWifiConfiguration(
      {required this.connectToNetworks, required this.readCurrentNetwork});
  final bool connectToNetworks;
  final bool readCurrentNetwork;
  Map<String, Object?> toMap() => {
        'connectToNetworks': connectToNetworks,
        'readCurrentNetwork': readCurrentNetwork,
      };
}

/// Explicit iOS tag technologies; CoreNFC verifies the signed entitlement.
class WeappNfcConfiguration {
  const WeappNfcConfiguration(
      {this.ndef = true,
      this.isoDep = false,
      this.mifareUltralight = false,
      this.nfcF = false,
      this.nfcV = false});
  final bool ndef, isoDep, mifareUltralight, nfcF, nfcV;
  Map<String, Object?> toMap() => {
        'ndef': ndef,
        'isoDep': isoDep,
        'mifareUltralight': mifareUltralight,
        'nfcF': nfcF,
        'nfcV': nfcV
      };
}

/// Own a session independently of its widget. Explicitly await close() to persist
/// storage and release native resources. Detaching a widget keeps its JS isolate.
class WeappContainerController {
  WeappContainerController._(this.id, this._platform, this.atomicHostLayout) {
    _subscription =
        _platform.events.where((value) => value['id'] == id).listen((value) {
      final event =
          WeappContainerEvent(Map<String, Object?>.from(value['event'] as Map));
      if (event.type == 'hostLayoutObservation' &&
          event.fields['observation'] is Map) {
        _pendingHostLayout = _layoutCopy(event.fields['observation'] as Map);
        _lastHostLayoutObservation = _layoutCopy(_pendingHostLayout!);
      } else if (event.type == 'hostLayoutAccepted') {
        final accepted = event.fields['acceptedLayout'];
        if (accepted is Map) {
          _acceptedHostLayout = _layoutCopy(accepted);
          if (const [
                'schemaVersion',
                'ownerId',
                'surfaceGeneration',
                'observationId'
              ].every((key) => accepted[key] == _pendingHostLayout?[key]) &&
              _layoutEqual(accepted['windowMetrics'],
                  _pendingHostLayout?['windowMetrics'])) {
            _pendingHostLayout = null;
          }
        }
      }
      if (event.type == 'hostCall') {
        unawaited(_hostCall(event.fields));
      } else if (event.type == 'accountCleanupRequired') {
        if (!_closed) {
          final task = _cleanupAccount(event.fields['operationId'] as String);
          _cleanupTasks.add(task);
          unawaited(task.whenComplete(() => _cleanupTasks.remove(task)));
        }
      } else if (event.type == 'accountCleanupCancelled') {
        if (_cleanupOperationId == event.fields['operationId']) {
          _cleanupCancellation?._cancel();
        }
      } else if (event.type == 'hostCallCancelled') {
        _calls.remove(event.fields['callId'])?.cancellation._cancel();
      } else if (event.type == 'accountSwitch' &&
          (event.fields['receipt'] as Map?)?['phase'] == 'revoking') {
        _cleanupCancellation?._cancel();
        for (final call in _calls.values) {
          call.cancellation._cancel();
        }
        _calls.clear();
        _acceptedHostLayout = null;
        _pendingHostLayout = null;
      }
      _events.add(event);
    }, onError: _events.addError);
  }
  static Future<WeappContainerController> create(
      {required String? storageKey,
      bool? gpuRequired,
      bool? devDiagnostics,
      bool atomicHostLayout = false}) async {
    if (storageKey != null && storageKey.trim().isEmpty)
      throw ArgumentError.value(
          storageKey, 'storageKey', 'Must be nonblank, or null for memory');
    final platform = WeappContainerPlatform.instance;
    await platform.initialize();
    final result = await platform.invoke<Map>('create', {
      'storageKey': storageKey,
      if (gpuRequired != null) 'gpuRequired': gpuRequired,
      if (devDiagnostics != null) 'devDiagnostics': devDiagnostics,
      if (atomicHostLayout)
        'hostLayout': {'protocolVersion': '1.0', 'atomic': true},
    });
    return WeappContainerController._(
        result!['id'] as int, platform, atomicHostLayout);
  }

  final int id;
  final bool atomicHostLayout;
  Map<String, Object?>? _pendingHostLayout;
  Map<String, Object?>? _lastHostLayoutObservation;
  Map<String, Object?>? _acceptedHostLayout;
  Map<String, Object?> _layoutCopy(Map value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
  bool _layoutEqual(Object? left, Object? right) {
    if (left is Map && right is Map) {
      return left.length == right.length &&
          left.keys.every((key) =>
              right.containsKey(key) && _layoutEqual(left[key], right[key]));
    }
    if (left is List && right is List) {
      return left.length == right.length &&
          List.generate(left.length, (index) => index)
              .every((index) => _layoutEqual(left[index], right[index]));
    }
    return left == right;
  }

  Map<String, Object?>? get pendingHostLayout =>
      _pendingHostLayout == null ? null : _layoutCopy(_pendingHostLayout!);
  Map<String, Object?>? get lastHostLayoutObservation =>
      _lastHostLayoutObservation == null
          ? null
          : _layoutCopy(_lastHostLayoutObservation!);

  /// The real native acceptance event. This is not a GPU presentation receipt.
  Map<String, Object?>? get acceptedHostLayout =>
      _acceptedHostLayout == null ? null : _layoutCopy(_acceptedHostLayout!);
  final WeappContainerPlatform _platform;
  final _events = StreamController<WeappContainerEvent>.broadcast();
  final _methods = <String, WeappHostMethod>{};
  final _apiHandlers = <String, WeappHostMethod>{};
  final _calls = <String, WeappHostCall>{};
  final _cleanupHandlers = <WeappAccountCleanup>{};
  final _cleanupTasks = <Future<void>>{};
  Future<void> _cleanupTail = Future<void>.value();
  WeappCancellationToken? _cleanupCancellation;
  String? _cleanupOperationId;
  late final StreamSubscription<Map<String, Object?>> _subscription;
  Future<void>? _closing;
  bool _closeRequested = false;
  final _closeListeners = <void Function()>{};
  bool _closed = false;
  bool _loadRequested = false;
  Object? _viewOwner;
  Future<void> _retirement = Future.value();
  Stream<WeappContainerEvent> get events => _events.stream;
  bool get isClosed => _closed;

  /// View retirement begins with close intent, including a failed close that
  /// still needs an explicit retry. A late command cannot reactivate that View.
  bool get closeRequested => _closeRequested;

  // View implementation hook. A removable listener avoids retaining detached
  // Views or accumulating one pending lifetime callback per layout operation.
  void Function() listenForCloseRequest(void Function() listener) {
    if (_closeRequested) {
      listener();
    } else {
      _closeListeners.add(listener);
    }
    return () => _closeListeners.remove(listener);
  }

  Future<T?> _invoke<T>(String method,
      [Map<String, Object?> arguments = const {}]) {
    if (_closed || _closeRequested)
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

  Future<void> configureHostServices(Map<String, Object?> configuration) async {
    if (_loadRequested)
      throw StateError('Configure trusted host services before load');
    await _invoke<void>('configureHostServices', _layoutCopy(configuration));
  }

  Future<void> registerApiHandler(String name, WeappHostMethod handler) async {
    if (_loadRequested) throw StateError('Register API handlers before load');
    if (_apiHandlers.containsKey(name))
      throw ArgumentError.value(name, 'name', 'Already registered');
    await _invoke<void>('registerApiHandler', {'name': name});
    _apiHandlers[name] = handler;
  }

  /// Register cleanup for custom resources; failure leaves account startup blocked.
  void Function() registerAccountCleanupHandler(WeappAccountCleanup handler) {
    if (_closed || _closeRequested)
      throw StateError('Session is closing or closed');
    _cleanupHandlers.add(handler);
    return () => _cleanupHandlers.remove(handler);
  }

  Future<void> _cleanupAccount(String operationId) {
    _cleanupCancellation?._cancel();
    final cancellation = WeappCancellationToken();
    _cleanupCancellation = cancellation;
    _cleanupOperationId = operationId;
    final previous = _cleanupTail;
    final task = () async {
      // Revocation is immediate; retirement still waits for every earlier
      // handler's real terminal, including handlers that ignore cancellation.
      await previous;
      bool retired() =>
          !identical(_cleanupCancellation, cancellation) ||
          cancellation.isCancelled ||
          _closed ||
          _closeRequested;
      Object? failure;
      if (!retired())
        await Future.wait(_cleanupHandlers.toList().map((handler) async {
          try {
            await handler(operationId, cancellation);
          } catch (error) {
            failure ??= error;
          }
        }));
      try {
        // Retirement still owes the exact native transport its real terminal.
        // This bypasses the business-command gate while close is waiting.
        await _platform.invoke<void>('completeAccountCleanup', {
          'id': id,
          'operationId': operationId,
          if (retired()) 'retired': true,
          if (failure != null && !retired())
            'error': {
              'code': 'ERR_ACCOUNT_CLEANUP',
              'message': failure.toString()
            }
        });
      } catch (error, stack) {
        if (!_closed && !_closeRequested) _events.addError(error, stack);
      } finally {
        if (identical(_cleanupCancellation, cancellation)) {
          _cleanupCancellation = null;
          _cleanupOperationId = null;
        }
      }
    }();
    _cleanupTail =
        task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }

  /// Install OS-backed adapters; native permissions remain separately authorized.
  Future<void> installNativeDeviceApis(
          {bool bluetooth = true,
          List<String> allowedNetworkOrigins = const [],
          bool allowLoopbackForDevelopment = false,
          List<String> allowedMediaOrigins = const [],
          bool nfc = false,
          bool enableWifi = false,
          WeappWifiConfiguration? wifiConfiguration,
          WeappNfcConfiguration? nfcConfiguration,
          String linuxDesktopId = '',
          bool linuxBluetoothExclusive = false,
          bool dedicatedAudioSession = false}) =>
      _invoke<void>('installNativeDeviceApis', {
        'bluetooth': bluetooth,
        'allowedNetworkOrigins': List<String>.from(allowedNetworkOrigins),
        'allowLoopbackForDevelopment': allowLoopbackForDevelopment,
        'allowedMediaOrigins': List<String>.from(allowedMediaOrigins),
        'nfc': nfc,
        'enableWifi': enableWifi,
        if (wifiConfiguration != null)
          'wifiConfiguration': wifiConfiguration.toMap(),
        if (nfcConfiguration != null)
          'nfcConfiguration': nfcConfiguration.toMap(),
        'linuxDesktopId': linuxDesktopId,
        'linuxBluetoothExclusive': linuxBluetoothExclusive,
        'dedicatedAudioSession': dedicatedAudioSession,
      });
  Future<void> retryAccountCleanup() => _invoke<void>('retryAccountCleanup');
  Future<List<Object?>> hostComponents() async =>
      List<Object?>.from((await _invoke<List>('hostComponents'))!);
  Future<void> authorizeInstalledPack(Map<String, Object?> application) =>
      _invoke<void>('authorizeInstalledPack', _layoutCopy(application));
  Future<void> migrateLegacyStorage(String sourceKey) =>
      _invoke<void>('migrateLegacyStorage', {'sourceKey': sourceKey});
  Future<Map<String, Object?>> deleteAccountData(String principalId) async =>
      Map<String, Object?>.from((await _invoke<Map>(
          'deleteAccountData', {'principalId': principalId}))!);
  Future<void> emitHostApiEvent(Map<String, Object?> event) =>
      _invoke<void>('hostApiEvent', _layoutCopy(event));
  Future<Map<String, Object?>> submitHostComponentFrame(
          Map<String, Object?> frame) async =>
      Map<String, Object?>.from(
          (await _invoke<Map>('hostComponentFrame', frame))!);
  Future<void> emitHostComponentEvent(Map<String, Object?> event) =>
      _invoke<void>('hostComponentEvent', _layoutCopy(event));
  Future<void> authorizePhoneButton(String nodeId) =>
      _invoke<void>('authorizePhoneButton', {'nodeId': nodeId});
  Future<void> prepareAccountHostServiceSnapshots(
          String operationId, Map<String, Object?> values) =>
      _invoke<void>('prepareAccountHostServiceSnapshots',
          {'operationId': operationId, 'values': _layoutCopy(values)});
  Future<void> updateHostServiceSnapshots(Map<String, Object?> values,
          {WeappHostSnapshotContext? context}) =>
      _invoke<void>('updateHostServiceSnapshots', {
        'values': _layoutCopy(values),
        if (context != null) 'context': context.toMap(),
      });
  Future<Map<String, Object?>> switchAccount(Map<String, Object?> account,
          {Map<String, Object?> launches = const {}}) async =>
      Map<String, Object?>.from((await _invoke<Map>(
          'switchAccount', {'account': account, 'launches': launches}))!);
  Future<Map<String, Object?>?> queryAccountSwitch(
      {String? operationId}) async {
    final value = await _invoke<Map>('queryAccountSwitch',
        {if (operationId != null) 'operationId': operationId});
    return value == null ? null : Map<String, Object?>.from(value);
  }

  Future<void> updateAccountSwitchLaunch(Map<String, Object?> options) =>
      _invoke<void>('updateAccountSwitchLaunch', {'options': options});
  Future<void> retryAccountSwitch({Map<String, Object?> options = const {}}) =>
      _invoke<void>('retryAccountSwitch', {'options': options});
  Future<void> cancelAccountSwitch(String operationId) =>
      _invoke<void>('cancelAccountSwitch', {'operationId': operationId});
  Future<Map<String, Object?>> createHostBinary(List<int> bytes) async =>
      Map<String, Object?>.from(
          (await _invoke<Map>('createHostBinary', {'bytes': bytes}))!);
  Future<List<int>> readHostBinary(String handle,
          {int offset = 0, required int length}) async =>
      List<int>.from((await _invoke<List>('readHostBinary',
          {'id': handle, 'offset': offset, 'length': length}))!);
  Future<void> retainHostBinary(String handle) =>
      _invoke<void>('retainHostBinary', {'id': handle});

  /// Read only the asset of an exact live API call; requires apiResourceChunks 1.0.
  Future<Map<String, Object?>> readHostApiResource(Map<String, Object?> context,
          {int offset = 0, required int length}) async =>
      Map<String, Object?>.from((await _invoke<Map>('hostApiResource', {
        'context': _layoutCopy(context),
        'offset': offset,
        'length': length
      }))!);
  Future<void> releaseHostBinary(String handle) =>
      _invoke<void>('releaseHostBinary', {'id': handle});

  Future<void> load(String packPath,
      {String? route,
      Map<String, Object?> options = const {},
      Map<String, Object?>? initialHostChrome,
      Map<String, Object?>? initialHostLayout}) {
    _loadRequested = true;
    return _invoke<void>('load', {
      'packPath': packPath,
      if (route != null) 'route': route,
      'options': options,
      if (initialHostChrome != null) 'initialHostChrome': initialHostChrome,
      if (initialHostLayout != null) 'initialHostLayout': initialHostLayout,
    });
  }

  /// Apply a verified immutable development pack. A returned startup/frame
  /// result is separate from the native GPU presentation receipt.
  Future<Map<String, Object?>> applyDevPack(String packPath,
      {String? route,
      Map<String, Object?> options = const {},
      Map<String, Object?>? initialHostChrome,
      Map<String, Object?>? initialHostLayout}) async {
    _loadRequested = true;
    return Map<String, Object?>.from((await _invoke<Map>('applyDevPack', {
      'packPath': packPath,
      if (route != null) 'route': route,
      'options': options,
      if (initialHostChrome != null) 'initialHostChrome': initialHostChrome,
      if (initialHostLayout != null) 'initialHostLayout': initialHostLayout,
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
  Future<void> switchTab(String route) =>
      _invoke<void>('switchTab', {'route': route});

  /// Parse verified host presentation configuration without executing guest JS.
  /// This preflight is independent of native view measurement and load authority.
  Future<Map<String, Object?>> inspectPackChrome(String packPath,
          {String? route}) async =>
      Map<String, Object?>.from((await _invoke<Map>('inspectPackChrome', {
        'packPath': packPath,
        if (route != null) 'route': route,
      }))!);

  /// Publish measured Flutter client-window logical rectangles. The platform
  /// adapter converts their origin to the actual native screen before receipt;
  /// the native view remains the viewport/display metric owner.
  Future<void> updateHostChrome(Map<String, Object?> geometry) => _invoke<void>(
      'hostChrome', {...geometry, 'coordinateSpace': 'flutterClient'});

  /// Transform a prospective layout without mutating the accepted runtime.
  Future<Map<String, Object?>> prepareHostChrome(
          Map<String, Object?> geometry) async =>
      Map<String, Object?>.from((await _invoke<Map>('prepareHostChrome',
          {...geometry, 'coordinateSpace': 'flutterClient'}))!);

  /// Correlated SDK command. Opaque owner/revision values remain strings.
  Future<Map<String, Object?>> command(String operation,
          [Map<String, Object?> payload = const {}]) async =>
      Map<String, Object?>.from((await _invoke<Map>('command', {
        'operation': operation,
        'payload': payload,
      }))!);

  Future<Map<String, Object?>> beginDevPackAttempt(
    String packPath, {
    required String operation,
    required Map<String, Object?>? expectedAccepted,
    String? route,
    Map<String, Object?> options = const {},
  }) =>
      command('beginDevPackAttempt', {
        'operation': operation,
        'packPath': packPath,
        'expectedAccepted': expectedAccepted,
        if (route != null) 'route': route,
        'options': options,
      });

  Future<Map<String, Object?>> applyDevPackAttempt(
    Map<String, Object?> receipt, {
    required Map<String, Object?>? expectedAccepted,
    Map<String, Object?>? initialHostLayout,
  }) {
    _loadRequested = true;
    return command('applyDevPackAttempt', {
      'ownerId': receipt['ownerId'],
      'attemptId': receipt['attemptId'],
      'expectedAccepted': expectedAccepted,
      if (initialHostLayout != null) 'initialHostLayout': initialHostLayout,
    });
  }

  Future<Map<String, Object?>> queryDevPackAttempt(
          Map<String, Object?> receipt) =>
      command('queryDevPackAttempt', {
        'ownerId': receipt['ownerId'],
        'attemptId': receipt['attemptId'],
      });

  Future<Map<String, Object?>> cancelDevPackAttempt(
          Map<String, Object?> receipt) =>
      command('cancelDevPackAttempt', {
        'ownerId': receipt['ownerId'],
        'attemptId': receipt['attemptId'],
      });

  Future<void> requestHostLayoutObservation() =>
      _invoke<void>('observeHostLayout');

  /// Prove that this submitted measurement was superseded. The dedicated
  /// state query does not request another observation, renew its deadline,
  /// acknowledge presentation, or mutate the navigation/candidate attempt.
  Future<bool> wasHostLayoutSuperseded({
    required Map<String, Object?> observation,
    required String layoutRevision,
  }) async {
    if (!atomicHostLayout) return false;
    final captured =
        (jsonDecode(jsonEncode(observation)) as Map).cast<String, Object?>();
    return supersededHostLayout(captured, layoutRevision, await state());
  }

  /// Native adapter supplies screen-coordinate conversion. No partial geometry
  /// or guessed display metrics cross the atomic host layout boundary.
  Future<Map<String, Object?>> prepareHostLayout({
    required Map<String, Object?> observation,
    required Map<String, Object?> chrome,
    required String layoutRevision,
    Map<String, Object?>? restartAttempt,
  }) async =>
      Map<String, Object?>.from((await _invoke<Map>('prepareHostLayout', {
        'observation': observation,
        'chrome': chrome,
        'layoutRevision': layoutRevision,
        'coordinateSpace': 'flutterClient',
        // This is only a measurement claim. Native code verifies the current
        // owner journal and health; it never grants input or presentation.
        if (restartAttempt != null)
          'restartAttempt': _layoutCopy(restartAttempt),
      }))!);

  Future<void> updateHostLayout({
    required Map<String, Object?> observation,
    required Map<String, Object?> chrome,
    required String layoutRevision,
  }) =>
      _invoke<void>('hostLayout', {
        'observation': observation,
        'chrome': chrome,
        'layoutRevision': layoutRevision,
        'coordinateSpace': 'flutterClient',
      });

  /// Covering developer controls do not background or stop the mini-program.
  Future<void> setPreviewOccluded(bool occluded) =>
      _invoke<void>('setPreviewOccluded', {'occluded': occluded});

  /// Windows/Linux use real native chrome above their native child surface.
  Future<void> updateNativeChrome(Map<String, Object?> chrome) =>
      _invoke<void>('nativeChrome', chrome);
  Future<void> sendMessage(Object? message) =>
      _invoke<void>('sendMessage', {'message': message});
  Future<void> setForeground(bool foreground) =>
      _invoke<void>('setForeground', {'foreground': foreground});
  Future<void> flushStorage() => _invoke<void>('flushStorage');
  Future<Map<String, Object?>> state() async =>
      Map<String, Object?>.from((await _invoke<Map>('state'))!);
  Future<Map<String, Object?>> capabilities() async =>
      Map<String, Object?>.from((await _invoke<Map>('capabilities'))!);

  /// Prepare an empty runtime after the native view supplies real metrics.
  /// This runs no mini-program module and grants no presentation authority.
  Future<Map<String, Object?>> prepareView() async =>
      Map<String, Object?>.from((await _invoke<Map>('prepareView'))!);
  Future<void> close() {
    if (_closed) return Future.value();
    if (!_closeRequested) {
      _closeRequested = true;
      _cleanupCancellation?._cancel();
      for (final call in _calls.values) {
        call.cancellation._cancel();
      }
      _calls.clear();
      final listeners = _closeListeners.toList();
      _closeListeners.clear();
      for (final listener in listeners) {
        listener();
      }
    }
    return _closing ??= _close();
  }

  Future<void> _close() async {
    try {
      if (_cleanupTasks.isNotEmpty) await Future.wait(_cleanupTasks.toList());
      if (_cleanupHandlers.isNotEmpty) {
        final cancellation = WeappCancellationToken();
        Object? failure;
        await Future.wait(_cleanupHandlers.toList().map((handler) async {
          try {
            await handler('close:$id', cancellation);
          } catch (error) {
            failure ??= error;
          }
        }));
        if (failure != null) throw failure!;
      }
      await _platform.invoke<void>('close', {'id': id});
      _closed = true;
      _cleanupHandlers.clear();
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
        event['deadlineNs']?.toString(),
        WeappCancellationToken(),
        event['context'] is Map
            ? Map<String, Object?>.unmodifiable(
                _layoutCopy(event['context'] as Map))
            : null,
        event['cancelToken'] as String?);
    _calls[callId] = call;
    Map<String, Object?> completion;
    try {
      final method = _apiHandlers[call.method] ?? _methods[call.method];
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
    if (_calls[callId] != call ||
        call.cancellation.isCancelled ||
        _closed ||
        _closing != null) return;
    final retained = event['retainUntilCancelled'] == true &&
        completion.containsKey('result');
    if (!retained) _calls.remove(callId);
    try {
      await _invoke<void>(
          'completeHostCall', {'callId': callId, ...completion});
    } on PlatformException catch (error, stack) {
      // Native cancellation can win after the Dart handler has completed.
      if (error.code != 'cancelled' &&
          error.code != 'ERR_STALE_CALL' &&
          error.code != 'ERR_IDENTITY_SWITCHING' &&
          !_closed) _events.addError(error, stack);
    } catch (error, stack) {
      if (!_closed) _events.addError(error, stack);
    }
  }

  // Package implementation hooks; host applications use WeappContainerView.
  bool ownsView(Object owner) => identical(_viewOwner, owner);

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
