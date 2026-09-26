import 'dart:async';
import 'dart:convert';

import 'package:easytier_pro_app/src/auth/console_auth_service.dart';
import 'package:easytier_pro_app/src/core/core_lifecycle_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const String _machineId = '6f1f5c3a-6d24-4a4b-9f0c-2c9a5e1d7b30';
const String _instanceId = 'bce27f42-5c4c-41ff-9a49-2db5fd2560ca';
const String _instanceName = 'demo-instance';
const String _runtimeNetworkLabel = 'et_demo';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OhosRuntimeSnapshot', () {
    test('parses the snapshot contract', () {
      final snapshot = OhosRuntimeSnapshot.parse(
        jsonEncode({
          'configServerConnected': true,
          'activeVpnInstanceName': _instanceName,
          'activeVpnInstanceId': _instanceId,
          'vpnConfig': _vpnConfig(),
          'instances': {_runtimeNetworkLabel: _instanceId},
          'lastError': '',
        }),
      );

      expect(snapshot, isNotNull);
      expect(snapshot!.configServerConnected, isTrue);
      expect(snapshot.activeVpnInstanceName, _instanceName);
      expect(snapshot.activeVpnInstanceId, _instanceId);
      expect(snapshot.instances, {_runtimeNetworkLabel: _instanceId});
    });

    test('rejects a payload without the control-plane flag', () {
      expect(OhosRuntimeSnapshot.parse('{}'), isNull);
      expect(OhosRuntimeSnapshot.parse('not-a-snapshot'), isNull);
      expect(OhosRuntimeSnapshot.parse(null), isNull);
    });

    test('skips instance map entries that are not instance ids', () {
      final snapshot = OhosRuntimeSnapshot.parse(
        jsonEncode({
          'configServerConnected': false,
          'instances': {
            '': _instanceId,
            _runtimeNetworkLabel: '',
            'nested': {'id': _instanceId},
            'other': _instanceId,
          },
        }),
      );

      expect(snapshot!.instances, {'other': _instanceId});
    });
  });

  group('OhosCoreRuntime', () {
    late _OhosRuntimeHarness harness;

    setUp(() {
      harness = _OhosRuntimeHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    group('app resume', () {
      test('keeps the native control session the snapshot reports', () async {
        harness.snapshot = _snapshotJson(
          configServerConnected: true,
          activeVpnInstanceName: _instanceName,
          activeVpnInstanceId: _instanceId,
          vpnConfig: _vpnConfig(),
          instances: {_runtimeNetworkLabel: _instanceId},
        );

        expect(await harness.runtime.shouldRecoverAfterAppResume(), isFalse);

        expect(harness.methodNames, contains('getRuntimeSnapshot'));
        expect(
          harness.methodNames,
          isNot(contains('isConfigServerClientConnected')),
        );
        expect(harness.methodNames, isNot(contains('startConfigServerClient')));
        expect(harness.vpnControlMethods, isEmpty);
      });

      test(
        'asks for recovery when the control plane is disconnected',
        () async {
          harness.snapshot = _snapshotJson();

          expect(await harness.runtime.shouldRecoverAfterAppResume(), isTrue);

          expect(harness.methodNames, contains('getRuntimeSnapshot'));
          expect(
            harness.methodNames,
            isNot(contains('startConfigServerClient')),
          );
        },
      );

      test('surfaces an unknown runtime instead of restarting it', () async {
        harness.snapshot = null;
        final events = harness.collectEvents();

        expect(await harness.runtime.shouldRecoverAfterAppResume(), isFalse);
        await events.waitFor(CoreRuntimeEventTypes.runtimeUnknown);

        expect(harness.methodNames, contains('getRuntimeSnapshot'));
        expect(harness.methodNames, isNot(contains('startConfigServerClient')));
        expect(harness.vpnControlMethods, isEmpty);
        final error = events.events
            .lastWhere(
              (event) => event.type == CoreRuntimeEventTypes.runtimeUnknown,
            )
            .data['error']
            ?.toString();
        expect(error, isNotNull);
        expect(error, isNotEmpty);
        // A runtime that cannot be read is unknown, never a failure state.
        expect(
          events.events.where(
            (event) => event.type == CoreRuntimeEventTypes.error,
          ),
          isEmpty,
        );
      });
    });

    group('status', () {
      test(
        'shows the tunnel that outlived a frozen UI without a control start',
        () async {
          harness.snapshot = _snapshotJson(
            configServerConnected: true,
            activeVpnInstanceName: _instanceName,
            activeVpnInstanceId: _instanceId,
            vpnConfig: _vpnConfig(),
            instances: {_runtimeNetworkLabel: _instanceId},
          );

          final status = await harness.runtime.readStatus(_bootstrap());

          expect(status, isNotNull);
          expect(status!.phase, CoreRunPhase.running);
          expect(status.machineId, _machineId);
          expect(harness.methodNames, contains('getRuntimeSnapshot'));
          expect(
            harness.methodNames,
            isNot(contains('isConfigServerClientConnected')),
          );
          expect(
            harness.methodNames,
            isNot(contains('startConfigServerClient')),
          );
          expect(harness.vpnControlMethods, isEmpty);
        },
      );

      test('reports unknown when the snapshot request fails', () async {
        harness.snapshot = null;

        expect(await harness.runtime.readStatus(_bootstrap()), isNull);

        expect(harness.methodNames, contains('getRuntimeSnapshot'));
      });

      test(
        'reports a known runtime that cannot be probed as an error',
        () async {
          harness.snapshot = _snapshotJson(
            configServerConnected: true,
            activeVpnInstanceName: _instanceName,
            activeVpnInstanceId: _instanceId,
            vpnConfig: _vpnConfig(),
          );
          expect(await harness.runtime.readStatus(_bootstrap()), isNotNull);
          harness.snapshot = null;

          await expectLater(
            harness.runtime.readStatus(_bootstrap()),
            throwsA(isA<PlatformException>()),
          );
          expect(harness.vpnControlMethods, isEmpty);
        },
      );

      test('reports a stopped runtime as unknown until it answers', () async {
        harness.snapshot = _snapshotJson(
          configServerConnected: true,
          activeVpnInstanceName: _instanceName,
          activeVpnInstanceId: _instanceId,
          vpnConfig: _vpnConfig(),
        );
        expect(await harness.runtime.readStatus(_bootstrap()), isNotNull);
        harness.snapshot = null;
        await harness.runtime.stop();

        expect(await harness.runtime.readStatus(_bootstrap()), isNull);
      });

      test('reports unknown for a payload that is not a snapshot', () async {
        harness.snapshot = '{}';

        expect(await harness.runtime.readStatus(_bootstrap()), isNull);
      });

      test('reports unknown while the control plane is disconnected', () async {
        harness.snapshot = _snapshotJson(
          activeVpnInstanceName: _instanceName,
          activeVpnInstanceId: _instanceId,
          vpnConfig: _vpnConfig(),
        );

        expect(await harness.runtime.readStatus(_bootstrap()), isNull);
      });
    });

    group('tunnel ownership', () {
      test('config server events never start, retain or re-route', () async {
        final events = harness.collectEvents();

        harness.emit(_configServerEvent());
        await events.waitFor(CoreRuntimeEventTypes.configServer);
        await _settle();

        expect(harness.methodNames, isNot(contains('startVpn')));
        expect(harness.methodNames, isNot(contains('retainNetworkInstance')));
        expect(harness.methodNames, isNot(contains('stopVpn')));
        expect(harness.methodNames, isNot(contains('callJsonRpc')));
      });

      test(
        'a granted permission does not start the pending instance',
        () async {
          final events = harness.collectEvents();

          harness.emit(_configServerEvent());
          harness.emit({
            'type': CoreRuntimeEventTypes.vpnPermissionGranted,
            'payload': <String, Object?>{},
          });
          await events.waitFor(CoreRuntimeEventTypes.configServer);
          await events.waitFor(CoreRuntimeEventTypes.vpnPermissionGranted);
          await _settle();

          expect(harness.vpnControlMethods, isEmpty);
          expect(harness.methodNames, isNot(contains('callJsonRpc')));
        },
      );

      test(
        'config server events do not start VPN for the active snapshot',
        () async {
          harness.snapshot = _snapshotJson(
            configServerConnected: true,
            activeVpnInstanceName: _instanceName,
            activeVpnInstanceId: _instanceId,
            vpnConfig: _vpnConfig(),
            instances: {_runtimeNetworkLabel: _instanceId},
          );
          expect(await harness.runtime.readStatus(_bootstrap()), isNotNull);
          final events = harness.collectEvents();

          harness.emit(_configServerEvent());
          harness.emit({
            'type': CoreRuntimeEventTypes.vpnStopped,
            'payload': <String, Object?>{'instanceName': _instanceName},
          });
          await events.waitFor(CoreRuntimeEventTypes.configServer);
          await events.waitFor(CoreRuntimeEventTypes.vpnStopped);
          await _settle();

          expect(harness.vpnControlMethods, isEmpty);
        },
      );
    });

    group('ensureRunning', () {
      test(
        'starts the control session and restores state from the snapshot',
        () async {
          harness.instances = {_instanceName: _instanceId};
          harness.snapshot = _snapshotJson(
            configServerConnected: true,
            activeVpnInstanceName: _instanceName,
            activeVpnInstanceId: _instanceId,
            vpnConfig: _vpnConfig(),
            instances: {_runtimeNetworkLabel: _instanceId},
          );

          final result = await harness.runtime.ensureRunning(
            _bootstrap(),
            forceReinstall: false,
          );

          expect(result.phase, CoreRunPhase.running);
          expect(harness.startedConfigServerUrl, isNotNull);
          expect(harness.methodNames, contains('startConfigServerClient'));
          expect(harness.methodNames, contains('getRuntimeSnapshot'));
          expect(harness.vpnControlMethods, isEmpty);

          // The snapshot read restored the instance map of the native runtime.
          final statuses = await harness.runtime.readNetworkPeerStatuses(
            _runtimeNetworkLabel,
          );
          expect(statuses.values.single.hostname, 'demo-host');
        },
      );

      test(
        'asks for VPN permission before starting the control session',
        () async {
          harness.prepareVpnPermission = false;

          final result = await harness.runtime.ensureRunning(
            _bootstrap(),
            forceReinstall: false,
          );

          expect(result.phase, CoreRunPhase.needsVpnPermission);
          expect(
            harness.methodNames,
            isNot(contains('startConfigServerClient')),
          );
          expect(harness.vpnControlMethods, isEmpty);
        },
      );

      test('reports a failure when the snapshot cannot be read', () async {
        harness.snapshot = null;

        await expectLater(
          harness.runtime.ensureRunning(_bootstrap(), forceReinstall: false),
          throwsA(isA<PlatformException>()),
        );

        expect(harness.methodNames, contains('startConfigServerClient'));
        expect(harness.vpnControlMethods, isEmpty);
      });
    });

    group('user exit', () {
      test('stops the native tunnel without any local VPN state', () async {
        await harness.runtime.preemptActiveVpnForExit();

        expect(harness.methodNames, <String>['stopVpn']);
      });

      test('stops the tunnel the snapshot reported as active', () async {
        harness.snapshot = _snapshotJson(
          configServerConnected: true,
          activeVpnInstanceName: _instanceName,
          activeVpnInstanceId: _instanceId,
          vpnConfig: _vpnConfig(),
        );
        expect(await harness.runtime.readStatus(_bootstrap()), isNotNull);

        await harness.runtime.preemptActiveVpnForExit();

        expect(harness.vpnControlMethods, <String>['stopVpn']);
      });

      test('resumes the native tunnel instead of replaying a config', () async {
        harness.snapshot = _snapshotJson(
          configServerConnected: true,
          activeVpnInstanceName: _instanceName,
          activeVpnInstanceId: _instanceId,
          vpnConfig: _vpnConfig(),
        );
        expect(await harness.runtime.readStatus(_bootstrap()), isNotNull);
        await harness.runtime.preemptActiveVpnForExit();

        await harness.runtime.restoreActiveVpnAfterFailedExit();

        expect(harness.vpnControlMethods, <String>['stopVpn', 'resumeVpn']);
        expect(harness.calls.last.arguments, isNull);
      });

      test('surfaces an unreachable runtime on preempt and restore', () async {
        harness.failingMethods.add('stopVpn');
        harness.failingMethods.add('resumeVpn');

        await expectLater(
          harness.runtime.preemptActiveVpnForExit(),
          throwsA(isA<PlatformException>()),
        );
        await expectLater(
          harness.runtime.restoreActiveVpnAfterFailedExit(),
          throwsA(isA<PlatformException>()),
        );
      });
    });

    group('runtime events', () {
      test('treats a runtime disconnect as unknown, not as a stop', () async {
        harness.snapshot = _snapshotJson(
          configServerConnected: true,
          activeVpnInstanceName: _instanceName,
          activeVpnInstanceId: _instanceId,
          vpnConfig: _vpnConfig(),
        );
        expect(await harness.runtime.readStatus(_bootstrap()), isNotNull);
        final events = harness.collectEvents();

        harness.emit({
          'type': 'runtime_disconnected',
          'payload': <String, Object?>{},
        });
        await events.waitFor('runtime_disconnected');
        harness.snapshot = null;
        await _settle();

        // A transport-only event neither stops the native runtime nor turns its
        // known state into a stopped runtime.
        expect(await harness.runtime.shouldRecoverAfterAppResume(), isFalse);
        await expectLater(
          harness.runtime.readStatus(_bootstrap()),
          throwsA(isA<PlatformException>()),
        );
        expect(harness.methodNames, isNot(contains('startConfigServerClient')));
        expect(harness.vpnControlMethods, isEmpty);
      });

      test('restores the instance map before any status read', () async {
        harness.instances = {_instanceName: _instanceId};
        final events = harness.collectEvents();

        harness.emit({
          'type': 'runtime_snapshot',
          'payload': _snapshotJson(
            configServerConnected: true,
            activeVpnInstanceName: _instanceName,
            activeVpnInstanceId: _instanceId,
            vpnConfig: _vpnConfig(),
            instances: {_runtimeNetworkLabel: _instanceId},
          ),
        });
        await events.waitFor('runtime_snapshot');

        final statuses = await harness.runtime.readNetworkPeerStatuses(
          _runtimeNetworkLabel,
        );

        expect(statuses.values.single.hostname, 'demo-host');
        expect(harness.vpnControlMethods, isEmpty);
      });

      test('ignores a payload that is not a snapshot', () async {
        final events = harness.collectEvents();
        harness.instances = {_instanceName: _instanceId};

        harness.emit({
          'type': 'runtime_snapshot',
          'payload': '{}',
        });
        await events.waitFor('runtime_snapshot');

        // The unusable payload left no state behind: the runtime still answers
        // from the real snapshot instead of a fabricated one.
        expect(await harness.runtime.readStatus(_bootstrap()), isNull);
      });

      test('drops aliases the snapshot no longer reports', () async {
        harness.instances = {_instanceName: _instanceId};
        final events = harness.collectEvents();

        // A pre-freeze event taught this UI the runtime label of an instance.
        harness.emit(_configServerEvent());
        await events.waitFor(CoreRuntimeEventTypes.configServer);
        expect(
          await harness.runtime.readNetworkPeerStatuses(_runtimeNetworkLabel),
          isNotEmpty,
        );

        // The snapshot of the reconnected runtime no longer lists that
        // network, so its label must stop resolving to a live instance.
        harness.emit({
          'type': 'runtime_snapshot',
          'payload': _snapshotJson(configServerConnected: true),
        });
        await events.waitFor('runtime_snapshot');
        await _settle();

        await expectLater(
          harness.runtime.readNetworkPeerStatuses(_runtimeNetworkLabel),
          throwsA(isA<StateError>()),
        );
      });
    });
  });

  group('OhosCoreRuntime route refresh', () {
    late _OhosRuntimeHarness harness;

    setUp(() {
      harness = _OhosRuntimeHarness();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('a native VPN start event schedules no route timer', () async {
      final events = harness.collectEvents();

      harness.emit({
        'type': CoreRuntimeEventTypes.vpnStarted,
        'payload': <String, Object?>{
          'instanceName': _instanceName,
          'addresses': <String>['10.126.0.9/24'],
          'routes': <String>['10.126.0.0/24'],
        },
      });
      await events.waitFor(CoreRuntimeEventTypes.vpnStarted);

      // The Android runtime refreshes the interface on a three second timer;
      // the Extension owns that now, so no refresh may be requested here.
      await Future<void>.delayed(const Duration(seconds: 4));

      expect(harness.methodNames, isNot(contains('callJsonRpc')));
      expect(harness.methodNames, isNot(contains('startVpn')));
      expect(harness.vpnControlMethods, isEmpty);
    });
  });
}

class _OhosRuntimeHarness {
  _OhosRuntimeHarness() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_methodChannel, _handleCall);
    runtime = OhosCoreRuntime(
      methodChannel: _methodChannel,
      eventChannel: _FakeEventChannel(nativeEvents.stream),
    );
  }

  static const MethodChannel _methodChannel = MethodChannel(
    'test.easytier/ohos_core_runtime',
  );

  final List<MethodCall> calls = <MethodCall>[];
  final StreamController<Object?> nativeEvents =
      StreamController<Object?>.broadcast();
  final List<StreamSubscription<CoreRuntimeEvent>> _eventSubscriptions =
      <StreamSubscription<CoreRuntimeEvent>>[];
  late final OhosCoreRuntime runtime;

  /// Snapshot JSON answered by `getRuntimeSnapshot`; `null` fails the request
  /// the way an unreachable runtime does.
  String? snapshot = _snapshotJson();

  /// Methods that must fail the way an unreachable runtime does.
  final Set<String> failingMethods = <String>{};
  bool prepareVpnPermission = true;
  Map<String, String> instances = <String, String>{};
  String? startedConfigServerUrl;

  List<String> get methodNames =>
      calls.map((call) => call.method).toList(growable: false);

  /// Calls that hand the tunnel to this process; the OHOS Extension owns them.
  List<String> get vpnControlMethods => calls
      .map((call) => call.method)
      .where(
        (method) => const <String>{
          'startVpn',
          'stopVpn',
          'resumeVpn',
          'retainNetworkInstance',
        }.contains(method),
      )
      .toList(growable: false);

  void emit(Object? event) {
    nativeEvents.add(event);
  }

  _CollectedEvents collectEvents() {
    final collected = _CollectedEvents();
    _eventSubscriptions.add(runtime.events.listen(collected._add));
    return collected;
  }

  Future<void> dispose() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_methodChannel, null);
    for (final subscription in _eventSubscriptions) {
      await subscription.cancel();
    }
    _eventSubscriptions.clear();
    await runtime.dispose();
    await nativeEvents.close();
  }

  Future<Object?> _handleCall(MethodCall call) async {
    calls.add(call);
    if (failingMethods.contains(call.method)) {
      throw PlatformException(
        code: 'OHOS_RUNTIME_IPC_FAILED',
        message: '${call.method} unavailable',
      );
    }
    switch (call.method) {
      case 'getRuntimeSnapshot':
        final value = snapshot;
        if (value == null) {
          throw PlatformException(
            code: 'OHOS_RUNTIME_IPC_FAILED',
            message: 'runtime unavailable',
          );
        }
        return value;
      case 'getMachineId':
        return _machineId;
      case 'getHostname':
        return 'harmony-host';
      case 'prepareNotifications':
        return true;
      case 'prepareVpn':
        return prepareVpnPermission;
      case 'startConfigServerClient':
        startedConfigServerUrl = (call.arguments as Map?)?['url']?.toString();
        return null;
      case 'listInstances':
        return jsonEncode(instances);
      case 'callJsonRpc':
        return _jsonRpcResponse(call);
      case 'stopVpn':
      case 'resumeVpn':
      case 'stopRuntime':
        return null;
      default:
        throw PlatformException(
          code: 'UNEXPECTED_METHOD',
          message: call.method,
        );
    }
  }

  String _jsonRpcResponse(MethodCall call) {
    final arguments = call.arguments as Map?;
    switch (arguments?['methodName']?.toString() ?? '') {
      case 'show_node_info':
        return jsonEncode({
          'node_info': {
            'virtual_ipv4': '10.126.0.9/24',
            'hostname': 'demo-host',
            'peer_id': 'demo-local-peer',
          },
        });
      case 'list_route':
        return jsonEncode({'routes': <Object?>[]});
      case 'list_peer':
        return jsonEncode({'peer_infos': <Object?>[]});
      default:
        return '{}';
    }
  }
}

