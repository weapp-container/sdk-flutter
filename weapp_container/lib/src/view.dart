import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';
import 'host_layout.dart';

Map<String, Object?>? _chromeSnapshot(Map<String, Object?>? value) =>
    value == null
        ? null
        : (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();

bool _chromeEqual(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every((key) =>
            right.containsKey(key) && _chromeEqual(left[key], right[key]));
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        List.generate(left.length, (index) => index)
            .every((index) => _chromeEqual(left[index], right[index]));
  }
  return left == right;
}

bool _sameChromeObservation(
    Map<String, Object?>? left, Map<String, Object?>? right) {
  if (left == null || right == null) return left == null && right == null;
  return const [
    'schemaVersion',
    'ownerId',
    'surfaceGeneration',
    'observationId',
    'sessionId',
    'pageId',
    'windowMetrics',
  ].every((key) => _chromeEqual(left[key], right[key]));
}

class _ChromeRetired implements Exception {}

class _DesiredHostGeometry {
  _DesiredHostGeometry(this.chrome, this.observation);
  final Map<String, Object?> chrome;
  final Map<String, Object?>? observation;
  int? get revision => chrome['revision'] as int?;
  bool same(_DesiredHostGeometry? other) =>
      other != null &&
      _chromeEqual(chrome, other.chrome) &&
      _sameChromeObservation(observation, other.observation);
}

/// A real embedded platform view on mobile and a native texture on desktop.
/// Give this widget finite positive constraints. Its controller outlives detach.
class WeappContainerView extends StatefulWidget {
  const WeappContainerView({
    super.key,
    required this.controller,
    this.foreground = true,
    this.occluded = false,
    this.hostChrome,
    this.hostLayoutObservation,
    this.prepareOnly = false,
    this.nativeChrome,
    this.onHostChromeApplied,
    this.onError,
  });
  final WeappContainerController controller;
  final bool foreground;

  /// Presentation/input suspension only. App lifecycle and timers keep running.
  final bool occluded;
  final Map<String, Object?>? hostChrome;
  final Map<String, Object?>? hostLayoutObservation;

  /// Measure a prospective shell without changing the accepted guest environment.
  final bool prepareOnly;

  /// Native Windows/Linux host controls. Optional `accessibilityLabels` accepts
  /// `more`, `close`, `back`, `navigation` and `tabs` host-localized strings;
  /// omitted labels retain English defaults. This never changes guest content.
  final Map<String, Object?>? nativeChrome;
  final ValueChanged<int>? onHostChromeApplied;
  final void Function(Object error, StackTrace stack)? onError;
  @override
  State<WeappContainerView> createState() => _WeappContainerViewState();
}

