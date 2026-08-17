
import { common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { FlutterPage } from '@ohos/flutter_ohos';

const storage = LocalStorage.getShared();
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS';
const BUNDLE_NAME = 'net.easytier.pro';
const VPN_ABILITY_NAME = 'EasyTierVpnAbility';

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext;
  @LocalStorageLink('viewId') viewId: string = "";

  aboutToAppear(): void {
    const want: Want = {
      bundleName: BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: {
        socketFilesDir: this.context.filesDir,
      },
    };
    console.info('[EasyTierProVpn] requesting VPN Extension from Index.aboutToAppear');
    vpnExtension.startVpnExtensionAbility(want).catch((error: Error): void => {
      console.error(`[EasyTierProVpn] Index VPN request failed: ${error.message}`);
    });
  }

  build() {
    Column() {
      FlutterPage({ viewId: this.viewId })
    }
  }

  onBackPress(): boolean {
    this.context.eventHub.emit(EVENT_BACK_PRESS);
    return true;
  }
}
