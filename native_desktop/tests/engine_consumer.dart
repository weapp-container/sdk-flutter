import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

const methods = MethodChannel('dev.weapp.container/methods');
const eventChannel = EventChannel('dev.weapp.container/events');
const pack = String.fromEnvironment('WEAPP_TEST_PACK');
const evidence = String.fromEnvironment('WEAPP_TEST_EVIDENCE');
final texture = ValueNotifier<int?>(null);
final boundary = GlobalKey();
final received = <Map<dynamic, dynamic>>[];
Object? decodeChannel(Object? value) => Platform.isLinux && value is Uint8List
    ? jsonDecode(utf8.decode(value))
    : value;
Future<dynamic> call(
  String method, [
  Map<String, dynamic> arguments = const {},
]) async {
  debugPrint('native start $method');
  final result = await methods
      .invokeMethod(
        method,
        Platform.isLinux
            ? Uint8List.fromList(utf8.encode(jsonEncode(arguments)))
            : arguments,
      )
      .timeout(const Duration(seconds: 15));
  debugPrint('native complete $method');
  return decodeChannel(result);
}

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

Future<void> waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline))
      throw TimeoutException('native event timed out: $received');
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

Future<Map<String, dynamic>> metrics(int id, {double? scale}) async {
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final dpr = scale ?? view.devicePixelRatio;
  return {
    'id': id,
    'windowWidth': 320,
    'windowHeight': 440,
    'pixelRatio': dpr,
    'screenWidth': view.display.size.width / view.display.devicePixelRatio,
    'screenHeight': view.display.size.height / view.display.devicePixelRatio,
    'statusBarHeight': 0,
    'screenTop': 0,
    'deviceOrientation': 'landscape',
  };
}

Future<void> linuxRetirement(int first, Map<String, dynamic> report) async {
  final slots = <int>{texture.value!};
  final peer =
      (await call('create', {'storageKey': 'engine-peer'}))['id'] as int;
  slots.add((await call('attach', await metrics(peer)))['textureId'] as int);
  await call('load', {
    'id': peer,
    'packPath': pack,
    'options': <String, dynamic>{},
  });
  await call('sendMessage', {
    'id': peer,
    'message': {'op': 'store', 'value': 'peer-only'},
  });
  for (var cycle = 0; cycle < 24; cycle++) {
    final id = cycle.isEven ? first : peer;
    await call('setForeground', {'id': id, 'foreground': false});
    texture.value = null;
    await call('detach', {'id': id});
    final next = (await call('attach', await metrics(id)))['textureId'] as int;
    slots.add(next);
    texture.value = next;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    if (cycle < 2) {
      final image =
          await (boundary.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final colors = <int>{};
      for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
        colors.add(bytes.getUint32(i));
      }
      image.dispose();
      check(colors.length == 1, 'reused empty texture exposed a prior frame');
    }
    await call('setForeground', {'id': id, 'foreground': true});
    await Future<void>.delayed(const Duration(milliseconds: 35));
  }
  check(
    slots.length == 2,
    'retired texture pool grew beyond concurrent high-water mark',
  );
  texture.value = null;
  await call('close', {'id': peer});
  final again =
      (await call('create', {'storageKey': 'engine-peer'}))['id'] as int;
  texture.value =
      (await call('attach', await metrics(again)))['textureId'] as int;
  await call('load', {
    'id': again,
    'packPath': pack,
    'options': <String, dynamic>{},
  });
  await call('sendMessage', {
    'id': again,
    'message': {'op': 'read'},
  });
  await waitFor(
    () => received.any(
      (event) =>
          event['id'] == again &&
          event['event']['type'] == 'message' &&
          event['event']['message']['kind'] == 'storedValue' &&
          event['event']['message']['value'] == 'peer-only',
    ),
  );
  texture.value = null;
  await call('close', {'id': again});
  report['retirementCycles'] = 24;
  report['concurrentTextureSlots'] = slots.length;
  report['emptyReattachPixels'] = 'transparent';
}