class _WeappContainerViewState extends State<WeappContainerView>
    with WidgetsBindingObserver {
  final _focus = FocusNode();
  final _pointers = <int, Map<String, Object?>>{};
  PointerDownEvent? _tapStart;
  late final WeappContainerController _controller;
  late final Future<void> _ready;
  int? _texture;
  bool _disposed = false;
  bool _resumed = true;
  bool? _foreground;
  Future<void>? _syncing;
  Map<String, Object?>? _pendingMetrics;
  Map<String, Object?>? _metrics;
  _DesiredHostGeometry? _desiredGeometry;
  _DesiredHostGeometry? _committedGeometry;
  _DesiredHostGeometry? _attemptedGeometry;
  String? _nativeChromeSignature;
  String? _appliedNativeChromeSignature;
  int _chromeDesiredVersion = 0;
  int _chromeHandledVersion = 0;
  bool _chromeRunning = false;
  final _chromeWaiters = <void Function()>{};
  late final void Function() _cancelCloseListener;
  bool _occluded = false;
  bool _nativeOccluded = false;
  Future<void> _chromeSync = Future.value();
  bool get _desktop => switch (defaultTargetPlatform) {
        TargetPlatform.macOS ||
        TargetPlatform.windows ||
        TargetPlatform.linux =>
          true,
        _ => false,
      };
  @override
  void initState() {
    super.initState();
    _controller = widget.controller;
    _cancelCloseListener =
        _controller.listenForCloseRequest(_retireChromeWaits);
    _ready = _controller.claimView(this);
    _run(_ready);
    _resumed = WidgetsBinding.instance.lifecycleState == null ||
        _isVisibleLifecycle(WidgetsBinding.instance.lifecycleState!);
    WidgetsBinding.instance.addObserver(this);
    _updateChrome();
  }

  @override
  void didUpdateWidget(covariant WeappContainerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller))
      throw StateError('Use a new widget key when changing controller');
    _updateForeground();
    _updateChrome();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateForeground();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = _isVisibleLifecycle(state);
    _updateForeground();
  }

  bool _isVisibleLifecycle(AppLifecycleState state) =>
      state == AppLifecycleState.resumed ||
      (_desktop && state == AppLifecycleState.inactive);
  void _error(Object error, StackTrace stack) {
    if (widget.onError != null) {
      widget.onError!(error, stack);
    } else {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'weapp_container',
        ),
      );
    }
  }

  void _run(Future<void> future) {
    unawaited(future.catchError(_error));
  }

  void _updateForeground() {
    final next = widget.foreground && _resumed;
    if (_foreground == next || _controller.closeRequested) return;
    _foreground = next;
    _run(_controller.setForeground(next));
  }

  void _updateChrome() {
    // Desired geometry, controls metadata and covering are independent channels.
    // A title/locale update must neither consume a new observation nor discard
    // the only queued geometry. Only a successful current request is committed.
    final geometry =
        widget.prepareOnly ? null : _chromeSnapshot(widget.hostChrome);
    final observation = _chromeSnapshot(widget.hostLayoutObservation);
    final next =
        geometry == null ? null : _DesiredHostGeometry(geometry, observation);
    final nativeSupported = defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    final nativeSignature = widget.nativeChrome != null && nativeSupported
        ? jsonEncode(widget.nativeChrome)
        : null;
    final geometryChanged =
        next == null ? _desiredGeometry != null : !next.same(_desiredGeometry);
    final nativeChanged = nativeSignature != _nativeChromeSignature;
    final occlusionChanged = widget.occluded != _occluded;
    if (!geometryChanged && !nativeChanged && !occlusionChanged) return;
    if (geometryChanged) _desiredGeometry = next;
    _nativeChromeSignature = nativeSignature;
    _occluded = widget.occluded;
    _chromeDesiredVersion++;
    _scheduleChrome();
  }

  bool get _chromeActive => !_disposed && !_controller.closeRequested;

  void _retireChromeWaits() {
    final waiters = _chromeWaiters.toList();
    _chromeWaiters.clear();
    for (final retire in waiters) {
      retire();
    }
  }

  Future<T> _awaitChrome<T>(Future<T> operation) {
    final waiters = _chromeWaiters;
    final result = Completer<T>();
    void retire() {
      if (!result.isCompleted) result.completeError(_ChromeRetired());
    }

    if (_chromeActive) {
      waiters.add(retire);
    } else {
      retire();
    }
    // Keep an error handler on the actual operation after retiring its wait;
    // late native replies cannot leak errors or reactivate this View.
    operation.then<void>((value) {
      waiters.remove(retire);
      if (!result.isCompleted) result.complete(value);
    }, onError: (Object error, StackTrace stack) {
      waiters.remove(retire);
      if (!result.isCompleted) result.completeError(error, stack);
    });
    return result.future;
  }

  bool _currentGeometry(_DesiredHostGeometry value) =>
      _chromeActive &&
      mounted &&
      !widget.prepareOnly &&
      value.same(_desiredGeometry) &&
      _chromeEqual(value.chrome, widget.hostChrome) &&
      _sameChromeObservation(value.observation, widget.hostLayoutObservation);

  bool _eligibleGeometry(_DesiredHostGeometry value) =>
      _currentGeometry(value) &&
      (!_controller.atomicHostLayout ||
          (value.observation != null &&
              _sameChromeObservation(
                  value.observation, _controller.pendingHostLayout)));

  // A success reply establishes only this command's accepted geometry, never a
  // presented frame. A subsequently consumed observation may restore covering
  // only for the exact geometry this View actually committed, using its real
  // native receipt. A new revision or merely healthy state is insufficient.
  bool _acceptedCommittedGeometry(_DesiredHostGeometry value) {
    final observation = value.observation;
    final accepted = _controller.acceptedHostLayout;
    if (observation == null ||
        accepted == null ||
        observation['schemaVersion'] != 1 ||
        accepted['schemaVersion'] != 1 ||
        accepted['layoutRevision'] != value.revision?.toString()) return false;
    for (final field in const [
      'ownerId',
      'surfaceGeneration',
      'observationId',
      'windowMetrics',
    ]) {
      if (!_chromeEqual(accepted[field], observation[field])) return false;
    }
    final chrome = accepted['chrome'];
    if (chrome is! Map) return false;
    return chrome['revision'] == value.revision &&
        chrome['sessionId'] == observation['sessionId'] &&
        chrome['pageId'] == observation['pageId'] &&
        chrome['sessionId'] == value.chrome['sessionId'] &&
        chrome['pageId'] == value.chrome['pageId'];
  }

  bool _successfulCurrentGeometry(_DesiredHostGeometry value) {
    if (!_currentGeometry(value)) return false;
    if (!_controller.atomicHostLayout) return true;
    final pending = _controller.pendingHostLayout;
    return pending != null
        ? _sameChromeObservation(pending, value.observation)
        : _acceptedCommittedGeometry(value);
  }

  bool get _mayRestoreChrome {
    if (!_chromeActive || !mounted || widget.prepareOnly || _occluded)
      return false;
    if (!_controller.atomicHostLayout) return true;
    final committed = _committedGeometry;
    if (committed == null || !_chromeEqual(widget.hostChrome, committed.chrome))
      return false;
    final pending = _controller.pendingHostLayout;
    if (pending != null) {
      return _sameChromeObservation(pending, committed.observation) &&
          _sameChromeObservation(
              widget.hostLayoutObservation, committed.observation);
    }
    return (widget.hostLayoutObservation == null ||
            _sameChromeObservation(
                widget.hostLayoutObservation, committed.observation)) &&
        _acceptedCommittedGeometry(committed);
  }

  void _scheduleChrome() {
    if (_chromeRunning || !_chromeActive) return;
    _chromeRunning = true;
    _chromeSync = _syncChrome().whenComplete(() {
      _chromeRunning = false;
      if (_chromeActive && _chromeHandledVersion != _chromeDesiredVersion)
        _scheduleChrome();
    });
    _run(_chromeSync);
  }

  Future<void> _syncChrome() async {
    try {
      await _awaitChrome(_ready);
      while (_chromeActive) {
        final version = _chromeDesiredVersion;
        _chromeHandledVersion = version;
        if (_occluded && !_nativeOccluded) {
          await _awaitChrome(_controller.setPreviewOccluded(true));
          _nativeOccluded = true;
        }
        if (!_chromeActive) return;
        final geometry = _desiredGeometry;
        if (geometry != null &&
            !geometry.same(_committedGeometry) &&
            !identical(geometry, _attemptedGeometry) &&
            _eligibleGeometry(geometry)) {
          _attemptedGeometry = geometry;
          try {
            if (_controller.atomicHostLayout) {
              await _awaitChrome(_controller.updateHostLayout(
                  observation: geometry.observation!,
                  chrome: geometry.chrome,
                  layoutRevision: geometry.revision.toString()));
            } else {
              await _awaitChrome(_controller.updateHostChrome(geometry.chrome));
            }
            if (_successfulCurrentGeometry(geometry)) {
              _committedGeometry = geometry;
              if (geometry.revision != null) {
                widget.onHostChromeApplied?.call(geometry.revision!);
              }
            }
          } on PlatformException catch (error, stack) {
            var cancelled = false;
            if (error.code == 'ERR_CANCELLED') {
              if (!_currentGeometry(geometry)) {
                cancelled = true;
              } else {
                try {
                  final current = await _awaitChrome(_controller.state());
                  if (_controller.atomicHostLayout) {
                    cancelled = supersededHostLayout(geometry.observation!,
                        geometry.revision.toString(), current);
                  } else {
                    final page = current['page'];
                    cancelled = (geometry.chrome['sessionId'] != null &&
                            geometry.chrome['sessionId'] !=
                                current['sessionId']) ||
                        (geometry.chrome['pageId'] != null &&
                            page is Map &&
                            geometry.chrome['pageId'] != page['id']);
                  }
                } on _ChromeRetired {
                  rethrow;
                } catch (_) {
                  // An unavailable read-only proof cannot rewrite the original
                  // cancellation or prevent independent controls from updating.
                  cancelled = false;
                }
              }
            }
            if (!cancelled && _chromeActive) {
              _error(error, stack);
            }
          } on _ChromeRetired {
            rethrow;
          } catch (error, stack) {
            if (_chromeActive) _error(error, stack);
          }
        }
        if (!_chromeActive) return;
        // Even a skipped consumed geometry must not swallow newer locale/title
        // metadata. It also cannot acknowledge that geometry or restore input.
        final nativeSignature = _nativeChromeSignature;
        if (nativeSignature != null &&
            nativeSignature != _appliedNativeChromeSignature) {
          final snapshot =
              (jsonDecode(nativeSignature) as Map).cast<String, Object?>();
          try {
            await _awaitChrome(_controller.updateNativeChrome(snapshot));
            _appliedNativeChromeSignature = nativeSignature;
          } on _ChromeRetired {
            rethrow;
          } catch (error, stack) {
            if (_chromeActive) _error(error, stack);
          }
        }
        if (!_chromeActive) return;
        if (_mayRestoreChrome &&
            (_nativeChromeSignature == null ||
                _nativeChromeSignature == _appliedNativeChromeSignature) &&
            _nativeOccluded) {
          await _awaitChrome(_controller.setPreviewOccluded(false));
          _nativeOccluded = false;
        }
        if (version == _chromeDesiredVersion) return;
      }
    } on _ChromeRetired {
      // Ignore late replies after this View or its controller began retirement.
    }
  }

  void _layout(Map<String, Object?> next) {
    if (_disposed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_disposed || !mounted) return;
      final measured = Map<String, Object?>.of(next);
      if (_desktop) {
        final box = context.findRenderObject();
        if (box is RenderBox && box.hasSize) {
          final origin = box.localToGlobal(Offset.zero);
          measured['previewX'] = origin.dx;
          measured['previewY'] = origin.dy;
        }
      }
      if (mapEquals(measured, _pendingMetrics ?? _metrics)) return;
      _pendingMetrics = measured;
      if (_syncing == null) {
        _syncing = _sync();
        _run(_syncing!);
      }
    });
  }

  Future<void> _sync() async {
    try {
      await _ready;
      while (!_disposed &&
          !_controller.closeRequested &&
          _pendingMetrics != null) {
        final next = _pendingMetrics!;
        _pendingMetrics = null;
        if (_texture == null) {
          _texture = await _controller.attachTexture(next);
        } else {
          await _controller.resizeTexture(next);
        }
        _metrics = next;
        if (mounted) setState(() {});
      }
    } finally {
      _syncing = null;
    }
  }

  Future<void> _detach() async {
    try {
      await _ready;
      await _syncing;
    } catch (_) {
      /* Reported by the operation owner. */
    }
    if (_desktop) {
      if (_texture != null) await _controller.detachTexture();
    } else {
      await _controller.detachPlatformView();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelCloseListener();
    _retireChromeWaits();
    WidgetsBinding.instance.removeObserver(this);
    final retirement = _detach();
    _controller.releaseView(this, retirement);
    _run(retirement);
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb)
      throw UnsupportedError(
        'The native Weapp Container SDK does not target web',
      );
    if (!_desktop) {
      return FutureBuilder<void>(
        future: _ready,
        builder: (context, snapshot) {
          if (snapshot.hasError) return const SizedBox.shrink();
          if (snapshot.connectionState != ConnectionState.done)
            return const SizedBox.shrink();
          return _mobile(context);
        },
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final display = View.of(context);
        final ratio = display.devicePixelRatio;
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (!width.isFinite || !height.isFinite)
          throw FlutterError('WeappContainerView needs finite constraints');
        if (width.round() > 0 && height.round() > 0) {
          _layout({
            'windowWidth': width.round(),
            'windowHeight': height.round(),
            'pixelRatio': ratio,
            'screenWidth':
                (display.display.size.width / display.display.devicePixelRatio)
                    .round(),
            'screenHeight':
                (display.display.size.height / display.display.devicePixelRatio)
                    .round(),
            'statusBarHeight': display.viewPadding.top / ratio,
            'screenTop': 0,
            'deviceOrientation':
                display.display.size.width > display.display.size.height
                    ? 'landscape'
                    : 'portrait',
          });
        }
        // -1 identifies an actual native child preview, never a Flutter pixel
        // texture. Native OS hit testing owns its input; forwarding it through
        // Flutter as well would duplicate clicks and gestures.
        if (_texture == -1) return const SizedBox.expand();
        return Focus(
          focusNode: _focus,
          onKeyEvent: (_, event) {
            _input([
              {
                'type': event is KeyUpEvent ? 'keyup' : 'keydown',
                'timeStamp': event.timeStamp.inMilliseconds,
                'detail': {
                  'key': event.character ?? event.logicalKey.keyLabel,
                  'code': event.physicalKey.debugName ?? '',
                  'repeat': event is KeyRepeatEvent,
                  'altKey': HardwareKeyboard.instance.isAltPressed,
                  'ctrlKey': HardwareKeyboard.instance.isControlPressed,
                  'shiftKey': HardwareKeyboard.instance.isShiftPressed,
                  'metaKey': HardwareKeyboard.instance.isMetaPressed,
                },
              },
            ]);
            return KeyEventResult.handled;
          },
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) {
              if (!_acceptsInput) return;
              _focus.requestFocus();
              _tapStart = _pointers.isEmpty && event.buttons == kPrimaryButton
                  ? event
                  : null;
              _pointer('touchstart', event);
            },
            onPointerMove: (event) {
              final start = _tapStart;
              if (start != null &&
                  (event.position - start.position).distance > 10) {
                _tapStart = null;
              }
              _pointer('touchmove', event);
            },
            onPointerUp: (event) {
              final start = _tapStart;
              _tapStart = null;
              _pointer('touchend', event);
              if (start != null &&
                  start.pointer == event.pointer &&
                  (event.position - start.position).distance <= 10 &&
                  event.timeStamp - start.timeStamp <=
                      const Duration(milliseconds: 500)) {
                _input([
                  {
                    'type': 'tap',
                    'x': event.localPosition.dx,
                    'y': event.localPosition.dy,
                    'detail': {
                      'x': event.localPosition.dx,
                      'y': event.localPosition.dy,
                    },
                  },
                ]);
              }
            },
            onPointerCancel: (event) {
              _tapStart = null;
              _pointer('touchcancel', event);
            },
            onPointerSignal: (event) {
              if (event is PointerScrollEvent && _acceptsInput) {
                GestureBinding.instance.pointerSignalResolver.register(event, (
                  _,
                ) {
                  _input([
                    {
                      'type': 'wheel',
                      'x': event.localPosition.dx,
                      'y': event.localPosition.dy,
                      'deltaX': event.scrollDelta.dx,
                      'deltaY': event.scrollDelta.dy,
                      'timeStamp': event.timeStamp.inMilliseconds,
                    },
                  ]);
                });
              }
            },
            // Like mobile PlatformViews, the embedded surface owns contacts
            // that start inside it. Raw input must not continue alongside a
            // parent Scrollable that won Flutter's gesture arena.
            child: RawGestureDetector(
              behavior: HitTestBehavior.opaque,
              gestures: _acceptsInput
                  ? {
                      EagerGestureRecognizer:
                          GestureRecognizerFactoryWithHandlers<
                              EagerGestureRecognizer>(
                        () => EagerGestureRecognizer(
                          allowedButtonsFilter: (_) => _acceptsInput,
                        ),
                        (_) {},
                      ),
                    }
                  : const {},
              child: SizedBox.expand(
                child: _texture == null
                    ? const SizedBox.shrink()
                    : Texture(textureId: _texture!),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _mobile(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return PlatformViewLink(
        viewType: 'dev.weapp.container/view',
        surfaceFactory: (_, controller) => AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.opaque,
          gestureRecognizers: {
            Factory<OneSequenceGestureRecognizer>(
              () => EagerGestureRecognizer(),
            ),
          },
        ),
        onCreatePlatformView: (params) =>
            PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: 'dev.weapp.container/view',
          layoutDirection: Directionality.of(context),
          creationParams: {'id': _controller.id},
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
              ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
              ..create(),
      );
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: 'dev.weapp.container/view',
        layoutDirection: Directionality.of(context),
        creationParams: {'id': _controller.id},
        creationParamsCodec: const StandardMessageCodec(),
        gestureRecognizers: {
          Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
        },
      );
    }
    throw UnsupportedError('Unsupported native platform');
  }

  void _pointer(String type, PointerEvent event) {
    final touch = <String, Object?>{
      'identifier': event.pointer,
      'clientX': event.localPosition.dx,
      'clientY': event.localPosition.dy,
      'pageX': event.localPosition.dx,
      'pageY': event.localPosition.dy,
    };
    if (type == 'touchend' || type == 'touchcancel') {
      _pointers.remove(event.pointer);
    } else {
      _pointers[event.pointer] = touch;
    }
    _input([
      {
        'type': type,
        'x': event.localPosition.dx,
        'y': event.localPosition.dy,
        'timeStamp': event.timeStamp.inMilliseconds,
        'touches': _pointers.values.toList(),
        'changedTouches': [touch],
        'detail': <String, Object?>{},
      },
    ]);
  }

  bool get _acceptsInput =>
      _texture != null &&
      _foreground == true &&
      !widget.occluded &&
      !_disposed &&
      !_controller.closeRequested;

  void _input(List<Map<String, Object?>> input) {
    if (_acceptsInput) _run(_controller.sendInput(input));
  }
}
