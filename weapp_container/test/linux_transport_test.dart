import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:weapp_container_platform_interface/weapp_container_platform_interface.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('weapp-test/linux-methods');
  const eventChannel = EventChannel('weapp-test/linux-events');
  const codec = StandardMethodCodec();
  Uint8List encode(Object? value) =>
      Uint8List.fromList(utf8.encode(jsonEncode(value)));
  Object? decode(Object? value) => jsonDecode(utf8.decode(value as Uint8List));

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('weapp-test/linux-events'),
      null,
    );
  });

  test('Linux bytes preserve nested Unicode, NUL, null and session IDs',
      () async {
    final transport = MethodChannelWeappContainer(
      methods: methods,
      events: eventChannel,
      jsonByteTransport: true,
    );
    final payload = <String, Object?>{
      'id': 9007199254740991,
      'message': {
        'text': '中文 🧊 \u0000 after',
        'empty': null,
        'items': [false, 1.5]
      },
    };
    final received = <Object?>[];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods,
        (call) async {
      received.add(decode(call.arguments));
      return call.method == 'echo'
          ? encode(decode(call.arguments))
          : encode(null);
    });
    expect(await transport.invoke<Map>('echo', payload), payload);
    expect(await transport.invoke<Object?>('void', {'id': 1}), isNull);
    expect(received, [
      payload,
      {'id': 1}
    ]);
  });

  test('Linux initialization and event bytes preserve cancellation identity',
      () async {
    final transport = MethodChannelWeappContainer(
      methods: methods,
      events: eventChannel,
      jsonByteTransport: true,
    );
    final listening = Completer<void>();
    Object? initialize;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods,
        (call) async {
      initialize = decode(call.arguments);
      return null;
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('weapp-test/linux-events'),
      (call) async {
        if (call.method == 'listen') listening.complete();
        return null;
      },
    );
    final first = transport.events.first;
    await transport.initialize();
    await listening.future;
    expect((initialize as Map)['clientEpoch'], isA<String>());
    final event = {
      'id': 7,
      'event': {'type': 'hostCallCancelled', 'callId': 'request\u0000suffix'},
    };
    await binding.defaultBinaryMessenger.handlePlatformMessage(
      'weapp-test/linux-events',
      codec.encodeSuccessEnvelope(encode(event)),
      (_) {},
    );
    expect(await first, event);
  });

  test('Structured platforms retain native map and platform errors', () async {
    final transport = MethodChannelWeappContainer(
      methods: methods,
      events: eventChannel,
      jsonByteTransport: false,
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(methods,
        (call) async {
      if (call.method == 'fail')
        throw PlatformException(code: 'cancelled', message: 'retired');
      return call.arguments;
    });
    expect(await transport.invoke<Map>('echo', {'value': 'a\u0000b'}),
        {'value': 'a\u0000b'});
    await expectLater(
        transport.invoke<void>('fail', {}),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
        ));
  });
}
