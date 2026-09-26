# EasyTier Pro App

EasyTier Pro App 是 EasyTier Pro 的跨平台客户端，用于把桌面和移动设备接入已授权的零信任网络。它负责登录控制台、选择工作区与网络、启动本机 EasyTier runtime、展示节点状态与路由信息，并在支持的平台上提供自动更新和系统集成。

本仓库只包含客户端应用层。控制台、设备生命周期、策略编排等后端能力由 EasyTier Pro 控制台提供；隧道、组网、路由和数据面能力由 EasyTier core 提供。

## 功能概览

- 控制台登录、设备授权和本地登录态保存。
- 工作区、网络、设备和节点状态展示。
- 加入或断开已授权网络，查看虚拟 IP、路由、流量和连接状态。
- Windows 和 macOS 桌面客户端随包携带 `easytier-pro-installer`，用于安装和管理本机 EasyTier runtime。
- Android 客户端通过系统 `VpnService` 建立可见 VPN 连接，把授权网络和子网路由交给 EasyTier 处理。
- 桌面端使用 `auto_updater` 接入自动更新；macOS 使用 Sparkle appcast，Windows 使用 WinSparkle appcast。
- 诊断日志覆盖认证、控制面连接、runtime 启停、VPN 授权、路由下发和更新检查等关键路径。

## 下载

正式构建会发布到以下位置：

- GitHub Releases: <https://github.com/EasyTier-Pro/easytier-pro-app/releases>
- Gitee Releases: <https://gitee.com/EasyTier-Pro/easytier-pro-app/releases>

常见发布产物：

- Windows: `easytier-pro-windows-x64-setup-*.exe` 和 `easytier-pro-windows-x64.zip`
- macOS: `easytier-pro-macos-arm64.dmg`、`easytier-pro-macos-x64.dmg` 以及 Sparkle 更新用 `.zip`
- Android: `easytier-pro-android-arm64-v8a.apk` 和 `easytier-pro-android-x86_64.apk`

macOS 首次安装的 `.dmg` 需要完整的 Apple Developer ID 代码签名、公证和 stapling，才能在普通浏览器下载后稳定通过 Gatekeeper。Sparkle 的 EdDSA 签名只用于自动更新包校验，不能替代 Apple 的签名与公证。

## 开发环境

基础依赖：

- Flutter stable，包含匹配的 Dart SDK。
- Windows 桌面开发需要 Visual Studio Build Tools 和 Windows 桌面组件。
- macOS 桌面开发需要 Xcode、CocoaPods 和可用的 macOS runner 环境。
- Android 开发需要 Android SDK、Android NDK 和 JDK 17。
- 如需重建随包 installer 或 EasyTier JNI/core，需要 Rust toolchain 和对应 target。

安装依赖：

```bash
flutter pub get
```

静态分析和测试：

```bash
dart analyze
flutter test
```

本地运行：

```bash
flutter run -d windows
flutter run -d macos
flutter run -d android
```

## 构建

桌面 release 构建：

```bash
flutter build macos --release
flutter build windows --release
```

Android release 构建：

```bash
flutter build apk --release --target-platform android-arm64,android-x64 --split-per-abi
```

仓库内提供了一组发布辅助脚本：

- `scripts/package_windows_installer.ps1` 生成 Windows 安装器。
- `scripts/package_macos_dmg.sh` 生成 macOS `.dmg`。
- `scripts/package_android_release_apks.ps1` 整理 Android split APK。
- `scripts/generate_appcast.dart` 生成桌面自动更新使用的 appcast XML。
- `scripts/verify_android_release_inputs.ps1` 和 `scripts/verify_android_porting_readiness.ps1` 用于 Android 发布前检查。

更完整的自动更新和发布说明见 [docs/auto-update-desktop.md](docs/auto-update-desktop.md) 与 [docs/android-release.md](docs/android-release.md)。

### HarmonyOS：VPN Extension 子进程运行

HarmonyOS 使用 Flutter-OH `3.41.10-ohos-0.0.2-beta`，不能用普通 Flutter SDK 替代其构建链。配置好 Command Line Tools、Node、JDK 17 和 API 23 兼容 SDK 后，可构建不依赖私有签名的 Debug 包：

```bash
flutter pub get
CI=true flutter build hap --debug --no-codesign --no-pub
```

产物为 `build/ohos/hap/entry-default-unsigned.hap`。此包未签名，不能直接当作真机可安装包。

