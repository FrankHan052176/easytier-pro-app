import path from 'path'
import fs from 'fs';
import crypto from 'crypto';
import { execFileSync } from 'child_process';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';
import { getNode, HvigorNode, HvigorPlugin } from '@ohos/hvigor';

const signingConfigFileName = 'signingConfigs.json';
const pubspecPath = path.resolve(__dirname, '../pubspec.yaml');
const agcdChangelogPath = path.resolve(__dirname, '../agcd-changelog.json');
const coreHarPath = path.resolve(__dirname, 'easytier-ohrs-0.0.1.har');
const coreModuleDir = path.resolve(__dirname, 'oh_modules/easytier-ohrs');
const coreHarStampPath = path.resolve(__dirname, 'oh_modules/.easytier-ohrs-har.sha256');
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

interface AgcdSourceSection {
    triggerId?: string;
    sourceName: string;
    repo: string;
    version: string;
    summary: string;
    items: string[];
}

interface AgcdChangelogPayload {
    projectId?: string;
    versionName: string;
    versionCode: number;
    releaseDate: string;
    summary: string;
    mainProject?: AgcdSourceSection;
    upstreams: AgcdSourceSection[];
    generatedAt: number;
}

function calcHash(content: string | Buffer): string {
    return crypto.createHash('sha256').update(content).digest('hex');
}

// Local AGCD copies the cached OHPM artifact to ohos/easytier-ohrs-0.0.1.har right before a build.
// ohpm keeps an already installed file: dependency, so mirror the injected HAR into oh_modules
// whenever its SHA-256 differs from the recorded stamp.
function syncInjectedCoreHar(): void {
    if (!fs.existsSync(coreHarPath) || !fs.existsSync(coreModuleDir)) {
        return;
    }
    try {
        const harSha256 = calcHash(fs.readFileSync(coreHarPath));
        const targetPackagePath = path.join(coreModuleDir, 'oh-package.json5');
        if (fs.existsSync(coreHarStampPath) && fs.existsSync(targetPackagePath)) {
            const recordedSha256 = fs.readFileSync(coreHarStampPath, 'utf8').trim();
            if (recordedSha256 === harSha256) {
                return;
            }
        }
        const targetDir = fs.realpathSync(coreModuleDir);
        const extractDir = path.resolve(__dirname, 'oh_modules/.easytier-ohrs-sync-tmp');
        fs.rmSync(extractDir, { recursive: true, force: true });
        fs.mkdirSync(extractDir, { recursive: true });
        try {
            execFileSync('tar', ['-xzf', coreHarPath, '--strip-components=1', '-C', extractDir]);
            for (const entry of fs.readdirSync(targetDir)) {
                fs.rmSync(path.join(targetDir, entry), { recursive: true, force: true });
            }
            for (const entry of fs.readdirSync(extractDir)) {
                fs.cpSync(path.join(extractDir, entry), path.join(targetDir, entry), { recursive: true });
            }
            fs.writeFileSync(coreHarStampPath, `${harSha256}\n`, 'utf8');
            console.log(
                `> hvigor Synced injected ${path.basename(coreHarPath)} into oh_modules ` +
                `(${harSha256.slice(0, 12)})`
            );
        } finally {
            fs.rmSync(extractDir, { recursive: true, force: true });
        }
    } catch (error) {
        console.warn(`> hvigor Warning: failed to sync ${coreHarPath} into oh_modules: ${error}`);
    }
}

function normalizeStringList(raw: unknown): string[] {
    if (!Array.isArray(raw)) {
        return [];
    }
    return raw
        .filter((item): item is string => typeof item === 'string')
        .map(item => item.trim())
        .filter(item => item.length > 0);
}

function normalizeAgcdSection(raw: unknown, fallbackSourceName: string): AgcdSourceSection | undefined {
    if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) {
        return undefined;
    }
    const record = raw as Record<string, unknown>;
    const sourceName = typeof record.sourceName === 'string' && record.sourceName.trim().length > 0
        ? record.sourceName.trim()
        : fallbackSourceName;
    const section: AgcdSourceSection = {
        sourceName,
        repo: typeof record.repo === 'string' ? record.repo.trim() : '',
        version: typeof record.version === 'string' ? record.version.trim() : '',
        summary: typeof record.summary === 'string' ? record.summary.trim() : '',
        items: normalizeStringList(record.items),
    };
    if (typeof record.triggerId === 'string' && record.triggerId.trim().length > 0) {
        section.triggerId = record.triggerId.trim();
    }
    return section;
}

