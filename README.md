<p align="center">
  <img src="MenuRight/Resources/menuright-logo.png" alt="MenuRight" width="128">
</p>



<h1 align="center">MenuRight</h1>

<p align="center">为 macOS 访达（Finder）右键菜单补充一批「本来应该有」的操作。</p>

MenuRight 由两部分组成：一个 **Finder 扩展**（负责在右键菜单里显示条目）和一个**主应用**（负责所有真正的文件操作、授权与设置界面）。扩展本身没有任何文件写入权限——它只发送请求，所有副作用都由主应用在**你已授权的文件夹范围内**执行。这是本项目的核心不变量，无法在设置里关闭。

## 功能

### 右键菜单

| 场景 | 菜单项 |
| --- | --- |
| 选中文件/文件夹 | 创建别名、锁定、解锁、复制文件名、复制路径、复制文件 URL、剪切、压缩 ▸ |
| 选中压缩包 | 上面全部，外加 解压 ▸ |
| 文件夹空白处 | 打开终端、复制文件夹名、复制文件夹路径、新建文件 ▸、新建文件夹、粘贴到这里、常用文件夹/软件/网页 ▸ |

- **压缩 ▸**：压缩为 ZIP / TAR / TAR.GZ / TAR.BZ2，或「自定义压缩…」打开对话框。
  列出的格式由设置里的「允许的压缩格式」决定；全部取消勾选时仍保留「自定义压缩…」
- **解压 ▸**：第一项「解压到当前文件夹」始终解压到压缩包所在文件夹（不受设置影响）；第二项跟随「解压位置」——
  每次询问 → 「解压到指定位置…」弹出选目录面板；指定文件夹 → 「解压到「文件夹名」」直接解压过去；
  压缩包所在文件夹 → 与第一项重复，因此不显示
- **自定义压缩**：保存为、标签（写入 ZIP 归档注释）、位置、压缩格式、压缩模式（快速/标准/极限）；
  加密压缩、分卷压缩、固实压缩三项**置灰并写明原因**（需要自研 ZIP 加密或 7-Zip 写入能力，本版本没有）；
  对话框里的「取消」会真正中止正在进行的压缩（归档在内存里组装、最后才落盘，因此不会留下半个文件）
- **新建文件 ▸**：Word / Excel / PowerPoint（自研 OOXML 生成）以及 Pages / Numbers / Keynote（基于空白模板）
- **常用文件夹/软件/网页 ▸**：在设置里配置，右键直达；带图标（见下）

### 常用项图标

常用文件夹、常用软件、常用网页在**设置列表**和 **Finder 右键子菜单**里都显示真实图标：文件夹用它自己的图标（包括你在访达里自定义的），软件用 App 图标，网页用站点 favicon。

图标怎么跨进程送达：

- Finder 扩展是沙箱进程——它读不到主 App 的资源目录，也没有网络权限——所以**主 App 是唯一的图标生产者**。它在 `<App Group>/FavoritesIcons/` 里为每个收藏项写一张 64×64 PNG，并把文件名写进收藏项（`iconFile`）；扩展只按文件名把图片读回来（`FinderFavoriteIcons`）。
- favicon 由主 App 抓取（`https://<主机>/favicon.ico`，取不到就解析页面里的 `<link rel="…icon…">`），因此主 App 需要 `com.apple.security.network.client`；扩展依然没有任何网络权限。抓不到就退回纯文字，不影响该收藏项的打开。
- 图标在**每次启动**补齐（也会在打开对应设置面板、或点「刷新」时重新生成），装完就能用，不需要先访问设置页。

**为什么现在是全彩 PNG，而上一版把菜单图标整个撤掉了**：第一版用的是**模板（template）图片**，而 Finder 绘制扩展菜单项的图片时不做高亮/禁用染色，于是选中行上会显示一个纯黑图标；当时因此移除了菜单图标。全彩 PNG 没有"染色"这一步，不受该限制。代价是菜单会为图标预留一列内边距。

### 代码预览（空格预览 + 设置内预览）

**按空格预览代码文件时，MenuRight 用自己的高亮器上色**，配色与字体来自设置里的「代码主题」；**Markdown 则是真正渲染出来的**（标题、加粗、列表、引用、代码块、表格），不是源码高亮。设置面板里的预览用的是**同一个引擎、同一份配置**，两处不可能漂移。

