
import { FlutterAbility, FlutterEngine } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import OhosCoreRuntimeBridge from '../runtime/OhosCoreRuntimeBridge';
import { getOhosBackgroundTaskService } from '../runtime/OhosBackgroundTaskService';
import OhosSharedPreferencesBridge from '../runtime/OhosSharedPreferencesBridge';
import OhosUrlLauncherBridge from '../runtime/OhosUrlLauncherBridge';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)
    flutterEngine.getPlugins()?.add(new OhosSharedPreferencesBridge())
    flutterEngine.getPlugins()?.add(new OhosCoreRuntimeBridge())
    flutterEngine.getPlugins()?.add(new OhosUrlLauncherBridge())
  }

  onForeground(): void {
    getOhosBackgroundTaskService(this.context).setUiBackground(false);
    super.onForeground();
  }

  onBackground(): void {
    super.onBackground();
    getOhosBackgroundTaskService(this.context).setUiBackground(true);
  }

  onDestroy(): void {
    getOhosBackgroundTaskService(this.context).setUiBackground(false);
    super.onDestroy();
  }
}
