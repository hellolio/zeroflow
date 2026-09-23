# AGENTS.md

macOS 截图菜单栏工具(截图 + 画线/矩形/圆框/文字气泡/马赛克 + 撤销重做 + Dock 单击最小化 + 内置 ⌘⇥ 窗口缩略图切换器)。SwiftUI + AppKit,无第三方依赖,零测试/零 lint 目标。文档为中文: `README.md`(用户说明)、`需求文档.md`(需求与验收, 含第 12 章「内置 ⌘⇥ 窗口缩略图切换器」完整需求)、本文件(AI/开发者构建与架构速查)。

## 构建与部署

前置: macOS 14+、Xcode 16+。没有测试/lint 命令,唯一验证 = `xcodebuild` 通过 + 手动运行。

```bash
# Debug（需 -allowProvisioningUpdates：App Group 自动配置新 profile）
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow -configuration Debug -derivedDataPath build -allowProvisioningUpdates build
# 产物一般在 build/Build/Products/Debug/Zeroflow.app
open build/Build/Products/Debug/Zeroflow.app
```
```bash
# Release
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project Zeroflow.xcodeproj \
  -scheme Zeroflow \
  -configuration Release \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  build
# 产物一般在 build/Build/Products/Release/Zeroflow.app
open build/Build/Products/Release/Zeroflow.app
```
- **构建必须带 `-allowProvisioningUpdates`**: FinderSync 扩展 target 带 App Group(`8NHN73Q43T.com.zeroflow.app`,Team 前缀)与沙盒授权,需要 Xcode 自动生成/更新带该 App Group 的 provisioning profile;不带会直接 `No profiles ... were found` BUILD FAILED。
- **FinderSync 扩展必须沙盒化**: pkd(pluginkit)会静默拒绝非沙盒的扩展(`com.apple.security.app-sandbox` 缺失时 `pluginkit -m` 永远不出现、`-a` 返回 0 却无任何日志)。扩展与主 app 通过 App Group(`8NHN73Q43T.com.zeroflow.app`)共享设置:主 app 非沙盒但带 `com.apple.security.application-groups`,双方直接读写 group container 里的 `finder-sync-settings.plist` 文件——**不要用 `UserDefaults(suiteName:)` 读 App Group**(沙盒扩展里读不到,cfprefsd 报 `Container: (null)`)。登记/启用一键脚本:`scripts/install-findersync.sh [Debug|Release]`,内含两个致命坑的规避:① **pkd 内存会僵住**,新扩展 `pluginkit -a` 返回 0 却查不到,必须 `killall pkd`;② **LS 残留的旧路径插件记录**(如 build 目录)会让 pkd 解析到无效路径而拒绝,必须先 `lsregister -u` 所有旧路径的 app 及其 appex,再只注册 /Applications。诊断用扩展的 os_log(`log show --predicate 'subsystem == "com.zeroflow.app.finderSync"'`)。**右键菜单项被 Finder 硬编码在菜单底部,无 API 调整位置**;**macOS Sequoia/Tahoe 陈旧扩展 bug**: app 重建/覆盖安装后扩展显示已启用但右键菜单不出现,手动关开一次即恢复——已程序化复现(`pluginkit -e ignore`→`-e use` election 循环):脚本 `install-findersync.sh` 内建(支持 `--reload-only`),主 app 启动自愈走 `Zeroflow/Services/FinderSyncReloader.swift`,设置页有「刷新右键菜单扩展」按钮。完整开发流程见 skill `findersync-workflow`。
- **FinderSync 扩展四个沙盒/协议坑**(功能 Debug 时踩过):
  ① **真实家目录**: 沙盒进程里 `FileManager.default.homeDirectoryForCurrentUser` 返回的是容器目录(`~/Library/Containers/<bundle>/Data`),直接当 `directoryURLs` 会让 Finder 完全不监控任何用户路径、`menu(for:)` 永不触发。要用 `URL(fileURLWithPath: "/Users/\(NSUserName())")` 拼真实家目录。
  ② **`NSMenuItem.representedObject` 跨 XPC 不保留**: 点击动作回调里 `sender` 拿不到自定义 `representedObject`(会 `createFile: invalid sender`)。目标目录必须在动作里用 `FIFinderSyncController.default().targetedURL()`/`selectedItemURLs()` 重新推导(`targetDirectory()`),不要依赖 sender。
  ③ **右键目录无写权限**: `files.user-selected.read-write` 不覆盖 FinderSync 右键目标(`deny file-write-create`),写文件必须加 `com.apple.security.temporary-exception.files.home-relative-path.read-write`(值 `["/"]`,覆盖整个家目录;不入 App Store 可接受)。
  ④ **子进程继承沙盒**: 扩展里 `Process` 拉起的命令仍被沙盒约束,终端/pty 类命令(如 `wezterm start`)会 EPERM 秒退。自定义命令不能在扩展里执行:扩展把请求写进 group container 的 `finder-command-*.plist` 并广播分布式通知(沙盒发通知不能带 userInfo),由非沙盒的主 app 代为执行(`Zeroflow/Services/FinderCommandRunner.swift`,启动时也会消化积压请求,超过 30s 的请求丢弃;扩展侧主 app 未运行时会把它拉起)。