- **接管哪些类型**：`.swift`、`.py`、`.js`/`.mjs`、`.tsx`、`.html`、`.css`、`.json`、`.yml`/`.yaml`、`.md`/`.markdown`、`.sh`/`.bash`/`.zsh`、`.c`/`.h`、`.cpp`/`.hpp`、`.java`（`QLSupportedContentTypes` 里声明的 UTI）。**其余文件一律回退系统预览**——图片、PDF、Office 文档，以及 macOS 没有稳定 UTI 的 `.ts`/`.rs`/`.go`/`.sql` 都不接管。
- **Markdown 渲染**：用 Foundation 的 `AttributedString(markdown:)` 解析，再把块模型交给 AppKit 渲染。支持标题（六级，字号递减）、加粗/斜体、行内代码（等宽 + 主题色 + 淡底）、链接（主题 function 色 + 下划线）、有序/无序/嵌套列表、引用、围栏代码块（**按语言提示复用同一个高亮器**，整行淡底）、表格（按显示宽度对齐，中日韩字符按两列算）、分隔线。正文用系统字体（等宽字体读长段落很难受），代码部分用设置里的等宽字体。
- **Markdown 为什么接管**：本机这个类型原本由 WPS Office 的快速查看扩展渲染。**Quick Look 没有"运行时交还"机制**——实测在扩展里对 `.md` 抛错并不会回退给别的渲染器，只会让面板空掉；`QLSupportedContentTypes` 又写死在签名后的 Info.plist 里，所以"按语言开关"做不到。既然接管了，就把它做成**渲染**而不是降级成源码高亮。
- **`.ts` 不声明**：系统把 `.ts` 解析成 `public.mpeg-2-transport-stream`（MPEG-2 传输流），声明它会把视频文件抢过来。
- **想整块关掉空格预览**：系统设置 → 通用 → 登录项与扩展 → 快速查看（macOS 15+），或 `pluginkit -e ignore -i xin.ljhsu.MenuRight.MenuRightCodePreview`。这是**全局**开关，Quick Look 不支持按语言单独开关。
- **语言识别**：按扩展名（外加 UTI）选择；`Makefile`、`Dockerfile`、`CMakeLists.txt` 这类无扩展名文件按文件名识别；识别不出就回退**纯文本**，永远不报错。
- **高亮器**（`Shared/CodePreview/`）零依赖、只 `import Foundation`：单遍扫描 + 跨行状态（块注释、多行字符串、JS 模板字符串、Markdown 围栏代码），每种语言由一份数据（`CodeSyntaxProfile`）驱动，HTML 有一个专用模式。它是**预览级**高亮器，不是解析器。
- **大文件不卡**：最多读 1 MB、最多渲染 5 000 行，超出时底部显示一行提示；读取发生在扩展进程里，不阻塞 Finder。
- **主题怎么到扩展**：主 App 把设置写进 App Group，扩展读同一份 `UserDefaults`。所以扩展带 `com.apple.security.application-groups` 权限；**没有这个权限时它会静默回落到默认主题**（看起来像"切主题不生效"）。
- **硬约束**：单测钉住「逐行无损」——代码路径每行的 token 拼回去必须与源码逐字符相同；任何语言漏字、串行都会挂测试。
- **排障**：扩展没有自己的界面，出错只能看日志：
  ```sh
  log show --last 5m --predicate 'subsystem == "xin.ljhsu.MenuRight"' --style compact
  # preview rendered file=Greeting.swift language=swift lines=10 theme=xcode-light truncated=false
  ```
  这条 `preview rendered` 就是「扩展跑起来了 / 读到了文件 / 读到了哪套主题」的证据；读文件失败会记 `preview unreadable … error=…`。

### 设置

