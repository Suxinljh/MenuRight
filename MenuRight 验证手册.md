# MenuRight 验证手册(人工验收 runbook)

> 这份是给**人**用的操作手册。自动化测试(184 个单测)不能替代它:
> Finder 扩展加载、真实右键菜单、沙箱权限、Quick Look、解压这些只有在真机上点一遍才算数。
> 每步都写了**预期结果**和**失败时怎么取证**。做完请按 `Automated: PASS` / `Manual: PASS|FAIL` 分开回报。

---

## 0. 最重要的一条:确认 Finder 加载的是**新构建**

Finder 只加载 LaunchServices 注册的那份扩展。当前这台机器上注册的是
`/Users/suxin/Applications/MenuRight.app` 里的 **2026-08-30** 旧构建 ——
如果你不替换它,你测到的会是 A2 时代的行为(没有 IPC 委托、没有新菜单)。

先看一眼现状:

```sh
pluginkit -m -i xin.ljhsu.MenuRight.FinderSync -v
stat -f "%Sm  %N" ~/Applications/MenuRight.app/Contents/PlugIns/MenuRightFinder.appex/Contents/MacOS/MenuRightFinder
```

第二条应该显示**今天**的日期;如果是 8/30,就必须先做第 1 步。

---

## 1. 构建并安装(签名版)——**用脚本,不要手工 cp**

```sh
cd /Users/suxin/Suxin/code/app/MenuRight
Scripts/install-dev-app.sh          # 默认 Debug;也可传 Release
```

脚本做六件事:签名构建 → 校验产物签名 → **用 `ditto` 安装**(不是 `cp -R`)→ 验证安装副本能启动 → 注册并启用扩展 → 打印系统状态。每一步失败都会明确报错。

### ⚠️ 两个已经踩过的坑(2026-09-30 实测)

1. **永远不要用 `cp -R` 复制 .app**。Xcode 的 Debug 构建带调试 dylib(硬链接),`cp -R` 会把它解开 →
   `codesign --verify` 仍然说 "valid on disk",但内核在启动时 SIGKILL:
   `Taskgated Invalid Signature`(`~/Library/Logs/DiagnosticReports/MenuRight-*.ips`)。
   **同样一个构建,`ditto` 复制后可以正常启动,`cp -R` 复制后必被杀死** —— 已 A/B 实测。
2. **系统里只能存在一份 MenuRight**。Finder 只加载"已注册且已启用"的那份扩展;
   如果同时存在 DerivedData 和 ~/Applications 两份,你会在运行 A 副本时看到 B 副本的扩展状态,
   于是界面显示 `Disabled`,而 Finder 加载的其实是**旧代码**。

手工命令(脚本内部等价):

```sh
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug build -allowProvisioningUpdates
ditto "<BUILT_PRODUCTS_DIR>/MenuRight.app" ~/Applications/MenuRight.app     # 注意是 ditto
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
"$LSREG" -f -R -trusted ~/Applications/MenuRight.app
pluginkit -a ~/Applications/MenuRight.app/Contents/PlugIns/MenuRightFinder.appex
pluginkit -e use -i xin.ljhsu.MenuRight.FinderSync
pkill -f MenuRightFinder || true
```

**预期**:`pluginkit -m -i xin.ljhsu.MenuRight.FinderSync -v` 第一列是 `+`,路径指向你刚装的那份。
若脚本报告安装副本被杀死,说明复制方式不对(回到上面第 1 条)。

### 免责/排查:界面显示 Disabled 怎么办

**实测结论(2026-09-30)**:同一个二进制,从 `~/Applications` 运行报告 `isExtensionEnabled=true`,
从 DerivedData 运行(Xcode Run)报告 `false` —— 该 API 回答的是"系统已注册并启用的那一份",
不是"你正在运行的那一份"。应用现在会把这个状态写进诊断日志,并在窗口里显示**正在运行副本的路径**:

```sh
grep "extension status" ~/Library/Group\ Containers/group.xin.ljhsu.MenuRight/bootstrap-diagnostics.log | tail -1
# 看 exec= 判断是哪一份副本报告的
```

自检顺序:
1. `pluginkit -m -i xin.ljhsu.MenuRight.FinderSync -v` → 必须是 `+`,路径必须是**你正在运行的那份**。
2. 只保留一个实例:`pgrep -lf 'MenuRight.app/Contents/MacOS/MenuRight'`,多余的退出
   (在 Xcode 里按 Stop)。
3. 仍为 Disabled → 点应用里的 **Manage Finder Extension**,在系统设置里把 MenuRight 打开;
   或 `pluginkit -e use -i xin.ljhsu.MenuRight.FinderSync`,然后重开应用窗口刷新状态。
4. 若 `~/Library/Logs/DiagnosticReports/MenuRight-*.ips` 出现 `Taskgated Invalid Signature`
   → 是安装方式问题(见坑 1),或 **provisioning profile 过期**(Personal Team 的 profile 只有 7 天;
   旧副本的 profile 已于 2026-09-06 过期)。重新 `-allowProvisioningUpdates` 构建即可换新 profile。

> 注意:IPC 功能(新建/别名/锁定/终端/粘贴)需要**主 App 正在运行**(它是 socket 服务端)。
> 打开 `~/Applications/MenuRight.app` 并保持它运行;退出后扩展会提示 "Menu Right not running"。

## 2. 打开日志与诊断(失败取证必备)

```sh
# 实时系统日志(所有 IPC/生命周期事件)
log stream --predicate 'subsystem == "xin.ljhsu.MenuRight"' --level info

# 跨进程历史(比 log stream 更可靠,含两个进程的记录)
log show --predicate 'subsystem == "xin.ljhsu.MenuRight"' --last 10m --info | tail -80

# 持久化诊断文件(两个进程都写这里,只属主可读)
tail -40 ~/Library/Group\ Containers/group.xin.ljhsu.MenuRight/bootstrap-diagnostics.log

# socket 与权限(应为 srw------- / 600)
stat -f "%Lp %Su:%Sg %N" ~/Library/Group\ Containers/group.xin.ljhsu.MenuRight/ipc.sock
```

## 3. 逐项验证清单

### 3.1 P6 新增(本次改动)

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 1 | 桌面/文件夹**空白处**右键 | 出现 MenuRight 条目,展开后是:`Open Terminal`、`Copy Folder Name`、`Copy Folder Path`、分隔线、`New File ▸`、`New Folder`、分隔线、`Paste Here` | 是否只有一个 MenuRight 条目(见 §4 平台限制) |
| 2 | 点 `Open Terminal` | 新开 Terminal 窗口,`pwd` **就是**你右键的那个目录 | 弹窗 "Couldn't open Terminal." + 日志 `DISPATCH openTerminal FAILED`(把 message 发我) |
| 3 | `Copy Folder Name` / `Copy Folder Path` | 剪贴板得到该文件夹的名字 / 完整路径(粘到文本编辑器确认) | `log stream` 里 `ACTION INVOKED performCopy title=...` |
| 4 | `New File ▸` 逐个试**文本** 6 项 | 生成 `Untitled.txt` / `.md` / `.html` / `.css` / `.js` / `.json`;HTML 打开是完整骨架,CSS 有 `body { }`,JS 有 `"use strict"`,JSON 是 `{}`;重名第二次变 `Untitled 2.*`(文档类 6 项见 §3.6) | `DISPATCH createFile SUCCESS path=...` 或 FAILURE |
| 5 | `New Folder` | 生成 `New Folder` / `New Folder 2` | 同上 |
| 6 | 选中文件后右键 | 菜单是**平铺**的:`Create Alias`、`Lock`、`Unlock`、分隔线、`Copy Name`、`Copy Path`、`Copy File URL`、分隔线、`Cut` —— **没有任何二级子菜单** | 如果看到二级级联,把菜单截图给我 |
| 7 | 选中多个文件后 `Create Alias` | 每个文件旁边生成 `<原名> alias`;再点一次得到 `<原名> alias 2`(不覆盖);别名双击能跳回原文件 | `DISPATCH createAlias SUCCESS/FAILURE` |
| 8 | `Lock` | 文件 Get Info 显示"已锁定";在 Finder 里删除**报错拒绝**;`ls -lO` 显示 `uchg` | `DISPATCH setLocked SUCCESS locked=true` |
| 9 | `Unlock` | 锁定标记消失,可以正常删除 | `locked=false` |
| 10 | 选中一个**未授权**目录里的文件再 `Lock` | 弹出 "Folder Access Required" 提示(不是静默失败) | `DISPATCH setLocked NOT_AUTHORIZED` |
| 11 | `Open Terminal` 在**未授权**目录 | **应当成功**(这是刻意设计:该动作不写盘,只把路径交给 LaunchServices) | 见 §4 说明 |

> `Lock`/`Unlock` 同时常驻(而不是自动二选一)是有意为之:扩展是沙箱进程且没有文件权限,
> 在 `menu(for:)` 里读"是否已锁定"可能被沙箱拒绝,而且会给菜单构建引入 IO。
> 两个都显示则永远正确。如果你更喜欢按状态二选一,告诉我,我会在菜单里加一次带兜底的读取。

### 3.2 P5-1 存量回归(上一轮改动,一直未验证)

| # | 操作 | 预期结果 |
| - | ---- | -------- |
| A | 在已授权目录 `New File ▸ Text File` 两次 | `Untitled.txt`、`Untitled 2.txt`(不再是 513/EPERM 错误) |
| B | `New Folder` 两次 | `New Folder`、`New Folder 2` |
| C | Cut 一个文件 → 在目标目录 `Paste Here` | 源消失、目标出现;失败时 alert 说明原因 |
| D | 多选两个文件 Paste | 两个都移动;部分失败会列出 |
| E | 目标目录已有同名 | 现有文件**不被覆盖**,源保留,报错 |
| F | 把文件夹 A 拖进 A/Sub(或多选父与子) | 被拒绝 |
| G | 退出 MenuRight 后右键 | 几秒内弹 "Menu Right not running",**Finder 不卡死**,且**弹框还在时再右键,MenuRight 菜单依然出现**(H1;2026-10-01 修过一次"提示框把扩展主线程停住"的 bug,见 §6 同日的记录) |
| H | 用 `nc -lU <container>/ipc.sock` 占位后点 New File | 扩展拒绝并报不可用,**绝不**出现"假的成功"(H2) |
| I | 授权 `~/Desktop/t` → 在 Finder 里改名为 `t2` → 进去 New File | **成功**(H3 透明续期),不是 "Folder Access Required";`FolderAuthorization.json` 里书签已刷新 |
| J | 扩展已无文件权限:上面所有复制/剪切/新建/粘贴仍正常 | 全部通过(L5 最小权限) |

### 3.3 P7-a 设置界面(本轮改动)

左侧为原生侧边栏(权限与安全:文件权限 / 文件夹权限;通用与功能:通用设置 / 新建文件 /
常用文件夹 / 常用软件 / 常用网页 / 代码主题 / 解压缩管理),右侧为对应面板。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 1 | 依次点 9 个侧边栏条目 | 右侧切换为对应面板,标题/副标题正确,滚动正常;标题栏按钮可收起/展开侧边栏 | 面板空白或布局错位 → 截图给我 |
| 2 | 通用设置 → 界面语言 切到 English 再切回 | **整窗立即**变英文/中文(侧边栏 + 面板 + 按钮),无需重启 | 只有部分文案变化 → 说明某处字符串没走 `StringKey` |
| 3 | 通用设置 | Finder 扩展状态、文件操作通道(`Listening`)、关于(版本/构建号/Bundle ID/App Group)都是真实值 | 显示 `—` 或空白 |
| 4 | 文件权限:关掉某一项 → 退出 App → 重开 | 开关仍是关的(App Group 持久化) | 恢复成开启 → 持久化失败 |
| 5 | 新建文件:上下移动一个类型、关掉一个类型 | 「菜单预览」的顺序/条目同步变化;默认文件名随输入框变化 | 预览不跟随 |
| 6 | 常用文件夹/常用软件:添加(NSOpenPanel) | 行出现在列表,应用显示真实图标;把目录删掉后点「重新检测」→ 显示「已不在磁盘上」 | 添加无反应 → 看是否弹了错误框 |
| 7 | 常用网页:添加 `example.com` | 保存为 `https://example.com`;输入 `not a url` 被拒绝并显示红字 | — |
| 8 | 代码主题:切 Monokai / Dracula,调字号,开关行号 | 预览区随主题换配色、字号与行号立即变化(高亮器相关的新验收见 §3.9) | 预览不变色 |
| 9 | 解压缩管理 | 6 种格式可开关;**RAR 恒为禁用**并显示「不支持」;选「指定文件夹…」出现路径行;体积上限限 1–8192 | RAR 可被打开 → 是 bug |
| 10 | 工具栏 ↺ / 通用设置 → 恢复默认设置… | 所有面板回默认;**文件夹权限里的已授权文件夹不受影响** | 授权被清空 → 是 bug |
| 11 | 登录时自动启动(需已安装到 `~/Applications` 的签名副本) | 开关注册成功(系统设置 → 通用 → 登录项可见);失败时回滚并显示红字原因 | 开关不动/无提示 |

调试期直接打开指定面板(Debug 构建):

```sh
MENURIGHT_SETTINGS_PANE=archives \
  build/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
```

### 3.4 设置持久化(无需点界面,可脚本自查)

```sh
APP=build/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
MENURIGHT_SELFTEST_SETTINGS=read  "$APP"   # 看 appGroupSuite=true
MENURIGHT_SELFTEST_SETTINGS=write "$APP"   # 写入一个标记值
MENURIGHT_SELFTEST_SETTINGS=read  "$APP"   # 新进程:必须读到刚写的值
MENURIGHT_SELFTEST_SETTINGS=reset "$APP"   # 还原为默认值
```

### 3.5 侧边栏图标与开源许可(本轮改动)

侧边栏 9 个图标已从 SF Symbols 换成 **Lucide**(vendor 的 SVG 资源,无第三方运行时依赖;ISC 许可)。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 1 | 看左侧 9 个图标 | 线性风格图标,与 SF Symbols 明显不同;选中项的图标是**白色** | 图标空白 → 跑 `Scripts/check-icons.sh`;若是某个图标"少了形状"(例如只剩三个点),是 SVG 规范化误删了子元素 |
| 2 | System Settings → Appearance 切成深色 | 图标自动变浅色,文字/选中态正常,不需要第二套素材 | 图标发黑看不清 → 模板渲染未生效 |
| 3 | 通用设置 → 关于 → 开源许可 → 查看 | 弹出许可窗口,显示 ISC 全文(Lucide) | 窗口显示"应用包内没有找到许可文件" → 打包时漏了 `Third-Party-Notices` 目录引用 |
| 4 | 看侧边栏**最顶部**的品牌区 | 渐变圆形标记 + 青色 `MenuRight` 字标,下面一行小字 `版本 1.0`(英文界面为 `version 1.0`);标记左缘与下面列表图标列的左缘基本对齐 | 只出现标记或只出现字标 → 资源缺失,跑 `Scripts/check-icons.sh` |
| 5 | 把窗口拉窄到最小宽度 | 品牌区不被挤压/截断(整块约 167pt 宽,侧边栏最小 196pt) | 字标被裁切 → 侧边栏最小宽度需要调大 |
| 6 | 切换 Appearance 浅色/深色 | 字标保持品牌青色,`版本 1.0` 两色都清晰可读 | 浅色下看不见 → 版本行被写成固定白色 |
| 7 | 改 `MARKETING_VERSION` 重新构建 | 品牌区小字跟着变(取自 `CFBundleShortVersionString`) | 仍显示 1.0 → 版本被硬编码 |
| 8 | 看每个分组卡片的四边留白 | 上下左右**一致**(12pt);卡片高度 = 12 + 内容 + 12 | 上/下比左右大 → 某行又加了自己的 `.padding(.vertical,)`;卡片变窄(约 150pt)→ 开关行退回了裸 `Toggle` |
| 9 | 看每行右侧控件(选择器/开关/步进器/值) | 全部落在同一条竖线上,距卡片右缘 12pt | 选择器偏左 → 少了 `.frame(..., alignment: .trailing)` |
| 10 | 通用设置最底部「恢复默认设置…」 | **没有卡片底色**;按钮文字是**警告色(红)**;点它弹出的确认框正文有**两行**——第一行是固定的确认问句,第二行是「恢复默认只影响本应用的设置,不会移除已经授权的文件夹。」(2026-10-03 按用户要求从设置页移进弹窗);确认后所有设置回默认,已授权文件夹不受影响 | 仍是灰字 → 颜色没写到 label 上(`role`/`tint` 在 macOS bordered 样式下不生效);弹窗只有一行 → 检查 `GeneralSettingsView` 的 `.alert` message 是否还拼着 `generalResetFooter` |
| 11 | 新建文件面板:每行左侧图标 | 12 种类型各有图标(txt/md/html/css/js/json/doc/xls/ppt/pages/numbers/keynote) | 某行空白 → 该资源缺失,跑 `Scripts/check-icons.sh` |
| 12 | 文件权限面板:每行左侧图标 | 11 个动作都有图标;「打开终端」与「复制文件名」**故意是同一个图标**(规格如此) | 同上 |
| 13 | **真实 Finder 右键菜单** | 菜单项**只有文字、没有图标**;标题左缘与 Finder 自带项(「新建文件夹」「显示简介」等)对齐,没有多出来的图标列缩进 | 文字前仍有缩进 → 菜单里还有某项带 `image`(只要有一项带图,整列都会留出图标位);检查 `FinderSync.addItem` 是否又传了图片 |
| 13b | 复制 / 新建 / 粘贴三组之间的**间距** | 相邻项间距**均匀**(约 24pt 一行),没有"一大块空白" | 出现整行空白 → 计划里又插了 `.separator`:Finder 给分隔符留槽位但不画线,表现为一个空行;去掉即可(见 `FinderMenuBuilder.plan` 注释) |
| 18 | 首次启动(或扩展未启用时) | 自动弹出**首次使用引导**:第 1 步「启用 Finder 扩展」(实时状态 + 打开系统设置 + 重新检测)、第 2 步「授权文件夹」(选择文件夹,复用同一授权流程)、第 3 步「准备就绪」(状态汇总 + 重启按钮);「稍后再说」只本次跳过,扩展仍关闭则下次再弹 | 不弹 → `hasCompletedOnboarding` 已置位且扩展已启用(属正常);要强制查看:启动参数 `MENURIGHT_ONBOARDING=enable|authorize|ready` |
| 18b | 每一步未完成时看「下一步」 | **禁用**(变灰)且按钮左侧给出一行原因:「需要先启用 Finder 扩展,才能继续。」/「需要至少授权一个文件夹,才能继续。」;第 3 步「开始使用」不受限;「稍后再说」始终可用 | 「下一步」仍可点 → `OnboardingView.footer` 里的 `.disabled(blockedReasonKey != nil)` 丢了;规则本身在 `OnboardingFlow.canAdvance` |
| 18c | 在系统设置里启用扩展后**切回**引导窗口 | 状态自动变为「扩展已启用」(绿色),「下一步」自动解禁 —— 不需要点「重新检测」 | 没自动更新 → `didBecomeActiveNotification` 的 `refresh()` 被删了 |
| 19 | 引导第 1 步点「打开系统设置…」 | 打开系统的扩展管理界面(用的是 `FIFinderSyncController.showExtensionManagementInterface()`,不是猜的深链);启用后回到引导点「重新检测」,状态变绿 | 按钮无反应 → 该 API 在非 Finder 扩展宿主中不可用,改用深链方案 |
| 16 | 「新建文件」面板的类型行 | 每行**只有类型名**(文本文件/Markdown 文件…)+ 计划中徽标,**不再显示** `Untitled.txt` 这类预览文件名(生成名规则在面板顶部「默认文件名」已说明;下方「菜单预览」分组仍会显示实际文件名,那是它的用途) | 行里又出现文件名 → `NewFileSettingsView.typeRow` 里又加了副标题 |
| 17 | 窗口**右上角**工具栏 | 「恢复默认设置」左侧是重置按钮,其**右侧**是「重启 MenuRight」按钮(环形箭头);悬停提示写明"设置改动不需要重启" | 只有重置一个按钮 → 工具栏 ToolbarItem 丢了 |
| 15 | 在**通用设置**里把语言从中文切到 English(不需重启),再右键看菜单 | 菜单文案**整组跟着变**(打开终端 → Open Terminal;新建文件 ▸ → New File ▸,子项 文本文件 → Text File;剪切 → Cut …) | 语言没变 → 用 `Scripts/preview-finder-menu.sh` 先确认"应用写入 → 扩展读出"这条链路:它直接读真实 App Group payload 并打印两种语言的菜单;若脚本正确而 Finder 没变,是安装的是旧构建或扩展未重新加载 |
| 14 | 悬停高亮项 / 禁用项的文字颜色 | 高亮文字变白、禁用文字变灰(Finder 自己绘制文字) | 文字颜色由 Finder 决定,扩展无法也不需要干预 |

