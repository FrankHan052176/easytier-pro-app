import path from 'path'
import fs from 'fs';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';
import { getNode } from '@ohos/hvigor';

function loadSigningConfigs() {
    const path = 'C:\\Users\\23820\\Documents\\HomoPublish\\EasyTier_All\\Sign\\pro\\sign.json';
    try {
        fs.accessSync(path);
    } catch (e) {
        if (e.code !== 'ENOENT') {
            console.error(e);
        }
        return [];
    }
    const data = fs.readFileSync(path);
    return JSON.parse(data.toString());
}
const rootNode = getNode(__filename);
rootNode.afterNodeEvaluate(node => {
    const appContext = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
    const buildProfileOpt = appContext.getBuildProfileOpt();
    console.log("✅ 覆写签名")
    buildProfileOpt['app']['signingConfigs'] = loadSigningConfigs();
    appContext.setBuildProfileOpt(buildProfileOpt);
})

export default {
    system: appTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[flutterHvigorPlugin(path.dirname(__dirname))]         /* Custom plugin to extend the functionality of Hvigor. */
}