- **权限与安全**：文件权限、文件夹权限（哪些操作允许出现在菜单里、授权哪些文件夹）
- **新建文件**：启用哪些类型、默认文件名
- **常用文件夹 / 常用软件 / 常用网页**：收藏目标，支持分组
- **代码主题**：代码预览的高亮主题（9 套配色，含"跟随系统"）、字体、字号、行号；预览区用真实高亮器渲染示例代码，可切换 17 种语言
- **解压缩管理**：允许的压缩格式（同时约束 `压缩 ▸` 与「自定义压缩」的格式下拉）、解压位置（作用于「解压到指定位置…」一项，选到未授权文件夹时面板会给出提示）、同名文件策略、解压后删除原包（仅在该次解压**没有任何内容被跳过**时执行）、跳过 `__MACOSX` 与 `.DS_Store`、体积上限
- **通用设置**：界面语言（跟随系统/中文/英文）、登录时自动启动、Finder 扩展状态、文件操作通道状态、**更新**（自动检查开关 + 立即检查 + 新版本提示）、关于（版本与构建号、产品网站、开源许可）

### 菜单栏图标与生命周期

菜单栏上有一个 MenuRight 图标（品牌标 `top-bar-logo.svg`，按**模板**渲染，跟随菜单栏配色），单击下拉三项：

| 菜单项 | 行为 |
| --- | --- |
| 打开设置 | 重新打开设置窗口（窗口关掉后也能调回来），⌘, |
| 检查更新 | 手动检查，**每种结果都会报告**：有新版本弹「前往下载/跳过此版本/稍后」，已是最新或失败也弹框说明 |
| 退出 MenuRight | 真正结束主应用，⌘Q |

**为什么必须有这个图标**：Finder 扩展由 Finder 按需拉起、用完自己退出 —— 没有任何 App 能启动或阻止它退出。
它每次要执行文件操作时，都要通过 App Group 套接字把活交给主应用；**主应用一旦不在，右键菜单里的每一项都会以「主应用未运行」告终**。
所以**关闭设置窗口不再退出主应用**（`applicationShouldTerminateAfterLastWindowClosed` 返回 `false`，规则由 `AppLifecycle` 持有、
`Scripts/`+`MenuRightTests/StatusMenuTests.swift` 钉住），菜单栏的「退出」是唯一的出口。
Finder 侧不需要我们保活：主应用在线，扩展被拉起时就有对端。

### 版本与更新

**版本号只有一个来源**：`Config/Version.xcconfig`。工程级配置把它作为 base configuration，四个 target（主 App、Finder 扩展、Quick Look 扩展、测试）全部继承 —— 以前这 16 行散在 8 个 build configuration 里，改一次要动 16 处，而嵌入的 appex 版本与主 App 不一致时 Xcode 的 `embeddedBinaryValidationUtility` 会在构建最后一步直接报错。

```sh
Scripts/version.sh                  # 1.0 (1)
Scripts/version.sh bump build       # 只加构建号
Scripts/version.sh bump minor       # 1.0 -> 1.1（构建号同时 +1）
Scripts/version.sh set 1.1 2        # 指定
Scripts/check-version.sh            # 断言 4 个 target 版本一致
```

**检查更新**：读 GitHub Releases 的 `releases/latest`（仓库公开，无需 token）。

- 默认**开启**，**每天最多一次**（手动点「立即检查」不受限制）；开关在「通用设置 → 更新」。
- 只做三件事：**检查 → 提示 → 打开下载页**。**不会自动下载或替换 App** —— 静默替换需要签名校验、原子替换与重启（那是 Sparkle 的职责，本项目不引第三方依赖）。
- 发现新版本时，启动后弹一次提示（当前版本 / 最新版本 / 更新说明节选），按钮是「前往下载 / 跳过此版本 / 稍后」；「跳过此版本」后只有更高的版本才会再提示。
- 失败是静默的（后台检查不会弹框）；手动检查会把失败原因显示在那一行下面。
- 想看它实际跑起来：`Scripts/release.sh` 的 `--publish` 会把版本发布到 GitHub Releases，客户端随后就能查到。

```sh
Scripts/release.sh                  # 构建两个架构，出 DMG + ZIP + 源码 ZIP + SHA256SUMS
Scripts/release.sh --publish        # 建 tag + gh release create（需要 gh 已登录）
```

发布资产：每个架构一个 `.dmg`（内含 MenuRight.app 与「应用程序」快捷方式）和一个 `.zip`，
外加 `MenuRight-<版本>-source.zip`（`git archive` 出的源码）与 `SHA256SUMS.txt`。
发布说明末尾会自动附一段「构建与验证说明」——**发布机只能运行自己的架构**，另一个架构属于
交叉编译，只会做静态检查，因此必须被明确标注为「未经测试」，由脚本自动生成而不是手写。