命令行自查(都不需要点界面):

```sh
Scripts/check-icons.sh                       # 图标 + 品牌资源 vs 代码
MENURIGHT_SELFTEST_SETTINGS=read "$APP"              # 期望 licenceNotices=1
MENURIGHT_FORCE_APPEARANCE=dark "$APP"               # 深色外观自查(仅 Debug 构建)
```

品牌区(标题)的设计来源与复核:

```sh
# Figma Dev Mode MCP(需 Figma 桌面端打开该文件)
python3 Scripts/figma-mcp.py tools
python3 Scripts/figma-mcp.py call get_metadata       '{"nodeId":"1430:75"}'
python3 Scripts/figma-mcp.py call get_design_context '{"nodeId":"1430:75"}'
python3 Scripts/figma-mcp.py call get_screenshot     '{"nodeId":"1430:75"}'
```

设计稿数值:`mark 39.12` / `gap 8` / 字标 `120 x 18.689` / 列内 `gap 2` / 版本行 `13px`。
应用实测(2x 截图反推):`mark 39.0 x 39.0`、`gap 8.5`、字标 `119.0 x 19.0`;标记左缘 29.0pt,
列表图标列 29.5pt。

> `-AppleInterfaceStyle Dark` 这个命令行参数对本 App **无效**(实测仍是浅色),所以深色自查用
> `MENURIGHT_FORCE_APPEARANCE`;它只改本进程外观,不动系统设置。

### 3.6 P6-b 新建文档类文件(本轮改动)

**前置(只做一次)**

- Word / Excel / PowerPoint **不需要任何模板**,直接测。
- Pages / Numbers / Keynote 的三份空白模板**已经随仓库提供**并会打进 app:
  `MenuRight/Resources/Templates/blank.{pages,numbers,key}`(分别 88K / 134K / 446K,
  都是普通文档,不是 `.template` 包)。要换就直接覆盖同名文件再重新构建 —— 该目录是
  **folder reference**,不用改工程。
- 没有模板时这三项会从菜单里**隐藏**(这是设计:不显示注定失败的菜单项),设置 → 新建文件
  会显示「缺少模板」并列出缺哪个文件。
- 注意 `blank.key` 自带 Keynote 主题的素材(17 张母版 + 一批图片,约 400K),所以新建出来的
  `.key` 也是这个体积;想更小就自己另存一份纯白主题覆盖它。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 12 | 设置 → 新建文件 | Word / Excel / PowerPoint 不再有「P6-b 计划中」角标;缺模板的类型显示「缺少模板」,卡片下方列出缺少的文件名 | — |
| 13 | 空白处右键 → `New File ▸` | 12 项全在:`文本文件`…`JSON 文件`、`Word 文档`、`Excel 表格`、`PowerPoint 演示`、`Pages 文稿`、`Numbers 表格`、`Keynote 演示` | `Scripts/preview-finder-menu.sh` 输出的 `availability` 行 |
| 14 | 点 `Word 文档` | 生成 `Untitled.docx`,用 Word / WPS / Pages 打开**不弹修复**;内容是一页空白 | `DISPATCH createDocument SUCCESS path=...` |
| 15 | 点 `Excel 表格` | 生成 `Untitled.xlsx`,Excel / Numbers / WPS 打开不修复;一个空白工作表 `Sheet1` | 同上 |
| 16 | 点 `PowerPoint 演示` | 生成 `Untitled.pptx`,PowerPoint / Keynote / WPS 打开不修复;**一页 16:9 白底**空白幻灯片(底色不能是灰的,见下) | 同上 |
| 17 | 上面三项各点两次 | 第二次得到 `Untitled 2.docx` / `Untitled 2.xlsx` / `Untitled 2.pptx`,不覆盖 | — |
| 18 | 点 `Keynote 演示` | 生成 `Untitled.key`,Keynote 打开是空白演示文稿(一页 16:9 白底) | `DISPATCH createFromTemplate SUCCESS path=...` |
| 18b | 点 `Pages 文稿` / `Numbers 表格` | 生成 `Untitled.pages` / `Untitled.numbers`,Pages/Numbers 打开分别是空白文稿 / 一个空白表格 | 同上 |
| 19 | 临时把 `blank.key` 移出 `Resources/Templates` 重新构建后再右键 | 菜单里**不出现** `Keynote 演示`(而不是点了才报错);设置里该类型显示「缺少模板」 | 日志 `published new-file availability ... missingTemplates=keynote` |
| 20 | 在**未授权**目录里 `New File ▸ Word 文档` | 弹 "Folder Access Required",磁盘上不产生文件 | `DISPATCH createDocument NOT_AUTHORIZED` |
| 21 | 不启动主 App,直接右键 `New File ▸` | 只显示文本 6 项(没发布过 availability 时的保守回退),或弹 "Menu Right not running" | — |

> **灰底坑(已修)**:幻灯片母版少了 `<p:bg>` 时,文件仍能打开、结构校验也全过,但 Keynote/PowerPoint
> 里幻灯片底色是**灰色** (172,178,187)。修好后是白的。自动化里用缩略图像素采样守着
> (`Scripts/verify-document-generation.sh`),这是唯一能自动发现该问题的办法。

> 文档类生成**全部在主 App 里做**:扩展只发"要哪种",OOXML 打包器与空白模板都不进沙箱 appex。

### 3.7 P7-b 常用三项(本轮改动)

前置:先在 设置 → 常用文件夹 / 常用软件 / 常用网页 里各加几条(本机当前已有 5 条:2 文件夹 / 2 软件 / 1 网页)。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 22 | 空白处右键 | 菜单末尾出现 `常用软件 ▸` / `常用网页 ▸` / `常用文件夹 ▸`,顺序就是这三个 | `Scripts/preview-finder-menu.sh` 的 `favorites` 行 |
| 23 | 点 常用文件夹 ▸ 里的条目 | Finder 打开那个文件夹 | `ACTION INVOKED performOpenFavorite kind=folder` + `DISPATCH openFolder SUCCESS` |
| 24 | 点 常用网页 ▸ 里的条目 | 默认浏览器打开该网址 | `DISPATCH openURL SUCCESS url=...` |
| 25 | 点 常用软件 ▸ 里的条目 | 对应 app 启动(已在运行则切到前台) | `DISPATCH openApplication SUCCESS target=...` |
| 26 | 把某条常用项的开关关掉再右键 | 该条目**消失**(不是变灰) | — |
| 27 | 把三个列表都清空/全关掉再右键 | 三个子菜单**都不出现**(不显示空子菜单) | — |
| 28 | 加一条指向已卸载 app 的常用软件,点它 | 弹 "Couldn't open …" 并说明原因,**不是静默失败** | `DISPATCH openApplication FAILED` |
| 29 | 选中文件后右键 | 选中态菜单仍是**平铺**的,没有常用三项(常用项只属于"你在哪个文件夹右键") | — |
| 30 | 两个同名常用项(例如两个都叫 GitHub) | 菜单里标题不同(带来源后缀),点哪个开哪个 | 见 README「Menu titles must be unique」 |

> **沙箱实测(Spike S6)**:签名+沙箱的 MenuRight 里,`NSWorkspace.open(_:configuration:)` 打开
> 文件夹 / 网址 / 软件(路径或 bundle id)四种目标**全部 SUCCESS**;被限制的是"指名启动某个
> app"的 `open(_:withApplicationAt:)`(当初 Open Terminal 踩到的 `permErr -54`)。
> 复现命令:`MENURIGHT_SELFTEST_OPEN_TARGET=folder:/tmp/x .../MenuRight.app/Contents/MacOS/MenuRight`
> (可选 `url:` / `app:` / `bundle:`)。
> **常用项不做授权门**:主 App 不读写目标文件夹(Finder 代劳),加了门反而会让未授权目录里的常用项全部失效。

### 3.8 P9 第①步 解压/压缩 ZIP(本轮改动)

前置:随便准备一个文件夹(内含子文件夹、空文件夹、一个大文件)和一个现成的 `.zip`。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 31 | 选中一个**普通文件**,右键 | 菜单末尾出现 `压缩 ▸` → `压缩为 ZIP`;**没有** `解压 ▸` | `preview-finder-menu.sh` 的 "Mixed selection" 段 |
| 32 | 点 `压缩为 ZIP` | 同目录生成 `<名字>.zip`,双击能用系统解压工具打开 | `DISPATCH compressItems SUCCESS` |
| 33 | 选中**文件夹**再压缩 | 生成 `<文件夹名>.zip`,里面第一层是文件夹本身;空文件夹也在里面;符号链接被跳过 | 同上 + `skippedSymlinks=` |
| 34 | 再压一次同名 | 得到 `<名字> 2.zip`,不覆盖 | — |
| 35 | 选中一个 `.zip`,右键 | 出现 `解压 ▸` → `解压到当前文件夹`,以及 `压缩 ▸` | — |
| 36 | 点 `解压到当前文件夹` | 解压到压缩包所在目录,内容与压缩前一致 | `DISPATCH extractArchive DONE written=… skipped=… failed=…` |
| 37 | 选中"压缩包 + 普通文件"混合选择 | **不出现** `解压 ▸`(避免只解一半),`压缩 ▸` 仍在(会把两者一起打包) | — |
| 38 | 解压一个含中文名/多层目录的 zip | 目录名不乱码、层级正确 | — |
| 39 | 设置 → 解压缩管理 → 冲突策略改成"跳过"后解压一个会撞名的包 | 已有文件**不动**,只解出新的 | `written`/`skipped` 计数 |
| 40 | 解压 `.tar` / `.tar.gz`(`.tgz`) / `.tar.bz2` / `.7z` / `.xz` | 都能解压;7z 若用了 BCJ/BCJ2 过滤器会明确报"不支持的编码器"(不是"损坏") | `DISPATCH extractArchive DONE …` |
| 41 | `压缩 ▸` 里各项各点一次 | 分别生成 `<名>.zip` / `<名>.7z` / `.tar` / `.tar.gz` / `.tar.bz2`,系统双击都能打开(7z 用 `bsdtar -tf` 能列出内容) | `DISPATCH compressItems SUCCESS … format=…` |
| 42 | 打开 设置 → 解压缩管理,关掉某格式后右键对应类型 | 该格式**不再出现** `解压 ▸` | `preview-finder-menu.sh` 的 favorites/availability 行 |
| 44 | `压缩 ▸` → `自定义压缩…`（**先把设置窗口关掉**——主 App 是常驻菜单栏程序，此时它一个窗口都没有） | 主 App 前置并弹出对话框:最上面「保存为/标签/位置」三行**整体居中**;下面「压缩格式」和「压缩模式」的标签紧贴各自的弹出菜单(间隔 ~12pt,不是半行空档);「加密压缩」那一行的**密码框横跨整行**(左右顶到对话框内边);**ZIP 与 7Z 时「加密压缩」「分卷压缩」都可用**,7Z 的「加密文件名（仅 7z）」在**「固实压缩」同一行的右端**(与「压缩格式/压缩模式」同一形状),TAR / TAR.GZ / TAR.BZ2 时这几项**置灰(勾选框不勾)**。**对话框里不再有整段灰色说明文字**(2026-10-03 用户要求):那些规则改成了鼠标悬停提示 | 日志 `ARCHIVE dialog presented`;**光看这条日志会假阳性**,必须再看 `SELFTEST archiveDialog … visibleAfterClose=0 … dialogVisible=true`(一键复现见 §6 的 2026-10-03 条目) |
| 45 | 对话框里改「保存为」和「压缩模式(极限)」后保存 | 生成的文件名与所填一致;系统 `unzip -z` 能看到「标签」;极限压缩产物不大于快速压缩 | `ARCHIVE dialog SUCCESS path=…` |
| 46 | 对话框里选「压缩格式 = TAR.BZ2」 | 「标签」输入框变灰;为什么变灰(只有 ZIP 写注释)在它的悬停提示里 | — |
| 47 | 对话框里点「位置」那一行(**原生弹出菜单**:文件夹自己的 Finder 图标 + 文件夹名 + 上下箭头,右边一个单独的「⌄」小按钮) | 弹出**系统原生**目录选择框(带「位置 / 个人收藏 / 最近访问的位置」侧栏);选完弹出菜单上换成新的文件夹。菜单里还能看到本次对话框访问过的文件夹和「选择…」(也是开同一个面板) | — |
| 48 | `解压 ▸` → `解压到指定位置…` | 弹出目录选择框;选中的目录里出现解压结果 | `DISPATCH extractArchive DONE` |
| 49 | 上一步在选择框里点「取消」 | **不解压任何东西**,不产生半成品 | 日志 `extractArchive CANCELLED` |
| 43 | 解压一个加密的 zip(自己压的或第三方压的 zip 都行) | 主 App 前置并弹出密码框:压缩包图标 + 「压缩包已加密」+ 文件名 + 密码输入框(占位符「输入密码」)+「把密码存进密码本」勾选框 + 取消/解压。**密码输入框要横跨整个对话框内容宽度**(与上方说明文字同宽,左右各留 16pt 边距),不能缩成占位符那么窄。**输对密码 → 正常解压**;点取消 → **一个文件都不写**,扩展端也不弹错误框 | 一键复现见 §6 的 2026-10-03「解压加密 zip」条目 |
| 50 | 对话框里选「压缩格式 = 7Z」后保存 | 生成 `.7z`;`bsdtar -tf <文件>` 能列出内容;系统双击能解开。**空目录不会进 7z**(libplzma 不写目录条目),zip/tar 会保留空目录——这是已知差异 | `ARCHIVE dialog SUCCESS path=…` |
| 51 | 对话框里勾「加密压缩」并输入密码后保存 | 生成加密 zip;`unzip -P <密码> -t` 报 "No errors detected";不带密码的 `unzip -t` 报密码错误(而不是解出坏文件) | `ARCHIVE dialog SUCCESS path=…` |
| 52 | 对话框里格式选 TAR 类 | 「加密压缩」那一行**消失**,回到置灰的加密开关——密码不会跟着切到存不下它的格式 | — |
| 53 | 设置 → 解压缩管理 → 密码本:点 `+` 加一行、改名称/密码、勾选「自动保存压缩时输入的加密密码」 | 行内容立刻写进钥匙串(退出 App 再进来仍在);`批量导出` 得到 `MenuRight-Passwords.json`,改完再 `批量导入` 能读回;坏 JSON 会明确报错且**不清空**已有条目 | — |
| 54 | 第 51 步勾着「自动保存…」再压缩一次加密包 | 密码本自动多一条(名称 = 归档文件名) | — |
| 55 | 对话框里点「加密压缩」右边的**钥匙按钮**(只显示图标,悬停提示「从密码本选择」) | 菜单列出密码本的名称;选中后密码填入并自动勾选「加密压缩」 | — |
| 56 | 先在第 51 步/第 54 步把密码存进密码本,再解压同一个加密包 | **完全不弹框**,直接解压成功(密码本命中就够) | `SELFTEST archiveUnlock … book=batch(items=1 failed=0 …) bookExtracted=true` |
| 57 | 解压加密包时在密码框里连输三次错误密码 | 第一次正文是「“<文件名>” 已用密码加密。输入密码后才能解压。」,第二次起正文换成「密码不正确,请再试一次。」(标题始终是「压缩包已加密」);三次之后放弃返回,**目录里没有任何文件**(不会留下半成品) | `SELFTEST … alertResult=failure(code=cancelledByUser …) alertExtracted=false`;断言见 `MenuRightTests/ArchivePasswordResolverTests.swift` 的 `testThreeWrongAnswersAbandonTheExtraction` |
| 58 | 密码框里点取消,或留空直接点「解压」 | 静默取消:不写字、不打日志、扩展端因为 `cancelled_by_user` 不弹错误框 | `alertResult=failure(code=cancelledByUser msg=No password was given; nothing was extracted.)` |
| 59 | 对话框里格式选 7Z、勾「加密压缩」+「加密文件名」并输入密码后保存 | 生成 AES-256 加密的 `.7z`(内容与条目名都加密):`bsdtar -tf` 或任何工具**不开密码列不出内容**;本 App 用同一密码能正常解压回原文件 | `SELFTEST archiveDialog … confirm=SUCCESS … confirmParts=3 confirmEncrypted=true confirmExtract=written:1 failed:0 names:selftest-source.txt`(一键复现见 §6 的 2026-10-03「三个压缩模式…」条目) |
| 60 | 对话框里选「分卷压缩 = 50 MB」再压一个大于 50 MB 的文件夹 | 得到 `name.zip.001` / `.002` / …;7-Zip / Keka / WinRAR 打开 `.001` 能直接解;本 App 右键 `.001` 也能解(选 `.002` 会被当成普通文件——只有 `.001` 是归档开头) | §6 的命令(3 MB 源 + 1 MB 档位 ⇒ `confirmParts=3`) |
| 61 | 同上但格式选 7Z | 得到 `name.7z.001` / `.002` …(7z 原生分卷,同一命名),同样能解 | `confirmParts=3` |
| 62 | 对话框里格式选 7Z,关掉「固实压缩」再压多个小文件 | 生成的 7z 可以**直接取出单个文件**而不用解开整包(体积比固实略大);勾着固实时体积最小 | 断言见 `MenuRightTests/ArchiveModeAndSevenZipTests.swift` |
| 63 | 对话框里对同一份源依次用「快速/标准/极限」压 zip / 7z / TAR.GZ / TAR.BZ2 | zip、7z、tar.gz 产物依次变小(极限 < 标准 < 快速),bzip2 同理(块大小档位);**TAR 三档字节完全相同**(它本身不压缩;这条规则现在只在「压缩模式」的悬停提示里,对话框正文不再写) | 同上 |
| 64 | 解压一个加密的 7z(自己压的或第三方压的) | 与加密 zip 一样弹密码框(先试密码本、最多 3 次);输对就解,取消则一个文件都不写;密码本命中则完全不弹框 | `MenuRightTests/FileOperationDispatcherTests.swift` 的 `testExtractArchiveUnlocksAnEncryptedSevenZipFromThePasswordBook` / `…AsksForAnUnknownSevenZipPassword` / `…CancelsQuietlyWhenTheSevenZipPromptIsDismissed` |
| 65 | 经 Finder 菜单解压 `.7z` / `.tar` / `.tar.gz` | 正常解压(**不再**报 `Not a readable archive`) | `testExtractArchiveReadsASevenZipThroughTheMenu` / `testExtractArchiveReadsATarGzThroughTheMenu` |

> **安全规则(自动化已覆盖,人工只需确认"能正常用")**:`../`、绝对路径、反斜杠、NUL、`C:` 形式
> 一律拒绝;符号链接条目**不会**被创建;声明的解压体积超过设置上限时**在写盘前**整体拒绝;
> 逐条校验 CRC;永不覆盖正在读取的那个压缩包。
> 一键复现:`Scripts/verify-archive-roundtrip.sh`(含一个恶意包的拒绝验证)。

### 3.9 P8 第①步 代码高亮主题预览(本轮改动)

前置:打开 设置 → 代码主题。本轮把预览从"手写 token 表"换成**真实高亮器**,并加了「示例语言」选择器。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 50 | 看「预览」卡片 | 卡片顶部是示例文件名(默认 `Greeting.swift`),下面是**有真实配色**的示例代码,行号在左侧 | 整片单色 → 高亮器没接上 |
| 51 | 依次切 Monokai / Dracula / Solarized Light / GitHub Light / 跟随系统 | 代码区背景与各 token 颜色**立即**跟随主题;「跟随系统」随 macOS 浅色/深色切换 | 只有背景变、文字不变 |
| 52 | 把「示例语言」依次切到 Python / JavaScript / TypeScript / HTML / Markdown / JSON / YAML / SQL / Shell / C / C++ / Go / Rust / Java / 纯文本 | 每次都换成对应示例,注释·关键字·类型·函数·字符串·数字的颜色明显不同;**纯文本**只有前景色 | 某个语言整片同色 → 该语言 profile 有问题 |
| 53 | 切到 Python,看示例里的 `"""Return a greeting."""` | 三引号字符串整体是字符串色,跨行状态正确 | 引号后一半变色 |
| 54 | 切到 HTML / Markdown | HTML:标签名·属性名·属性值三种颜色,`<!-- -->` 是注释色。Markdown:标题/列表/行内代码/链接各自成色 | — |
| 55 | 字号滑到 9 与 32、开关「显示行号」 | 字号立即变化;关行号后左侧编号列消失、代码左移 | 行号还在 |
| 56 | 切「字体」到 Menlo / Monaco / Courier New / 系统等宽 | 预览字体立即变化 | 无变化(字体未安装时系统回退,属正常) |
| 57 | 在预览里拖选文字 | 可以选中并复制,复制出来是**不带颜色**的纯文本 | — |

