# PITFALLS_DEV.md

开发踩坑记录(dev-test skill 维护,新增条目按 `DEV-XXX` 递增编号,勿改已有编号)。

## DEV-001: 本地 xcodebuild 不带 `-allowProvisioningUpdates` 直接 BUILD FAILED
- **Pitfall:** 构建时报 `No profiles ... were found`,BUILD FAILED。
- **Cause:** FinderSync 扩展 target 带 App Group(`8NHN73Q43T.com.zeroflow.app`)与沙盒授权,需要 Xcode 自动生成/更新含该 App Group 的 provisioning profile。
- **Prevention:** 本地构建一律带 `-allowProvisioningUpdates`;无团队证书的环境用 CI 等价命令(`CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=`)。

## DEV-002: `-derivedDataPath` 指向无写权限目录直接 BUILD FAILED
- **Pitfall:** 给 `-derivedDataPath` 的目录为只读(如 0644)时,构建直接失败。
- **Cause:** xcodebuild 需要在 derived data 目录写中间产物,无写权限即失败。
- **Prevention:** 换一个可写路径。

## DEV-003: xcodebuild 产物路径不可靠,直接 `cp -R` 得到坏符号链接
- **Pitfall:** Debug 产物可能落在 `build/Build/Intermediates.noindex/ArchiveIntermediates/.../Applications/Zeroflow.app`,用 `cp -R` 复制它得到的是坏符号链接。
- **Cause:** 产物落点不总是确定的。
- **Prevention:** 用 `find <derived>/Build -name "Zeroflow.app"` 定位;复制用 `cp -R -L` 解引用;复制前先 `rm -rf` 目标。

## DEV-004: 新增 target 需手改 pbxproj,改错直接 BUILD FAILED
- **Pitfall:** 以为 `.swift` 文件和 target 一样自动纳入工程,新增 target 时漏配;或手改 pbxproj 出错后构建失败。
- **Cause:** 源文件走 `PBXFileSystemSynchronizedRootGroup` 自动纳入(不要手改 pbxproj 加文件),但 target 本身、Embed App Extensions 阶段、target dependency、FinderSync.framework 链接(App 用于 `FIFinderSyncController.isExtensionEnabled`)都是手工维护的。
- **Prevention:** 新增 `.swift` 文件放对应目录即可;新增/调整 target 才动 pbxproj,改完立即构建验证。当前仅 `FinderSyncExtension/` 一个扩展 target,已配好。

## DEV-005: FinderSync 扩展未沙盒化会被 pkd 静默拒绝
- **Pitfall:** `pluginkit -m` 永远不出现该扩展,`pluginkit -a` 返回 0 却无任何日志,右键菜单不出现。
- **Cause:** pkd(pluginkit)静默拒绝非沙盒的 FinderSync 扩展(`com.apple.security.app-sandbox` 缺失)。
- **Prevention:** 扩展 target 必须保持沙盒授权;排查扩展不可见时先核对 entitlements。

## DEV-006: pkd 进程僵死,新扩展登记不上
- **Pitfall:** 新扩展 `pluginkit -a` 返回 0 但 `pluginkit -m` 查不到,反复登记无效。
- **Cause:** pkd 内存会僵住,僵死的旧实例不响应新插件注册。
- **Prevention:** 登记后查不到就 `killall pkd` 再查;`scripts/install-findersync.sh` 已内置处理。

## DEV-007: LaunchServices 残留旧路径插件记录导致 pkd 拒绝扩展
- **Pitfall:** pkd 解析到无效路径(如 build 目录里的旧 app/appex)而拒绝扩展。
- **Cause:** LS 记录了旧路径的插件(重复构建产物留下的登记),优先于新路径被解析。
- **Prevention:** 先 `lsregister -u` 所有旧路径的 app 及其 appex,再只注册 /Applications;`install-findersync.sh` 已内置处理。

## DEV-008: macOS Sequoia/Tahoe 覆盖安装后 Finder 右键菜单消失(陈旧扩展实例)
- **Pitfall:** app 重建/覆盖安装后,扩展显示已启用(`FIFinderSyncController.isExtensionEnabled` 为 true、设置页绿色),但 Finder 右键菜单不出现;手动关闭再开启一次即恢复。
- **Cause:** pkd 与 Finder 仍持有旧扩展实例;已程序化复现(`pluginkit -e ignore` → `-e use` 的 election 循环)。
- **Prevention:** 主 app 启动自愈走 `Zeroflow/Services/FinderSyncReloader.swift`,设置页有「刷新右键菜单扩展」按钮;安装用 `scripts/install-findersync.sh`(支持 `--reload-only` 仅重载)。