- `EasyTierVpnAbility`（系统 VPN Extension 进程）独立持有 Core、控制面连接、逐 socket 保护和 TUN。它从现有 HAR 的 Core 状态读取虚拟地址与聚合路由，并在子进程内协调接口建立、更新和撤销，不依赖 Flutter 定时器或 UI 是否消费事件。
- `EntryAbility` 不再申请 `dataTransfer` 长时任务，也不再发布随机下载进度的“保活”实况通知。这里的子进程是 VPN Extension，不是 `childProcessManager`。
- UI 冻结、IPC 断开或 Flutter 重建不等于 VPN 已停止。恢复时重新连接并读取 `getRuntimeSnapshot` 全量快照；读取失败报告状态未知，不伪造空实例列表，也不据此销毁子进程。相同启动参数重复到达不会重建已有控制面会话。
- 冻结期间 Extension 自行恢复 TUN 时，UI 进程收不到那条 `vpn_started`：恢复流程只在快照**控制面已连接且报告了已挂载 TUN 的实例身份**时，把残留的失败状态收敛回运行中；未知、控制面断开或没有已挂载 TUN 时保持原状态，不伪造事件、不无条件清错、不重启运行时。
- IPC 对每个客户端限制待发送队列并设置写超时；冻结的 UI 读端只会失去自己的连接，不阻塞内核协调和其他客户端。重连不自动重放超时的修改命令。
- 用户退出网络时，子进程先撤销 TUN 并暂停该实例的自动建立；退出失败时 `resumeVpn` 从 Core 重新读取当前路由，而不是重放 UI 的旧配置。实例消失或运行时显式停止会清除暂停状态。

宿主机行为回归（跑真实 ETS 实现；系统/N-API 与 IPC 客户端边界受控，因此不构成真机证据）：

```bash
bun test test/ohos_vpn_runtime.test.ts test/ohos_core_runtime_ipc.test.ts test/ohos_runtime_bridge.test.ts
flutter test --no-pub
```

这些检查不能替代真机 VPN 授权、后台/息屏调度、逐 socket 保护和实际载流验收。子进程模式不承诺在系统强制终止应用、撤销 VPN 授权或销毁 Extension 后继续运行；系统生命周期边界见 [HarmonyOS VPN 开发指南](https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension)。

## 自动更新

桌面端内置 appcast feed 优先级：

1. Gitee: `https://gitee.com/EasyTier-Pro/easytier-pro-app/releases/download/latest/appcast.xml`
2. OSS: `https://easytier.net/releases/appcast.xml`
3. GitHub: `https://github.com/EasyTier-Pro/easytier-pro-app/releases/latest/download/appcast.xml`

如需在测试环境覆盖 feed，可以在构建时传入：

```bash
flutter build macos --release --dart-define=EASYTIER_APPCAST_URLS=https://example.com/appcast.xml
flutter build windows --release --dart-define=EASYTIER_APPCAST_URLS=https://example.com/appcast.xml
```

多个 URL 可以使用分号、逗号、空白或换行分隔。客户端启动时会探测并选择第一个可访问且看起来像 appcast XML 的 feed。

## 发布流程

推送 `vX.Y.Z` tag 会触发 `Desktop Packages` workflow。workflow 会构建 Windows、macOS、Android 产物，生成 appcast XML，并创建 GitHub draft release。

```bash
git tag v1.0.7
git push origin v1.0.7
```

发布前请确认：

- `pubspec.yaml` 中的短版本号与 tag 一致。
- Windows installer、Windows portable zip、macOS `.dmg`、macOS `.zip`、Android APK 和 appcast XML 都已生成。
- macOS 正式分发包已经完成 Developer ID 签名、公证和 stapling。
- appcast 中的下载 URL 指向对应发布渠道，并且所有文件都可以通过 HTTPS 下载。
- 私钥、keystore、notarization 凭据和生产环境密钥没有提交到仓库。

## 仓库结构

```text
lib/        Flutter 应用代码
android/    Android runner、VpnService 与 JNI 集成
ios/        iOS runner
macos/      macOS runner 与 Sparkle 配置
windows/    Windows runner、安装器资源与 WinSparkle 配置
linux/      Linux runner
assets/     图标、图片和字体资源
docs/       发布、自动更新和 Android 移植说明
scripts/    构建、打包、签名和验证脚本
test/       Dart 单元测试与 widget 测试
```

## 相关项目

- EasyTier core: <https://github.com/EasyTier/EasyTier>
- EasyTier Pro installer: <https://github.com/EasyTier-Pro/installer>
- EasyTier Pro console: <https://github.com/EasyTier-Pro/easytier-console>
- 控制台: <https://console.easytier.net/>

## 许可证

EasyTier Pro App 使用 GNU Affero General Public License v3.0 发布。详见 [LICENSE](LICENSE)。

第三方依赖、字体、图标和平台 SDK 仍遵循其各自的许可证。
