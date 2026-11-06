// Independent public API acceptance host. Copy into a prepared consumer's lib/.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:weapp_container/weapp_container.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HostLifecycleConsumer());
}

class HostLifecycleConsumer extends StatefulWidget {
  const HostLifecycleConsumer({super.key});
  @override
  State<HostLifecycleConsumer> createState() => _HostLifecycleConsumerState();
}

class _HostLifecycleConsumerState extends State<HostLifecycleConsumer> {
  final navigator = GlobalKey<NavigatorState>();
  final primaryKey = GlobalKey();
  final detailKey = GlobalKey();
  final parentScroll = ScrollController();
  final checks = <String>[];
  final issues = <String>[];
  final history = <Map<String, dynamic>>[];
  WeappContainerController? controller;
  StreamSubscription<WeappContainerEvent>? events;
  File? reportFile;
  Future<void> writes = Future.value();
  String stage = 'starting';
  String? error;
  bool primaryVisible = true;
  bool onDetail = false;
  bool checkingWheel = false;
  double parentBeforeChildWheel = 0;
  double previousNativeScrollTop = 0;
  int taps = 0;
  Map<String, dynamic>? geometry;
  Map<String, dynamic>? initial;
  bool get desktop =>
      Platform.isMacOS || Platform.isWindows || Platform.isLinux;
  String semanticsReport = '{}';
  bool reportScheduled = false;

  List<int> textureIds(GlobalKey key) {
    final found = <int>[];
    void visit(Element element) {
      if (element.widget case Texture texture) found.add(texture.textureId);
      element.visitChildElements(visit);
    }

    final context = key.currentContext;
    if (context is Element) visit(context);
    return found;
  }

  int platformViewCount(GlobalKey key) {
    var count = 0;
    void visit(Element element) {
      if (element.widget is AndroidViewSurface || element.widget is UiKitView)
        count++;
      element.visitChildElements(visit);
    }

    final context = key.currentContext;
    if (context is Element) visit(context);
    return count;
  }

  int presentationCount(GlobalKey key) =>
      desktop ? textureIds(key).length : platformViewCount(key);

  Map<String, Object?> get report {
    final key = onDetail ? detailKey : primaryKey;
    final render = key.currentContext?.findRenderObject();
    final box = render is RenderBox && render.hasSize ? render : null;
    final origin = box?.localToGlobal(Offset.zero);
    return {
      'schemaVersion': 1,
      'stage': stage,
      'status': error != null
          ? 'failed'
          : stage == 'complete'
          ? (issues.isEmpty ? 'passed' : 'failed')
          : 'running',
      'error': error,
      'issues': issues,
      'checks': checks,
      'controllerId': controller?.id,
      'closed': controller?.isClosed,
      'route': onDetail ? 'detail' : 'primary',
      'parentOffset': parentScroll.hasClients ? parentScroll.offset : 0,
      'tapCount': taps,
      'textureIds': textureIds(key),
      'platformViewCount': platformViewCount(key),
      'viewOrigin': origin == null ? null : {'x': origin.dx, 'y': origin.dy},
      'viewSize': box == null
          ? null
          : {'width': box.size.width, 'height': box.size.height},
      'geometry': geometry,
      'history': history,
    };
  }

  @override
  void initState() {
    super.initState();
    parentScroll.addListener(changed);
    unawaited(start().catchError(fail));
  }

  void changed() {
    if (mounted) setState(() {});
    save();
  }