class _CollectedEvents {
  final List<CoreRuntimeEvent> events = <CoreRuntimeEvent>[];

  List<String> get types =>
      events.map((event) => event.type).toList(growable: false);

  void _add(CoreRuntimeEvent event) {
    events.add(event);
  }

  Future<void> waitFor(
    String type, {
    Duration timeout = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (types.contains(type)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Timed out waiting for $type. Events: $types');
  }
}

CoreBootstrapConfig _bootstrap() {
  return const CoreBootstrapConfig(
    version: '2.6.4',
    configServer: 'tcp://127.0.0.1:22020',
    bootstrapToken: 'bootstrap-token',
  );
}

Map<String, Object?> _vpnConfig() {
  return <String, Object?>{
    'addresses': <String>['10.126.0.9/24'],
    'routes': <String>['10.126.0.0/24'],
  };
}

String _snapshotJson({
  bool configServerConnected = false,
  String activeVpnInstanceName = '',
  String activeVpnInstanceId = '',
  Map<String, Object?>? vpnConfig,
  Map<String, String> instances = const <String, String>{},
}) {
  return jsonEncode(<String, Object?>{
    'configServerConnected': configServerConnected,
    'activeVpnInstanceName': activeVpnInstanceName,
    'activeVpnInstanceId': activeVpnInstanceId,
    'vpnConfig': vpnConfig,
    'instances': instances,
    'lastError': '',
  });
}

Map<String, Object?> _configServerEvent() {
  return <String, Object?>{
    'type': CoreRuntimeEventTypes.configServer,
    'payload': <String, Object?>{
      'event': 'run_network_instance',
      'instance_name': _instanceName,
      'instance_id': _instanceId,
      'network_name': _runtimeNetworkLabel,
      'vpn_config': _vpnConfig(),
    },
  };
}

/// Lets the serialized native-event work that follows a delivered event run.
Future<void> _settle() {
  return Future<void>.delayed(const Duration(milliseconds: 50));
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