- **产物路径不可靠**: Debug 产物可能落在 `build/Build/Intermediates.noindex/ArchiveIntermediates/.../Applications/Zeroflow.app`(`cp -R` 复制这个可能是坏符号链接)。用 `find <derived>/Build -name "Zeroflow.app"` 定位,复制用 `cp -R -L` 解引用,复制前 `rm -rf` 目标。
- **dist/ 已被 gitignore**,是发布副本。部署流程: `rm -rf dist/Zeroflow.app && cp -R -L <找到的app> dist/ && pkill -f Zeroflow.app`,再 `open dist/Zeroflow.app`。
- 给 `-derivedDataPath` 的目录若无写权限,构建会直接 `BUILD FAILED`(0644/只读目录),换一个可写路径。
- **新增 .swift 文件自动纳入编译**: 工程用 `PBXFileSystemSynchronizedRootGroup`,不要手动改 pbxproj 加文件。
- **新增 target 需手改 pbxproj**: 唯一的例外是 FinderSync 扩展 target(`FinderSyncExtension/`)。它也是 `PBXFileSystemSynchronizedRootGroup` 自动纳入源码,但 target 本身、Embed App Extensions 阶段、target dependency、FinderSync.framework 链接(App 用于 `FIFinderSyncController.isExtensionEnabled` 状态)都要在 pbxproj 里手工维护,改错会直接 `BUILD FAILED`。

## 架构要点

- 入口 `Zeroflow/ZeroflowApp.swift`(`@main` 手动建 `NSApplication` + `MenuBarController`); 菜单栏 `MenuBar/MenuBarController.swift`; 服务层 `Services/`:
  - `GlobalHotkeyManager`: Carbon 全局热键,受截图总开关 `screenshotEnabled` 控制(`reapply()` 里判断)。
  - `ScreenCapture`: ScreenCaptureKit 截图; 按 displayID 缓存 `SCContentFilter`(屏幕参数变化通知里 `invalidateFilterCache()`)。
  - `CaptureCoordinator`: 权限→遮罩→捕获→编辑页 的协调器,`isActive` 防重入。
  - `DockClickMinimizer`: Dock 单击最小化(CGEventTap + AX),受 `dockClickMinimize` 开关控制。
  - `CommandTabSwitcher`: 内置 ⌘⇥ 窗口缩略图切换器(CGEventTap + AX),受 `cmdTabSwitcherEnabled` 开关控制; 会话中 ⇥/⇧⇥/方向键移动选择, 悬停卡片可退出/关闭/最小化/全屏(`WindowOps`, 本 app 窗口走主线程 NSWindow)。
  - `DockHoverPreviewController` + `Views/DockPreviewPanel`: Dock 悬停窗口预览(listen-only CGEventTap + Dock AX 探测独立拷贝自 DockClickMinimizer,受 `dockPreviewEnabled` 开关控制); 窗口来源与切换器同源(`WindowList.enumerate()` 按 bundleID 过滤, 含最小化瓦片), idle→pending→visible 状态机 + generation 作废, 面板非激活 NSPanel, 卡片点击激活(`WindowActivator`)/悬停关闭(`WindowOps`)。
  - `WindowList`: 窗口枚举(CGWindowList 公开 API)+ 幽灵窗口过滤 + 窗口级 MRU 排序 + 无窗口 app 占位卡(开关 `windowSwitcherShowWindowlessApps`, 排最后); `CGSWindowServer`: SkyLight/CGS 私有 API dlsym 桥(SLS 批量枚举 + 可见/全量成员列表 + Space 拓扑, 符号缺失退回公开 API); `PhantomWindowDetector`: 幽灵判定(对齐 AltTab cgsVerdict, 含 AX subrole 兜底); `WindowActivityTracker`: AX 焦点通知维护窗口级 MRU; `WindowThumbnailer`: SkyLight 私有 API(dlsym)抓缩略图 + 缓存/节流/降级; `WindowActivator`: AX 还原/前置/激活(本 app 窗口走主线程 makeKeyAndOrderFront, AX 后台线程会崩)。切换器模块完整需求见 `需求文档.md` 第 12 章。
  - `AccessibilityPermission` / `ScreenRecordingPermission`: 辅助功能 / 屏幕录制权限检测与申请。
  - `FinderCommandRunner`: 执行 Finder 扩展转交的「访达自定义命令」(请求文件 + 分布式通知 IPC, 非沙盒代执行, 见上方坑位④); 扩展侧在 `FinderSyncExtension/FinderSync.swift` 的 `CustomCommandRunner`。
  - `ZSLog`: 统一日志(stderr + `/tmp/zeroflow.log`)。