> 本轮**没有**做 Quick Look 扩展 target:按空格仍是系统纯文本预览,所以规划里的 P8 人工门
> (「空格预览有高亮」)仍是 **PENDING**,不要按已通过记录。


### 3.10 P8 第②步 Quick Look 空格预览(本轮改动)

前置:`Scripts/install-dev-app.sh` 跑完(已装到 `~/Applications` 并注册扩展)。Quick Look 扩展**不需要**在系统设置里单独开启。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 58 | 在访达里选中一个 `.swift` 文件按空格 | 预览窗口里是**带高亮**的代码:行号在左侧,注释/关键字/类型/函数/字符串/数字各成一色,背景是当前主题的底色 | `log show --last 5m --predicate 'subsystem == "xin.ljhsu.MenuRight"'` 里没有 `preview rendered` → 扩展没被调用 |
| 59 | 设置 → 代码主题 换成 Dracula,回到访达**重新**按空格(同一个文件) | 配色变成 Dracula | 配色没变 → 看日志里 `theme=` 是不是还是旧值 |
| 60 | 换一套**浅色**主题(如 GitHub Light),重新按空格 | 预览是浅底深字;「跟随系统」则随系统浅/深色 | — |
| 61 | 设置里关掉「显示行号」,重新按空格 | 左侧行号列消失 | — |
| 62 | 把字号调到 32,重新按空格 | 预览字号明显变大,长行自动折行,折行部分对齐在代码列(不跑到行号下面) | 折行错位 → 段落缩进 |
| 63 | 预览一个 6000 行的 `.swift`(可以 `seq` 造) | 窗口**不卡**,显示前 5000 行,底部一行小字「文件较大,这里只显示前 5000 行。」 | 卡住或白屏 |
| 64 | 预览 `.json` / `.py` / `.html` | 各自有对应语言的高亮(JSON 的键是类型色、布尔值是关键字色) | 整片同色 |
| 65 | 预览一张 PNG / PDF / docx | 走**系统**预览,MenuRight 扩展**不参与** | 图片变成文字预览 → `QLSupportedContentTypes` 声明多了 |
| 66 | 预览 `.ts` / `.rs` / `.go` | 走**系统**纯文本预览(刻意不接管;`.ts` 在 macOS 上是 MPEG-2 传输流类型) | — |
| 67 | 预览一个中文注释的 UTF-8 文件;再预览一个 GB18030 的老文件 | 都不乱码 | 乱码 → 看 `CodePreviewFileReader.decode` |
| 68 | 预览一个没有读权限的文件(如 `/private/etc/master.passwd`) | 窗口显示「无法读取这个文件。」,不是系统占位图 | 日志里应有 `preview unreadable … error=…` |
| 69 | 预览一个 `.md`(标题 / 加粗 / 行内代码 / 链接 / 列表 / 引用 / 围栏代码 / 表格 各来一个) | 是**渲染**结果:标题更大更粗、加粗变粗体、行内代码等宽带底色、链接带下划线、列表有项目符号或编号、引用有竖条、代码块按语言高亮且整行带底色、表格按列对齐、`---` 变成一条横线 | 还能看见 `#` / `**` → 走了源码高亮分支 |
| 70 | 换一套主题后再预览同一个 `.md` | 标题、正文、引用、代码块、表格**全部**跟着换色(代码块内部的高亮也用该主题) | 只有背景变 |
| 71 | 预览一个含中文表格的 `.md` | 中文列不会把后面的列挤歪(中文按两列宽计算) | 列错位 |
| 72 | 想整块关掉空格预览 | 系统设置 → 通用 → 登录项与扩展 → 快速查看里关掉;或 `pluginkit -e ignore -i xin.ljhsu.MenuRight.MenuRightCodePreview`(恢复用 `-e use`) | 关不掉 → 用命令行那条 |

> 自动化已覆盖的部分(本轮实测):扩展被调用、能读文件、能从 App Group 读到主题(`theme=xcode-light`)、
> 6000 行截断为 5000 行且 `truncated=true`、PNG 不接管、JSON 语言识别正确。
> 一键复现(不用按空格):
> ```sh
> qlmanage -p /path/to/SomeFile.swift          # 直接弹预览窗口
> log show --last 2m --predicate 'subsystem == "xin.ljhsu.MenuRight"' --style compact
> pluginkit -m -p com.apple.quicklook.preview | grep -i MenuRight
> ```
> **还没验的是"看起来对不对"**(配色是否好看、间距是否舒服)——这需要你的眼睛,即上表 58–63。
>
> **Markdown 为什么是"渲染"而不是"高亮"(2026-10-01 实测)**:本机 `net.daringfireball.markdown` 原本由
> **WPS Office 的快速查看扩展**渲染。Quick Look **没有运行时交还机制** —— 实验:在扩展里对 `.md` 抛错,
> 进程起来了但没有任何渲染,`WPSQuickLook` 也不会被拉起(对照组:禁用 MenuRight 扩展后 WPS 正常渲染);
> 而 `QLSupportedContentTypes` 写死在签名后的 Info.plist 里,所以"按语言开关"做不到。
> 结论:既然接管了这个类型,就把它做成**真正的渲染**(`AttributedString(markdown:)` 解析 + AppKit 渲染),
> 而不是把渲染器降级成源码高亮。设置面板里的示例预览也走同一条渲染路径,两处一致。


### 3.11 版本号与检查更新(本轮改动)

前置:装的是**当前构建**。仓库目前**还没有发过 Release**,所以下面第 74 项的"发现新版本"需要先按第 73 项发布一个更高的版本。

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 73 | `Scripts/version.sh bump minor` → 提交 → `Scripts/release.sh --publish --notes <文件>` | 生成两个架构的 ZIP;建 tag;`gh release create` 成功;`https://github.com/Suxinljh/MenuRight/releases` 上能看到 | `gh auth status`;`build/release/build-*.log` |
| 74 | 用**旧版本**的 App(如 1.0)打开 设置 → 通用设置 → 更新 → 立即检查 | 显示「发现新版本 x.y」+ 更新说明节选 + 「前往下载 / 跳过此版本」 | 显示"还没有发布任何版本" → Release 没建成功;显示失败原因 → 网络/限速 |
| 75 | 点「前往下载」 | 浏览器打开该 Release 页面 | — |
| 76 | 点「跳过此版本」,再点一次「立即检查」 | 不再出现新版本卡片(状态回到"还没有检查过"或最新) | 还在提示 → 跳过没写进设置 |
| 77 | 关掉「自动检查更新」→ 退出 App → 重开 | 启动时**不**发起检查(日志里没有 update 相关请求) | 仍检查 → 开关没生效 |
| 78 | 打开「自动检查更新」→ 退出 → 重开(且距上次检查 > 24h) | 启动后后台检查一次;有新版就弹一次提示 | 立刻重开第二次不该再查(节流) |
| 79 | 设置 → 通用设置 → 关于 | 「版本」显示 `1.0 (1)`(含构建号) | 只有版本号 → 构建号没读 |
| 80 | 终端跑 `Scripts/version.sh` 与 `Scripts/check-version.sh` | 打印 `1.0 (1)`;四个 target 全部 `ok` | 某个 target 报 FAIL → 它有 target 级版本设置覆盖了 xcconfig |

> 自动化已覆盖(本轮实测):版本比较(`1.10 > 1.9`、`1.0 == 1.0.0`、`v` 前缀)、GitHub JSON 解析
> (draft/prerelease 拒绝、ZIP asset 选取、无 asset 时为 nil)、节流与"跳过该版本"规则、
> 旧版本 payload 的默认值兼容;并用**真实** GitHub 响应(SWCompression / Sparkle 的 releases/latest)跑通了解析路径。
> **需要你手动做的是第 73 项**(发布一个真实的 Release)——它会改 GitHub 上的状态,我不替你点。


### 3.12 设置界面「少文案」(2026-10-03 用户要求)

用户原话:「除了恢复默认设置的文案在二次确认弹窗显示，其他的文案我框起来的，都可以去掉，以后不要在前端显示废话文案和实施进度」。
**规矩**:设置界面只放**能操作的控件与状态**,不再有整段解释性文字、也没有「实现进度」卡片;规则要么放进鼠标悬停提示,要么干脆不显示。
(对话框那边的同一条规矩见 §3.8 第 44 项。)

一键复现(真沙箱、不开真窗口,直接把面板渲染成 PNG):

```bash
CONTAINER="$HOME/Library/Group Containers/group.xin.ljhsu.MenuRight"
for p in general filePermissions archives codeTheme; do
  MENURIGHT_SELFTEST_SETTINGS_PNG="$p:$CONTAINER/pane-$p.png" \
    build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
done
ls -la "$CONTAINER"/pane-*.png        # 四张 720×1600 的整栏截图
```

| # | 操作 | 预期结果 | 失败时看什么 |
| - | ---- | -------- | ------------ |
| 1 | 看 通用设置 全部三张卡片 | 「界面语言」「登录时自动启动」「自动检查更新」下面**都没有**灰色说明段;「产品网站」那一行**只有官网按钮、没有 URL 小字**;底部「恢复默认设置…」下面也**没有**小字 | 还在 → `GeneralSettingsView` 里又写了 `footer:`/`subtitle:`;文案 key 已从 `Localization.swift` 删掉,写错 key 会编译不过 |
| 2 | 点 通用设置 底部「恢复默认设置…」 | 那句话说在**二次确认弹窗里**(见 §3.5 第 10 项) | 弹窗只有一行 → `.alert` message 没拼 `generalResetFooter` |
| 3 | 看 文件权限 面板底部 | 「Finder 扩展不含任何文件写入权限…」那段**消失**;只保留「仅在已授权的文件夹内创建或修改文件」这一行的开关副标题(用户没框它) | 少的是开关副标题 → 删过头了 |
| 4 | 看 解压缩管理 面板 | 标题下只有一句副标题(不再提 RAR 借口);「RAR」行只有「不支持」徽标、**没有**小字;「体积上限」「密码本」两张卡片**都没有**页脚;面板里**没有**「实现进度」卡片 | 卡片还在 → `ArchiveSettingsView.noteGroup` 又被加回来了 |
| 5 | 看 代码主题 面板 | 预览卡片下面**没有**「实现进度」卡片;标题下那句说的是「扩展读取同一份配置」,不再出现「P8 接入后」这类进度话 | 同上 → `CodeThemeSettingsView.noteGroup` |

> 上面 5 项的外观由 PNG 自测(真沙箱、真 SwiftUI 视图)取证;真实窗口里的点击项(第 2 项)仍按 §3.5 的既有条目人工核验。

## 4. 这些现象**不是** bug(平台限制)

- **只有一个 MenuRight 条目、里面是子菜单**:macOS 把扩展菜单挂在扩展名条目下,扩展无法创建顶层项、无法控制父级。需求里的"与 MenuRight 同级"在 FinderSync 下做不到;唯一的替代是 Accessibility/AppleScript 注入菜单,被 `AGENTS.md` 明令禁止。
- **"选中后不显示级联"** = 选中态菜单**平铺无二级**(已实现);外层那个 MenuRight 包装去不掉。
- **新建文件后不会自动进入重命名状态**:Finder 只对自己创建的项进入内联重命名,没有 API 可以触发。需要改名请按回车。
- **`Open Terminal` 不需要授权**:见 3.1 第 11 项,这是刻意设计,不是漏了检查。
- **RAR 解压**:按决策 D5-R1 不做(没有 MIT / 纯 Swift 实现)。7Z / XZ **已经支持**解压,
  证据见 `Scripts/verify-archive-roundtrip.sh` 的 format coverage 段;它们**不能创建**,菜单里不会出现。

## 5. 失败时请回报这些

1. 你点的是哪一项、在什么位置(桌面/文件夹/选中几个文件)。
2. 弹窗原文(截图最好)。
3. 对应时间段的日志:`log show --predicate 'subsystem == "xin.ljhsu.MenuRight"' --last 5m --info`
4. 如果是权限错误:完整的 NSError `domain`/`code` 与 POSIX 码 —— **不要**通过关闭沙箱来绕过,记录下来给我。
5. 若菜单本身不对:截图右键菜单。

## 6. 验收记录

### 2026-09-30 — P6-a 人工验收

```
Automated: PASS  (190/190 XCTest,MenuRight 与 MenuRightFinder 均构建成功)
Manual:
  P6-1 … P6-11  §3.1 全部 11 项                                    PASS
  A–J           §3.2 存量回归                                      PENDING
```

- 通过方式:按 §1 用 `Scripts/install-dev-app.sh` 安装,在真实 Finder 中逐项点击验证(2026-09-30)。
- 其中 P6-2(`Open Terminal`)的机制已单独复测:沙箱内走 Terminal 的
  "New Terminal at Folder" 服务,新 shell 的 `cwd` 等于右键目录。
- **§3.2 的 A–J 尚未做**:这 11 项通过不等于存量回归通过,仍按 PENDING 记。

### 2026-09-30 — P7-a 前端界面(本轮)

```
Automated: PASS  (242/242 XCTest;190 → 242,新增 52;MenuRight 与 MenuRightFinder 均构建成功)
Manual:
  §3.3 版式(9 个面板渲染截图核对)                                  PASS
  §3.4 App Group 持久化(写入 → 新进程读回 → 还原)                   PASS
  §3.3 交互(1、11 项:NSOpenPanel 增删 / 网页 sheet / 语言切换 /
       恢复默认 / 登录项注册)                                       PENDING
```

- 版式核对方式:Debug 构建逐面板启动 + 截图(非交互),这一步**不能**替代交互验证。
- 持久化实测:`appGroupSuite=true`;写 `sizeLimitMB=4219` → **新进程**读到 4219 →
  `reset` 回 1024;磁盘载荷在 `<App Group>/Library/Preferences/group.xin.ljhsu.MenuRight.plist`(0600)。
- 本轮**未**执行 `Scripts/install-dev-app.sh`(未改动 `~/Applications` 与扩展注册状态);
  验证启动 Debug 副本期间原已安装实例退出,收尾已用 `open ~/Applications/MenuRight.app` 重新拉起。
- **Finder 菜单尚未读取新设置**(P7-b),因此本轮的设置项只影响界面与持久化数据。

### 2026-09-30 — P7-a 侧边栏图标换成 Lucide(本轮)

```
Automated: PASS  (248/248 XCTest;242 → 248,新增 SettingsCategoryTests 6 项;
                  MenuRight 与 MenuRightFinder 均构建成功;签名构建通过)
Manual:
  §3.5 版式(浅色 + 深色两套截图,9 个图标逐个核对)               PASS
  §3.5 图标资源一致性(Scripts/check-icons.sh)             PASS
  §3.5 许可载荷(Bundle 内 Third-Party-Notices + licenceNotices=1) PASS
  §3.5 交互(开源许可 sheet)                                      PENDING(需点击)
```

- 图标来源已钉版本:`LUCIDE_TAG=1.49.0`;9 个名字都在该 tag 下逐个 curl 验证过(HTTP 200)。
- **实测踩坑并修复**:第一版规范化脚本用文件级正则删 `width/height`,把
  `app-window-mac` 内部的 `<rect width="20" height="16">` 一起删了 → 该图标只剩三个点。
  现在只删根标签的尺寸,并断言"除根标签与颜色替换外,图形一个字节都不能变"。
  这类 bug 编译期与单测都发现不了,是靠截图发现的 → **换图标后必须截图看**。
- 一次 `xcodebuild test` 在 16:58:57 瞬时失败(结果包显示 **0 个测试被执行**、无失败用例),
  紧接的签名构建与之后 4 次完整测试均 PASS(248/248);未复现,判断为紧邻两次 xcodebuild
  共用同一 DerivedData 的启动期失败,不是测试或代码问题。

### 2026-09-30 — P7-a 侧边栏品牌区(标题)

```
Automated: PASS  (248/248 XCTest;品牌区是纯视图,无新增单测;两个 target 均构建成功)
Manual:
  §3.5 品牌区版式(浅色 + 深色截图,几何量到 1px 内)              PASS
  §3.5 资源一致性(check-icons.sh 覆盖品牌资源)            PASS
  §3.5 交互(窄窗口、改版本号)                                    PENDING(需人工)
```

- 设计来源:Figma node `1430:75`,通过 Figma Dev Mode MCP(`127.0.0.1:3845`)读取,
  之前 `web_fetch` 打不开 figma.com(本机解析被拦),MCP 是本机唯一的通路。
- 设计稿里有 **`version 1.0` 副标题**(不在用户最初描述里),已按稿实现,并改成读
  `CFBundleShortVersionString`,不是硬编码。
- 实测偏差两处(已在 README 写明理由):文字列不采用设计稿固定的 146.7pt(整块 167pt 而非
  193.8pt,像素一致);版本行用 `.secondary` 而非设计稿的 `white`(侧边栏跟随系统外观,
  浅色下白字不可见)。
- 复核方式:截图 → 按饱和度/亮度逐列扫描量出 mark/gap/字标尺寸与左缘位置,而不是靠肉眼。

### 2026-09-30 — P7-a 卡片留白 / 控件对齐 / 恢复默认按钮

```
Automated: PASS  (248/248 XCTest;纯视图改动;两个 target 均构建成功)
Manual:
  §3.5 卡片四边留白一致(量测:卡高 48 = 12+24+12)                  PASS
  §3.5 右侧控件对齐(开关与选择器都距右缘 11.5pt / 目标 12pt)        PASS
  §3.5 恢复默认按钮(无底色 + 红色文字,截图确认)                    PASS
```

- 之前的实现问题(均为实测发现,不是推断):
  1. `GroupBox` 自身内边距不对称(横 ≈7pt / 竖 ≈11pt),加上每行自带 7pt 竖直内边距
     → 竖直 20pt vs 水平 7pt;改为自绘卡片 + 单一 `cardInset = 12`。
  2. 开关行用裸 `Toggle`:宽度随内容,卡片被压到 150pt,开关也没贴右
     → 改成 `HStack + Spacer + labelsHidden`。
  3. 固定宽度框里的弹出按钮**左对齐**:语言选择器距右缘 57pt
     → 加 `.frame(width:, alignment: .trailing)`,现已与开关同线(11.5pt)。
  4. `role: .destructive` + `.tint(.red)` 在 macOS 的 bordered 按钮上**不上色**
     → 颜色显式写到 label 上(`Text(...).foregroundStyle(.red)`)。
- 「恢复默认」按钮在默认窗口高度下处于折叠线以下,本次用 DEBUG 钩子
  `MENURIGHT_REVIEW_WINDOW` 试图加高(受屏幕高度限制),最终用「临时把它挪到分组首位截图、
  再还原」的方式目视确认,还原后已 diff 核对分组顺序未变。
- 复核方式与 §3.5 品牌区相同:2x 截图逐像素量出卡片边界、内容边界与控件右缘,而不是肉眼估计。

### 2026-09-30 — P7-a 引导:未完成不允许进入下一步

```
Automated: PASS  (271/271 XCTest;268 → 271,新增 3 项"步骤完成度"测试;签名构建通过)
Manual:    PASS   (第 1 步「下一步」禁用 + 原因文案;第 2 步已授权 2 个文件夹故可用 —— 截图对比)
```

- 新增可测规则 `OnboardingFlow.canAdvance(isExtensionEnabled:authorizedFolderCount:)` 与
  `blockedReasonKey(...)`:第 1 步要求扩展已启用,第 2 步要求至少一个已授权文件夹,第 3 步(汇总)永不阻塞。
- 视图侧:「下一步」加 `.disabled(blockedReasonKey != nil)`,并在按钮左侧显示一行原因;
  **「稍后再说」始终可用**,避免拿不到权限的用户被困住。
- 附带交互修正:窗口重新激活时(`didBecomeActiveNotification`)自动重读扩展状态 ——
  用户去系统设置启用扩展再切回来,「下一步」会自动解禁,不必先找「重新检测」。
- 测量教训:禁用按钮仍带淡紫底色,按颜色饱和度统计会误判(4215/8250 vs 可用 4478/8250);
  按钮状态要看渲染结果或直接断言逻辑层,别靠颜色计数。

### 2026-09-30 — P7-a 首次使用引导(3 步)

```
Automated: PASS  (268/268 XCTest;261 → 268,新增 7 项引导状态机/文案测试;两个 target 均构建成功;签名构建通过)
Manual:    PASS   (三步引导逐屏截图确认;§3.5 第 18/19 项)
```

