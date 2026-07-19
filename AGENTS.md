# 项目指南

## 产品背景
本仓库是 EasyTier Pro 的 Flutter 客户端应用。
该产品属于零信任组网系统，能力范围对齐 Tailscale，但需要满足中国大陆的合规化要求。
在实现功能时，可以参考 Tailscale 类似的产品行为，但应优先使用 EasyTier Pro 自身的术语、流程和合规约束，避免直接照搬。

## 关联系统
- 中心控制台仓库：https://github.com/EasyTier-Pro/easytier-console
- 中心控制台线上环境：https://console.easytier.net/
- 本地 E2E 测试环境：http://10.147.223.128:14173/
- EasyTier 核心仓库：https://github.com/EasyTier/EasyTier

## 架构指引
- 将本仓库视为客户端应用层，不要在这里发明本应由控制台或后端定义的控制面行为。
- 如果后端契约、认证流程、设备生命周期或网络编排逻辑不清楚，优先查看中心控制台仓库。
- 如果隧道行为、节点互联、路由或 Mesh 组网实现细节不清楚，优先查看 EasyTier 核心仓库。
- 产品语言尽量与零信任组网概念保持一致，例如设备、用户、网络、策略、路由、中继等。

## 构建与测试
- 安装依赖：`flutter pub get`
- 静态分析：`dart analyze`
- 运行测试：`flutter test`
- 运行 Windows 桌面端：`flutter run -d windows`

## HarmonyOS / OpenHarmony 环境迁移与编译

以下基线已在 WSL2 Ubuntu 24.04 的 Linux 文件系统中验证。迁移时优先保持版本一致，不要直接执行 `flutter upgrade` 或混用官方 Flutter SDK；工程、Flutter-OH SDK 和 Command Line Tools 都应放在 Linux 文件系统（例如 `$HOME`），不要放在 `/mnt/c`，以避免权限、软链接和文件监听问题。

### 已验证版本

| 组件 | 版本或基线 |
| --- | --- |
| Flutter-OH | `3.41.10-ohos-0.0.2-beta`，commit `eea47c62cc5ff1000db068306ffe7279d53e889b` |
| Flutter-OH 仓库 | `https://gitcode.com/CPF-Flutter/flutter_flutter.git` |
| Dart / DevTools | Dart `3.11.5`，DevTools `2.54.1` |
| HarmonyOS Command Line Tools | `6.1.1.290`；CI 使用兼容的 `6.1.1.280` |
| ohpm / Hvigor / Node | ohpm `6.1.2.285`，Hvigor `6.24.3`，工具包自带 Node `18.20.1` |
| JDK | OpenJDK `17` |
| HarmonyOS SDK | HarmonyOS `6.1.1 Release`，API `24` |
| 项目 SDK 目标 | `compatibleSdkVersion` / `targetSdkVersion` 均为 `6.1.0(23)`；API 24 SDK 可编译该 API 23 项目 |

版本事实来源包括本节、`ohos/build-profile.json5` 和 `.github/workflows/linux.yml`。升级 Flutter-OH 或 Command Line Tools 时应同时更新本节和 CI，并重新执行无签名 HAP 构建。

### 1. 安装主机依赖

Ubuntu / WSL2 至少安装 Git、解压工具、OpenJDK 17 和 HarmonyOS 构建所需的 OpenGL 库：

```bash
sudo apt-get update
sudo apt-get install --yes git curl unzip openjdk-17-jdk libgl1-mesa-dev
java -version
```

应使用 Command Line Tools 自带的 Node，不要让系统 Node 覆盖其优先级。

### 2. 安装并固定 Flutter-OH

```bash
mkdir -p "$HOME/development"
git clone --branch 3.41.10-ohos-0.0.2-beta \
  https://gitcode.com/CPF-Flutter/flutter_flutter.git \
  "$HOME/development/flutter-ohos"
git -C "$HOME/development/flutter-ohos" rev-parse HEAD
```

`rev-parse HEAD` 应为 `eea47c62cc5ff1000db068306ffe7279d53e889b`。若版本需要变更，应先确认 Flutter-OH、Hvigor 插件和现有 ArkTS bridge 兼容性，不能用普通 Flutter stable 替代。

### 3. 安装 HarmonyOS Command Line Tools

从华为开发者官方页面下载 Linux x64 Command Line Tools `6.1.1.290`，解压到 `$HOME/command-line-tools`。解压后应能直接看到 `$HOME/command-line-tools/version.txt`、`bin/`、`sdk/` 和 `tool/`；不要额外多套一层压缩包目录。

将以下内容加入 `~/.bashrc` 或当前 shell 对应的启动文件：

```bash
export FLUTTER_GIT_URL="https://gitcode.com/CPF-Flutter/flutter_flutter.git"
export COMMANDLINE_TOOL_DIR="$HOME/command-line-tools"
export DEVECO_NODE_HOME="$COMMANDLINE_TOOL_DIR/tool/node"
export DEVECO_SDK_HOME="$COMMANDLINE_TOOL_DIR/sdk"
export OHOS_SDK_HOME="$DEVECO_SDK_HOME"
export OHOS_NDK_HOME="$DEVECO_SDK_HOME/default/openharmony"
export PATH="$HOME/development/flutter-ohos/bin:$COMMANDLINE_TOOL_DIR/bin:$DEVECO_NODE_HOME/bin:$OHOS_NDK_HOME/native/llvm/bin:$OHOS_NDK_HOME/toolchains:$PATH"
```

