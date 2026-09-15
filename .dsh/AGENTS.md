# EasyTier Pro 工作区交接指南

本文是 `/Users/frankhan/Docs/EasyTier-Pro-交接文档.md` 在当前工作区内的执行版指引。它补充仓库根目录 `AGENTS.md`；若两者冲突，以更具体且与当前代码一致的本文件为准。交接文档更新时间为 `2026-08-19`。

## 1. 项目定位与边界

- 当前工作区：`/Users/frankhan/HarmonyOS/P_EasyTier/R_EasyTier-Pro`
- Git 仓库：`git@github.com:FrankHan052176/easytier-pro-app.git`
- 技术栈：Flutter / Dart；HarmonyOS 壳与系统集成位于 `ohos/`
- Bundle name：`net.easytier.pro`
- HarmonyOS 主入口：`EntryAbility`（Flutter 壳，无自定义控制台地址启动页）
- 目标与兼容 API：`6.1.0(23)`
- 本地 `default` Debug 版本固定为 `0.0.1`，`versionCode=99999999`

EasyTier Pro 是商用跨平台客户端，不要与原生 ArkTS 开源版混淆。普通业务和 UI 由 Flutter 层负责；HarmonyOS 系统能力、Ability、VPN 生命周期和 OHRS 集成由 `ohos/` 负责。网络、隧道及 OHRS 接口的事实来源属于 EasyTier Core，客户端不要重复实现内核逻辑。

## 2. 已验证工具链基线

| 组件 | 版本或基线 |
| --- | --- |
| Flutter-OH | `3.41.10-ohos-0.0.2-beta` |
| Flutter-OH commit | `eea47c62cc5ff1000db068306ffe7279d53e889b` |
| Flutter-OH 仓库 | `https://gitcode.com/CPF-Flutter/flutter_flutter.git` |
| Dart | `3.11.5` |
| JDK | OpenJDK 17 |
| Command Line Tools | 本地 `6.1.1.290`；CI `6.1.1.280` |
| 项目 API | `6.1.0(23)` |
| 推荐迁移环境 | Ubuntu 24.04 / WSL2 的 Linux 文件系统 |

硬性约束：

- 不要用官方 Flutter stable 替代 Flutter-OH。
- 不要执行 `flutter upgrade`。
- WSL2 下应把工程、Flutter-OH 和 Command Line Tools 放在 Linux 文件系统，不要放在 `/mnt/c`。
- 使用 Command Line Tools 自带的 Node，避免系统 Node 覆盖其优先级。
- 新增 Flutter 插件前必须确认其明确支持 OHOS；不能假定 Android/iOS 插件会自动生成 OHOS 实现。

## 3. 新环境部署

### 3.1 安装主机依赖

```bash
sudo apt-get update
sudo apt-get install --yes \
  git curl unzip openjdk-17-jdk libgl1-mesa-dev
java -version
```

### 3.2 安装并固定 Flutter-OH

```bash
mkdir -p "$HOME/development"
git clone --branch 3.41.10-ohos-0.0.2-beta \
  https://gitcode.com/CPF-Flutter/flutter_flutter.git \
  "$HOME/development/flutter-ohos"
git -C "$HOME/development/flutter-ohos" rev-parse HEAD
```

输出必须为：

```text
eea47c62cc5ff1000db068306ffe7279d53e889b
```

### 3.3 安装并配置 Command Line Tools

从华为开发者官网下载 Linux x64 Command Line Tools `6.1.1.290`，解压到 `$HOME/command-line-tools`。目录下应直接存在 `bin/`、`sdk/`、`tool/` 和 `version.txt`，不要多嵌套一层压缩包目录。

将以下环境变量加入 shell 配置：

```bash
export FLUTTER_GIT_URL="https://gitcode.com/CPF-Flutter/flutter_flutter.git"
export COMMANDLINE_TOOL_DIR="$HOME/command-line-tools"
export DEVECO_NODE_HOME="$COMMANDLINE_TOOL_DIR/tool/node"
export DEVECO_SDK_HOME="$COMMANDLINE_TOOL_DIR/sdk"
export OHOS_SDK_HOME="$DEVECO_SDK_HOME"
export OHOS_NDK_HOME="$DEVECO_SDK_HOME/default/openharmony"
export PATH="$HOME/development/flutter-ohos/bin:$COMMANDLINE_TOOL_DIR/bin:$DEVECO_NODE_HOME/bin:$OHOS_NDK_HOME/native/llvm/bin:$OHOS_NDK_HOME/toolchains:$PATH"
```