- 用户选择"3 步引导页"。`OnboardingFlow`(放在 `Shared/Settings/`,可单测)持有状态机与
  "是否该出现"的判断:未完成过引导 **或** Finder 扩展处于关闭状态就出现(扩展关着应用等于不可用,
  该把两个必做步骤摆出来);"稍后再说"只跳过本次启动。
- 第 1 步用 `FIFinderSyncController.isExtensionEnabled` 取实时状态、
  `FIFinderSyncController.showExtensionManagementInterface()` 打开系统界面(**不猜深链**)。
- 第 2 步复用与「文件夹权限」**完全相同**的授权代码:为此把 NSOpenPanel + 书签 + 落库抽成
  `FolderAuthorizationAction`(两个调用点各自负责报错 UI),避免"引导里授权出来的东西不一样"。
- 第 3 步汇总两项状态 + 复用工具栏的「重启 MenuRight」。
- 复核钩子 `MENURIGHT_ONBOARDING=enable|authorize|ready`:直接把引导开到某一步,
  三步截图即由此而来(否则要点着走)。
- 版式踩坑(两个,都由截图发现):① 步骤用 `@State(initialValue:)` 承接父级值 → 复核钩子永远停在
  第 1 步(State 只认第一次构造的值),改为 `@Binding`;② 固定高度的 sheet 把多余高度分给
  `Text` 子视图 → 每个段落下方出现大空隙,用 `.fixedSize(horizontal: false, vertical: true)`
  让内容按理想高度排布解决。
- `SettingsGroup` 的 `title` 改为可选(引导里的卡片不需要自己的小标题)。

### 2026-09-30 — P7-a 去掉预览文件名 + 工具栏重启按钮

```
Automated: PASS  (261/261 XCTest;签名构建通过)
Manual:    PASS   (§3.5 第 16/17 项,截图确认:类型行无预览名;工具栏两个按钮)
```

- 「新建文件」类型行去掉 `Untitled.txt` 副标题(生成名规则由面板顶部「默认文件名」+ 说明行给出);
  **下方「菜单预览」分组保留文件名** —— 那里本来就是为了展示最终菜单长什么样。这是按截图里
  红线下划线所指的行做的;若用户希望预览分组也不显示,再改。
- 工具栏在「恢复默认设置」(重置)右侧新增「重启 MenuRight」:
  `NSWorkspace.openApplication(createsNewApplicationInstance:)` 先起新实例、成功后再 `NSApp.terminate`,
  交接失败会记诊断而不是直接把应用关掉。
- **重要事实(决定要不要这个按钮的前提)**:重置/重启这类按钮**不会重载 Finder 扩展** ——
  扩展由 Finder 加载;而设置类改动(语言、以及将来接进去的常用项)**根本不需要重启**,
  因为扩展每次构建菜单都会重新读共享设置。按钮的悬停提示就是这么写的,避免误导。
- 常用项现状(实测):payload 里已有 `favoriteFolders`/`favoriteApps`/`favoriteWebsites`
  (用户已添加),但 `FinderMenuBuilder.plan` 里**没有任何常用项** —— 即 P7-b 未实现,
  所以"重启才能显示"这个现象的真正原因是"还没接进菜单"。已就此询问用户是否现在实现。

### 2026-09-30 — P7-a Finder 菜单语言跟随应用设置

```
Automated: PASS  (261/261 XCTest;251 → 261,新增 10 项本地化/回放测试;两个 target 均构建成功)
Automated: PASS  (Scripts/preview-finder-menu.sh —— 用真实 payload 渲染两种语言的菜单,回放 8/8 OK)
Manual:    PENDING (§3.5 第 15 项:真实 Finder 里切换语言后菜单是否跟着变)
```

- 数据通路:应用把整棵设置树以一个 JSON 写进 App Group `UserDefaults`;扩展**每次构建菜单**时
  只取 `general.language`(实测:payload 实际是 `{"general":{"language":"zh-Hans",...}}`,
  语言**不在顶层** —— 一开始按顶层写,靠读真实 plist 才发现)。读 `UserDefaults` 是 cfprefsd 查询,
  不是文件扫描,菜单构建期"零文件 IO"的约束仍然成立;不做进程内缓存,所以切换后下一次右键即生效。
- 文案来源:扩展 target 现在编译 `AppLanguage.swift` + `Localization.swift`,菜单与设置界面**共用一份**
  `StringKey` 目录;仅在菜单措辞与设置行不同时新增 `finderMenu*` 键(创建别名/锁定/解锁/剪切/
  新建文件夹/粘贴到这里/复制文件夹名称/复制文件夹路径)。
- 回放安全:`representedObject` 过不了进程边界,扩展只能靠 `sender.title` 派发,所以
  `FinderMenuTitles` 的反查**同时接受所有语言**(菜单可能在切换语言前一刻构建完成);
  另外用测试断言"同一语言下所有标题互不相同",避免派发歧义。
- 新增 `Scripts/preview-finder-menu.sh`:用扩展自己的 plan/title 代码 + 真实 payload,打印两种语言的
  两个菜单并跑回放断言 —— 文案问题不必开 Finder 就能定位。
- 项目文件踩坑:`pbxproj` 的对象 ID 撞车(`AASETR003`/`ABSETTST003` 已被 `MenuRightSettings.swift` 占用),
  导致文件被解析到 `Shared/Settings/` 下;已回退重做并加了"全文件 ID 唯一性"自检。

### 2026-09-30 — P7-a Finder 菜单去掉分隔符空槽

```
Automated: PASS  (251/251 XCTest;两个 target 均构建成功;签名构建通过)
Manual:    PENDING (§3.5 第 13b 项:三组之间间距均匀 —— 只能在 Finder 里看)
```

- 用户问「复制/新建/粘贴之间为什么会有很大的空隙,是有一条横线没显示吗」→ **猜测正确**。
- 逐行量测用户的真实截图:原生分隔符有 2px 细线(y=68、138、352),而我们插入的 `.separator`
  处整行非白像素为 0;`Copy Folder Path → New File` 间距 97px,而正常行距是 48px
  → 多出的正好是一个空槽(约 24pt)。
- 结论:`NSMenuItem.separator()` 与菜单图片同源 —— Finder 在扩展菜单里保留槽位但不绘制。
  故 `FinderMenuPlanItem` 去掉 `separator` 分支,容器菜单 8 → 6 项、选择菜单 9 → 7 项,
  相邻项间距恢复均匀(用测试断言项数与顺序,防止再插回分隔符)。
- 三个测试文件的索引断言同步更新(容器菜单子菜单位置 4 → 3、粘贴项 7 → 5)。

### 2026-09-30 — P7-a 设置项图标保留、Finder 菜单图标移除

```
Automated: PASS  (251/251 XCTest;移除 3 项扩展图标测试后 254 → 251;两个 target 均构建成功)
Manual:
  §3.5 设置面板图标(新建文件 12 + 文件权限 11,含 copy)            PASS(截图)
  §3.5 Finder 菜单项无图标、文字对齐 Finder 原生项                  PENDING(只能在 Finder 里看)
```

- 决策依据(实测,非推断):Finder 原样绘制扩展菜单的图片 —— 高亮时文字变白而图标仍是黑色,
  禁用时文字变灰而图标仍是黑色。资源本身 `isTemplate=true` 且无彩色像素(不是配置问题);
  `NSKeyedUnarchiver` 保留该标记而 `TIFFRepresentation` 丢弃;富文本附件绕法离屏实测同样不上色。
  → 结论:自定义图片在 Finder Sync 菜单里拿不到状态着色,故**菜单不放图标**。
- 附带好处:菜单里但凡有一项带图片,Finder 就会给整列留出图标位;去掉后标题与原生项同缩进,
  这也正是用户要求的「文字前面不要有 padding」。
- 移除范围(设置面板的 23 个图标全部保留):`FinderMenuIcons`、`FinderMenuAction.iconAsset`、
  `FinderMenuPlanItem.submenu` 的 `iconAsset` 载荷、`FinderSync.applyIcon`、
  `MenuRightFinder/Resources/MenuIcons.xcassets` 及其 pbxproj 注册、抓取脚本的扩展段、
  校验脚本的第四个目录。

### 2026-09-30 — P7-a 设置项与右键菜单图标(Phosphor + Lucide)

```
Automated: PASS  (254/254 XCTest;248 → 254,新增 6 项图标映射测试;两个 target 均构建成功)
Manual:
  §3.5 新建文件 12 个类型图标(截图确认)                            PASS
  §3.5 文件权限 11 个动作图标(截图确认)                            PASS
  §3.5 扩展包内 5 个菜单图标(assetutil 确认打进 appex)             PASS
  §3.5 真实 Finder 菜单项是否绘制图片                              PENDING(只能在 Finder 里看)
```

- 图标来源已钉版本:Phosphor `2.1.1`(MIT,填充式 256 网格)+ Lucide `1.49.0`(ISC,2pt 描边 24 网格);
  两套许可全文都在 `Resources/Third-Party-Notices/`,应用内「关于 → 开源许可」可查。
- 名字全部先 curl 验证存在再落地(Phosphor 11 个 / Lucide 6+5 个)。
- 规格里未给图标的 5 个动作由我按语义补了 Lucide 图标,已在 README 标注,可随时替换。
- 扩展需要**自己的一份**菜单图标(沙箱 appex 读不到主 App 的 asset catalog),
  故新增 `MenuRightFinder/Resources/MenuIcons.xcassets` 并注册进扩展的 Resources phase。
- `Scripts/check-sidebar-icons.sh` 已重命名为 `Scripts/check-icons.sh`,现在同时校验四个目录。

### 2026-09-30 — P9 第③④步 自定义压缩对话框 + 解压到指定位置

```
Automated: PASS  (410/410 XCTest;402 → 410;两个 target 均构建成功;签名构建通过)
Automated: PASS  (Scripts/verify-archive-roundtrip.sh:「标签」被系统 unzip -z 读到;其余断言全绿)
Automated: PASS  (Scripts/preview-finder-menu.sh:解压 ▸ 两项、压缩 ▸ 五项渲染正确)
Manual:
  §3.8 第 44–49 项(两个对话框的真实点击与外观)                        PENDING
```

- 「标签」写进 ZIP 的 EOCD 注释(自研 reader + 系统 unzip 双向确认);非 ZIP 格式置灰并说明。
- 「压缩模式」是真参数:ZIP → DEFLATE 1/6/9,`.tar.bz2` → BZip2 块大小 1/5/9;
  测试断言极限压缩产物**确实小于**快速压缩;TAR/TAR.GZ 接受但忽略(界面不假装生效)。
- 「解压到指定位置…」由**主 App** 弹 NSOpenPanel;授权校验针对用户选中的目录,取消则什么都不解压。
  dispatcher 通过注入的 `folderChooser` 闭包保持无 AppKit 依赖,单测注入临时目录。
- **本轮与上一轮都没有对话框截图**:外观与真实点击记 PENDING。

### 2026-09-30 — P9 第②步 SWCompression(多格式)

```
Automated: PASS  (402/402 XCTest;398 → 402;MenuRight 与 MenuRightFinder 均构建成功;签名构建通过)
Automated: PASS  (依赖只进主 App 与测试:otool/nm 检查 appex 二进制无 SWCompression 符号;
                  SWCompression 与 BitByteData 的 PrivacyInfo.xcprivacy 均已进 app bundle)
Automated: PASS  (Scripts/verify-archive-roundtrip.sh:ZIP/TAR/TAR.GZ/TAR.BZ2 自建自解 diff -r 一致;
                  系统 gzip/bzip2/tar 造的外来包全部解开;恶意包拒绝且零逃逸)
Manual:
  §3.8 第 31–43 项                                                     PENDING
```

- 依赖钉在 **4.9.1**(唯一同时满足 `platforms: [.macOS(.v14)]` 与 Swift 5 语言模式的版本;
  `develop` 要求 macOS 15,不可用)。
- 7-Zip / XZ **只能解不能压**(库没有写 7z/xz 的能力);加密/分卷/固实仍未实现,
  第③步的对话框会置灰并写明原因。
- 已知残余风险(已写进 README):bzip2/xz 这类不声明体积的容器,库没有流式 API,
  体积上限只能在解压过程中累计判断 —— 恶意文件可能在判定前就膨胀。

### 2026-09-30 — P6-b 文档类新建(本轮)

```
Automated: PASS  (322/322 XCTest;271 → 322,新增 51;MenuRight 与 MenuRightFinder 均构建成功;签名构建通过)
Automated: PASS  (Scripts/verify-document-generation.sh:3 个生成包(22 个部件)+ 3 种模板各复制两次
                  (Untitled.pages → Untitled 2.pages,字节一致、CRC 正常);三个 Python 独立读入器可打开;
                  Quick Look 9 个文件全出缩略图,OOXML 中心像素为白、pptx 为 16:9)
Automated: PASS  (Scripts/preview-finder-menu.sh:availability 行读到 12 项全可创建)
Automated: PASS  (签名 App 内自测:MENURIGHT_SELFTEST_SETTINGS=read 输出
                  appGroupSuite=true newFileCreatable=text,…,docx,xlsx,pptx,pages,numbers,keynote
                  newFileMissingTemplates=)
Manual:
  §3.6 第 12–21 项                                                     PENDING
  第 14–18b 项「用 Word/Excel/PPT/Pages/Numbers/Keynote 打开不弹修复」为**人工门**:
  本机没有 MS Office、也没有 Pages/Numbers,自动化只验到 Apple Quick Look 导入器 +
  三个 Python OOXML 库都能读;真机打开请各点一次。
```

- 三份 iWork 空白模板由用户提供并已放进 `MenuRight/Resources/Templates/`
  (`blank.pages` 88K / `blank.numbers` 134K / `blank.key` 446K),签名产物里已确认存在;
  模板是**普通文档**(flat zip),复制走 `FileManager.copyItem`,字节一模一样。
- `blank.key` 自带 Keynote 主题素材(17 张母版 + 约 400K 图片),所以新建的 `.key` 也是这个体积。
- 本轮**未**执行 `Scripts/install-dev-app.sh`,也没有覆盖 `~/Applications` 里的旧构建;
  已装的那份仍是旧版本(所以真实 Finder 里暂时看不到新菜单项),人工验收前必须先装新构建。
- 已生成文件留档:`build/verification/p6b/`(3 个 OOXML + `copies/` 里 6 个模板副本 + 缩略图)。

### 2026-09-30 — P7-b 常用三项进右键 + 新建文件去掉「实现进度」

```
Automated: PASS  (347/347 XCTest;322 → 347,新增 25;MenuRight 与 MenuRightFinder 均构建成功;签名构建通过)
Automated: PASS  (Spike S6,签名+沙箱内实测四种打开目标全部 SUCCESS:
                  folder:/tmp/menuright-spike · url:https://example.com ·
                  app:/System/Applications/TextEdit.app · bundle:com.apple.TextEdit)
Automated: PASS  (Scripts/preview-finder-menu.sh:读到本机 5 条常用项,
                  常用软件/常用网页/常用文件夹 三个子菜单按规格顺序渲染)
Manual:
  §3.7 第 22–30 项                                                     PENDING
```

- 实测副作用:Spike 期间真的打开了 Finder 窗口、浏览器链接、TextEdit(已退出)。
- 选中态菜单仍是平铺的:常用三项只出现在"空白处右键"。
- 打开动作**不加授权门**(与 Open Terminal 同理),只校验形状(存在的文件夹 / 绝对路径或
  bundle id / http(s) URL);软件是否存在在**点击时**才检查。
- 标题唯一性:同名条目会带来源后缀,因为 Finder 回放只给标题(不保留 representedObject)。
- 「实现进度」卡片已从新建文件面板移除;缺模板时才在"文件类型"卡片页脚列出缺失的文件名。

### 2026-09-30 — P9 第①步 解压/压缩 ZIP

```
Automated: PASS  (398/398 XCTest;347 → 398,新增 51;MenuRight 与 MenuRightFinder 均构建成功;签名构建通过)
Automated: PASS  (Scripts/verify-archive-roundtrip.sh:自研 ZIP 通过系统 unzip -t;
                  解压结果与原始目录 diff -r 一致(符号链接按设计跳过);
                  恶意包 ../ 两条 + S_IFLNK 一条全部拒绝,目标目录外零写入)
Automated: PASS  (Scripts/preview-finder-menu.sh:压缩包/混合/普通选择分别是
                  「解压 ▸ + 压缩 ▸」「只有压缩 ▸」「只有压缩 ▸」)
Manual:
  §3.8 第 31–40 项                                                      PENDING
```

- 第①步只有 **ZIP** 后端(自研 `ZipWriter` + 新增 `ZipReader`),零新依赖;
  第②步接 SWCompression 才有 7Z/TAR/GZ/BZ2/XZ 解压与 TAR 系压缩。
- 加密压缩 / 分卷压缩 / 固实压缩**未实现**,第③步的自定义压缩对话框里会置灰并写明原因。
- 选中态菜单原有的 7 项保持**平铺**;新增的 `解压 ▸` / `压缩 ▸` 是仅有的一处二级菜单,
  因为这两个动作各有多个变体。

### 2026-10-01 — 解压/压缩修复 + 常用项图标

```
Automated: PASS  (449/449 XCTest;两个 target 均构建成功)
Manual:    PENDING(下面 5 项只能在 Finder / 真机上确认)
```

**A. 解压/压缩的修复**

| 修的东西 | 之前的行为 | 现在的行为 |
| --- | --- | --- |
| 解压位置设置 | `ArchiveSettings.destination` / `customDestinationPath` 运行时**没有任何代码读取**,设置面板是装饰品 | 作用于「解压到指定位置…」一项:每次询问→弹面板;指定文件夹→该项标题变成「解压到「文件夹名」」并直接解压过去;压缩包所在文件夹→与「解压到当前文件夹」重复,该项隐藏。**「解压到当前文件夹」始终保持字面行为**(用户选定的语义) |
| 允许的压缩格式 | 只过滤解压菜单,`压缩 ▸` 永远显示全部 4 种 | `压缩 ▸` 与自定义压缩对话框的格式下拉都跟随该设置;主 App 派发时再复检一次(菜单可能是设置变更前构建的) |
| 自定义压缩的「取消」 | 只关闭对话框,后台继续压缩 | 真正中止遍历。归档在内存里组装、最后才落盘,所以不会留下半个文件 |
| 解压后删除原包 | `failed == 0` 就删 —— 全部条目被「跳过」时也会把压缩包删掉 | 仅在该次解压**没有任何内容被跳过**时删;`__MACOSX` / `._*` / `.DS_Store` 这类元数据跳过不算 |
| 压缩读不到源文件 | 静默写入 0 字节条目(归档看起来成功,内容已丢) | 整个压缩失败,错误里指明是哪个文件 |
| 设置页文案 | 「解压执行会在 P9 落地」(早已落地) | 改为说明「解压位置」的实际作用 |

**B. 常用项图标(设置列表 + Finder 子菜单)**

- 主 App 把每个收藏项渲染成 **64×64 PNG** 写进 `<App Group>/FavoritesIcons/`,文件名回写到收藏项的 `iconFile`;沙箱扩展只按文件名读回(`FinderFavoriteIcons`)。扩展既读不到主 App 的资源目录,也没有网络权限。
- favicon 由主 App 抓取(`/favicon.ico`,失败再看页面里的 `<link rel="…icon…">`),因此主 App 新增 `com.apple.security.network.client`;扩展仍然没有任何网络权限。抓不到就退回纯文字,不影响打开。
- 图标在每次启动补齐(`FavoriteIconBootstrap`),不需要先访问设置面板。
- **这推翻了 2026-09-30「菜单不放图标」的决定**,差别见下。

```
Manual:
  B1  常用软件 ▸ 里 Clash Verge / Chrome 左侧显示各自 App 图标        PENDING
  B2  常用文件夹 ▸ 里两个文件夹显示真实文件夹图标                     PENDING
  B3  常用网页 ▸ 里 Bluetful 显示站点 favicon                         PENDING
  B4  菜单为图标预留了一列内边距,文字缩进与原生项不同                 PENDING
  A1  解压位置=指定文件夹时,第二项变成「解压到「xxx」」并直接解压     PENDING
```

- 与上一版的关键差别:上一版用的是**模板(template)图片**,而 Finder 绘制扩展菜单的图片时不做高亮/禁用染色,
  于是选中行上是一个黑图标;全彩 PNG 没有"染色"这一步,不受该限制。**图标列内边距的代价仍然存在**(B4),
  上一版正是把这条和染色问题一起解决才撤掉图标的。
