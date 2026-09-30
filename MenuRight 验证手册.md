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
| G | 退出 MenuRight 后右键 | 几秒内弹 "Menu Right not running",**Finder 不卡死**(H1) |
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
| 8 | 代码主题:切 Monokai / Dracula,调字号,开关行号 | 预览区随主题换配色、字号与行号立即变化 | 预览不变色 |
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
| 10 | 通用设置最底部「恢复默认设置…」 | **没有卡片底色**;按钮文字是**警告色(红)**;确认弹窗后所有设置回默认,已授权文件夹不受影响 | 仍是灰字 → 颜色没写到 label 上(`role`/`tint` 在 macOS bordered 样式下不生效) |
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
| 41 | `压缩 ▸` 里四项各点一次 | 分别生成 `<名>.zip` / `.tar` / `.tar.gz` / `.tar.bz2`,系统双击都能打开 | `DISPATCH compressItems SUCCESS … format=…` |
| 42 | 打开 设置 → 解压缩管理,关掉某格式后右键对应类型 | 该格式**不再出现** `解压 ▸` | `preview-finder-menu.sh` 的 favorites/availability 行 |
| 44 | `压缩 ▸` → `自定义压缩…` | 主 App 前置并弹出对话框:保存为/标签/位置/压缩格式/压缩模式;加密·分卷·固实三个开关**置灰且旁边写明原因** | 日志 `ARCHIVE dialog presented` |
| 45 | 对话框里改「保存为」和「压缩模式(极限)」后保存 | 生成的文件名与所填一致;系统 `unzip -z` 能看到「标签」;极限压缩产物不大于快速压缩 | `ARCHIVE dialog SUCCESS path=…` |
| 46 | 对话框里选「压缩格式 = TAR.BZ2」 | 「标签」输入框变灰并提示仅 ZIP 写入 | — |
| 47 | 对话框里点「位置 → 选择…」换目录 | 压缩产物出现在新选的目录 | — |
| 48 | `解压 ▸` → `解压到指定位置…` | 弹出目录选择框;选中的目录里出现解压结果 | `DISPATCH extractArchive DONE` |
| 49 | 上一步在选择框里点「取消」 | **不解压任何东西**,不产生半成品 | 日志 `extractArchive CANCELLED` |
| 43 | 解压一个加密的 zip | 明确报"受密码保护、本版本不支持",不是 CRC 之类的困惑错误 | `archive_unsupported` |

> **安全规则(自动化已覆盖,人工只需确认"能正常用")**:`../`、绝对路径、反斜杠、NUL、`C:` 形式
> 一律拒绝;符号链接条目**不会**被创建;声明的解压体积超过设置上限时**在写盘前**整体拒绝;
> 逐条校验 CRC;永不覆盖正在读取的那个压缩包。
> 一键复现:`Scripts/verify-archive-roundtrip.sh`(含一个恶意包的拒绝验证)。

## 4. 这些现象**不是** bug(平台限制)

- **只有一个 MenuRight 条目、里面是子菜单**:macOS 把扩展菜单挂在扩展名条目下,扩展无法创建顶层项、无法控制父级。需求里的"与 MenuRight 同级"在 FinderSync 下做不到;唯一的替代是 Accessibility/AppleScript 注入菜单,被 `AGENTS.md` 明令禁止。
- **"选中后不显示级联"** = 选中态菜单**平铺无二级**(已实现);外层那个 MenuRight 包装去不掉。
- **新建文件后不会自动进入重命名状态**:Finder 只对自己创建的项进入内联重命名,没有 API 可以触发。需要改名请按回车。
- **`Open Terminal` 不需要授权**:见 3.1 第 11 项,这是刻意设计,不是漏了检查。
- **7Z/RAR/XZ 解压**:P9 才做(且 RAR 按决策不做)。

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
