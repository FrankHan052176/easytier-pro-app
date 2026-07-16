import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';

void main() {
  group('OhosCoreRuntime app resume recovery', () {
    late StreamController<Object?> nativeEvents;
    late MethodChannel methodChannel;
    late OhosCoreRuntime runtime;
    var configServerConnected = false;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      nativeEvents = StreamController<Object?>.broadcast();
      methodChannel = const MethodChannel('test.easytier/ohos_core_runtime');
      configServerConnected = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, (MethodCall call) async {
            if (call.method == 'isConfigServerClientConnected') {
              return configServerConnected;
            }
            fail('Unexpected HarmonyOS method call: ${call.method}');
          });
      runtime = OhosCoreRuntime(
        methodChannel: methodChannel,
        eventChannel: _FakeEventChannel(nativeEvents.stream),
      );
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodChannel, null);
      await runtime.dispose();
      await nativeEvents.close();
    });

    test('keeps a connected config server after resume', () async {
      configServerConnected = true;

      expect(await runtime.shouldRecoverAfterAppResume(), isFalse);
    });

    test('recovers a disconnected config server after resume', () async {
      expect(await runtime.shouldRecoverAfterAppResume(), isTrue);
    });
  });
}

class _FakeEventChannel extends EventChannel {
  _FakeEventChannel(this._events)
    : super('test.easytier/ohos_core_runtime_events');

  final Stream<Object?> _events;

  @override
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) {
    return _events;
  }
}
