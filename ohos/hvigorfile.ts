import path from 'path'
import fs from 'fs';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';
import { getNode } from '@ohos/hvigor';

function loadSigningConfigs(): Array<any> {
    const signingConfigPath = path.resolve(__dirname, '../../Sign/EasyTierPro/sign.json');
    try {
        const data = fs.readFileSync(signingConfigPath);
        const signingConfigs: Object = JSON.parse(data.toString());
        if (!Array.isArray(signingConfigs) || signingConfigs.length === 0) {
            return [];
        }
        return signingConfigs;
    } catch {
        return [];
    }
}
const rootNode = getNode(__filename);
rootNode.afterNodeEvaluate(node => {
    const appContext = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
    const buildProfileOpt = appContext.getBuildProfileOpt();
    const signingConfigs = loadSigningConfigs();
    const localSigningConfigs = Array.isArray(buildProfileOpt.app.signingConfigs)
        ? buildProfileOpt.app.signingConfigs
        : [];
    buildProfileOpt.app.signingConfigs = [...localSigningConfigs,...signingConfigs];
    appContext.setBuildProfileOpt(buildProfileOpt);
})

export default {
    system: appTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[flutterHvigorPlugin(path.dirname(__dirname))]         /* Custom plugin to extend the functionality of Hvigor. */
}