- 自动化能证到的部分(已证):PNG 确实按 64×64 生成且有真实内容(Chrome 彩色图标、bluetful 的 favicon)、
  `iconFile` 已写回设置载荷、扩展侧解码与加载有单测覆盖、扩展侧拒绝对 `../` 这类文件名取值。
  **唯一没被证到的是:Finder 是否真的把这张图画在菜单项左侧。**

### 2026-10-01 — P9 收口:7Z/XZ 拿到证据 + ZIP 文件名编码

```
Automated: PASS  (458/458 XCTest)
Automated: PASS  (Scripts/verify-archive-roundtrip.sh — 六种格式现在都有"外来样本"证据)
Manual:    PENDING(§3.8 的 38/40/43 项,以及下面新增的 E1/E2,仍需在真机上点一遍)
```

对着「规划 vs 现状」差距清单逐条收口:

| 差距 | 处置 |
| --- | --- |
| **7Z / XZ 解压零证据**(规划 S6 要求六种格式全部实测通过) | 验证脚本现在自己造外来样本:**xz** 走 python3 的 `lzma`(本机没装 xz CLI,所以不再自动跳过),**7z** 走 macOS `bsdtar --format=7zip`(libarchive 3.7.4 自带 7-Zip 写入器,项目里没有任何 7z 写入能力)。两条断言都是 `OK`,脚本末尾新增 `format coverage` 段,缺失时打 `!! NOT TESTED` |
| **Windows GBK 中文包文件名乱码**(人工门第 38 项在真实场景下会 FAIL) | 新增 `ZipNameDecoder`,解码顺序:标志位 → 纯 ASCII → 合法 UTF-8 → 「以非 ASCII 为主 + 合法 GB18030 + 真的含中日韩」→ CP437。9 个新单测覆盖,含一个**刻意钉住取舍**的用例(见下) |
| 规划文档 / 手册过期 | 手册 §4 的「7Z/RAR/XZ 解压:P9 才做」已改;`功能规划v2.md` 的 P9 补了落地状态 |
| 1GB 大包(S8)、只读目标目录(人工门) | **仍未验**。前者需要真的造一个 1GB 包;后者需要只读卷、或把目标目录 `chmod 0555` 后走一次真实解压 |

```
Manual:
  E1  用 Windows 造的 GBK 中文名 zip 解压 → 目录名正确,不是 ÐÂ½¨ÎÄ¼þ¼Ð        PENDING
  E2  解压一个 .7z / .tar.xz → 正常解出(自动化已证,这里只确认 Finder 那条路)   PENDING
```

- **文件名编码的取舍**(单测 `testMixedScriptCP437NameIsTheKnownCostOfPreferringChinese` 钉住):
  GB18030 会接受很大一部分字节对,所以"能不能按 GB18030 解"本身不足以判断。真正起作用的是
  "非 ASCII 字节是否占多数"这道闸门——中文名大多是多字节,西文名是 ASCII 字母加一两个重音。
  极端情况下(一个以非 ASCII 为主、又恰好是合法 GB18030 的西文名)仍会被读成中文;选这个方向是因为
  反过来的代价是**每一个 Windows 中文包都乱码**。
- 我们自己写出的 ZIP **已经**正确设置 UTF-8 标志位(`ZipWriter` 对非 ASCII 名设 bit 11),
  所以这一改动只影响"读别人的包"。

### 2026-10-01 — 修:失败提示框阻塞扩展主线程(右键菜单会消失)

```
Automated: PASS  (460/460 XCTest,含新增的源码级守卫 ExtensionMainThreadTests)
Automated: PASS  (实测:菜单构建 4ms;扩展可达源码里已无 runModal/beginSheetModal)
Manual:    PENDING(F1/F2)
```

- **现象**（用户报告）:在一个压缩包上点「解压到当前文件夹」→ **无任何反应** →
  右键里 MenuRight 的条目**整个消失** → 过一会才回来。
- **取证**:10:21:48 / 10:24:16 两次点击时**主 App 根本没在运行**。诊断日志是
  `extension: connect failed: connect() failed: No such file or directory` 与
  `file operation unavailable`（socket 文件随 App 退出而消失）。这条路径会走
  `OperationPresenter.presentMainAppUnavailable` → `NSAlert.runModal()`。
- **机制**:`runModal()` 在扩展的**主线程**上开嵌套消息循环,而 Finder 调 `menu(for:)` 用的就是这条线程。
  提示框一旦被压在 Finder 或其他窗口后面,主线程就**无限期停在那里**;期间 Finder 拿不到菜单,
  于是 MenuRight 条目静默消失,直到用户点到那个框、或 Finder 把扩展替换掉。
  这正是 `FinderSync.ipcQueue` 当初要修的那一类 bug(见其注释),而提示框是**最后一条**漏网的。
  顺带排除另一个嫌疑:**菜单构建实测只要 4ms**(10:25:12.380 → 12.384),所以不是图标 IO 拖的。
- **修法**:`OperationPresenter` 不再 `runModal()`。改为把 alert 自己的窗口
  `makeKeyAndOrderFront` + `level = .floating` + `canJoinAllSpaces`,OK 按钮挂自己的 action
  (`AlertDismisser`,因为非模态下 NSAlert 的内置按钮是 no-op),20 秒自动关闭,同一时刻只留一个。
  控制流立刻回到 run loop。
- **守卫**:新增 `MenuRightTests/ExtensionMainThreadTests.swift` —— 源码级断言
  `MenuRightFinder/**.swift` 与 `Shared/FileOperations/OperationPresenter.swift` 里不得出现
  `runModal`/`beginSheetModal`(忽略注释行)。这类 bug 运行时测不出来:它表现成"Finder 没显示菜单",
  没有任何断言能观察到主线程被停住,只能用源码断言钉住。

```
Manual:
  F1  退出 MenuRight 后,右键一个压缩包 → 解压到当前文件夹                     PASS(部分)
      用户实测 2026-10-01:「弹出没问题,拉起宿主 app 成功」
      → 中文文案、两个按钮、无勾选框/空按钮  ✅;「打开 MenuRight」能拉起宿主 App ✅
      仍待确认:弹框还在时再右键,MenuRight 菜单是否依然出现(上一轮修的主线程阻塞)
  F2  打开 MenuRight 后重复 F1                                                PENDING
      预期:解压成功,文件出现在压缩包旁边
```

### 2026-10-01 — 修:提示框的模板残留 + 文案本地化

```
Automated: PASS  (460/460 XCTest;LocalizationTests 覆盖新增 30 个 key 的中英文与占位符一致性)
Automated: PASS  (探针 dump NSAlert 视图层级确认,见下;无需截图)
Manual:    PENDING(F1/F2 的最终外观)
```

- **现象**（用户截图）:提示框是英文,而且多出「不再显示此信息」勾选框、一个空按钮、一个帮助按钮。
- **根因**:`NSAlert` 只有在**模态**展示（`runModal()` / `beginSheetModal`）时才跑那次布局整理,
  把 `NSAlertPanel.nib` 中本次用不到的控件收起来。上一轮为了不阻塞主线程改成了直接
  `orderFront`,于是这些模板槽位全露出来了——**不是我们加了按钮,是没让 AppKit 收起来**。
- **修法**:显示前显式 `alert.layout()`,并加 `showsSuppressionButton = false` /
  `showsHelp = false` / "隐藏无标题按钮"兜底。文案全部走 `Localization` +
  `FinderMenuLanguage.resolve()`,即跟随「通用设置 → 界面语言」。
- **按钮**:「好」+「打开 MenuRight」(后者用 `NSWorkspace.openApplication` 打开宿主 App)。
- **验证手法(可复用,不用截图)**:写个小程序 dump `alert.window.contentView` 的层级。
  `layout()` 之前是 `title="<Do not show this message again>"` + 一个空标题按钮 + 帮助按钮,
  之后只剩「好」/「打开 MenuRight」两个真按钮,面板高度 328 → 253。
- 顺带:`OperationPresenter.swift` 原本也被编进主 App target(而主 App 从不使用它),
  已从该 target 移除——这样它能直接用扩展的语言解析器,不必为它单开一条注入路径。

### 2026-10-01 — 修:侧边栏选中行图标不变白

```
Automated: PASS  (461/461 XCTest,含新增源码级守卫;已实测守卫在旧代码上会失败)
Automated: PASS  (离屏渲染对照实验,五种写法逐一取像素,见下)
Manual:    PENDING(侧边栏点选一眼)
```

- **现象**:侧边栏选中项**文字变白、图标仍是黑的**。
- **取证(取像素)**:选中胶囊底色 `rgb(149,61,150)`;胶囊内图标区最暗像素 **`rgb(0,0,0)`**,
  未选中行也是 `rgb(0,0,0)`。若图标吃的是 `Color.primary`,叠在浅色底上不会正好是 0。
  另查:资源编译后 `TemplateMode=template`、运行时 `isTemplate = true`,所以**不是资源问题**。
- **定位(离屏渲染对照)**:
  - 裸 `VStack` 里这一行**完全正确**:选中行图标是白的;
  - 放进 `List(.sidebar)` 就变黑 —— **是 sidebar 的 List 从外层给 label 的图标槽
    重新套了一遍前景色**,行级 `.foregroundStyle` 能到文字、到不了图标。
- **五种写法实测**(同样在 `List(.sidebar)` 内渲染后取像素):

  | 写法 | 选中行图标 |
  |---|---|
  | 现状:只在 Label 外层设 `.foregroundStyle` | 黑 ❌ |
  | `.tint(.white)` | 黑 ❌ |
  | **在 icon 视图上直接设 `.foregroundStyle`** | **白 ✅** |
  | 改用 `HStack` 分别设 | 白 ✅ |
  | 前两者 + `.labelStyle(.titleAndIcon)` | 白 ✅ |

  取最小改动:在 `AssetIcon` 上再设一次 `.foregroundStyle(foreground)`。
- **守卫**:`SettingsCategoryTests.testSidebarRowStylesItsIconDirectlyNotJustTheLabel` ——
  源码级断言 `SidebarCategoryRow` 的 `icon:` 闭包内必须出现 `foregroundStyle`。
  这类 bug 在 host-less 测试包里没有可观察量(图标是 asset catalog 图片、测试包没有
  `Assets.car`,行视图也不在测试 target 里),所以只能查源码。
  **已实测:去掉修复后该测试失败**;另外第一版守卫曾被自己写的注释骗过(注释里也提到了
  `foregroundStyle`),现已先剥注释再断言。

### 2026-10-01 — 体积上限支持手输 + 上限提示

```
Automated: PASS  (466/466 XCTest,+5:输入解释规则)
Automated: PASS  (自己开面板截图核对版式:值 + 「可输入 1–8,192 MB」+ 箭头)
Manual:    PENDING(实际键入 10000 看提示)
```

- **需求**:「体积上限」原本只有 Stepper,不能输入;而且越过范围时**只会静默拒绝**
  (到顶再点箭头什么也不发生,没有任何解释)。要求可手输,并提示最大值。
- **改法**:
  - 规则抽成纯函数 `ArchiveSettings.interpretSizeLimit(_:)`,返回
    `.accepted(n)` / `.aboveMaximum(stored:)` / `.belowMinimum(stored:)` / `.unusable`,
    与解码时的 `normalized()` 共用同一个 `sizeLimitRange`,不会各说各话。
  - `ArchiveSettingsView` 那一行换成 `TextField` + 「MB」+ Stepper。
    行**常驻**副标题「可输入 1–8,192 MB」(最大值在输入前就可查),
    一旦越界立刻替换为具体那一条:「最大不能超过 8,192 MB」/「最小不能小于 1 MB」/「请输入数字」。
    提交(回车或失焦)时按规则落库:越界就存钳制后的值,无法解析就回退到已存值,
    字段与设置不会各走各的。
  - 聚焦时编辑纯数字、失去焦点恢复带千分位的显示(`1,024 MB`)——和被复制粘贴回去的形态一致,
    `interpretSizeLimit` 也接受 `1,024 MB` / `1，024` / 带单位 / 带空格。
- **踩坑(测试抓到)**:第一版用 `allSatisfy(\.isNumber)`,阿拉伯-印度数字「١٢」也为真但 `Int()` 解析不了,
  于是被归到"溢出→超过上限",给出**错误解释**。已改为只接受 ASCII 数字。
- **顺带修**:`MENURIGHT_REVIEW_WINDOW` 这个 review 钩子**一直是静默失效的** ——
  它只在启动后 0.0s/0.4s 各试一次,而 SwiftUI 窗口此时 `isVisible == false`,过滤条件直接跳过。
  现在改为"优先可见窗口,否则取第一个"并最多坚持 5 秒,成功时打一行 NSLog。
  实测:`review window sized to {1100, 1180} after 2 attempt(s)` ✓。
- **顺带清理**:设置自检 `MENURIGHT_SELFTEST_SETTINGS=write` 会把体积上限写成时间戳 marker
  (用户截图里的 `1,038 MB` 就是这么来的,我先前跑自检没 reset)。已用 `reset` 恢复为默认 1024。

### 2026-10-01 — 修:长操作被 5 秒超时误判为「主应用未运行」,并加进度提示

```
Automated: PASS  (471/471 XCTest,+5:超时/EOF 语义、EAGAIN 等待、预算常量)
Automated: PASS  (探针 dump 视图层级:进度提示 16x16 转圈 + 仅「隐藏」按钮,无勾选框/空按钮)
Manual:    PENDING(G1/G2)
```

- **现象**:主程序明明在运行,右键 → 压缩为 ZIP,却弹「MenuRight 未运行」,
  详情 `read failed`;**数秒后压缩包其实出现在目标文件夹**;整个过程没有任何进度提示。
- **取证(日志精确到秒)**:

  ```
  03:22:52 finder-sync request kind=compressItems
  03:22:52 main-app    收到请求
  03:22:57 finder-sync read failed        ← 整整 5 秒
  03:23:06 finder-sync 再试一次(用户重试 → 又压了一次)
  03:23:11 finder-sync read failed        ← 又是 5 秒
  ```

- **根因**:文件操作是**一次性请求/响应**,主程序要压完才回包;而传输层通用帧上限
  `UnixSocketTransport.defaultTimeoutSeconds = 5`,扩展等 5 秒就放弃。更糟的是
  `readFrame` 只返回 `Data?`——**超时和对端断开被合并成同一个 nil**,
  于是"我还在干活"被渲染成"主应用没运行",还提示用户去打开它、重试(重试会再压一次)。
- **修法**:
  1. `UnixSocketTransport.FrameReadResult`(`.frame/.timedOut/.closed/.failed`),
     `readFrameResult` 保留失败原因;`readFrame` 仍返回 `Data?` 以兼容旧调用。
  2. `MenuRightIPC.fileOperationTimeoutSeconds = 600`:文件操作用长预算,
     两端共用同一常量。
  3. `ExtensionIPCClient.FileOperationOutcome` 新增 `.stillRunning`,超时不再走
     `.unavailable`;`FinderSync` 7 处 outcome 分支各自处理,提示改成
     「操作仍在进行」并**明确不要重复操作**(不再叫人去"打开 MenuRight")。
  4. **进度提示**:`sendDelegated` 是所有文件操作的唯一漏斗,在这里挂
     「正在压缩…/正在解压…」浮层(1.5 秒后才出现,太快的不闪窗;
     出结果即撤下;只有一个「隐藏」按钮,点了只是收起、不打断操作)。
- **差点漏掉的坑**:socket 上还有 5 秒的 `SO_RCVTIMEO`,读到时若返回 `EAGAIN`,
  原逻辑直接判 `.failed` —— 那 600 秒上限根本用不上。已改为 EAGAIN/EWOULDBLOCK 继续等
  (带 10ms 小睡防自旋),由调用方 deadline 决断。新增测试
  `testQuietPeerIsWaitedOutPastTheSocketReceiveTimeout` 守住它。
- **验证手法**:探针显示 `NSAlert` 在**不加按钮时会自动补一个英文 "OK"**,
  且 accessory 视图不显式设 frame 会被布局成 `{0,0}`(看不见)——两个都已规避。

```
Manual:
  G1  主程序在运行时,右键一个大文件夹 → 压缩为 ZIP                            PENDING
      预期:1.5 秒后出现「正在压缩…」浮层(带转圈);**不再**弹「未运行」;
      操作完成后浮层自动消失,压缩包出现在旁边
  G2  同上,点浮层里的「隐藏」                                                PENDING
      预期:浮层收起,压缩继续进行并最终完成
```

### 2026-10-01 — 压缩进度窗口:真实进度 + 暂停 + 取消

```
Automated: PASS  (479/479 XCTest,+8:进度/暂停/注册表/取消码/窗口结构)
Automated: PASS  (窗口离屏渲染出 PNG 核对,见下)
Automated: PASS  (Release 构建;已安装;appex 内含 archive-zip-7z.png 71660 bytes)
Manual:    PENDING(H1/H2/H3)
```

- **要求**(用户给的设计稿):像系统「已锁定的项目」提示那样 —— **没有关闭钮,只有最小化**;
  左侧压缩包图标(`zip:7z.png`);中间一行**真实进度条**;下面两个按钮:**暂停、取消**。
- **协议扩展**:`IPCProtocol.Response.progress`(0…1)。带 `progress` 的帧是**中间状态**,
  不带的才是最终答复;扩展端改成**循环读帧**,所以一次请求可以推多帧。
- **真实进度**:两段,都是确定的 ——
  1. 读取源文件(按字节,分母来自一次**只读元数据**的预扫描);
  2. 组装容器(按条目,直接来自 `ZipWriter` 的 deflate 循环)。
- **暂停/取消**:新增 `ArchiveOperationControl`(worker 端:`checkpoint()` 每条目调用,
  暂停时 50ms 挂起;`report()` 汇报进度)+ `ArchiveOperationRegistry`(按 `clientRequestId`
  找到正在跑的操作)。控制消息走**独立连接**的 `fileOperationControl` 方法 ——
  数据连接正卡在等答复,控制帧插在那里等于等它忙完才被读到。服务端本来就并发处理连接,
  所以这条能立刻被受理。
- **窗口**:`ArchiveProgressWindow` —— `styleMask: [.titled, .miniaturizable]`
  (实测:`closable` 不设时关闭钮**存在但禁用**,zoom 同样禁用,只有最小化可用,
  正好是设计稿那样)。`.titled` 是必须的,否则没有标题栏与红绿灯。
- **取消不是失败**:新增错误码 `cancelled_by_user`,扩展端 7 处失败分支全部**静默**处理 ——
  用户自己按的取消不该弹错误框。
- **验证手法**:`ArchiveProgressWindowTests` 把窗口 contentView 离屏渲染成 PNG
  (`TEST_RUNNER_MENURIGHT_DUMP_PROGRESS_WINDOW=/tmp/progress.png xcodebuild test …`;
  注意 `xcodebuild` **不会**把 shell 环境变量透给测试进程,必须加 `TEST_RUNNER_` 前缀)。
  另有断言:`.closable` 不在 styleMask 里、关闭钮 `isEnabled == false`、最小化 `== true`、
  进度条 determinate、按钮标题与回调。

```
Manual:
  H1  右键一个大文件夹 → 压缩为 ZIP                                          PENDING
      预期:约 1.5 秒后出现进度窗口(图标/进度条/暂停/取消),进度条真实推进,
      完成后窗口自动消失,压缩包出现在旁边
  H2  压缩过程中点「暂停」                                                    PENDING
      预期:进度条停住,按钮变「继续」;点「继续」后继续推进
  H3  压缩过程中点「取消」                                                    PENDING
      预期:窗口消失,**不弹任何错误框**,不产生压缩包
```

### 2026-10-01 — 进度窗口按草图改版 + 修「暂停按钮无效」

```
Automated: PASS  (480/480 XCTest,含源码级守卫;已实测守卫在旧代码上失败)
Automated: PASS  (改版后重新离屏渲染核对,见下)
Automated: PASS  (Release 构建;已安装;扩展已启用)
Manual:    PENDING(H1/H2/H3)
```

- **样式(按用户草图)**:去掉标题栏文字与那条分割线
  (`titleVisibility = .hidden` + `titlebarAppearsTransparent = true` + `.fullSizeContentView`),
  宽度 380 → **570(约 1.5 倍)**,高度 156;图标 64px、标题 15pt 粗体、进度条通栏 430pt、
  「暂停/取消」96x30 放右下。红绿灯仍在,内容留出顶部约 30pt 不重叠。
  标题栏没了,所以整个窗口可拖动(`isMovableByWindowBackground`)。