重新加载 shell 并配置 Flutter：

```bash
source ~/.bashrc
flutter config --enable-ohos
flutter config --ohos-sdk "$OHOS_NDK_HOME"
```

验收命令：

```bash
flutter --version
flutter doctor -v
flutter config --list
ohpm --version
hvigorw --version
node --version
java -version
```

Flutter-OH 显示 `unknown channel` 或 `unknown upstream source` 属于预期。若只构建 HarmonyOS，Android SDK 或 Chrome 缺失不构成阻塞；必须确认 OpenHarmony SDK 已识别，且 `ohos-sdk` 指向 `sdk/default/openharmony`。

## 4. 克隆、依赖与 Core HAR

克隆后先确认工作树状态：

```bash
git clone git@github.com:FrankHan052176/easytier-pro-app.git R_EasyTier-Pro
cd R_EasyTier-Pro
git status --short --branch
```

确认仓库跟踪的 Core HAR 存在并记录摘要：

```bash
test -s ohos/easytier-ohrs-0.0.1.har
shasum -a 256 ohos/easytier-ohrs-0.0.1.har
```

恢复依赖：

```bash
flutter pub get
cd ohos
ohpm install
cd ..
```

`ohos/local.properties` 被 Git 忽略并包含机器绝对路径，不要跨机器原样复制。Flutter 通常自动生成；手工排障时可使用：

```properties
hwsdk.dir=/home/<user>/command-line-tools/sdk
flutter.sdk=/home/<user>/development/flutter-ohos
```

Core HAR 更新流程：

1. 从 EasyTier Core / OHRS 构建或可信 CI 获取 HAR。
2. 记录 Core commit、包版本和 SHA-256。
3. 替换 `ohos/easytier-ohrs-0.0.1.har`。
4. 在 `ohos/` 执行 `ohpm install`。
5. 回到仓库根目录执行 `flutter pub get`。
6. 先执行无签名迁移构建，再执行签名 Debug HAP 构建。
7. 安装真机并验证 VPN、后台和组网生命周期。

不要在未确认 EasyTier Core 的 `easytier-ohrs` 桥接确有变化时随意重建或替换 HAR。

当前集成包为 `easytier-ohrs@2.7.0-main-99-3112-1-gc96b6c19`，Core commit 为 `c96b6c1961edca732aea5189743727ad71f29baa`。HAR 大小 `9195315` 字节，SHA-256 为 `dc6106e0387e56eb937c97caf7367d90ed2a9a4d6aefab4076207e558e165435`。Core 的内部拆分没有改变 Pro 的包入口；不要从文件名推断版本或改用未经发布验证的独立 Pro HAR。

VPN 使用排除列表语义：没有排除项时省略应用列表字段，不传空 `trustedApplications`，不生成多 VPN `vpnId`。`NativeSocketProtectionService` 只保护 Core 选定的底层传输 socket，必须等系统 `protect(fd)` 返回后 ACK；FD 由 Core 持有，ArkTS 不得关闭它。停止运行时时先停止保护请求并等待在途 ACK，再执行同步 native 停机；保护失败保持 fail-closed。不要恢复进程级 `protectProcessNet()`，它也会绕过需要留在 TUN 内的 socket。

宿主机行为回归命令为 `bun test test/ohos_vpn_runtime.test.ts`，执行实际 ArkTS 源码，控制系统与 N-API 边界，覆盖排除列表、保护失败、ACK 时序、TUN 单独停止和运行时重启。通过不代表设备 UID 路由或原生浏览器访问子网 NAS 已通过；仍需按第 7 节真机验收。

VPN 的逐 socket 保护由 Core 驱动：`enableSocketProtection` → ArkTS 循环取 `nextSocketProtectionRequest()` → `protect(fd)` → `completeSocketProtection()`。Core 的 `complete_request` 在**请求的等待方已被丢弃**（socket 创建被取消）时返回 false，`protect()` 本身失败也会让该 socket 创建失败。这两种情况都只影响那一个 socket，**绝不能让 ArkTS 侧升级成致命错误**：早期版本把「ACK 被拒」当致命错误并触发 fail-stop，结果整个 VPN 运行时被停掉，表现为「VPN 已建立、UID 范围与路由都正确、但隧道完全不载流」，并伴随 `HarmonyOS socket protection failed: ... ACK rejected` 日志。现在 `NativeSocketProtectionService` 只对「保护流意外结束」保持致命处理，单 socket 失败 NACK 并继续。排障时看 `[EasyTierProVpn] socket protection request ... was already released`（正常）与 `socket protection failed for fd ...`（单 socket 失败）。

