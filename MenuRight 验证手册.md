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
| 4 | `New File ▸` 逐个试 6 项 | 生成 `Untitled.txt` / `.md` / `.html` / `.css` / `.js` / `.json`;HTML 打开是完整骨架,CSS 有 `body { }`,JS 有 `"use strict"`,JSON 是 `{}`;重名第二次变 `Untitled 2.*` | `DISPATCH createFile SUCCESS path=...` 或 FAILURE |
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
