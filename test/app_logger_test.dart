import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easytier_pro_app/src/logging/app_logger.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('HarmonyOS logs use the UIAbility sandbox files directory', () {
    final directory = resolveAppLogDirectoryForPlatform(
      operatingSystem: 'ohos',
      targetPlatform: TargetPlatform.ohos,
      environment: const <String, String>{'HOME': '/storage/Users/currentUser'},
      systemTempPath: '/data/storage/el2/base/temp',
      ohosFilesDir: '/data/storage/el2/base/haps/entry/files',
    );

    expect(directory.path, '/data/storage/el2/base/haps/entry/files/logs');
    expect(directory.path, isNot(contains('/storage/Users/currentUser')));
  });

  test('HarmonyOS logger keeps a sandboxed temporary fallback', () {
    final directory = resolveAppLogDirectoryForPlatform(
      operatingSystem: 'ohos',
      targetPlatform: TargetPlatform.ohos,
      environment: const <String, String>{'HOME': '/storage/Users/currentUser'},
      systemTempPath: '/data/storage/el2/base/temp',
    );

    expect(directory.path, '/data/storage/el2/base/temp/easytier-pro-app/logs');
    expect(directory.path, isNot(contains('/storage/Users/currentUser')));
  });

  test(
    'HarmonyOS prepares and returns the persistent download directory',
    () async {
      const channel = MethodChannel('test.easytier/diagnostics_download');
      MethodCall? receivedCall;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            receivedCall = call;
            return '/storage/Users/currentUser/Download/net.easytier.pro';
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final directory = await requestOhosDiagnosticsExportDirectory(
        channel: channel,
      );

      expect(receivedCall?.method, 'prepareDiagnosticsExportDirectory');
      expect(directory, '/storage/Users/currentUser/Download/net.easytier.pro');
    },
  );

  test('HarmonyOS rejects an empty download directory response', () async {
    const channel = MethodChannel('test.easytier/diagnostics_download_empty');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => '  ');
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    await expectLater(
      requestOhosDiagnosticsExportDirectory(channel: channel),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'OHOS_DIAGNOSTICS_DIRECTORY_UNAVAILABLE',
        ),
      ),
    );
  });
}