## 5. 签名安全与选择

CI 或可迁移环境通过以下变量注入签名目录：

```text
EASYTIER_PRO_SIGNING_DIR=/secure/path/EasyTierPro
```

该目录必须包含 `signingConfigs.json` 以及配套的 `.p12`、`.cer`、`.p7b`。当前 `ohos/hvigorfile.ts` 在未设置环境变量时会尝试读取仓库外的 `../../Sign/EasyTierPro/sign.json`；这是已配置机器的本地回退，不能作为可移植部署依赖。

安全约束：

- 签名密码和材料只能通过安全渠道部署。
- 禁止将签名材料、密码、AGC Token、本机凭据提交到 Git、写入文档、测试快照或日志。
- 排障时只检查路径、配置名、文件存在性和权限，不输出密钥内容。
- `default` 与 `publish` product 会在存在同名签名配置时自动绑定该配置。

构建场景：

| 场景 | 构建方式 | 签名选择 |
| --- | --- | --- |
| 新环境迁移、编译链验证 | `default/debug --no-codesign` | 无签名，仅验证构建 |
| 本地真机、VPN、后台与跨设备测试 | `default/debug` | 手动调试签名 |
| 跨应用或开放能力联合调试 | `default/debug` | 手动调试签名，Profile 必须覆盖设备和能力 |
| AGC 测试版、AppGallery 正式包 | `publish/release` App | publish 发布签名 |

无签名 HAP 不能用于正常真机功能验收。相同 bundle 使用不同证书时通常不能覆盖安装；卸载异签名旧包前应记录旧包信息，且必须明确卸载会清除应用数据。

## 6. 构建流程

### 6.1 无签名迁移构建

新环境首先执行最小构建链验证：

```bash
flutter pub get
CI=true flutter build hap --debug --no-codesign --no-pub
test -s build/ohos/hap/entry-default-unsigned.hap
```

预期产物：

```text
build/ohos/hap/entry-default-unsigned.hap
```

此产物只证明 Flutter-OH、Hvigor、OHPM 和 HAR 能完成编译，不用于设备功能验收。

### 6.2 本地签名 Debug HAP

签名配置中应有与 `default` product 同名的调试签名：

```bash
EASYTIER_PRO_SIGNING_DIR=/secure/path/EasyTierPro \
  flutter build hap \
  --debug \
  --flavor default \
  --no-pub
```

预期汇总产物：

```text
build/ohos/hap/entry-default-signed.hap
```

Hvigor 原始产物：

```text
ohos/entry/build/default/outputs/default/entry-default-signed.hap
```

校验包元数据：

```bash
HAP=build/ohos/hap/entry-default-signed.hap
test -s "$HAP"
unzip -p "$HAP" module.json | jq '.app | {
  bundleName, versionName, versionCode, buildMode, debug,
  targetAPIVersion, compileSdkVersion
}'
```

`default` product 固定生成 `0.0.1 / 99999999`，不跟随 `pubspec.yaml` 的正式版本。

### 6.3 Publish / Release App

HarmonyOS `publish` 固定表示 App 级发布产物，不要将发布请求替换成 `flutter build hap`、`assembleHap` 或其他模块级产物。

```bash
EASYTIER_PRO_SIGNING_DIR=/secure/path/EasyTierPro \
CORE_HAR_VERSION=2.4.5-main-0-1-1-g12345678 \
EASYTIER_PRO_BUILD_NUMBER=1 \
CI=true flutter build app \
  --release \
  --flavor publish \
  --target-platform ohos-arm64 \
  --no-pub
```

版本要求：

- `CORE_HAR_VERSION` 必须以三段语义版本开头，并与实际集成的 HAR 对应；不得为通过构建而伪造版本。
- `EASYTIER_PRO_BUILD_NUMBER` 必须是 `1..99`。
- `pubspec.yaml` 的 Pro `major.minor.patch` 与 Core 三段版本目前每段都必须能放入一位十进制数字。
- `versionName` 使用 Pro 的 `pubspec.yaml` 三段版本。
- `versionCode` 由 `[Pro major][Pro minor][Pro patch][Core major][Core minor][Core patch][两位构造序号]` 拼接。

例如 Pro `1.0.7`、Core `2.4.5`、构造序号 `1`：

```text
versionName = 1.0.7
versionCode = 10724501
```

预期 App 产物：

```text
ohos/build/outputs/publish/*-signed.app
```

只有用户明确要求设备安装包时才构建 HAP；正式发布流程使用 App 级产物。

