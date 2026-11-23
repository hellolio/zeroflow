# Zeroflow

[English](README.md) · **简体中文** · [日本語](README.ja.md)

macOS 原生的轻量效率工具集：截图标注、窗口切换、Dock 增强、剪贴板历史、灵动岛，全部收进一个菜单栏图标。

无弹窗、无第三方依赖，安装包小、启动快、常驻内存低。

与 AltTab（窗口切换工具）和 Maccy（剪贴板历史管理工具）相比，ZeroFlow 在功能丰富数倍的情况下，内存占用却远低于两者。无论是刚启动时，还是经过长时间、大量使用后，都能保持更低的内存占用。欢迎大家自行下载体验并进行对比测试。

[![Sponsor][SponsorBadge]][SponsorUrl]
[![Latest release](https://img.shields.io/github/v/release/hellolio/zeroflow)](https://github.com/hellolio/zeroflow/releases/latest)
[![License: AGPL-3.0](https://img.shields.io/github/license/hellolio/zeroflow)](LICENSE)
[![macOS: 14.0+](https://img.shields.io/badge/macOS-14.0%2B-black?logo=apple&logoColor=white)](https://github.com/hellolio/zeroflow)

[SponsorUrl]: https://github.com/sponsors/hellolio
[SponsorBadge]: https://img.shields.io/github/sponsors/hellolio?style=flat&logo=github&logoColor=white

## 功能

| 模块 | 说明 |
|---|---|
| 截图标注 | `⌘⇧S` 随时截图，支持画线、矩形、圆框、文字气泡、马赛克，可撤销重做；快捷键可自定义 |
| 窗口切换 | `⌘⇥`（可自定义）以缩略图切换窗口，最小化与离屏窗口同样可见 |
| Dock 增强 | 单击图标最小化窗口；悬停图标预览窗口内容 |
| 剪贴板历史 | `⌘⇧C`（可自定义）呼出历史记录，搜索、方向键选择、回车直接粘贴 |
| 灵动岛 | 悬停或单击刘海展开，显示日历、系统资源（CPU / 内存 / GPU / 磁盘 / 网络）、正在播放 |
| 访达右键菜单 | 在 Finder 中自定义右键命令 |
| 鼠标滚动 | 翻转滚轮方向，触控板手势不受影响 |

## 安装

从 [Releases](https://github.com/hellolio/zeroflow/releases) 下载最新的 `Zeroflow-x.x.x.dmg`，打开后把 Zeroflow 拖入「应用程序」。

> 应用未做开发者签名与公证，首次启动可能被 Gatekeeper 拦截。任选其一：
>
> - 终端执行 `xattr -cr /Applications/Zeroflow.app` 后重新打开；
> - 或到 系统设置 → 隐私与安全性，找到 Zeroflow 的提示并点「仍要打开」。

## 构建

前置：macOS 14.0+、Xcode 16+。

```bash

rm -rf build
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates \
  MARKETING_VERSION=9.9.99 \
  build

rm -rf /Applications/Zeroflow.app
cp -r build/Build/Products/Release/Zeroflow.app /Applications/Zeroflow.app


open build/Build/Products/Release/Zeroflow.app
```

- 新增源文件放入 `Zeroflow/` 即自动纳入编译，无需修改 `project.pbxproj`。
- `-allowProvisioningUpdates` 用于自动生成 FinderSync 扩展所需的 App Group 描述文件。

CI 见 `.github/workflows/build.yml`：推送或 PR 到 `main` 触发编译检查并上传 app artifact；推送 `v*` tag 则以 Release 配置构建、打包 DMG 并发布到 GitHub Releases。

## 技术栈

| 项 | 选型 |
|---|---|
| 语言 / UI | Swift 5 + SwiftUI + AppKit |
| 屏幕捕获 | ScreenCaptureKit（`SCScreenshotManager`） |
| 全局热键 | Carbon `RegisterEventHotKey`（截图 / 剪贴板） |
| 事件拦截 | CGEventTap（`⌘⇥` 切换、滚轮翻转、Dock 与刘海热区） |
| 窗口缩略图 | SkyLight 私有 API `CGSHWCaptureWindowList`（`dlsym` 桥接，可截最小化 / 离屏窗口） |
| 系统集成 | EventKit（日历）、MediaRemote（正在播放）、Accessibility API |
| 依赖 | 无第三方库，单工程 |
| 最低系统 | macOS 14.0 Sonoma |

## 目录结构

```
zeroflow/
├── Zeroflow.xcodeproj/      # Xcode 工程
├── Zeroflow/
│   ├── ZeroflowApp.swift    # 程序入口
│   ├── MenuBar/             # 菜单栏控制器
│   ├── Models/              # 设置、快捷键、编辑文档、剪贴板模型
│   ├── Views/               # 设置页、选区遮罩、编辑页、各功能面板
│   ├── Services/            # 截屏、热键、窗口、Dock、剪贴板、灵动岛、访达
│   └── Resources/           # 国际化文案（Translations.json）
├── FinderSyncExtension/     # 访达右键菜单扩展（沙盒，经 App Group 与主程序通信）
├── scripts/                 # 扩展登记脚本
└── .github/workflows/       # CI：编译检查与 Release 发布
```

## 路线图

- [ ] 灵动岛显示宠物（视内存占用而定）
- [ ] 持续优化性能，重点降低内存占用，并不断改进交互逻辑与操作体验。

## License

[AGPL-3.0-only](LICENSE)

版权人保留以其他条款（含商业许可）分发本软件的权利。