## 安装与使用

1. 下载对应架构的安装包（Apple Silicon 或 Intel；DMG 或 ZIP 任选），打开后把 **MenuRight.app** 拖进「应用程序」。
2. 首次打开：如果系统提示无法验证开发者，请在「访达」里右键应用 → **打开**（本项目未做公证，属于预期行为）。
3. 在 MenuRight 的**首次使用引导**里点「打开系统设置…」，在「隐私与安全性 → 扩展 → 已添加的扩展」中启用 **MenuRight 扩展**。这是本应用唯一需要的系统权限。
4. 打开「文件夹权限」，授权你希望 MenuRight 操作的文件夹（可批量添加）。**未授权的路径无法写入**——这是 macOS 沙箱的限制，不是 bug。
5. 回到访达，在文件或文件夹上点右键即可看到菜单。

## 注意事项

- **需要 macOS 14.0 或更高版本。**
- **必须启用 Finder 扩展**才能看到菜单；扩展未启用时设置里会显示红色状态与原因。
- **沙箱授权**：所有写操作都要求目标路径位于已授权的文件夹内。移动硬盘、网络卷在授权后同样可用。
- **不支持的格式**：RAR 完全不做（没有可用的纯 Swift / MIT 许可实现）；7-Zip 与 XZ **只能解压不能创建**；加密、分卷、固实压缩一律不支持。
- **体积上限**：解压默认有体积上限，防止「压缩炸弹」；对 `.bz2`/`.xz` 这类不声明原始体积的格式，上限只能边解压边累计——极端情况下恶意文件仍可能在判定前占用大量内存。
- **符号链接**：压缩时会跳过符号链接（避免打包你并未选中的文件），解压时也不会创建符号链接。
- **压缩包安全**：解压会拒绝 `../` 等一切试图逃出目标目录的路径，并且永远允许**同名文件策略**（保留两者/跳过/覆盖）由你决定。
- **压缩包里的文件名编码**：ZIP 规范写的是「设置了 UTF-8 标志位就是 UTF-8，否则是 CP437」，但现实里两边都不守规矩——Windows 自带的「压缩」写 GBK 且**不设**标志位，而不少工具写 UTF-8 也**不设**标志位。所以解码顺序是「标志位 → 纯 ASCII → 合法 UTF-8 → 以非 ASCII 为主、且是合法 GB18030、且确实含中日韩字符 → CP437」。这样 Windows 中文包不会再解出 `ÐÂ½¨ÎÄ¼þ¼Ð` 这类乱码文件名。代价：极少数「以非 ASCII 为主、又恰好是合法 GB18030」的西文老包会被当成中文，这一取舍有单测钉住。
- 复制文件 URL 使用 `file://` 形式；「粘贴到这里」对应的是剪切板里的文件操作。

## 从源码构建

```bash
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Release build
```

- 要求 Xcode 26 及以上、Swift 6.2 工具链。
- 唯一的第三方依赖是 [SWCompression](https://github.com/tsolomko/SWCompression)（MIT，仅主应用与测试 target 链接）。
- 测试：`xcodebuild -project MenuRight.xcodeproj -scheme MenuRight test`
- 版本：改 `Config/Version.xcconfig`（或 `Scripts/version.sh`），改完跑 `Scripts/check-version.sh`。
- 发版：`Scripts/release.sh`（两个架构的 DMG + ZIP + 源码 ZIP + tags + GitHub Release）。
- 可复现的验证脚本见 `Scripts/`（`verify-archive-roundtrip.sh`、`preview-finder-menu.sh`、`check-icons.sh`、`version.sh`、`check-version.sh`、`release.sh` 等）。

## 开源许可

- 侧边栏图标来自 [Lucide](https://lucide.dev)（ISC）与 [Phosphor](https://phosphoricons.com)（MIT）
- 解压/压缩使用 [SWCompression](https://github.com/tsolomko/SWCompression) 与 [BitByteData](https://github.com/tsolomko/BitByteData)（均为 MIT）

完整许可全文随应用打包，可在「通用设置 → 关于 → 开源许可」中查看。