## 7. 真机安装与验收

只安装已签名 HAP。以下为示例设备；执行前必须确认真实目标，不能盲用示例地址：

```bash
HDC=/Users/frankhan/command-line-tools/sdk/default/openharmony/toolchains/hdc
TARGET=192.168.6.193:5555
BUNDLE=net.easytier.pro
HAP=build/ohos/hap/entry-default-signed.hap

$HDC list targets
$HDC -t "$TARGET" shell bm dump -n "$BUNDLE"
```

若设备已有异签名测试版或商店版，确认数据清除风险后再执行：

```bash
$HDC -t "$TARGET" uninstall "$BUNDLE"
$HDC -t "$TARGET" install -g "$HAP"
```

必须检查 HDC 的字面成功输出，不能只依赖退出码。启动应用：

```bash
$HDC -t "$TARGET" shell aa start \
  -a EntryAbility -b net.easytier.pro
```

控制台地址不使用运行时输入，只来自构建期 `--dart-define=EASYTIER_CONSOLE_URL`；不要恢复 BootstrapAbility、控制台地址选择页或控制台地址偏好存储。

安装后验证：

```bash
$HDC -t "$TARGET" shell bm dump -n "$BUNDLE"
$HDC -t "$TARGET" shell ps -ef | grep -F "$BUNDLE"
```

`bm dump` 至少核对 bundle、版本、`appIdentifier`、fingerprint 和 Ability。VPN 首次授权、实例启动、后台冻结恢复、跨设备与真实组网行为必须在真机回归；不能用无签名构建成功替代功能验收。

## 8. 常见故障

### `Unable to locate OpenHarmony SDK`

重新执行：

```bash
flutter config --ohos-sdk "$OHOS_NDK_HOME"
flutter config --list
```

确认路径指向 `sdk/default/openharmony`。

### `Invalid storeFile value` 或签名配置错误

签名 JSON 已被读取，但 `.p12/.cer/.p7b` 路径无效、权限不足或解析位置错误。检查 `storeFile`、`certpath`、`profile` 及目录权限，不要输出密码或材料内容。

### Debug 构建只有 unsigned HAP

没有 `default` 签名配置时，普通 Debug 构建只能生成 unsigned HAP。需要安装真机时，必须注入同名手动调试签名后重新构建。

### Publish 构建缺少版本变量

为 `publish` product 设置真实的 `CORE_HAR_VERSION` 和 `EASYTIER_PRO_BUILD_NUMBER=1..99`。Core 版本必须与实际 HAR 对应。

### WSL2 看不到 USB 设备

可在 Windows 宿主启动可远程访问的 HDC server，再在 WSL2 设置 `HDC_SERVER` 与 `HDC_SERVER_PORT`。环境迁移可先用无签名构建验收，但真机行为必须后续补测。

### `The hvigor depends on the npmrc file`

按 Command Line Tools / DevEco 文档配置用户级 `.npmrc` 后重试。不要将包含私服令牌的 `.npmrc` 提交到仓库。

## 9. 任务完成与交付检查

涉及 HarmonyOS 迁移、构建或发布时，至少核对：

- [ ] Flutter-OH commit 与规定基线一致。
- [ ] JDK 17、Command Line Tools、OpenHarmony SDK 可识别。
- [ ] `flutter pub get` 与必要时的 `ohpm install` 已完成。
- [ ] Core HAR 来源、版本、commit、SHA-256 已记录。
- [ ] 无签名 HAP 仅用于迁移和编译链验收。
- [ ] 本地设备包使用 `default/debug` 手动调试签名。
- [ ] Debug HAP 版本为 `0.0.1 / 99999999`。
- [ ] Publish 使用 `flutter build app --release --flavor publish`。
- [ ] 没有提交签名材料、密码、AGC Token 或本机凭据。
- [ ] 安装后通过 `bm dump`、进程状态和真机行为完成验收。

仓库当前可能存在他人或未完成的工作树改动。执行任务时：

- 先检查 `git status --short`，不要覆盖、回退或顺带提交与当前任务无关的变更。
- 保持改动最小且聚焦。
- 修改代码或文档后按根目录 `AGENTS.md` 要求执行一次 Git commit；只暂存和提交本次任务的文件。
- 若跨仓库协同，明确事实来源属于本应用、中心控制台还是 EasyTier Core。

## 10. 官方参考

- HarmonyOS Command Line Tools：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-get>
- 调试签名：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-signing>
- 应用安装、卸载与更新：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/application-package-install-uninstall>