  void save() {
    final file = reportFile;
    if (file == null || reportScheduled) return;
    reportScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      reportScheduled = false;
      if (!mounted) return;
      final value = jsonEncode(report);
      writes = writes.then((_) => file.writeAsString(value, flush: true));
      if (semanticsReport != value)
        setState(() {
          semanticsReport = value;
        });
    });
  }

  void fail(Object value, [StackTrace? stack]) {
    error = '$value\n${stack ?? ''}';
    stage = 'failed';
    changed();
  }

  Future<void> start() async {
    final support = await getApplicationSupportDirectory();
    reportFile = File('${support.path}/sdk-flutter-host-lifecycle.json');
    final pack = '${support.path}/sdk-host-lifecycle-pack';
    final names = jsonDecode(
      await rootBundle.loadString('assets/fixture-index.json'),
    ) as List;
    for (final name in names.cast<String>()) {
      final data = await rootBundle.load('assets/portable-pack/$name');
      final file = File('$pack/$name');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
    }
    final c = await WeappContainerController.create(
      storageKey: 'flutter-host-lifecycle-acceptance',
    );
    await c.registerHostMethod(
      'native.echo',
      (call) async => {'value': call.payload},
    );
    await c.registerHostMethod('native.delayed', (call) async => 'hidden-ok');
    await c.registerHostMethod('host.echo', (call) async => call.payload);
    events = c.events.listen(handle, onError: fail);
    controller = c;
    changed();
    await c.load(pack);
    await attached(primaryKey);
    initial = Map<String, dynamic>.from(await c.state());
    history.add({
      'action': 'initial',
      'state': initial,
      'textureIds': textureIds(primaryKey),
    });
    await c.sendMessage({'op': 'inspect'});
    checks.add('bounded-public-view-in-parent-scroll-container');
    stage = 'scroll-parent-then-check';
    changed();
  }

  void handle(WeappContainerEvent event) {
    if (event.type == 'error') {
      fail(StateError(event.fields.toString()));
      return;
    }
    if (event.type != 'message' || event.message is! Map) return;
    final message = Map<String, dynamic>.from(event.message as Map);
    if (message['kind'] == 'geometry') geometry = message;
    if (message['kind'] == 'tap') {
      taps = (message['count'] as num).toInt();
      if (stage == 'click-child-after-parent-scroll') {
        checks.add('native-pointer-coordinates-after-parent-scroll');
        parentBeforeChildWheel = parentScroll.offset;
        stage = 'scroll-child';
      }
    }
    if (message['kind'] == 'scroll' &&
        (stage == 'scroll-child' || stage == 'drag-child') &&
        !checkingWheel) {
      checkingWheel = true;
      unawaited(checkWheel(message).catchError(fail));
    }
    changed();
  }

  Future<void> checkWheel(Map<String, dynamic> message) async {
    final dragging = stage == 'drag-child';
    final nativeScrollTop = (message['scrollTop'] as num).toDouble();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final delta = parentScroll.offset - parentBeforeChildWheel;
    history.add({
      'action': dragging ? 'child-drag' : 'child-scroll',
      'nativeScrollTop': message['scrollTop'],
      'parentBefore': parentBeforeChildWheel,
      'parentAfter': parentScroll.offset,
    });
    if (nativeScrollTop <= previousNativeScrollTop) {
      throw StateError('Native child input did not advance its scroll offset');
    }
    previousNativeScrollTop = nativeScrollTop;
    checks.add(
      dragging
          ? 'native-child-drag-receives-input'
          : 'native-child-scroll-receives-input',
    );
    if (delta.abs() > 1) {
      issues.add(
        'Child ${dragging ? 'drag' : 'scroll'} input also scrolled the Flutter parent by $delta logical pixels',
      );
    } else {
      checks.add(
        dragging
            ? 'child-drag-does-not-double-scroll-parent'
            : 'child-scroll-does-not-double-scroll-parent',
      );
    }
    stage = desktop && !dragging ? 'arm-child-drag' : 'move-route';
    changed();
  }

  void armChildDrag() {
    parentBeforeChildWheel = parentScroll.offset;
    checkingWheel = false;
    stage = 'drag-child';
    changed();
  }

  Future<void> checkParent() async {
    if (parentScroll.offset < 20)
      throw StateError('Scroll the Flutter header first');
    history.add({'action': 'parent-scroll', 'offset': parentScroll.offset});
    checks.add('real-parent-scroll-with-live-native-texture');
    await controller!.sendMessage({'op': 'inspect'});
    stage = 'click-child-after-parent-scroll';
    changed();
  }

  Future<void> until(Future<bool> Function() condition) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!await condition()) {
      if (DateTime.now().isAfter(end))
        throw TimeoutException('Waiting during $stage');
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  bool presentationActive(Map<String, dynamic> state) =>
      state['foreground'] == true &&
      ((Platform.isLinux || Platform.isWindows) || state['surface'] != null);

  Future<void> attached(GlobalKey key) => until(() async {
    final state = await controller!.state();
    return presentationActive(state) && presentationCount(key) == 1;
  });

  Future<void> detached() => until(() async {
    final state = await controller!.state();
    return state['foreground'] == false && state['surface'] == null;
  });

  void sameSession(Map<String, dynamic> state) {
    if (state['sessionId'] != initial!['sessionId'] ||
        state['generation'] != initial!['generation']) {
      throw StateError('Host navigation replaced the SDK session');
    }
  }

  Future<void> moveRoute() async {
    final c = controller!;
    primaryVisible = false;
    stage = 'moving-route';
    changed();
    await WidgetsBinding.instance.endOfFrame;
    await detached();
    history.add({
      'action': 'primary-retired',
      'state': await c.state(),
      'textureIds': textureIds(primaryKey),
    });
    onDetail = true;
    final returned = navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text('SDK on second Flutter route')),
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: SizedBox(
              key: detailKey,
              height: 330,
              width: double.infinity,
              child: WeappContainerView(controller: c, onError: fail),
            ),
          ),
        ),
      ),
    );
    await attached(detailKey);
    final detail = Map<String, dynamic>.from(await c.state());
    sameSession(detail);
    history.add({
      'action': 'detail-attached',
      'state': detail,
      'textureIds': textureIds(detailKey),
    });
    checks.add('navigator-push-transfers-single-view-lease');
    stage = 'pop-flutter-route';
    changed();
    await returned;
    await detached();
    history.add({
      'action': 'detail-retired',
      'state': await c.state(),
      'textureIds': textureIds(detailKey),
    });
    onDetail = false;
    primaryVisible = true;
    changed();
    await attached(primaryKey);
    final back = Map<String, dynamic>.from(await c.state());
    sameSession(back);
    history.add({
      'action': 'primary-reattached',
      'state': back,
      'textureIds': textureIds(primaryKey),
    });
    checks.add('navigator-pop-preserves-controller-session-and-generation');
    stage = 'ready-to-close';
    changed();
  }

  Future<void> finish() async {
    final c = controller!;
    final state = Map<String, dynamic>.from(await c.state());
    sameSession(state);
    if (!presentationActive(state) || presentationCount(primaryKey) != 1) {
      throw StateError('Expected one current presentation lease before close');
    }
    history.add({
      'action': 'before-close',
      'state': state,
      'textureIds': textureIds(primaryKey),
    });
    await c.close();
    primaryVisible = false;
    changed();
    await WidgetsBinding.instance.endOfFrame;
    if (!c.isClosed || presentationCount(primaryKey) != 0)
      throw StateError('Close retained the presentation');
    checks.add(
      'close-after-host-navigation-retires-public-controller-and-texture',
    );
    history.add({
      'action': 'after-close',
      'closed': c.isClosed,
      'textureIds': textureIds(primaryKey),
    });
    stage = 'complete';
    changed();
    await writes;
  }

  @override
  void dispose() {
    unawaited(events?.cancel());
    unawaited(controller?.close());
    parentScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigator,
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Host lifecycle'),
        actions: [
          if (stage == 'scroll-parent-then-check')
            TextButton(
              onPressed: () => unawaited(checkParent().catchError(fail)),
              child: const Text('Check parent'),
            ),
          if (stage == 'arm-child-drag')
            TextButton(onPressed: armChildDrag, child: const Text('Test drag')),
          if (stage == 'move-route')
            TextButton(
              onPressed: () => unawaited(moveRoute().catchError(fail)),
              child: const Text('Move route'),
            ),
          if (stage == 'ready-to-close')
            TextButton(
              onPressed: () => unawaited(finish().catchError(fail)),
              child: const Text('Close SDK'),
            ),
        ],
      ),
      body: Column(
        children: [
          Semantics(
            label: semanticsReport,
            excludeSemantics: true,
            child: SizedBox(
              height: 52,
              child: Text(
                error ??
                    '$stage · parent ${parentScroll.hasClients ? parentScroll.offset.toStringAsFixed(1) : 0}',
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: parentScroll,
              child: Column(
                children: [
                  Container(
                    height: 140,
                    color: Colors.amber.shade100,
                    alignment: Alignment.center,
                    child: const Text(
                      'Scroll this Flutter parent header, then Check parent',
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      key: primaryKey,
                      height: 330,
                      width: double.infinity,
                      child: controller == null || !primaryVisible
                          ? const SizedBox.shrink()
                          : WeappContainerView(
                              controller: controller!,
                              onError: fail,
                            ),
                    ),
                  ),
                  Container(
                    height: 700,
                    color: Colors.blueGrey.shade50,
                    alignment: Alignment.topCenter,
                    child: const Text('Flutter parent footer'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