重新加载 shell 后配置 Flutter：

```bash
source ~/.bashrc
flutter config --enable-ohos
flutter config --ohos-sdk "$OHOS_NDK_HOME"
```

### 4. 验收工具链

```bash
flutter --version
flutter doctor -v
ohpm --version
hvigorw --version
node --version
java -version
```

CPF Flutter-OH 在 `flutter doctor -v` 中显示 `unknown channel` 或 `unknown upstream source` 属于预期现象。只构建 HarmonyOS 时，Android SDK 或 Chrome 缺失不构成阻塞；必须确认 OpenHarmony SDK 能被识别，且 `flutter config --list` 中 `enable-ohos` 为 `true`、`ohos-sdk` 指向 `$OHOS_NDK_HOME`。

### 5. 恢复项目依赖

克隆本仓库后，在 `EasyTier-Pro/` 执行：

```bash
test -s ohos/easytier-ohrs-0.0.1.har
sha256sum ohos/easytier-ohrs-0.0.1.har
flutter pub get
```

当前跟踪的 `ohos/easytier-ohrs-0.0.1.har` 大小为 `9357294` 字节，SHA-256 为 `8c659f30247a0a3350a3e8e875f9562d9ab14115ab9d209f6d2aa1f68e23fd4a`，并由 `ohos/oh-package.json5` 通过本地文件依赖引用。正常 Git clone 会带上该 HAR；除非 EasyTier Core 的 `easytier-ohrs` 桥接确有变更，否则不要重新构建或替换它。

如需单独恢复 ArkTS 依赖，可执行：

```bash
cd ohos
ohpm install
cd ..
```

`ohos/local.properties` 被 Git 忽略，并包含设备相关绝对路径，不要从旧设备原样复制。Flutter 通常会自动生成；需要手工排障时，`hwsdk.dir` 应指向 Command Line Tools 的 `sdk` 根目录，`flutter.sdk` 应指向 Flutter-OH 根目录，例如：

```properties
hwsdk.dir=/home/<user>/command-line-tools/sdk
flutter.sdk=/home/<user>/development/flutter-ohos
```

### 6. 首次无签名构建

迁移验收优先使用 `default` product 的无签名 debug HAP，不依赖私有签名材料：

```bash
flutter pub get
CI=true flutter build hap --debug --no-codesign --no-pub
test -s build/ohos/hap/entry-default-unsigned.hap
```

成功产物为 `build/ohos/hap/entry-default-unsigned.hap`。项目 product 与 module target 的映射是 `default -> default`、`publish -> publish`，修改名称时必须同时检查 `ohos/build-profile.json5` 中的 `applyToProducts`。

### 7. 恢复签名并构建 publish HAP

签名材料不得进入 Git、日志、文档或测试快照。`ohos/signing/` 已被 `ohos/.gitignore` 忽略；迁移时应通过安全渠道同时复制 `.p12`、`.cer`、`.p7b` 和本地 `sign.json`，只复制 `sign.json` 的结构无法完成签名。

`ohos/hvigorfile.ts` 中的 `signingConfigPath` 是签名配置文件路径的事实来源。不同工作区可能使用仓库外的 `../../Sign/EasyTierPro/sign.json`，也可能使用被忽略的 `ohos/signing/sign.json`；新设备必须检查当前代码并让该路径实际存在。`sign.json` 是数组，每项需要 `name`、`type` 和 `material`；`material` 至少包含 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`、`signAlg`、`profile`、`certpath`。不要在仓库中添加这些字段的真实值。

`storeFile`、`certpath`、`profile` 指向的文件必须在新设备存在。Hvigor 的相对路径通常按 `ohos/` 构建工作目录解析，迁移时优先使用经过验证的绝对路径，或先确认相对路径的实际解析结果。签名配置名必须与 `ohos/build-profile.json5` 中 publish product 的 `signingConfig: "publish"` 对应。

```bash
flutter build hap --debug --flavor publish --no-pub
test -s ohos/entry/build/publish/outputs/publish/entry-publish-signed.hap
```

Flutter 汇总产物通常位于 `build/ohos/hap/entry-publish-signed.hap`，Hvigor 原始产物位于 `ohos/entry/build/publish/outputs/publish/entry-publish-signed.hap`。可在不输出密钥内容的前提下校验签名：

```bash
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
java -jar "$OHOS_NDK_HOME/toolchains/lib/hap-sign-tool.jar" verify-app \
  -inFile ohos/entry/build/publish/outputs/publish/entry-publish-signed.hap \
  -outCertChain "$tmpdir/cert-chain.cer" \
  -outProfile "$tmpdir/profile.p7b"