- 编辑页就是 `Views/EditorView.swift`(单一 1300+ 行文件)。工具: `select / pencil(画线) / rect(矩形) / ellipse(圆框) / bubble(文字气泡) / mosaic(马赛克 半径 12/18/28)`。新增其他工具/图形也先加在这个文件。

### 编辑画布模型(`Models/EditDocument.swift`)

- 所有元素存**图像坐标**(非视图坐标); `EditorView` 用 `displayRect`/`scaleFactor` + `toView`/`toImage`(及 Rect 版本)换算。改元素绘制/命中时必须走这两个函数。
- `CanvasElement` 有 4 个 case: stroke / bubble / shape / mosaic,相等比较逐字段。
- 只有 bubble / shape 可选中、移动、缩放、删除(Backspace/Delete); stroke、mosaic 提交后不可再选。
- `EditDocument` 持有撤销/重做栈(上限 50),任何修改前先 `snapshotBeforeChange()`。
- **BubbleElement / ShapeElement 的 id 不可换**: 重设位置/大小/文字时要用 `init(id:...)` 沿用原 id,否则编辑覆盖层、拖动状态(`elementDrag`)、`selectedElementID` 按 id 索引的簿记全部失效。

### 文字气泡的交互

- 创建气泡后立即进入文字编辑(自动把 `text` 缓冲区置空); 文字编辑覆盖层 `bubbleEditor` 是内缩 8pt 的白底 `TextEditor`,边缘/四角仍可拖动缩放。
- **双击**气泡进入文字编辑(单击只选中)。
- TextEditor 必须显式 `.foregroundColor(.black)`,否则深色模式下黑底白字串字看不见; 顺带 `.environment(\.colorScheme, .light)`。
- 键盘(EditorView 内 NSEvent monitor): `⌘Z`/`⇧⌘Z`/`⌘S`/`⌘C`/`⌘L`(画线)/`T`(标注); Backspace/Delete(51/117) 删除选中气泡/形状(文字编辑中不生效); Esc(53) 文字编辑中=提交并退出编辑,否则关闭窗口。
- 导出(`exportedImage()`)用 AppKit 按原图尺寸重绘,不依赖视图层级,改绘制逻辑记得同步这里。

### 马赛克

- `drawMosaic`(画布)与 `drawMosaicIntoCanvas`(导出)共用 `MosaicOverlayCache`(整图最近邻像素化叠加图按半径缓存一次),临时笔划/已提交笔划/导出共用同一张图,保证三处样式一致。改动时保持这个一致性。

### 设置(`Models/SettingsStore.swift` + `Views/SettingsView.swift`)

- 三个标签页: 通用(开机自启)/ 截图(启用截图功能、快捷键、屏幕录制权限、保存)/ Dock(单击最小化开关 + 辅助功能权限引导)/ 切换(⌘⇥ 切换器)/ Dock 预览(悬停预览开关 + 悬停延时)/ 右键菜单(FinderSync)。
- `screenshotEnabled`(默认关)是总开关: 关闭时全局热键不注册、菜单「立即截图」置灰、`CaptureCoordinator.startCapture` 直接忽略。
- `dockClickMinimize` 开关变化由 `DockClickMinimizer` 监听通知启停 CGEventTap; `launchAtLogin` 变化经 `SMAppService.mainApp` 注册/注销(带防重入 + 注册失败回滚)。
- 所有 UserDefaults key 与默认值见 `需求文档.md` FR-12.9。

## 调试辅助环境变量(进程环境)

| 变量 | 作用 |
|---|---|
| `ZEROFLOW_AUTO_CAPTURE=1` | 启动 1.5s 后自动触发一次截图流程 |
| `ZEROFLOW_EDITOR_DEBUG=1` | 启动 1.5s 后直接打开编辑页(合成网格图),绕过截图 |
| `ZEROFLOW_DOCK_PROBE=1` | 启动 1s 后 dump Dock 的 AX 布局到日志 |
| `ZEROFLOW_SWITCHER_DEBUG=1` | 启动 1s 后 dump 一次窗口列表（数量、按 app 分组、是否含最小化窗口）+ 打印「⌘⇥ tap 是否已安装」到日志 |
| `ZEROFLOW_DOCKPREVIEW_DEBUG=1` | 打印 Dock 悬停预览的命中/展示/隐藏决策与 Dock 项缓存重建日志 |
| `ZEROFLOW_FAKE_PERMISSION=1` | 跳过真实权限检测(视为已授权) |
