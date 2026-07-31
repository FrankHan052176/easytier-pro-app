import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:easytier_pro_app/src/logging/app_logger.dart';

void main() {
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
}