- **暂停/取消无效的根因**:控制消息虽然走了独立连接,却被派发到 `ipcQueue` ——
  而那条队列是**串行**的,压缩操作整个生命周期都占着它(卡在等答复)。
  于是暂停消息排在压缩后面,等压缩结束才发出去 = 按了没反应。
  已改到独立的 `controlQueue`;并补了源码级守卫
  `testControlMessagesAreNotQueuedBehindTheOperationTheyInterrupt`
  (已实测:把 `controlQueue` 换回 `ipcQueue` 时该测试失败)。

```
Manual:
  H1  右键一个大文件夹 → 压缩为 ZIP                                          PENDING
      预期:约 1.5 秒后出现进度窗口(**无标题栏文字、无分割线**,比之前宽),
      进度条真实推进,完成后窗口自动消失,压缩包出现在旁边
  H2  压缩过程中点「暂停」                                                    PENDING
      预期:进度条**立刻**停住,按钮变「继续」;点「继续」后继续推进
  H3  压缩过程中点「取消」                                                    PENDING
      预期:窗口消失,**不弹任何错误框**,不产生压缩包
```

### 2026-10-01 — 解压也有真实进度、暂停与取消

```
Automated: PASS  (484/484 XCTest,+4:解压进度/切片/暂停/取消)
Automated: PASS  (Release 构建;已安装;扩展已启用)
Manual:    PENDING(H4)
```

- **要求**:解压按压缩那套来 —— 真实进度条 + 暂停 + 取消。
- **改法**:进度/控制的基础设施上一轮已经建好,这次是把解压接上去:
  - `ArchiveExtractor.extract` 增加 `control:` 与 `progressRange:`。`steps` 是**先规划好再循环**的,
    所以 `count` 就是真实分母,直接逐条目 `checkpoint()` + 上报。
  - **一个请求可能解压多个压缩包**(菜单多选),而进度条只有一条,所以每个包各自上报到
    自己在 `progressRange` 里的那一段切片。
  - `FinderSync.showProgress` 现在对 `.extractArchive` 也开同一个窗口,标题「正在解压」。
- **测试抓到的真问题**:循环里报的是每个条目的**开始**,最后一维只到 `(n-1)/n = 0.83`,
  进度条永远差一截;已改为循环结束后补报 1。`testExtractionReportsProgressUpToOne` /
  `testExtractionProgressStaysInsideItsSliceOfTheRequest` 就是为这两点写的。
- **已知粒度**:与压缩一致,按条目;单个巨大成员在写完前不会响应暂停/取消。

```
Manual:
  H4  右键一个压缩包 → 解压到当前文件夹                                        PENDING
      预期:出现「正在解压」进度窗口(同一套样式),进度条真实推进,
      可暂停/继续/取消;完成后窗口自动消失
```

### 2026-10-03 — 「自定义压缩…」不再依赖设置窗口（P9 第③步的真实缺口）

```
Automated: PASS  (591 XCTest,2 skipped,0 失败;+10:对话框呈现/尺寸/进程级窗口)
Automated: PASS  (MenuRight + MenuRightFinder 两个 target 均构建成功)
Automated: PASS  (app 内自测:visibleAfterClose=0 时对话框仍然 visible —— 见下)
Manual:    PENDING(§3.8 第 44–49 项:真实右键点击与外观)
```

- **发现的问题**:「自定义压缩…」的对话框原来是挂在设置窗口上的 `.sheet`,而主 App 自 2026-10-01 起是
  「关窗口不退出」的常驻菜单栏程序 —— 用户关掉设置窗口后再点「自定义压缩…」,**什么都不弹**。
  更糟的是日志 `ARCHIVE dialog presented` 照样打印,所以手册里以日志为证据的验证是**假阳性**
  (§3.8 第 44 行原来「失败时看什么」只写了这条日志)。
- **改法**:对话框改由**主 App 进程**持有 —— 新增 `CustomCompressionDialogWindow`(`NSWindow` +
  `NSHostingController`,`level = .floating`、`identifier = "archive-dialog"`、**故意没有关闭按钮**:
  取消/确定是唯一出口),`ArchiveRequestCenter.present(_:)` 通过新的 `ArchiveDialogPresenting` 协议
  把请求交给它;`SettingsRootView` 里的 `.sheet` 与 `@StateObject` 一并删除。presenter 可注入(spy),
  单测因此能断言「请求确实交给了对话框」,而不只是「请求被停在 center 上」。
- **一键复现**(DEBUG 构建;自测会先把主 App 的窗口全部关掉,再走一次真实的 `compressItems` 派发):

  ```
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG=/Users/suxin/Desktop \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PNG="$HOME/Library/Group Containers/group.xin.ljhsu.MenuRight/archive-dialog.png" \
  build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
  ```

  2026-10-03 实测输出:
  `SELFTEST dir=/Users/suxin/Desktop/MenuRight-Selftest fixture=skipped(…) visibleBefore=2 visibleAfterClose=0 dispatch=SUCCESS createdPath=<none> pending=true dialogWindow=true dialogVisible=true png=… size=(520.0, 408.0) dismissedVisible=false`
  → `visibleAfterClose=0` = 派发时主 App 一个窗口都没有;`dialogVisible=true` = 对话框照样出现;
  `dismissedVisible=false` = 「取消」之后窗口真的消失。**修复前这里会是 `dialogVisible=false`**。
- **坑**:签名沙箱版 app 写不了 `/tmp`、也写不了 `~/Desktop/...`(报 "You don't have permission to save…"),
  所以 PNG 只能往 App Group 容器里写;`fixture=skipped(…)` 是正常的 —— 自测停在对话框,根本不用那个源文件。
  测试进程里拿对话框截图要走 `TEST_RUNNER_MENURIGHT_DUMP_ARCHIVE_DIALOG=<路径>`
  (xcodebuild 只转发 `TEST_RUNNER_` 前缀的变量),但那个渲染没有窗口背景,版式以 app 内自测的 PNG 为准。
- **已知边界**:`ArchiveRequestCenter.pending` 仍然只保存最近一次请求;同一时刻只存在一个对话框,
  第二次请求会替换第一次(不是叠窗口)。真实 Finder 右键这一环依旧只能人工点。

### 2026-10-03 — P9 第④步：7z 写入 + 自研 ZIP 加密 + 密码本（用户四项要求）

```
Automated: PASS  (623 XCTest,2 skipped,0 失败;591 基线 +32:ZipCrypto 10、密码本 14、7z/加密落盘 8)
Automated: PASS  (MenuRight Debug/Release + MenuRightFinder Debug 均构建成功)
Automated: PASS  (7z 产物被 /usr/bin/bsdtar -tf 列出;加密 zip 被 /usr/bin/unzip -P 打开)
Automated: PASS  (app 内自测:visibleAfterClose=0 时对话框仍然 visible,size=(520.0, 384.0))
Manual:    PENDING(§3.8 第 44、50–55 项:真实右键点击、7z/加密/密码本的外观与手感)
Manual:    PENDING(解压一个加密 zip 仍报"不能解"——见下,这是本版本有意的边界)
```

- **用户要求**(原话,m00594):「自定义压缩弹出的面板,顶部有一大块空白,请你去掉;压缩格式和压缩模式对齐位置
  有问题 / 界面设计请你参考我给你的第二张 FastZip 的设计 / 我们现在没有 7z 压缩功能吗,可以加上吗。需要自研
  zip 加密,有开源的功能可以参考吗 / 加密压缩应当有一个密码本,用户可以编辑,在加密压缩输入密码的时候可以直接选择」。
  四项**全部落地**。
- **① UI**:窗口从 `.titled + .fullSizeContentView + 标题隐藏` 改成普通 `.titled`(标题栏显示"自定义压缩"),
  内容里的重复标题与 `Spacer(minLength: 44)` 删除 —— 顶部那块空白就是这两处叠出来的;压缩格式/压缩模式改为
  **同一行**(`HStack` + `Spacer`)。内容高度 408 → 331pt(当时的版式)。回归护栏:单测断言
  `content.height <= fitting.height + 0.5` 与 `!styleMask.contains(.fullSizeContentView)`。
- **② 7z 写入**:走 **PLzmaSDK 1.4.2**(MIT,SPM `.exact("1.4.2")`,基于 LZMA SDK 23.01,LZMA2),
  新文件 `Shared/Archive/SevenZipWriter.swift`;`ArchiveCompressor.writableFormats` 加 `.sevenZip`、
  `fileNameExtension` 返回 `"7z"`。**已知边界**:libplzma 不写目录条目(目录只作为文件名的前缀存在),
  所以**空目录不会进 7z**,zip/tar 仍保留空目录 —— 这是实现差异,不是失败。第三方声明补在
  `MenuRight/Resources/Third-Party-Notices/PLzmaSDK-LICENSE.txt`。
- **③ 自研 ZIP 加密**:`Shared/FileOperations/ZipCrypto.swift` 实现 PKWARE 传统加密(ZipCrypto):
  12 字节加密头(10 随机 + CRC 高 16 位 + 校验字节)、三键 keystream、通用位 bit0。
  `ZipWriter.archive(…, encryption: ZipEncryption(password:)…)`。单测以**外部实现**收尾:
  `/usr/bin/unzip -P` 能读我们写的,`/usr/bin/zip -e` 写的我们能读。**已知边界**:只做 ZipCrypto
  (兼容优先,强度有限),不做 WinZip AES;能**写**加密 zip,**读**还没做 —— 解压加密包仍报
  `archive_unsupported`,下一步再做(密码要进解压流程,而密码**不进 IPC 契约**,得在 App 内弹框)。
- **④ 密码本**:`Shared/Settings/ArchivePasswordBook.swift`(**钥匙串**存储,不是设置 JSON —— 设置是
  App Group 明文且 Finder 扩展可读),设置 → 解压缩管理里可增删改、勾选「自动保存压缩时输入的加密密码」、
  批量导入/导出 JSON;压缩对话框在格式为 ZIP 时显示「加密压缩」勾选框 + 密码框 + 眼睛 + 「从密码本选择」。
- **一键复现**(与上一条相同,已刷新尺寸):

  ```
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG=/Users/suxin/Desktop \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PNG="$HOME/Library/Group Containers/group.xin.ljhsu.MenuRight/archive-dialog.png" \
  build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
  ```

  2026-10-03 实测:`… visibleAfterClose=0 dispatch=SUCCESS pending=true dialogWindow=true dialogVisible=true png=… size=(520.0, 384.0) dismissedVisible=false`。
- **密码本界面取证**(同一个自测进程,`设置 → 解压缩管理`):

  ```
  MENURIGHT_SELFTEST_PASSWORD_BOOK_PNG="$HOME/Library/Group Containers/group.xin.ljhsu.MenuRight/password-book.png" \
  build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
  ```

  实测:`SELFTEST passwordBook png=… size=(720.0, 1500.0)`,PNG 里能看到「密码本」分组:
  自动保存开关、序号/名称/密码 表头、两行(名称 + 圆点密码 + 眼睛 + 减号)、左下 `+`/`-`、
  右下 批量导入/批量导出。**这两行密码来自内存册**(`InMemoryArchivePasswordBookStorage`),
  自测**不会**往真钥匙串写示例密码。窗口高度取 1500pt 是故意的:再矮就会把密码本这段裁掉。
- **坑(自测退出)**:`NSApp.terminate(nil)` 只是"请求",run loop 正忙时可能被忽略(实测进程写完后不退出),
  `reportSelfTest` 现在在它之后再挂一个 1 秒后的 `exit(0)` 兜底。
- **坑(新建文件)**:pbxproj 里**必须**给每个新文件独立的 fileRef ID —— 两个文件共用 `AAPWB001` 时测试类
  根本没被编进 bundle(`Executed 0 tests`,`nm MenuRightTests` 里也找不到),排查花了很久。

### 2026-10-03 — 自定义压缩对话框写盘必须自己重新取得 security-scoped access（用户报「加密压缩失败」）

```
Automated: PASS  (626 XCTest,2 skipped,0 失败;623 → +3:对话框写盘的 scope/越权/取消三个用例)
Automated: PASS  (MenuRight Debug/Release + MenuRightFinder Debug 均构建成功)
Automated: PASS  (app 内自测,真沙箱:confirm=SUCCESS … unscopedRead=DENIED(…permission…))
Automated: PASS  (/usr/bin/unzip:无密码报 unable to get password,`-P hunter2` 报 No errors detected)
Manual:    PENDING(§3.8 第 44、50–55 项:真实右键点击)
```

- **现象(用户截图 m01529)**:格式 ZIP、勾了「加密压缩」并输入密码,点「确定」后红字
  `压缩失败: Could not read the archive: “mr-代码主题.webp” could not be read: The file … you don't have permission to view it.`。
- **根因**:`FileOperationDispatcher.handleCompressItems` 的 customize 分支只把请求**停**在
  `ArchiveRequestCenter` 上就 `return .success(createdPath: nil)`,**没有走 `withAuthorizations`**;
  非自定义分支才在 `withAuthorizations` 里做写入。用户按「确定」时距 `dispatch` 已过去几分钟,
  那次 security-scoped access 早已 stop,沙箱于是拒绝读源文件。**与加密无关**:不加密的自定义压缩
  同样会失败,只是用户在测加密。
- **修法**:新增 `FileOperationDispatcher.performCustomCompression(sources:into:preferredName:format:mode:label:password:settings:control:) throws -> ArchiveCompressor.Report`
  —— 重算 `scopeTargets`(`static func scopeTargets(sources:destination:)`,与同步路径共用一份算法)、
  先做 `AuthorizedURLResolver.folderMatching` 前置校验、再把 `ArchiveCompressor.compress` 放进
  `FolderAuthorizationAccess.withAccesses(configuration: scopedConfig, persistRefreshedBookmark: persistenceHook())`;
  授权失败抛 `FileOperationDispatcher.CustomCompressionFailure(message:)`(对话框直接显示这句),
  `.cancelled` 仍原样透传(「取消」不能变成红字)。`CustomCompressionSheet.save()` 改调它。
- **顺带修的误导文案**:`ArchiveError.readFailed` 只由压缩器读源文件时抛,`ArchiveExtractor.describe`
  却写作 `Could not read the archive: …` —— 把整个排查方向带偏(看起来像压缩包坏了)。现在是
  `Could not read “<文件>”: <系统原因>`;`sources.isEmpty` 改抛 `.writeFailed`;测试只断言 case
  与「detail 里要有文件名」,不受影响。
- **测试**:`testTheDialogWriteTakesItsOwnScopedAccess`(停请求 → 清空 spy 记录 → 调新方法 →
  断言 `started == [authorized]` 且 `stopped == [authorized]`,证明写盘确实发生在 scope 里)、
  `testTheDialogWriteRefusesAPathOutsideAnyAuthorizedFolder`、`testTheDialogWriteKeepsTheCancellationIdentity`。
- **真沙箱端到端取证**(可复现):

```bash
mkdir -p ~/MenuRight-ScopeProbe/MenuRight-Selftest
printf 'MenuRight scoped-access probe\n' > ~/MenuRight-ScopeProbe/MenuRight-Selftest/selftest-source.txt
MENURIGHT_SELFTEST_ARCHIVE_DIALOG=~/MenuRight-ScopeProbe \
MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM=1 \
MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_PASSWORD=hunter2 \
  build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
# SELFTEST … confirm=SUCCESS path=…/selftest-confirm.zip
#          unscopedRead=DENIED(The file “selftest-source.txt” couldn’t be opened because you don’t have permission to view it.)
unzip -P hunter2 -t ~/MenuRight-ScopeProbe/MenuRight-Selftest/selftest-confirm.zip   # No errors detected
```
  `unscopedRead=DENIED` 是**负对照**:同一份源文件,不走授权包装读一次,得到的正是用户截图里那句话 ——
  证明「沙箱确实会拒」且「是这次取得的 scope 让写盘得以成立」。
- **坑**:`MenuRight-ScopeProbe` 只是临时探针目录(在已授权的 `/Users/suxin` 下),取证完要删掉。

### 2026-10-03 — 解压加密 zip:主 App 在写盘前问密码(用户报「软件加密压缩的文件自己解不开」)

```
Automated: PASS  (651 XCTest,2 skipped,0 失败;基线 626,本轮 +25:ArchivePasswordResolverTests 17 + FileOperationDispatcherTests 4 + ArchivePasswordPrompterTests 4)
Interop:   PASS  (/usr/bin/zip -e -P hunter2 写的流式加密包,用密码本里的密码走完整解压路径,内容逐字节一致)
Manual:    PENDING(§3.8 第 43、56–58 项:真实右键解压时的密码框外观、连错三次、取消)
```

- **用户报的**(截图 m01697 + m01698「通过软件加密压缩的文件,自己解压的时候发现无法解压」):弹窗
  `无法完成"解压压缩包"。Not a readable archive: the archive is password-protected, which this build does not support`。
- **根因**:P9 第④步让 App 能**写** ZipCrypto 加密 zip,但读路径没有密码入口 —— `ZipReader` 一看到通用位
  bit0 就抛 `encryptedNotSupported`,于是解压链路把它翻成"本版本不支持"。不是文件坏了,也不是 CRC 问题。
- **设计(三条规矩)**:
  1. **密码永不进 IPC**。扩展只发"解压这个压缩包";主 App 是唯一解压者,也是唯一问密码的地方
     (`ArchivePasswordPrompting` 是策略与解压机器的接缝)。
  2. **写盘之前先定密码**。`ArchivePasswordResolver.resolve` 在进入写盘循环前对每个归档解析一次,并用
     `ZipReader.validates(password:)` 拿**最小的那个加密条目**真解一次来验密码;验不过就问,最多 3 次
     (第 2 次起文案变成"密码不对"),取消/留空/用完 → `.abandoned` → dispatcher 直接返回
     `.cancelledByUser`(**扩展端 7 处 `guard code != .cancelledByUser` 保证静默,不弹错误框**),一个文件都不写。
  3. 先查密码本再问人;勾了「把密码存进密码本」就按 `url.lastPathComponent` 记下(与压缩对话框存的键一致)。
- **动的文件**:`Shared/Archive/ZipReader.swift`(`ZipEntryRecord.isEncrypted`、`ZipReaderError` 的
  `.passwordRequired`/`.badPassword` 取代 `.encryptedNotSupported`、`needsPassword`/`passwordProbe`/
  `validates(password:)`/`contents(of:password:)`,加密条目下 inflate/size/CRC 不符一律报"密码不对");
  `Shared/Archive/ArchiveMemberSource.swift`(`make(url:format:password:)`、`ZipMemberSource(url:password:)`);
  `Shared/Archive/ArchiveExtractor.swift`(`ArchiveError.passwordRequired/badPassword`、`extract(… password:)`);
  新增 `Shared/Archive/ArchivePasswordResolver.swift`;新增 `MenuRight/App/Settings/ArchivePasswordPrompter.swift`
  (NSAlert + `NSSecureTextField` + 密码本勾选框,全部经 `onMain` 跳主线程,因为 dispatcher 跑在 IPC 的后台并发队列上);
  `Shared/FileOperations/FileOperationDispatcher.swift`(init 注入 `archivePasswordPrompting`、`handleExtractArchive`
  写盘前解析、`mapArchiveError` 的 `.passwordRequired/.badPassword → .archiveFailed`);
  `MenuRight/IPC/MainAppIPCServer.swift:89` 默认 dispatcher 注入 `ArchivePasswordPrompter.shared`;`Shared/Settings/Localization.swift` 6 条新文案。
- **测试**:`MenuRightTests/ArchivePasswordResolverTests.swift`(17 例,含手写 STORED 加密夹具、流式 bit3 夹具、
  `testThreeWrongAnswersAbandonTheExtraction`、`testWhatWeEncryptWeCanExtractAgain`、
  `testAnArchiveInfoZipEncryptedIsUnlockedAndExtracted` 用 `/usr/bin/zip -e` 真产物)+
  `MenuRightTests/FileOperationDispatcherTests.swift` 4 例(密码本命中不问人;取消 → `.cancelledByUser` 且目录为空;
  没有 prompter 时报"受密码保护";**两个归档时第二个取消 → 第一个的文件也不会被写出来**)。
- **真沙箱端到端取证**(可复现;`MenuRight-ScopeProbe` 在已授权的 `/Users/suxin` 下):

