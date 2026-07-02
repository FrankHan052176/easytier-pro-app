import { common, OpenLinkOptions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  AbilityAware,
  AbilityPluginBinding,
  FlutterPlugin,
  FlutterPluginBinding,
  MethodCall,
  MethodCallHandler,
  MethodChannel,
  MethodResult,
} from '@ohos/flutter_ohos';

const METHOD_CHANNEL_NAME = 'plugins.flutter.io/url_launcher';

export default class OhosUrlLauncherBridge implements FlutterPlugin, MethodCallHandler, AbilityAware {
  private channel: MethodChannel | null = null;
  private abilityContext: common.UIAbilityContext | null = null;

  getUniqueClassName(): string {
    return 'OhosUrlLauncherBridge';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.channel = new MethodChannel(binding.getBinaryMessenger(), METHOD_CHANNEL_NAME);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.abilityContext = binding.getAbility().context;
  }

  onDetachedFromAbility(): void {
    this.abilityContext = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'canLaunch':
        result.success(this.canLaunch(this.readUrl(call)));
        return;
      case 'launch':
        this.launch(call, result);
        return;
      case 'closeWebView':
        result.success(null);
        return;
      default:
        result.notImplemented();
    }
  }

  private canLaunch(url: string): boolean {
    if (this.abilityContext === null || url.length === 0) {
      return false;
    }
    return this.isSupportedExternalUrl(url);
  }

  private launch(call: MethodCall, result: MethodResult): void {
    const url = this.readUrl(call);
    if (!this.canLaunch(url)) {
      result.success(false);
      return;
    }

    const context = this.abilityContext;
    if (context === null) {
      result.success(false);
      return;
    }

    const openLinkOptions: OpenLinkOptions = {
      appLinkingOnly: this.readBoolArgument(call, 'universalLinksOnly'),
    };

    try {
      context.openLink(url, openLinkOptions)
        .then(() => {
          result.success(true);
        })
        .catch((error: BusinessError) => {
          console.error(`OhosUrlLauncherBridge openLink failed: ${error.code}, ${error.message}`);
          result.success(false);
        });
    } catch (error) {
      const businessError = error as BusinessError;
      console.error(`OhosUrlLauncherBridge openLink threw: ${businessError.code}, ${businessError.message}`);
      result.success(false);
    }
  }

  private readUrl(call: MethodCall): string {
    const value: Object | null = call.argument('url') as Object | null;
    return value === null || value === undefined ? '' : `${value}`;
  }

  private readBoolArgument(call: MethodCall, key: string): boolean {
    const value: boolean | null = call.argument(key) as boolean | null;
    return value === true;
  }

  private isSupportedExternalUrl(url: string): boolean {
    const lower = url.toLowerCase();
    return lower.startsWith('http://') || lower.startsWith('https://');
  }
}