```

### 8. WSL2 连接设备（可选）

先执行 `hdc list targets`。若 USB 设备在 WSL2 中不可见，可在 Windows 宿主机启动可远程访问的 hdc server：

```bash
hdc kill
hdc -s WINDOWS_HOST_IP:8710 -m
```

再在 WSL2 中配置：

```bash
export HDC_SERVER="WINDOWS_HOST_IP"
export HDC_SERVER_PORT=8710
hdc list targets
```

Windows 侧的 hdc 版本应与 Linux 工具链兼容。环境迁移和源码编译验收不要求安装到真机，但 VPN Extension、授权、后台冻结恢复和实际组网行为仍必须在后续真机回归中验证。

### 常见问题

- 普通执行 `flutter build hap --debug` 时，`default` product 没有签名配置，可能出现 Hvigor 已成功生成 unsigned HAP、但 Flutter 仍在查找 signed HAP 的情况。迁移验收应显式使用 `--no-codesign`。
- `Unable to locate OpenHarmony SDK`：重新检查 `flutter config --ohos-sdk "$OHOS_NDK_HOME"`，并确认 `$OHOS_NDK_HOME` 是 `sdk/default/openharmony`。
- `00303107 Configuration Error` / `Invalid storeFile value`：`sign.json` 已被读取，但 `.p12` 等外部材料路径不存在或解析位置错误；同时检查 `storeFile`、`certpath` 和 `profile`。
- `The hvigor depends on the npmrc file`：按 Command Line Tools/DevEco 文档在用户目录配置 `.npmrc` 后重试，不要把含私服令牌的 `.npmrc` 提交到仓库。
- product 或 target 不匹配：检查 `ohos/build-profile.json5` 中 products、targets 和 `applyToProducts` 是否同名对应。
- 日志中的 Flutter/HAR 兼容性警告不等于失败；以最终 `BUILD SUCCESSFUL`、Flutter 的 `Built ...hap` 提示和目标文件存在为准，同时不要忽略真正的 `ERROR`。
- 新增 Flutter 插件前必须确认其明确支持 OHOS。项目当前主要通过自定义 ArkTS bridge 和本地 `easytier-ohrs` HAR 提供系统能力，不能假定 Android/iOS 插件会自动生成 OHOS 实现。

### 官方参考

- HarmonyOS Command Line Tools：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-commandline-get>
- SDK 命令行工具概览：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/command-line-tools-overview>
- 工程级 `build-profile.json5`：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-hvigor-build-profile-app>
- 模块级 `build-profile.json5`：<https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/ide-hvigor-build-profile>

## Flutter 桌面端无障碍与语义树
- Windows 桌面端已在 `lib/main.dart` 中对应用子树使用 `ExcludeSemantics`，以避免 Flutter/ForUI 的动态 `Tooltip`、`OverlayPortal`、滚动区域和动画语义树反复触发 Windows `accessibility_bridge.cc` / `Failed to update ui::AXTree` 日志。
- 该策略会牺牲 Windows 屏幕阅读器语义支持，但可以从源头避免向 Windows AXTree 提交复杂动态 semantics update；不要再为这类日志做局部猜测式修复，例如反复调整列表 key、局部包裹 `Semantics` 或过滤日志。
- 如果未来明确要恢复 Windows 无障碍能力，必须先撤销全局 `ExcludeSemantics`，再基于可复现步骤系统验证 `Tooltip`、`FTooltip`、`FPopoverMenu`、`OverlayPortal`、`ListView`、`GridView`、`AnimatedSwitcher`、图表和动态表单的语义树稳定性。
- 这类 native/engine 层日志通常无法通过 `FlutterError.onError` 或 `runZonedGuarded` 捕获，不要优先用 Dart 异常处理兜底。

## 约定
- 优先做最小且聚焦的改动，并保持与现有 Flutter 项目结构一致。
- 除非任务明确要求，否则不要把只适用于生产环境的地址硬编码进代码；应优先保留对本地 E2E 和线上环境都友好的可配置路径。
- 在增加 UI 或网络能力时，保持对桌面端工作流的兼容性。
- 本项目 UI 基于 ForUI。新增或替换交互控件、导航、表单、弹窗、菜单、提示等 UI 时，应优先选用 ForUI 已提供的组件和样式；只有 ForUI 缺少对应能力或业务布局需要自定义时，才使用 Flutter/Material 基础组件，并尽量将 Material 使用限制在 `Text`、`Icon`、`Color`、布局等基础层。
- 本项目包含中文文案，源码与文档按 UTF-8 处理。在 Windows/PowerShell 环境中，允许用 PowerShell 查看文件，但不要用 `Get-Content | ... | Set-Content`、PowerShell 正则替换或其他隐式编码写回方式修改包含中文的文件；手工小改优先使用 `apply_patch`，批量机械替换应使用明确指定 UTF-8 的 Node/Dart 脚本。修改后如涉及中文文案，应通过明确 UTF-8 读取校验真实文件内容，不以 PowerShell 终端显示为准。
- 每次完成代码或文档改动后，都要执行一次 `git commit`，提交信息应准确描述本次改动。
- 如果某个需求需要跨仓库协同，明确指出真实的事实来源属于哪一侧：本应用、中心控制台仓库，还是 EasyTier 核心仓库。
