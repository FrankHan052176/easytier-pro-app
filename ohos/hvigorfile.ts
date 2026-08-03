import path from 'path'
import fs from 'fs';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';
import { getNode, HvigorNode, HvigorPlugin } from '@ohos/hvigor';

const signingConfigFileName = 'signingConfigs.json';
const pubspecPath = path.resolve(__dirname, '../pubspec.yaml');
const localTestVersionName = '0.0.1';
const localTestVersionCode = 99999999;

interface SemanticVersion {
    major: number;
    minor: number;
    patch: number;
}

interface ProPackageVersion extends SemanticVersion {
    versionName: string;
}

function parseSemanticVersion(value: string, label: string): SemanticVersion {
    const match = value.trim().match(/^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/);
    if (match === null) {
        throw new Error(`${label} must start with a three-part semantic version: ${value}`);
    }
    const version: SemanticVersion = {
        major: Number.parseInt(match[1], 10),
        minor: Number.parseInt(match[2], 10),
        patch: Number.parseInt(match[3], 10),
    };
    if ([version.major, version.minor, version.patch].some(segment => segment < 0 || segment > 9)) {
        throw new Error(`${label} segments must fit one decimal digit for HarmonyOS versionCode: ${value}`);
    }
    return version;
}

function loadProPackageVersion(): ProPackageVersion {
    const pubspec = fs.readFileSync(pubspecPath, 'utf8');
    const match = pubspec.match(/^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*(?:#.*)?$/m);
    if (match === null) {
        throw new Error('pubspec.yaml version must start with major.minor.patch');
    }
    const semanticVersion = parseSemanticVersion(match[1], 'EasyTier Pro version');
    return {
        ...semanticVersion,
        versionName: match[1],
    };
}

function resolveBuildNumber(): number {
    const rawBuildNumber = process.env.EASYTIER_PRO_BUILD_NUMBER ?? '';
    if (!/^\d{1,2}$/.test(rawBuildNumber)) {
        throw new Error('EASYTIER_PRO_BUILD_NUMBER must be an integer between 1 and 99');
    }
    const buildNumber = Number.parseInt(rawBuildNumber, 10);
    if (buildNumber < 1 || buildNumber > 99) {
        throw new Error(`EASYTIER_PRO_BUILD_NUMBER is outside the supported range: ${buildNumber}`);
    }
    return buildNumber;
}

function resolveCoreVersion(appContext: OhosAppContext): SemanticVersion {
    const packageName = process.env.CORE_HAR_PACKAGE ?? 'easytier-ohrs';
    const dependencies = appContext.getOhpmDependencyInfo?.() ?? {};
    const dependencyVersion = dependencies[packageName]?.version;
    const candidates = [process.env.CORE_HAR_VERSION, dependencyVersion];
    for (const candidate of candidates) {
        if (typeof candidate !== 'string' || candidate.trim().length === 0) {
            continue;
        }
        const match = candidate.trim().match(/^(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/);
        if (match === null || Number.parseInt(match[1], 10) === 0) {
            continue;
        }
        return parseSemanticVersion(candidate, 'EasyTier Core version');
    }
    throw new Error(
        'CORE_HAR_VERSION must identify the EasyTier Core release used by a publish build'
    );
}

function composePublishVersionCode(
    pro: ProPackageVersion,
    core: SemanticVersion,
    buildNumber: number,
): number {
    const value = [
        pro.major,
        pro.minor,
        pro.patch,
        core.major,
        core.minor,
        core.patch,
        buildNumber.toString().padStart(2, '0'),
    ].join('');
    return Number.parseInt(value, 10);
}

function easyTierProVersionPlugin(): HvigorPlugin {
    return {
        pluginId: 'easytier-pro-version',
        apply(rootNode: HvigorNode): void {
            const appContext = rootNode.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
            rootNode.afterNodeEvaluate(() => {
                const productName = appContext.getCurrentProduct().getProductName();
                const appJsonOpt = appContext.getAppJsonOpt();
                if (productName === 'default') {
                    appJsonOpt.app.versionName = localTestVersionName;
                    appJsonOpt.app.versionCode = localTestVersionCode;
                } else if (productName === 'publish') {
                    const proVersion = loadProPackageVersion();
                    const coreVersion = resolveCoreVersion(appContext);
                    const buildNumber = resolveBuildNumber();
                    appJsonOpt.app.versionName = proVersion.versionName;
                    appJsonOpt.app.versionCode = composePublishVersionCode(
                        proVersion,
                        coreVersion,
                        buildNumber,
                    );
                } else {
                    return;
                }
                appContext.setAppJsonOpt(appJsonOpt);
                console.log(
                    `> hvigor EasyTier Pro ${productName} version: ` +
                    `${appJsonOpt.app.versionName} (${appJsonOpt.app.versionCode})`
                );
            });
        },
    };
}

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
    plugins:[
        flutterHvigorPlugin(path.dirname(__dirname)),
        easyTierProVersionPlugin(),
    ]         /* Custom plugins to extend the functionality of Hvigor. */
}
