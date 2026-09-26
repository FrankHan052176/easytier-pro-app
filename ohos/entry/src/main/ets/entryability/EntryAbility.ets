
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import OhosCoreRuntimeBridge from '../runtime/OhosCoreRuntimeBridge';
import OhosSharedPreferencesBridge from '../runtime/OhosSharedPreferencesBridge';
import OhosUrlLauncherBridge from '../runtime/OhosUrlLauncherBridge';

export default class EntryAbility extends FlutterAbility {
  private runtimeBridge: OhosCoreRuntimeBridge = new OhosCoreRuntimeBridge();

  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new OhosSharedPreferencesBridge())
    flutterEngine.getPlugins()?.add(this.runtimeBridge)
    flutterEngine.getPlugins()?.add(new OhosUrlLauncherBridge())
  }

  onForeground(): void {
    this.runtimeBridge.onForeground();
    super.onForeground();
  }

}