// Local AGCD writes the categorized changelog to the repository root before a Release build.
// When it is absent the build stays a normal local development build.
function loadAgcdChangelog(): AgcdChangelogPayload | undefined {
    if (!fs.existsSync(agcdChangelogPath)) {
        return undefined;
    }
    try {
        const parsed = JSON.parse(fs.readFileSync(agcdChangelogPath, 'utf8')) as Record<string, unknown>;
        const versionName = typeof parsed.versionName === 'string' ? parsed.versionName.trim() : '';
        const rawVersionCode = typeof parsed.versionCode === 'number'
            ? parsed.versionCode
            : Number.parseInt(String(parsed.versionCode ?? ''), 10);
        const versionCode = Number.isSafeInteger(rawVersionCode) && rawVersionCode > 0 ? rawVersionCode : 0;
        if (versionName.length === 0 || versionCode === 0) {
            console.warn(
                `> hvigor Ignoring ${agcdChangelogPath}: versionName and a positive versionCode are required`
            );
            return undefined;
        }
        const upstreams: AgcdSourceSection[] = [];
        if (Array.isArray(parsed.upstreams)) {
            parsed.upstreams.forEach((item, index) => {
                const normalized = normalizeAgcdSection(item, `上游依赖 ${index + 1}`);
                if (normalized) {
                    upstreams.push(normalized);
                }
            });
        }
        return {
            projectId: typeof parsed.projectId === 'string' ? parsed.projectId : undefined,
            versionName,
            versionCode,
            releaseDate: typeof parsed.releaseDate === 'string' ? parsed.releaseDate.trim() : '',
            summary: typeof parsed.summary === 'string' ? parsed.summary.trim() : '',
            mainProject: normalizeAgcdSection(parsed.mainProject, '主项目'),
            upstreams,
            generatedAt: typeof parsed.generatedAt === 'number' && Number.isFinite(parsed.generatedAt)
                ? parsed.generatedAt
                : 0,
        };
    } catch (error) {
        console.warn(`> hvigor Failed to parse ${agcdChangelogPath}: ${error}`);
        return undefined;
    }
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

function resolveBuildNumber(): number | undefined {
    const rawBuildNumber = process.env.EASYTIER_PRO_BUILD_NUMBER ?? '';
    if (rawBuildNumber.trim().length === 0) {
        return undefined;
    }
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
                if (productName !== 'default' && productName !== 'publish') {
                    return;
                }
                const appJsonOpt = appContext.getAppJsonOpt();
                const agcd = loadAgcdChangelog();
                let versionSource: string;
                if (agcd) {
                    appJsonOpt.app.versionName = agcd.versionName;
                    appJsonOpt.app.versionCode = agcd.versionCode;
                    versionSource = 'agcd-changelog.json';
                } else {
                    const buildNumber = productName === 'publish' ? resolveBuildNumber() : undefined;
                    if (buildNumber !== undefined) {
                        const proVersion = loadProPackageVersion();
                        const coreVersion = resolveCoreVersion(appContext);
                        appJsonOpt.app.versionName = proVersion.versionName;
                        appJsonOpt.app.versionCode = composePublishVersionCode(
                            proVersion,
                            coreVersion,
                            buildNumber,
                        );
                        versionSource = 'pubspec.yaml + EasyTier Core version + build number';
                    } else {
                        if (productName === 'publish') {
                            console.warn(
                                '> hvigor No agcd-changelog.json and no EASYTIER_PRO_BUILD_NUMBER: ' +
                                'the publish product uses the local development version'
                            );
                        }
                        appJsonOpt.app.versionName = localTestVersionName;
                        appJsonOpt.app.versionCode = localTestVersionCode;
                        versionSource = 'local development fallback';
                    }
                }
                appContext.setAppJsonOpt(appJsonOpt);
                console.log(
                    `> hvigor EasyTier Pro ${productName} version: ` +
                    `${appJsonOpt.app.versionName} (${appJsonOpt.app.versionCode}) from ${versionSource}`
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
syncInjectedCoreHar();
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
