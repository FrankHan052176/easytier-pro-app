import { Context } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

const METHOD_CHANNEL_NAME = 'plugins.flutter.io/shared_preferences';
const PREFERENCES_NAME = 'EasyTierProSharedPreferences';

export default class OhosSharedPreferencesBridge implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private context: Context | null = null;

  getUniqueClassName(): string {
    return 'OhosSharedPreferencesBridge';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    this.channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
    this.context = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    try {
      switch (call.method) {
        case 'getAll':
          result.success(this.getAll('', null));
          return;
        case 'getAllWithParameters':
          result.success(this.getAllWithParameters(call));
          return;
        case 'setBool':
          result.success(this.setValue(call, this.readBoolArgument(call, 'value')));
          return;
        case 'setDouble':
        case 'setInt':
          result.success(this.setValue(call, this.readNumberArgument(call, 'value')));
          return;
        case 'setString':
          result.success(this.setValue(call, this.readStringArgument(call, 'value')));
          return;
        case 'setStringList':
          result.success(this.setValue(call, this.readStringArrayArgument(call, 'value')));
          return;
        case 'remove':
          result.success(this.remove(call));
          return;
        case 'clear':
          result.success(this.clear());
          return;
        case 'clearWithParameters':
          result.success(this.clearWithParameters(call));
          return;
        default:
          result.notImplemented();
      }
    } catch (error) {
      const businessError = error as Error;
      result.error('OHOS_SHARED_PREFERENCES_ERROR', businessError.message, null);
    }
  }

  private setValue(call: MethodCall, value: preferences.ValueType): boolean {
    const key = this.readStringArgument(call, 'key');
    const store = this.getStore();
    store.putSync(key, value);
    store.flushSync();
    return true;
  }

  private remove(call: MethodCall): boolean {
    const key = this.readStringArgument(call, 'key');
    const store = this.getStore();
    store.deleteSync(key);
    store.flushSync();
    return true;
  }

  private clear(): boolean {
    const store = this.getStore();
    store.clearSync();
    store.flushSync();
    return true;
  }

  private clearWithParameters(call: MethodCall): boolean {
    const prefix = this.readOptionalStringArgument(call, 'prefix');
    const allowList = this.readOptionalStringArrayArgument(call, 'allowList');
    const store = this.getStore();
    const values = store.getAllSync() as Record<string, Object>;
    for (const key of Object.keys(values)) {
      if (this.isAllowedKey(key, prefix, allowList)) {
        store.deleteSync(key);
      }
    }
    store.flushSync();
    return true;
  }

  private getAllWithParameters(call: MethodCall): Record<string, Object> {
    return this.getAll(
      this.readOptionalStringArgument(call, 'prefix'),
      this.readOptionalStringArrayArgument(call, 'allowList'),
    );
  }

  private getAll(prefix: string, allowList: Array<string> | null): Record<string, Object> {
    const values = this.getStore().getAllSync() as Record<string, Object>;
    const result: Record<string, Object> = {};
    for (const key of Object.keys(values)) {
      if (!this.isAllowedKey(key, prefix, allowList)) {
        continue;
      }
      result[key] = values[key] as Object;
    }
    return result;
  }

  private isAllowedKey(key: string, prefix: string, allowList: Array<string> | null): boolean {
    if (prefix.length > 0 && !key.startsWith(prefix)) {
      return false;
    }
    return allowList === null || allowList.includes(key);
  }

  private getStore(): preferences.Preferences {
    if (this.context === null) {
      throw new Error('SharedPreferences context is unavailable');
    }
    return preferences.getPreferencesSync(this.context, { name: PREFERENCES_NAME });
  }

  private readStringArgument(call: MethodCall, key: string): string {
    const value: Object | null = call.argument(key) as Object | null;
    return value === null || value === undefined ? '' : `${value}`;
  }

  private readOptionalStringArgument(call: MethodCall, key: string): string {
    const value: Object | null = call.argument(key) as Object | null;
    return value === null || value === undefined ? '' : `${value}`;
  }

  private readBoolArgument(call: MethodCall, key: string): boolean {
    const value: boolean | null = call.argument(key) as boolean | null;
    return value === true;
  }

  private readNumberArgument(call: MethodCall, key: string): number {
    const value: number | null = call.argument(key) as number | null;
    return value ?? 0;
  }

  private readStringArrayArgument(call: MethodCall, key: string): Array<string> {
    return this.readOptionalStringArrayArgument(call, key) ?? [];
  }

  private readOptionalStringArrayArgument(call: MethodCall, key: string): Array<string> | null {
    const value: Array<string> | null = call.argument(key) as Array<string> | null;
    return value;
  }
}