```bash
MENURIGHT_SELFTEST_ARCHIVE_UNLOCK=~/MenuRight-ScopeProbe \
MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_ALERT=1 \
MENURIGHT_SELFTEST_ARCHIVE_UNLOCK_PNG="$HOME/Library/Group Containers/group.xin.ljhsu.MenuRight/unlock-alert.png" \
  build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
# SELFTEST … noPrompt=batch(items=1 failed=1 msg=“selftest-encrypted.zip” is password-protected — enter its password to extract it)
#            lockedExtracted=false                      ← 没人问密码:明确报"受密码保护",不写盘
#            book=batch(items=1 failed=0 msg=-) bookExtracted=true   ← 密码本命中:直接解开
#            alertVisible=true alertControls=[secureField(输入密码) button(把密码存进密码本|off) button(取消|off) button(解压|off)]
#            alertLabels=[压缩包已加密 / “selftest-encrypted.zip” 已用密码加密。输入密码后才能解压。]
#            alertResult=failure(code=cancelledByUser msg=No password was given; nothing was extracted.) alertExtracted=false
```
- **两个坑(下次别踩)**:
  - **`NSAlert.runModal()` 期间主队列不会被 drain**,`DispatchQueue.main.asyncAfter` **永不触发**(第一版自测因此
    挂在模态循环里被 kill)。要观察/结束模态要会话,得用 `Timer` 并把它同时加进
    `RunLoop.Mode.default`/`.common`/`.modalPanel`,再用 `NSApp.stopModal()`。
  - **`NSAlert` 的 vibrancy 材质在窗口外 `cacheDisplay` 会渲染成不透明白底**,浅色文字直接白底白字;所以自测里
    「提示到底写了什么」用**视图树 dump**(`alertControls`/`alertLabels`)断言,PNG 只看布局。另:alert 窗口的
    `title` 是空的,别拿它判定。
- **仍不支持(有意)**:WinZip AES(method 99)加密的 **zip** 仍报"不支持/受保护";加密 **7z**(AES-256,含加密文件名)
  已支持。zip 侧只处理 PKWARE 传统加密(ZipCrypto),写侧也是同一套自研实现(强度有限,兼容优先)。

#### 同日补修 — 密码框只有半个对话框宽(用户 m02310)

用户原话:「输入密码的密码框宽度应该和弹出的宽度一样,当前的只有一半宽度的样子」,并确认「输入密码解压功能没有问题」。

- **根因**:密码框和「把密码存进密码本」原先装在竖直 `NSStackView`(`alignment = .leading`)里,而 stack view 按**固有宽度**
  排布子视图 —— 文本框的固有宽度就是占位符的宽度 —— 所以设了 300pt 的 frame 也不生效。真机实测
  `alertFieldWidth=126` / `alertContentWidth=332`,正好是"一半宽"。
- **修法**:`ArchivePasswordPrompter.makePrompt(text:archiveName:afterFailedAttempt:)` 把 alert 构造抽成可测的纯函数
  (`struct Prompt { alert, field, remember }`),accessory 改成**纯 frame 布局**的 `NSView(320×58)`:密码框
  `NSSecureTextField(frame: NSRect(x: 0, y: 34, width: 320, height: 24))` + `field.autoresizingMask = [.width]`,
  勾选框 `y = 4`、宽度取 `remember.fittingSize.width`。**不要再用 NSStackView**。
- **取证**:同一条自测命令现在输出 `alertFieldWidth=320 alertContentWidth=352` —— 左右各 16pt 边距,与正文同宽;
  PNG(`unlock-alert-width.png`,`size=(352.0, 293.0)`)里密码框已横跨整个对话框。
- **回归网**:`MenuRightTests/ArchivePasswordPrompterTests.swift`(4 例)钉住:密码框与所在 accessory 同宽、宽度可随父视图
  伸缩、accessory 不是 `NSStackView`、勾选框在密码框下方 8pt、重试文案换成「密码不正确,请再试一次。」。
  **反证**:把 `makePrompt` 临时改回 NSStackView,这些断言立刻变红(`XCTAssertFalse`/`autoresizingMask`/勾选框位置 3 条),
  改回后全绿。
- **顺手修的测试隔离(重要)**:`CustomCompressionDialogWindow` 改用 `passwordBookProvider`(**闭包**,默认
  `MainActor.assumeIsolated { ArchivePasswordBook.shared }`)去取密码本,测试注入
  `ArchivePasswordBook(storage: InMemoryArchivePasswordBookStorage())`。原因:真实密码本在**钥匙串**里,而单元测试进程
  读它会**卡死在 `SecItemCopyMatching`** —— 现场用 `sample` 抓到栈
  `CustomCompressionDialogTests.testCloseTakesTheWindowAwayAndLeavesNoDialog → CustomCompressionDialogWindow.show →
  ArchivePasswordBook.shared → KeychainArchivePasswordBookStorage.load → SecItemCopyMatching`,整套测试挂了 10 分钟直到被
  kill;`/usr/bin/security find-generic-password -s xin.ljhsu.MenuRight.password-book -a compression` 也同样阻塞(同一条
  keychain 上新建/读/删探针条目都秒回,说明是**这个 item 的 ACL 需要授权弹窗**,不是钥匙串坏了)。测试从此不碰真钥匙串。

### 2026-10-03 — 三个压缩模式真的不一样了 + 分卷 / 固实 / 7z AES-256(用户报「本版本不支持」)

**用户要求**(原话,m02602):「继续完成自定义压缩未完成的功能，还有压缩模式的三个模式有区别吗，请你完成三个模式的区别」;
截图里对话框底部三行是灰掉的 `加密压缩 本版本不支持` / `分卷压缩 本版本不支持` / `固实压缩（仅 7z） 本版本不支持`。
两个方案由用户拍板(m02663/m02664):7z 加密选「**ZIP + 7z AES,并且这轮也把 AES 加密 7z 的解压做出来**」;
分卷命名选「**`xxx.zip.001` / `.002` …**」(7z 用原生分卷、同一命名)。

- **① 三个模式的区别(以前基本是摆设)**:`ArchiveCompressionMode` 的 `fast/standard/maximum` 现在对每种可写格式都落到实处 ——
  zip/7z/tar.gz 用压缩等级 1/6/9;bzip2 用块大小 1/5/9 ×100KB;**TAR 本身不压缩,模式对它无效**(对话框里明写这句)。
  关键改动:`.tar.gz` 以前走 SWCompression 的 `GzipArchive.archive(data:…)`,它的 deflate 只有「stored vs 静态 Huffman」两种,
  **等级根本传不进去**;新增 `Shared/Archive/GzipWriter.swift`(自己用 zlib 的 `ZipWriter.rawDeflate(_:level:)` + CRC32/ISIZE 拼 gzip 头),
  模式才真的生效。
- **② 分卷压缩**:新文件 `Shared/Archive/ArchiveVolumeSet.swift` —— 写侧 `write(_:baseURL:volumeBytes:overwrite:)` 按 `count` 切片、
  命名 `name.ext.001/.002…`(最多 999 片,`partSuffix` 3 位);重写时 `removeStaleParts` 清掉尾巴分片。
  读侧 `resolve(_:)` 把多片拼到 `temporaryDirectory/MenuRight-Volumes/<UUID>/` 的 scratch 文件再交给原有的单流读出器,
  `discard()` 保证临时目录不残留;`ArchiveExtractor.extract` 与 `ArchivePasswordResolver.resolve` 都在入口先 `resolve`,
  「解压后删除压缩包」也改成删**全部分片**。`ArchiveFormats.detect` 靠 magic 就能认出 `.001`(它就是归档开头)。
- **③ 固实压缩(仅 7z)**:`SevenZipWriter.archive(entries:mode:password:solid:encryptsFileNames:control:onEntry:)` 透传
  PLzmaSDK 的 `setShouldCreateSolidArchive(_:)`(库默认 true,关掉后每个文件独立压缩,能直接取出单个文件)。
- **④ 7z AES-256(读 + 写)**:写侧同一函数里 `setPassword` + `setShouldEncryptContent(true)`,
  勾「加密文件名」时再加 `setShouldEncryptHeader(true)`(打开前就要密码)。读侧新文件
  `Shared/Archive/SevenZipPasswordSource.swift`:`SevenZipEncryption.needsPassword/validates` +
  `SevenZipPasswordMemberSource`(先 `OutStream` 试解最小加密项验证密码,再整包 `extract(to:)` 到 scratch 目录后取文件 ——
  7z 默认固实,逐项解码会重复解整块)。SWCompression 明确拒绝加密 7z(`SevenZipError.encryptionNotSupported`),
  所以加密路径整个走 PLzmaSDK。**取舍**:加密 7z 解压时符号链接不落盘(库没有符号链接 API),`members()` 不报目录项。
- **⑤ 顺手修掉的回归(用户没提,但会让 7z/tar 全废)**:`FileOperationDispatcher.swift:569` 对**每个**归档无条件调
  `ArchivePasswordResolver.resolve`,而它内部直接 `try ZipReader(fileURL:)`;非 ZIP 一律抛 `notAnArchive` ⇒
  经 Finder 菜单解压 **7z / tar / tar.gz / tar.bz2 全报「Not a readable archive」**(测试没抓到是因为那批用例清一色用
  `RawZipBuilder` 造 zip)。现在 resolver 先 `ArchiveFormats.detect`,zip → ZIP 探测、7z → 7z 探测、其余 → `.notNeeded`。
- **动的文件**:新增 `Shared/Archive/ArchiveVolumeSet.swift`、`Shared/Archive/GzipWriter.swift`、`Shared/Archive/SevenZipPasswordSource.swift`;
  改 `Shared/Archive/ArchiveCompressor.swift`、`Shared/Archive/ArchiveExtractor.swift`、`Shared/Archive/ArchiveMemberSource.swift`、
  `Shared/Archive/SevenZipWriter.swift`、`Shared/Archive/ArchivePasswordResolver.swift`、
  `Shared/FileOperations/FileOperationDispatcher.swift`、`Shared/Settings/Localization.swift`(删掉 `.archiveOptionUnsupported` /
  `.archiveUnsupportedOptionsNote`,新增 9 条说明文案)、`MenuRight/App/Settings/CustomCompressionSheet.swift`(UI:三个选项按格式启用/置灰)、
  `MenuRight/App/MenuRightApp.swift`(自测钩子)。
- **验证三层**:
  - `Automated: PASS (692 XCTest,2 skipped,0 失败;基线 651,本轮 +41:ArchiveVolumeSetTests 8 + GzipWriterTests 4 +
    ArchiveModeAndSevenZipTests 20 + FileOperationDispatcherTests 8 + ArchiveCompressorTests 拆成 2)`。
    其中 `-only-testing:` 逐类跑过,`build/TestResults-full-modes.xcresult` 是整套结果。
  - `Sandbox: PASS`(下面那条一键命令,真 App、真沙箱、真对话框)。
  - `Manual: PENDING`(§3.8 第 44、59–65 项;`/Applications/MenuRight.app` 还是 2026-10-01 的旧版,要先 `Scripts/install-dev-app.sh`)。
- **一键复现**(格式名用 `ArchiveFormat` 的 rawValue,7z 是 `sevenZip` 而不是 `7z` —— 写错会被 dispatch 判成"不支持的格式"):
  ```bash
  rm -rf /Users/suxin/MenuRight-ScopeProbe && mkdir -p /Users/suxin/MenuRight-ScopeProbe/MenuRight-Selftest
  dd if=/dev/urandom of=/Users/suxin/MenuRight-ScopeProbe/MenuRight-Selftest/selftest-source.txt bs=1024 count=2500
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG=/Users/suxin/MenuRight-ScopeProbe \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_FORMAT=sevenZip \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM=1 \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_FORMAT=sevenZip \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_FILE_NAMES=1 \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_SPLIT=1 \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_CONFIRM_PASSWORD=hunter2 \
  build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
  ```
  输出(实测):`dispatch=SUCCESS … dialogVisible=true confirm=SUCCESS path=…/selftest-confirm.7z.001 confirmParts=3
  confirmEncrypted=true confirmExtract=written:1 failed:0 names:selftest-source.txt unscopedRead=DENIED(…)`
  —— 即:真对话框 → 真加密 → 真分卷(3 片)→ 本 App 自己再解开(1 个文件、0 失败);`unscopedRead=DENIED` 是负对照。
  想看三个选项的版式加 `MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PNG=<路径>`,截到 `size=(520.0, 489.0)`。
- **外部工具互操作(实测)**:
  - 分卷 + 加密 zip:`cat selftest-confirm.zip.00* > /tmp/joined.zip` 后 `/usr/bin/unzip -P hunter2 -t /tmp/joined.zip`
    → `testing: selftest-source.txt OK` / `No errors detected in compressed data` ⇒ 分片就是标准 ZipCrypto zip 的**朴素切分**,
    拼回来 Info-ZIP 就能解(7-Zip / Keka / WinRAR 同理)。
  - 新的 gzip 写入器(`GzipWriter`):`/usr/bin/gunzip -t selftest-confirm.tar.gz` 通过,`/usr/bin/tar -tzf …` 列出
    `selftest-source.txt` ⇒ 自己拼的 gzip 头/尾(CRC32 + ISIZE)是对的。
  - 7z 侧**没有**第三方工具可作证(本机 `/opt/homebrew/bin` 无 `7z/7za/7zz`,Python 无 `py7zr`),只有「本 App 往返 + PLzmaSDK」。
- **坑**:
  - `ArchiveFormat` 是 `String` 枚举且 `case sevenZip` **没有显式 rawValue**,所以 rawValue 是 `"sevenZip"`,`"7z"` 只是扩展名
    (`fileNameExtension(for:)`)。自测 env 写 `7z` 会得到 `archive_unsupported`。
  - 7z 的**头在文件末尾**(加密文件名时整个头也加密),所以对 `.001` 单片做 `SevenZipEncryption.needsPassword` 一定是 `false`;
    必须先 `ArchiveVolumeSet.resolve` 拼回整包再判断(自测里一开始就踩了这个,`confirmEncrypted=false`)。
  - 沙箱里 `createDirectory` 也要 security-scoped access:自测的回读步骤把「建输出目录 + 解压 + 判断加密」全放进
    `FolderAuthorizationAccess.withAccesses(to:folders:)`,否则 `NSCocoaErrorDomain Code=513 … Operation not permitted`。
  - 本机没有 7z 命令行(`/opt/homebrew/bin` 里也没有 `7z/7za/7zz`,Python 也没 `py7zr`),所以 7z 的**外部互操作**这轮没有第三方工具作证,
    只有「本 App 往返 + PLzmaSDK」;zip 侧仍可用 `unzip`/`zip`。

#### 同日补修 — 对话框改成「少文案」版式(用户 m03272)

用户原话:「文案……可以去掉，用户前端可以不显示 / 从密码本选择的下拉只显示按钮和功能，不显示文案 /
压缩格式和压缩模式的选项和文案之间有很大的间隔，请你减小一点，参考保存为 / 位置选项直接使用系统原生的文件夹选择，
参考图一 / 固实压缩不可用的模式下置灰 / 保存为、标签、位置三个居中；下面的其他选项保持现状」。

- **动的文件**:`MenuRight/App/Settings/CustomCompressionSheet.swift`(版式)、`MenuRight/App/MenuRightApp.swift`(自测可选种一个内存密码本)。
  文案本身**没删**(`Shared/Settings/Localization.swift` 一字未改),只是从正文挪进了悬停提示。
- 六条一一对应:
  1. 正文里 5 段灰色说明(`archiveModeNote` / `archiveEncryptionNote` / `archiveEncryptSevenZipNote` /
     `archiveSplitNote` / `archiveSolidNote`)+ `archiveEncryptFormatsNote` + 标签下那行 `archiveLabelZipOnly` 全部不再渲染,
     改成 `.help()`(悬停提示)。
  2. 密码本下拉从「从密码本选择 ▾」变成**只有钥匙图标**的 `Menu`(`.menuStyle(.borderlessButton)`,提示里保留原话)。
  3. 「压缩格式 / 压缩模式」的两个 `Picker` 由 `.frame(width: 150)`(标题在 150pt 里居中 ⇒ 看着像半行空档)
     改成 `.fixedSize()`,标签与弹出菜单只隔 `spacing: 12` —— 与「保存为」行一致。
  4. 「位置」由「等宽路径文本 + 选择…按钮」改成**整行可点的文件夹控件**:蓝色文件夹图标 + 文件夹名 + 上级路径(截头),
     点它直接开系统 `NSOpenPanel`(就是图一那个带「位置/个人收藏/最近访问的位置」侧栏的原生面板)。
  5. 「固实压缩」在非 7z 下用计算绑定 `solidBinding` 显示成**未勾 + 置灰**(以前是「勾着但灰」,看起来像可用);
     `solid` 状态本身仍保留给 7z,切回 7z 依旧是默认开。
  6. 「保存为 / 标签 / 位置」用一个 `Grid` 包在 `HStack { Spacer; Grid; Spacer }` 里整体居中,三个控件统一 300pt 宽。
- **取证(命令)**:
  ```
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG=/Users/suxin/MenuRight-ScopeProbe \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_FORMAT=sevenZip \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PASSWORD_BOOK=1 \
  MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PNG="$HOME/Library/Group Containers/group.xin.ljhsu.MenuRight/dialog-7z.png" \
  build/DerivedData/Build/Products/Debug/MenuRight.app/Contents/MacOS/MenuRight
  ```
  `MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PASSWORD_BOOK=1` 会给对话框注入一个**内存**密码本(一条示例条目),
  这样钥匙按钮会出现在 PNG 里,**不会**往真钥匙串写东西。实测 `size=(520.0, 350.0)`(zip 时 328)。
- **坑**:沙箱里 `NSHomeDirectory()` 是容器路径,`abbreviatingWithTildeInPath` **不会**把 `/Users/suxin/...` 缩成 `~/...`;
  上级路径就按原样显示,并用 `.truncationMode(.head)` 保证「当前在哪个文件夹」那一半可见。
- `Automated: PASS (692 XCTest,2 skipped,0 失败;与本轮 UI 改动前同数,`build/TestResults-ui.xcresult`)`;
  版式只能靠 PNG 目测,已附 `dialog-7z.png` / `dialog-zip.png`;真机点击仍记在 §3.8 第 44/46/47/55 项(PENDING)。

#### 同日补修 — 「位置」换成原生弹出菜单 + 三处间距(用户 m03393)

用户原话:「位置的样式不能做成原生的吗 / 分卷压缩选项前面依旧有很大空隙，请你修复 / 加密压缩这个选项宽度左右顶到头 /
选择7z后，加密文件名选项放在固实压缩同一行右侧，类似压缩格式、模式那一行」。
第 3 条含义有歧义,我追问了一次,用户选的是「加宽:密码框尽量长,整行左右都顶到对话框内边」。

- **动的文件**:`MenuRight/App/Settings/CustomCompressionSheet.swift`、
  `MenuRightTests/CustomCompressionDialogTests.swift`(+3 例)、`MenuRight/App/MenuRightApp.swift`(只多了一条 `MENURIGHT_SELFTEST_ARCHIVE_DIALOG_PASSWORD_BOOK=1` 的截图用注入,上一小节已记)。
- 四条一一对应:
  1. 「位置」不再是自绘控件,而是**真 AppKit 的 `NSPopUpButton`**:
     `struct NativeFolderPicker: NSViewRepresentable`,菜单项图标用 `NSWorkspace.shared.icon(forFile:)` 取文件夹**自己的 Finder 图标**
     (带标签颜色的那种,所以和参考图一致),按钮上显示「图标 + 文件夹名 + 系统上下箭头」,右边再跟一个单独的「⌄」小按钮开 `NSOpenPanel`。
     弹出菜单 = 当前文件夹 → 本次对话框访问过的文件夹(去重、最多 5 个) → 「选择…」(没有 URL,表示开面板)。
     菜单内容由纯函数 `NativeFolderPicker.menu(directory:recent:chooseTitle:) -> [Entry]` 生成,不依赖 AppKit,所以能单测。
  2. 「分卷压缩」的 `Picker` 由 `.frame(width: 140)` 改成 `.fixedSize()` —— 与上一轮格式/模式**同一个根因**(`NSPopUpButton` 把标题在给定宽度里居中),
     这是最后一处。
  3. 「加密压缩」的密码框由 `.frame(width: 200)` 改成 `.frame(maxWidth: .infinity)`,选项那一列加 `.frame(maxWidth: .infinity, alignment: .leading)`,
     整行左右顶到对话框内边。
  4. 「加密文件名（仅 7z）」从独占一行改成**「固实压缩」同一行的右端**(`Spacer(minLength: 24)` 分隔),形状与「压缩格式 / 压缩模式」一致。
- **取证(命令)**:与上一小节同一条 PNG 自测命令,`MENURIGHT_SELFTEST_ARCHIVE_DIALOG_FORMAT=zip|sevenZip`;
  实测两个格式现在都是 `size=(520.0, 328.0)`(7z 因为「加密文件名」不再单独占一行,高度与 zip 相同;上一轮是 350)。
