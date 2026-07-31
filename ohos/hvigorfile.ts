import path from 'path'
import fs from 'fs';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';
import { getNode } from '@ohos/hvigor';

const signingConfigFileName = 'signingConfigs.json';

function loadSigningConfigs(): Array<any> {
    const signingDir = process.env.EASYTIER_PRO_SIGNING_DIR;
    const signingConfigPath = signingDir
        ? path.join(signingDir, signingConfigFileName)
        : path.resolve(__dirname, '../../Sign/EasyTierPro/sign.json');
    try {
        const data = fs.readFileSync(signingConfigPath);
        const signingConfigs: Object = JSON.parse(data.toString());
        if (!Array.isArray(signingConfigs) || signingConfigs.length === 0) {
            return [];
        }
        return signingConfigs;
    } catch (error) {
        if (signingDir) {
            throw new Error(
                `Unable to read EasyTier Pro signing configuration from EASYTIER_PRO_SIGNING_DIR: ${error}`
            );
        }
        return [];
    }
}
const rootNode = getNode(__filename);
rootNode.afterNodeEvaluate(node => {
    const appContext = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
    const buildProfileOpt = appContext.getBuildProfileOpt();
    const localSigningConfigs = Array.isArray(buildProfileOpt.app.signingConfigs)
        ? buildProfileOpt.app.signingConfigs
        : [];
    const signingConfigs = [...localSigningConfigs, ...loadSigningConfigs()];
    buildProfileOpt.app.signingConfigs = signingConfigs;

    const signingConfigNames = new Set<string>();
    signingConfigs.forEach(signingConfig => {
        if (typeof signingConfig.name === 'string') {
            signingConfigNames.add(signingConfig.name);
        }
    });
    const products = buildProfileOpt.app.products;
    if (Array.isArray(products)) {
        products.forEach(product => {
            if (signingConfigNames.has(product.name)) {
                product.signingConfig = product.name;
            }
        });
    }
    appContext.setBuildProfileOpt(buildProfileOpt);
})

export default {
    system: appTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[flutterHvigorPlugin(path.dirname(__dirname))]         /* Custom plugin to extend the functionality of Hvigor. */
}
