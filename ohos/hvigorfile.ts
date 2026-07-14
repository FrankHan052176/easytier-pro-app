import path from 'path'
import fs from 'fs';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';
import { getNode } from '@ohos/hvigor';

function loadSigningConfigs(): Array<Object> {
    const signingConfigPath = 'C:\\Users\\23820\\Documents\\HomoPublish\\EasyTier_All\\Sign\\pro\\sign.json';
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
    const localSigningConfigs = buildProfileOpt['app']['signingConfigs'];
    if (Array.isArray(signingConfigs) && signingConfigs.length > 0
        && (!Array.isArray(localSigningConfigs) || localSigningConfigs.length === 0)) {
        buildProfileOpt['app']['signingConfigs'] = signingConfigs;
        appContext.setBuildProfileOpt(buildProfileOpt);
    }
})

export default {
    system: appTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[flutterHvigorPlugin(path.dirname(__dirname))]         /* Custom plugin to extend the functionality of Hvigor. */
}