## DEV-009: Finder 右键菜单位置无法调整
- **Pitfall:** 尝试把扩展的右键菜单项放到菜单顶部/中间,无法实现。
- **Cause:** 菜单项被 Finder 硬编码在菜单底部,无 API 可调整位置。
- **Prevention:** 放弃调序,接受固定位置。

## DEV-010: 不要用 `UserDefaults(suiteName:)` 读 App Group
- **Pitfall:** 沙盒扩展里读不到主 app 写入的设置,cfprefsd 报 `Container: (null)`。
- **Cause:** cfprefsd 在沙盒扩展进程里无法解析 App Group suite。
- **Prevention:** 主 app(非沙盒但带 `com.apple.security.application-groups`)与扩展双方直接读写 group container 里的 `finder-sync-settings.plist` 文件(见 `Models/SettingsStore.swift` 与 `FinderSyncExtension/FinderSync.swift`)。

## DEV-011: 沙盒里 `homeDirectoryForCurrentUser` 返回容器目录,扩展不监控任何路径
- **Pitfall:** 直接把 `FileManager.default.homeDirectoryForCurrentUser` 当 `directoryURLs` 会让 Finder 完全不监控用户路径,`menu(for:)` 永不触发。
- **Cause:** 沙盒进程里该 API 返回 `~/Library/Containers/<bundle>/Data`,不是真实家目录。
- **Prevention:** 用 `URL(fileURLWithPath: "/Users/\(NSUserName())")` 拼真实家目录。

## DEV-012: `NSMenuItem.representedObject` 跨 XPC 不保留
- **Pitfall:** 点击菜单动作回调里 `sender` 拿不到自定义 `representedObject`,报 `createFile: invalid sender`。
- **Cause:** FinderSync 菜单项动作跨 XPC 传递,representedObject 不会被保留。
- **Prevention:** 在动作里用 `FIFinderSyncController.default().targetedURL()` / `selectedItemURLs()` 重新推导目标(`targetDirectory()`),不要依赖 sender。

## DEV-013: FinderSync 右键目标目录无写权限
- **Pitfall:** 右键目录里新建文件失败,日志 `deny file-write-create`。
- **Cause:** `files.user-selected.read-write` 权限不覆盖 FinderSync 右键目标。
- **Prevention:** 加 `com.apple.security.temporary-exception.files.home-relative-path.read-write`(值 `["/"]`,覆盖整个家目录;不入 App Store 可接受)。

## DEV-014: 扩展里不能直接执行子进程命令(继承沙盒),需转交主 app 代执行
- **Pitfall:** 扩展里 `Process` 拉起终端/pty 类命令(如 `wezterm start`)EPERM 秒退。
- **Cause:** 子进程继承扩展的沙盒约束。
- **Prevention:** 自定义命令不在扩展执行:扩展把请求写进 group container 的 `finder-command-*.plist` 并广播分布式通知(沙盒发通知不能带 userInfo),由非沙盒主 app `Zeroflow/Services/FinderCommandRunner.swift` 代执行(启动时消化积压请求,超过 30s 的丢弃;扩展侧主 app 未运行时会拉起它)。

## DEV-015: 新 SDK(27.0)下 EventKit/CG/NSScreen 的 API 形态变化
- **Pitfall:** 灵动岛功能首编四处报错:`store.events(from:to:calendars:)` 不存在、`EKCalendar.color` 按 CGColor 用报类型错、`NSScreen.auxiliaryTopLeft/RightArea` 按 non-optional 用报可选错、`CGEvent.keyCode` 属性不存在。
- **Cause:** EventKit 便捷查询只剩谓词版 `events(matching:)`;macOS 上 `EKCalendar.color` 一直是 NSColor(iOS 才是 CGColor);辅助区矩形在新 SDK 声明为可选;CGEvent 键码要走 `getIntegerValueField(.keyboardEventKeycode)`。
- **Prevention:** 遇到系统框架 API 编译错先查本机 SDK 头文件(`/Applications/Xcode.app/.../System/Library/Frameworks/<F>.framework/Headers/*.h`)再改实现,不要凭记忆按 iOS 或旧文档签名写。

## DEV-016: `animator().setFrameOrigin(_:)` 对 NSWindow 无效
- **Pitfall:** 灵动岛面板从刘海后方 12pt 滑入,用 `animator().setFrameOrigin(final)` 做动画,面板最终停在起始位置(比目标高 12pt),像是"贴不到刘海下缘"。
- **Cause:** NSWindow 经 animator 代理可动画的属性只有 frame/alphaValue/bounds 等,`setFrameOrigin:` 不在其中,调用静默无效。
- **Prevention:** 窗口位移动画用 `animator().setFrame(_:display:)`(先 setFrame 到起始位置);或只动画 alphaValue/内容视图 transform。
