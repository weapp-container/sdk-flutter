import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'controller.dart';

/// A real embedded platform view on mobile and a native texture on desktop.
/// Give this widget finite positive constraints. Its controller outlives detach.
class WeappContainerView extends StatefulWidget {
  const WeappContainerView({
    super.key,
    required this.controller,
    this.foreground = true,
    this.occluded = false,
    this.hostChrome,
    this.nativeChrome,
    this.onHostChromeApplied,
    this.onError,
  });
  final WeappContainerController controller;
  final bool foreground;

  /// Presentation/input suspension only. App lifecycle and timers keep running.
  final bool occluded;
  final Map<String, Object?>? hostChrome;
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
  int? _hostChromeRevision;
  int? _nativeChromeRevision;
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
    if (_foreground == next || _controller.isClosed) return;
    _foreground = next;
    _run(_controller.setForeground(next));
  }

  void _updateChrome() {
    final geometry = widget.hostChrome;
    final native = widget.nativeChrome;
    final geometryRevision = geometry?['revision'] as int?;
    final nativeRevision = native?['revision'] as int?;
    final geometryChanged =
        geometry != null && geometryRevision != _hostChromeRevision;
    final nativeChanged = native != null &&
        nativeRevision != _nativeChromeRevision &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux);
    final occlusionChanged = widget.occluded != _occluded;
    if (!geometryChanged && !nativeChanged && !occlusionChanged) return;
    if (geometryChanged) _hostChromeRevision = geometryRevision;
    if (nativeChanged) _nativeChromeRevision = nativeRevision;
    final occluded = widget.occluded;
    _occluded = occluded;
    _chromeSync =
        _chromeSync.catchError((Object _, StackTrace __) {}).then((_) async {
      await _ready;
      if (_disposed || _controller.isClosed) return;
      // Suspend first when covering; restore only after the geometry/controls
      // matching the accepted generation have reached the native owner.
      if (occlusionChanged && occluded) {
        await _controller.setPreviewOccluded(true);
        _nativeOccluded = true;
      }
      if (geometryChanged) {
        try {
          await _controller.updateHostChrome(geometry);
        } on PlatformException catch (error) {
          if (error.code == 'ERR_CANCELLED') {
            if (_disposed ||
                !mounted ||
                widget.hostChrome?['revision'] != geometryRevision) return;
            // Runtime navigation can win before Flutter consumes its chrome
            // event. Confirm the new owner instead of faulting a healthy page.
            final current = await _controller.state();
            final currentPage = current['page'];
            if ((geometry['sessionId'] != null &&
                    geometry['sessionId'] != current['sessionId']) ||
                (geometry['pageId'] != null &&
                    currentPage is Map &&
                    geometry['pageId'] != currentPage['id'])) {
              _hostChromeRevision = null;
              return;
            }
          }
          rethrow;
        }
        if (!_disposed &&
            mounted &&
            widget.hostChrome?['revision'] == geometryRevision &&
            geometryRevision != null) {
          widget.onHostChromeApplied?.call(geometryRevision);
        }
      }
      if (nativeChanged) await _controller.updateNativeChrome(native);
      if (!occluded && _nativeOccluded) {
        await _controller.setPreviewOccluded(false);
        _nativeOccluded = false;
      }
    });
    _run(_chromeSync);
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
      while (!_disposed && _pendingMetrics != null) {
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
      !_controller.isClosed;

  void _input(List<Map<String, Object?>> input) {
    if (_acceptsInput) _run(_controller.sendInput(input));
  }
}