Future<void> runChecks() async {
  final subscription = eventChannel.receiveBroadcastStream().listen((
    dynamic event,
  ) {
    received.add(Map<dynamic, dynamic>.from(decodeChannel(event) as Map));
  });
  final report = <String, dynamic>{'engine': Platform.operatingSystem};
  try {
    await call('initialize', {'clientEpoch': 'engine-consumer-1'});
    final id =
        (await call('create', {'storageKey': 'engine-consumer'}))['id'] as int;
    bool loaded = false;
    final load =
        call('load', {
          'id': id,
          'packPath': pack,
          'options': <String, dynamic>{},
        }).then((_) {
          loaded = true;
        });
    await Future<void>.delayed(const Duration(milliseconds: 50));
    check(!loaded, 'load completed before measured attach');
    texture.value =
        (await call('attach', await metrics(id)))['textureId'] as int;
    await load;
    await waitFor(() => received.any((e) => e['event']['type'] == 'frame'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // A TextureLayer must contribute real external pixels to this snapshot.
    final image =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final colors = <int>{};
    for (var i = 0; i < bytes!.lengthInBytes; i += 4) {
      colors.add(bytes.getUint32(i));
    }
    check(
      colors.length > 8,
      'Flutter Texture did not composite native pixels (${colors.length} colors)',
    );
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('$evidence/texture.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    report['textureColors'] = colors.length;
    report['capabilities'] = await call('capabilities', {'id': id});
    final before = await call('state', {'id': id});
    try {
      await call('load', {
        'id': id,
        'packPath': '/does/not/exist',
        'options': <String, dynamic>{},
      });
      throw StateError('invalid pack accepted');
    } on PlatformException catch (_) {}
    check(
      (await call('state', {'id': id}))['generation'] == before['generation'],
      'failed load changed generation',
    );
    await call('navigate', {
      'id': id,
      'route': 'pages/detail/index',
      'query': <String, dynamic>{},
      'replace': false,
    });
    await call('back', {'id': id});
    await call('sendMessage', {
      'id': id,
      'message': {'op': 'store', 'value': '中文 🧊 \u0000 persisted'},
    });
    await call('flushStorage', {'id': id});
    await call('resize', await metrics(id, scale: 2));
    await call('setForeground', {'id': id, 'foreground': false});
    await call('sendMessage', {
      'id': id,
      'message': {'kind': 'hidden-pump'},
    });
    await waitFor(
      () => received.any(
        (e) =>
            e['event']['type'] == 'message' &&
            e['event']['message']['message']?['kind'] == 'hidden-pump',
      ),
    );
    texture.value = null;
    await call('detach', {'id': id});
    texture.value =
        (await call('attach', await metrics(id)))['textureId'] as int;
    await call('setForeground', {'id': id, 'foreground': true});
    if (Platform.isLinux) await linuxRetirement(id, report);
    await call('initialize', {'clientEpoch': 'engine-consumer-2'});
    texture.value = null;
    final reopened =
        (await call('create', {'storageKey': 'engine-consumer'}))['id'] as int;
    check(reopened > id, 'new epoch reused a session id');
    texture.value =
        (await call('attach', await metrics(reopened)))['textureId'] as int;
    await call('load', {
      'id': reopened,
      'packPath': pack,
      'options': <String, dynamic>{},
    });
    await call('sendMessage', {
      'id': reopened,
      'message': {'op': 'read'},
    });
    await waitFor(
      () => received.any(
        (e) =>
            e['id'] == reopened &&
            e['event']['type'] == 'message' &&
            e['event']['message']['kind'] == 'storedValue' &&
            e['event']['message']['value'] == '中文 🧊 \u0000 persisted',
      ),
    );
    texture.value = null;
    await call('close', {'id': reopened});
    await call('close', {'id': reopened});
    report['status'] = 'passed';
    report['events'] = received.length;
  } catch (error, stack) {
    report['status'] = 'failed';
    report['error'] = '$error';
    report['stack'] = '$stack';
  } finally {
    await subscription.cancel();
    await File('$evidence/result.json')
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  }
  if (Platform.isLinux && report['status'] == 'passed') {
    await SystemNavigator.pop();
  } else {
    exit(report['status'] == 'passed' ? 0 : 1);
  }
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: RepaintBoundary(
            key: boundary,
            child: SizedBox(
              width: 320,
              height: 440,
              child: ValueListenableBuilder<int?>(
                valueListenable: texture,
                builder: (context, id, _) => id == null
                    ? const ColoredBox(color: Colors.black)
                    : Texture(textureId: id),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(runChecks());
  });
}