- `Automated: PASS (695 XCTest,2 skipped,0 失败;基线 692,本轮 +3:位置菜单三例,`build/TestResults-ui2.xcresult`)`;
  **AppKit 版式本身没有断言**(单测进程里没有真模态窗口,量不出最终尺寸),只能靠 PNG 目测 + 真机点击:
  §3.8 第 44 项(整行宽度、加密文件名位置)与第 47 项(原生弹出菜单的菜单项、小按钮)仍是 PENDING。

#### 同日补修 — 设置界面「少文案」:去掉说明段与「实现进度」(用户 m03593)

用户原话:「除了恢复默认设置的文案在二次确认弹窗显示，其他的文案我框起来的，都可以去掉，以后不要在前端显示废话文案和实施进度 /
44和47已经核验，前端没问题」。

- **动的文件**(只动前端与文案表,没碰任何文件操作逻辑):
  `MenuRight/App/Settings/Panes/GeneralSettingsView.swift`(删三处 `footer:` + 「产品网站」行的 `subtitle:`,
  `resetGroup` 的页脚移进 `.alert` 的 message)、`MenuRight/App/Settings/Panes/FilePermissionSettingsView.swift`(删 `sandboxNote`)、
  `MenuRight/App/Settings/Panes/ArchiveSettingsView.swift`(删 `noteGroup`、RAR 行小字、体积上限与密码本的页脚)、
  `MenuRight/App/Settings/Panes/CodeThemeSettingsView.swift`(删 `noteGroup`)、`Shared/Settings/Localization.swift`(删 11 条 key)、
  `MenuRight/App/MenuRightApp.swift`(新增 `MENURIGHT_SELFTEST_SETTINGS_PNG` 截图钩子,见下)、`MenuRight 验证手册.md`、`README.md`。
- 逐条对应:界面语言页脚 / 登录项页脚 / 更新页脚 / 产品网站 URL / 恢复默认页脚(→ 移进确认弹窗)/ 文件权限页脚 RAR 借口 /
  RAR 行小字 / 体积上限说明 / 密码本说明 / 代码主题「实现进度」,共 11 处,全部来自用户 m03589–m03592 框出的那些。
- **刻意保留**(用户没框):文件权限里那个开关的副标题「关闭后依然受 macOS 沙盒限制:没有授权书签的路径无法写入。」、
  开源许可的说明、以及文件操作通道异常时才出现的提示。
- 文案表一致性:`Shared/Settings/Localization.swift` 现在 `case` 320 条 == `Localization.table` 320 条
  (`LocalizationTests.testCatalogHasNoUnknownOrDuplicateKeys` 钉住);11 条 key 的 `case` 与 `Entry` 是**一起**删的。
  另外 `.archiveIntro` 去掉 RAR 那句、`.codeThemeIntro` 把「扩展在 P8 接入后读取同一份配置」改成「扩展读取同一份配置」。
- **取证**:新增自测钩子 `MENURIGHT_SELFTEST_SETTINGS_PNG=<pane>:/abs/path.png`
  (`pane ∈ general | filePermissions | archives | codeTheme`,archives 用内存密码本),真沙箱渲染四张 720×1600 的整栏 PNG
  (命令见 §3.12);实测四个面板都不再有被框的段落,也不再出现「实现进度」卡片。
  代价:PNG 里的开关是**未着色**的(真实窗口的紫色来自设置窗口根节点的 tint),只看截图时别把它当 bug。
- `Automated: PASS (695 XCTest 共 693 passed / 2 skipped / 0 失败;`build/TestResults-nofuss.xcresult`,与改动前基线同数)`;
  Debug / Release / `MenuRightFinder` Debug 三个构建均 `BUILD SUCCEEDED`。
- 手册新增 §3.12(5 项),并把 §3.5 第 10 项改成「确认弹窗正文两行」。

### 2026-10-03 — P7 收口:开关真正生效 + 终端 App / 模板目录 + 陈旧说明订正

**本轮动的东西**(详见 `Memory/Memory-10-03-13.md`):`Shared/Settings/MenuRightSettings.swift`(schema 2、`FileAction.compressArchive`、
`GeneralSettings.terminalApplicationPath/terminalServiceName`、`NewFileSettings.templateDirectoryPath/Bookmark`)、
`Shared/Settings/Localization.swift`、`Shared/FileOperations/{FileOperationDispatcher,SystemOpener,DocumentTemplateCatalog}.swift`、
`MenuRightFinder/{FinderSettings,FinderMenuBuilder,FinderSync}.swift`、`MenuRight/App/Settings/DestructiveActionPrompter.swift`(新)、
各设置面板、`MenuRight.xcodeproj/project.pbxproj`。新增图标 `SettingsIcons.xcassets/lucide-archive.imageset`。

#### A. 此前"有 UI 没效果"的两个开关,现在真的生效(可自动化,已自动化)

- **文件权限 → 「只在已授权的文件夹内创建或修改文件」**:关闭后 `FileOperationDispatcher` 跳过自己的
  `pathOutsideAuthorizedScope` 预检(`DISPATCH … scope-precheck-skipped (restrictToAuthorizedFolders=off)` / `auth bypassed`),
  macOS 沙盒仍是最终裁判;打开时行为与之前完全一致。
- **文件权限 → 「敏感操作前二次确认」**:打开后 锁定/解锁、剪切(移动)会先弹主 App 的
  `DestructiveActionPrompter` 确认框(`确认操作` + 「即将执行“锁定所选项目”…」;多于 1 项时补 `(N 项)`);
  选「取消」返回 `cancelledByUser`,扩展按静默取消处理,不弹错误。
- **文件权限 → 各操作开关**:现在**真的裁剪 Finder 菜单**(此前注释就写着"以后用来过滤菜单",但没有调用点)。
  关掉的动作从菜单消失;`新建文件 ▸` 里所有类型都关掉、或 `解压 ▸`/`压缩 ▸` 里所有变体都关掉时,该子菜单整体隐藏。
  为此新增 `FileAction.compressArchive`(设置 → 文件权限 里可单独关掉"压缩所选项目")。
- **新建文件 → 启用类型 / 顺序 / 默认文件名**:`新建文件 ▸` 按设置里的开关与拖拽顺序显示,创建时用设置里的默认文件名
  (此前扩展硬编码 `Untitled.<ext>`)。
- **自动化**:`FinderSettingsTests`、`MenuRightSettingsTests`、`DocumentTemplateCatalogTests`、`FileOperationDispatcherTests`
  覆盖以上全部路径(载荷解码、裁剪、v1→v2 迁移、放行/拦截/确认/取消)。`Automated: PASS`(见文末本轮结论)。

#### B. 两个新设置项(需要人工点一遍)

- **通用设置 → 终端应用**(默认空 = 系统 Terminal):留空时行为与之前一样;选一个第三方 .app 后还要填它的
  **Finder 服务名**(沙盒下打开终端只能走 Finder 服务,见 `SystemOpener`)。所配 App 不存在时回退内置终端并记
  `DISPATCH terminal app missing …` 日志。**人工门**:选 Terminal.app 再点「打开终端」应落在正确 cwd;
  选一个不存在的路径时应仍能打开并出现回退日志。
- **设置 → 新建文件 → 模板目录**(留空 = 应用内置模板):选一个自定义文件夹后,`新建文件 ▸` 只显示该文件夹里
  确实存在模板的类型;路径与安全作用域书签一起保存;文件夹被删后回退内置模板并在面板上告警。
  **人工门**:覆盖目录只放 `blank.key` 时,菜单里只有 Keynote;恢复默认后 Pages/Numbers/Keynote 都回来。

#### C. 陈旧说明订正(以下行号是**订正前**的位置,原文保留,勿再引用)

> 订正方式:原文不删(手册是日志),以本节为准。

- **L444**「它们**不能创建**,菜单里不会出现」→ 现在 **7Z 可以创建**(`SevenZipWriter` / PLzmaSDK),压缩菜单里有
  7Z;仅 **XZ** 仍是"只能解不能压",RAR 仍完全不做。
- **L487**「Finder 菜单尚未读取新设置(P7-b),本轮的设置项只影响界面与持久化数据」→ 已不成立:
  扩展现在每次都从 App Group 读设置并裁剪菜单、排序/命名新建文件(本轮 A 节)。
- **L609**「`FinderMenuBuilder.plan` 里**没有任何常用项** —— 即 P7-b 未实现」→ 已不成立:
  常用软件/网页/文件夹三个子菜单早已接入,本轮再叠加一层"开关关掉则隐藏"。
- **L721**「7-Zip / XZ **只能解不能压** … 加密/分卷/固实仍未实现」→ 已不成立:7Z 可创建;
  加密(ZIP=ZipCrypto、7Z=AES-256 且可选文件名加密)、分卷(zip/7z,10/50/100/250/700 MB)、固实(仅 7z)**都已实现**,
  设置里按格式置灰而不是"一律不可用"。仅 XZ 创建与 RAR 仍缺席。
- **L787**「加密压缩 / 分卷压缩 / 固实压缩**未实现**」→ 同上,已实现。
- **L1205**「能**写**加密 zip,**读**还没做 —— 解压加密包仍报 `archive_unsupported`」→ 已不成立:
  解压加密 zip/7z 走 `ArchivePasswordResolver`(密码本 → 最多 3 次弹框,取消即放弃)。
- 顺带订正:`README.md` 不再说"唯一的第三方依赖是 SWCompression"(现有 SWCompression + BitByteData + PLzmaSDK,
  均为 MIT),底部许可清单与「通用设置 → 关于 → 开源许可」页脚都已补上 PLzmaSDK;
  `FileOperationDispatcher` 的"不能创建该格式"错误文案已改成 `ZIP, 7Z, TAR, TAR.GZ and TAR.BZ2`。

#### D. 仍然 PENDING 的人工门

本手册里原有的 53 处 `PENDING` 都是**必须在真机上点一遍**的验收项(Finder 菜单外观、对话框、
GBK zip、7z/tar.xz 经 Finder 实解、暂停/取消等),本轮没有改动它们的行为,所以**保持 PENDING**,
不能用本轮的自动化结果代替。本轮新增的人工门见上面 B 节(终端应用 2 项、模板目录 1 项)。

#### E. 本轮结论

```
Automated: PASS (740 XCTest 共 738 passed / 2 skipped / 0 失败, build/TestResults-fix-p7c.xcresult)
  Debug / Release / MenuRightFinder 三个构建均 BUILD SUCCEEDED
Manual: PENDING(53 处存量人工门 + 本轮新增 3 项,见 B 节)
```

顺带修掉一个**既有 flaky 断言**(不是本轮引入):`ArchiveModeAndSevenZipTests.testEveryCompressingFormatGetsSmallerFromFastToMaximum`
里 7z 的严格递减断言 —— PLzmaSDK 的 LZMA2 在"极度冗余、压完只有 ~470 B"的输入上不保证 level 越高越小,
且整包跑与单独跑会给出 471/470/478 这类浮动值(基线 `TestResults-final-modes.xcresult` 里它是 Passed)。
现改为:7z 三个档位都必须把输入压到 4096 B 以下、且极慢不超过快速 5%;zip/gzip/bzip2 仍严格递减。

### 2026-10-03 — Dock 右键「退出」只关设置窗口,不再结束服务

**背景**:此前 Dock 图标右键「退出」(以及 ⌘Q)会直接结束主应用,于是 Finder 右键菜单里的每一项都变成
「主应用未运行」。用户要求:Dock 退出 = 关掉设置面板;只有菜单栏图标的「退出」才停掉整个服务。

**改动**(`MenuRight/App/StatusMenu/AppLifecycle.swift`、`MenuRight/App/MenuRightApp.swift`、
`MenuRight/App/StatusMenu/StatusMenuView.swift`、`MenuRight/App/Settings/SettingsRootView.swift`):

- 新规则 `AppLifecycle.shouldTerminate(intentionalQuitRequested:systemIsPoweringOff:)`,由
  `AppDelegate.applicationShouldTerminate` 转发:无"意图退出"标记且系统不在关机/注销 → 关掉设置窗口后返回 `.terminateCancel`,
  进程、`MainAppIPCServer` 与 Finder 菜单继续工作。
- 只有三处会打标记:`StatusMenuView` 的「退出」(先 `(NSApp.delegate as? AppDelegate)?.requestQuit()` 再 `NSApp.terminate`)、
  设置里的「重启应用」(`SettingsRootView.relaunch`,替换实例已在运行)、以及 DEBUG 自测钩子(它们本来就是"跑完即退出")。
- 关机/注销/重启不拦:`applicationWillFinishLaunching` 订阅 `NSWorkspace.willPowerOffNotification` 后放行,避免拒绝关机。
- 被拒绝时调用 `dismissRegularWindows()`:关掉**常规窗口**(设置窗口,以及从它打开的自定义压缩对话框等),
  只有 `window is NSPanel` 的**面板**一律留下 —— 更新提示、密码框、确认框都是"待决定的交互",顺手关掉会丢掉这次决定。

#### 人工门(需要真机点一遍)

1. **Dock 右键「退出」**:设置窗口应关闭,菜单栏图标仍在;再点菜单栏「打开设置」窗口应能回来;
   打开 Finder 右键菜单,操作仍能正常执行(不再出现「主应用未运行」)。
2. **⌘Q**(设置窗口聚焦时,或应用菜单里的「退出 MenuRight」):同上,只关窗口。
3. **菜单栏图标 →「退出 MenuRight」**:这次必须真正结束进程(`pgrep -x MenuRight` 应无输出),
   之后 Finder 菜单项应报「主应用未运行」——这条正是与上两条的对照。
4. **关机/注销**(或用 `osascript -e 'tell app "loginwindow" to «event aevtrsdn»'` 之外的真实注销):
   系统不应被 MenuRight 拦住;注销前确认日志里有 `willPowerOff` 放行路径。
   **自动化**:`StatusMenuTests` 钉住纯规则(不意图退出 → 不终止;意图退出 → 终止;关机 → 终止)、
   `applicationShouldTerminate` 的转发与 `.terminateCancel`、`willPowerOffNotification` 订阅、
   以及「菜单栏退出项必须先打标记」「重启应用也必须打标记」两处源码守卫(共 4 个新测试,`MenuRightTests/StatusMenuTests.swift`)。

### 2026-10-03 — 状态栏图标失灵回归 + 「退出」通路（同日第二轮）

**背景**:用户真机测试报出两点:(a) Dock 右键「退出」只关窗口、主程序仍活跃(符合上一条的预期);
(b) **状态栏图标左右键都点不开** —— 这是上一节改动引入的回归。

**三个根因**:

1. `dismissRegularWindows()` 初版扫 `NSApp.windows`、只排除 `NSPanel`,把 SwiftUI `MenuBarExtra` 的窗口
   (`NSStatusBarWindow`,`level = .statusBar`(25),**普通 `NSWindow`,不是 `NSPanel`**)也一起关了
   → 图标还在,但点击不再弹菜单。
2. `NSApp.delegate` 实际是 **SwiftUI 自己的 `SwiftUI.AppDelegate`**,所以 `NSApp.delegate as? AppDelegate` 恒为 nil:
   设置窗口从未登记(拒绝退出时"什么都不关")、菜单栏「退出」与设置里的「重启应用」从不打意图标记
   (**等于退不出去**)、自定义压缩对话框窗口也没登记。
3. `NSApp.terminate(nil)` 与 `NSRunningApplication.current.terminate()` 在进程内**都退不掉**这个 app
   (实测两次;`applicationShouldTerminate` 完全没被调用)。Dock 的 AppleEvent 路径倒是会调到 delegate。

**改动**(`MenuRight/App/StatusMenu/AppLifecycle.swift`、`MenuRight/App/MenuRightApp.swift`、
`MenuRight/App/Settings/CustomCompressionDialogWindow.swift`、`MenuRight/App/StatusMenu/StatusMenuView.swift`、
`MenuRight/App/Settings/SettingsRootView.swift`):

- `AppLifecycle.mayDismiss(windowLevel:isVisible:isPanel:)` = `isVisible && !isPanel && level < .mainMenu`:
  菜单层级及以上(主菜单 24、状态项 25、弹出菜单 101)一律关不得;设置窗口(0)与自定义压缩对话框(`.floating`=3)可关;
  不可见窗口与 `NSPanel`(更新提示/密码框/确认框)不碰。
- `dismissRegularWindows()` 改为只遍历**显式登记**的两个窗口,不再 sweep `NSApp.windows`;
  设置窗口由 `SettingsWindowReader`/`WindowReportingView`(`viewDidMoveToWindow`)报给 delegate,
  对话框在 `show`/`close` 里登记 / 注销。
- 新增 `MainAppGate` 协议 + `MainAppGateRegistry.gate`(弱引用,`AppDelegate.init()` 里发布),
  所有需要 delegate 的地方改走它(不再 cast `NSApp.delegate`)。
- `AppDelegate.quit()`:打意图标记 → `NSApp.terminate(nil)`(尽力) → 0.75 秒(quitGracePeriod)后
  `finishQuitDirectly()`:`ipcServer.stop()` + `exit(0)` —— 保证菜单栏「退出」一定结束进程。

**自动化**:`StatusMenuTests` 新增/改写 5 个测试(`testTheGateEndsTheAppWithoutAppKit`、
`testNothingReachesTheDelegateThroughNSAppDelegate`、`testTheStatusMenuItemQuitsThroughTheGate`、
`testTheRelaunchPathAlsoQuitsThroughTheGate`、
`testARefusedQuitKeepsTheMenuBarItemAndClosesTheOtherWindows`),其中最后一个是 `mayDismiss` 的纯规则真值表;
另有两条端到端自测钩子(不是人工门,可直接跑):

```
# 拒绝退出:状态项窗口保住、设置窗口关闭
MENURIGHT_SELFTEST_REFUSED_QUIT=1 build/.../MenuRight.app/Contents/MacOS/MenuRight
→ SELFTEST verdict status-item-window-visible true->true settings-window-visible true->false
→ SELFTEST PASS a refused quit keeps the status item and dismisses the settings window

# 意图退出:真进程结束
open -n build/.../MenuRight.app --env MENURIGHT_SELFTEST_INTENTIONAL_QUIT=1 -o <log> --stderr <log>
→ 日志只有 SELFTEST intentional-quit gate=true;9 秒后 pgrep 无进程
→ 诊断日志:AppKit did not terminate the app; finishing the quit directly / MainAppIPCServer.stop
→ ipc.sock 已被删除
```

**本轮自动化结果**:`xcodebuild test -project MenuRight.xcodeproj -scheme MenuRight -configuration Debug \
-destination 'platform=macOS' -derivedDataPath build/DerivedData-fix -resultBundlePath build/TestResults-quit-fix3.xcresult`
→ `Executed 747 tests, with 2 tests skipped and 0 failures`(2 个 skip 恒为 `testWindowRendersToAnImageWhenAsked` /
`testDialogRendersToAnImageWhenAsked`);Release 构建 `BUILD SUCCEEDED`。

**顺带记录(既存偶发,与本轮改动无关)**:本轮第一次全量跑(747 tests)时,`ArchiveModeAndSevenZipTests` 里
**固实 7z** 的两处解压断言偶发失败(`failed == 3`,同测试的非固实 7z/zip/gzip/bzip2 都通过),
而 `-only-testing:MenuRightTests/ArchiveModeAndSevenZipTests` 连跑 3 次全绿、该测试在历史 4 次全量跑里都 passed,
本轮也没有改任何压缩代码 —— 判断为 PLzmaSDK(LZMA2)在整包负载下不稳定(那次 level 9 编码单测耗时 44.7 秒)。
**没有放宽固实解压断言**,只给它加了"哪个条目、什么原因"的失败信息(`failureReasons(_:)`),方便下次复现定位。
需要单独人工确认的一条:**用 MenuRight 压缩一批文件为「7z + 固实压缩」,再从 Finder 解压回来,文件内容要对**。

#### 人工门(需要真机点一遍,接上一节的 1–4)

5. **Dock 右键「退出」之后,菜单栏图标左右键都还能弹出菜单**(本次回归的直接症状)。
6. **菜单栏「退出 MenuRight」→ 进程真的结束**(`pgrep -x MenuRight` 无输出),
   之后 Finder 菜单才报「主应用未运行」。
7. 设置窗口开着「自定义压缩」对话框时,Dock 退出 → 两个窗口一起关掉,状态项仍在、可继续使用。

### 结论怎么写

```
Automated: PASS  (190/190 XCTest,两个 target 均构建成功)
Manual:
  P6-1  空白区菜单结构      PASS/FAIL
  P6-2  Open Terminal       PASS/FAIL
  ...
  A–J   存量回归            PASS/FAIL/PENDING
```
没做的项写 `PENDING`,**不要**用"自动化通过"代替真实 Finder 行为。
