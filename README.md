# SwiftPili

[![Build & Release IPA](https://github.com/haikiseven/SwiftPili/actions/workflows/build.yml/badge.svg)](https://github.com/haikiseven/SwiftPili/actions/workflows/build.yml)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)

原生 iOS / iPadOS 18+ 哔哩哔哩第三方客户端。

由于在 iOS 上经历了糟糕的 flutter 使用体验，本人决定制造一个本地人 iOS 客户端。

## 声明

该项目由多个溜溜梅编写而成，所以本项目不对你的账号和使用体验负责。使用该项目即视为你同意以上条款。

## 主要功能

- **视频与直播播放**
  - 支持 DASH 点播、直播流播放、VideoToolbox 硬件解码（含 AV1）、多 CDN 测速与自动切换、画质增强与音频均衡器。
  - 支持弹幕渲染与发送、外挂/内置字幕、手势控制、画中画（PiP）、后台音频播放与 SponsorBlock 空降助手片段跳过。
- **完整的浏览与互动体验**
  - 首页推荐、热门、分区、视频详情与合集、番剧/影视、直播间。
  - 动态与评论互动（支持图文查看器、回复、转发、点赞）、专栏文章、音乐、私信与系统通知、全局搜索。
  - 个人中心（扫码/密码/短信登录）、收藏夹、观看历史、稍后再看、离线缓存播放及本地 MP4 导出。
- **原生 iOS / iPadOS 体验**
  - 支持 iPhone 与 iPad 横竖屏、分栏与多窗口布局，适配深浅色主题及 iOS 26+ Liquid Glass 界面。

## 下载安装（IPA）

可直接前往 [Releases](https://github.com/haikiseven/SwiftPili/releases) 页面下载自动构建的 `.ipa`：

- **每日构建（`nightly`）**：每次推送到 `main` 分支都会自动构建并更新 [`nightly`](https://github.com/haikiseven/SwiftPili/releases/tag/nightly) 预发布中的 `SwiftPili.ipa` 与 `SwiftPili.ipa.sha256`。
- **正式版本（`v*`）**：推送 `v*` 标签后自动发布对应版本 `SwiftPili-<tag>.ipa`。

> 发布产物为**未签名 Release IPA**，可使用 TrollStore、AltStore、SideStore、Sideloadly 等工具自签名或侧载安装。

## 从源码构建

### 环境要求

- macOS + Xcode 26+（iOS 18.0+ 部署目标，Swift 6）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- `curl` 或 [GitHub CLI](https://cli.github.com/)（`gh`）

### 1. 克隆仓库并准备同级 `SwiftVLC`

`project.yml` 与 `Package.swift` 依赖同级目录 `../SwiftVLC`：

```bash
git clone https://github.com/haikiseven/SwiftPili.git
git clone https://github.com/haikiseven/SwiftVLC.git
cd SwiftPili
./patches/apply.sh ../SwiftVLC
```

### 2. 获取预编译依赖（`libvlc` + `ExportMediaDependencies`）

**快速方式（推荐）：** 直接从本仓库的 [`deps-v1`](https://github.com/haikiseven/SwiftPili/releases/tag/deps-v1) Release 下载预编译 XCFramework，脚本会自动校验 SHA-256 并解压到对应目录（支持 `gh` 或匿名 `curl`）：

```bash
./scripts/fetch-prebuilt-deps.sh
```

**从源码自行编译（可选）：** 如需自行重新编译底层依赖，可分别参考 `patches/libvlc/README.md` 在 `../SwiftVLC` 内构建 `Vendor/libvlc.xcframework`，以及参考 `Packages/MediaExportNative/README.md` 构建导出依赖：

```bash
./scripts/build-export-media.sh --sdk iphoneos --arch arm64
./scripts/build-export-media.sh --sdk iphonesimulator --arch arm64
./scripts/build-export-media.sh --package-only
```

### 3. 配置本地代码签名

`project.yml` 默认通过 `Configuration/Signing.xcconfig` 使用空 `DEVELOPMENT_TEAM`，并自动读取仓库根目录被 git 忽略的 `LocalSigning.xcconfig`：

```bash
cp LocalSigning.xcconfig.example LocalSigning.xcconfig
# 编辑 LocalSigning.xcconfig，填入你自己的 DEVELOPMENT_TEAM（以及可选的 PRODUCT_BUNDLE_IDENTIFIER）
```

### 4. 生成 Xcode 工程并运行

```bash
xcodegen generate
open SwiftPili.xcodeproj
```

也可以通过命令行在 iOS 模拟器中构建（无需签名）：

```bash
DEVICE="$(./scripts/pick-simulator.sh)"
xcodebuild build \
  -project SwiftPili.xcodeproj \
  -scheme SwiftPili \
  -configuration Debug \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  CODE_SIGNING_ALLOWED=NO
```

## 项目结构

- `SwiftPili/App/` — 应用入口、生命周期、窗口与方向管理
- `SwiftPili/Navigation/` — 路由协调与深链解析
- `SwiftPili/Core/` — 网络层、WBI 签名、登录鉴权与 Keychain、SwiftData 持久化、通用工具
- `SwiftPili/SharedUI/` — 通用组件、信息流列表、图片浏览器、设计样式定义
- `SwiftPili/Player/` — 播放器核心、解复用/解码/渲染管线、弹幕与播控界面
- `SwiftPili/Features/` — 首页、视频、番剧、直播、动态、消息、搜索、专栏、音乐、我的
- `Packages/PiliPlayerKit/` — 独立 SwiftPM 播放器基础模块
- `Packages/MediaExportNative/` — 原生 C / FFmpeg 离线媒体导出与直播流解复用模块
- `patches/` — `libvlc` 与 `SwiftVLC` 补丁及验证脚本
- `scripts/` — 构建辅助与依赖下载脚本
- `Design/` — 应用图标导出脚本

## GitHub Actions 与自动发布

仓库仅保留一个核心工作流 [`build.yml`](.github/workflows/build.yml)（运行于 `macos-26`）：

- **Pull Request 到 `main`**：自动编译 Release 归档并上传 IPA 构建产物（不覆盖 Release）。
- **推送到 `main`**：自动构建未签名 Release IPA，并滚动更新 [`nightly`](https://github.com/haikiseven/SwiftPili/releases/tag/nightly) 预发布（`SwiftPili.ipa` + `SwiftPili.ipa.sha256`）。
- **推送 `v*` 标签**（如 `v1.0.0`、`v1.1.0-beta.1`）：自动创建对应版本的 GitHub Release 并附带 `SwiftPili-<tag>.ipa` 与校验文件。
- **手动触发（`workflow_dispatch`）**：支持按需开启 Debug 模拟器构建（`run_debug_build`）以及是否发布到 `nightly`（`publish_release`）。

## 致谢

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)
- [BilibiliSponsorBlock](https://github.com/hanydd/BilibiliSponsorBlock)
- [bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect)
- [SwiftVLC](https://github.com/harflabs/SwiftVLC)
- [Kingfisher](https://github.com/onevcat/Kingfisher)
- [VLC / libVLC](https://www.videolan.org/vlc/)
- [FFmpeg](https://ffmpeg.org/)
- [dav1d](https://code.videolan.org/videolan/dav1d)
- [libplacebo](https://code.videolan.org/videolan/libplacebo)
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK)

## 免责声明

本项目为哔哩哔哩第三方开源客户端，仅用于学习与技术交流，与哔哩哔哩（Bilibili）官方无任何关联。

## 开源协议

本项目基于 [GNU General Public License v3.0](LICENSE) 开源协议发布。
