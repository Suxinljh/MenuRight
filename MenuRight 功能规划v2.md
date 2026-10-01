# MenuRight 功能规划 v2 — 技术可行性与排期重排

> 依据:`MenuRight 功能需求排期.md`(P0/P1/P2 需求清单)+ 2026-09-30 的实现现状。
> 本文档**不改动**原需求文件,只把"要什么"翻译成"macOS 允许怎么做、按什么顺序做、代价多少"。
> 可行性判断依据:本地 SDK 头文件、本地编译实测、第三方库**源码实测**(已下载校验),或明确标为"待 Spike"。
> 全部六个决策(D1–D6)已定,记录见 §5。

---

## 0. 一句话结论

需求里 **14 项可行、3 项部分可行、3 项在 macOS 上做不到(或与仓库约束冲突)**。
四个产品决策已定(D1–D4)。执行依赖已实测确认:**一个 MIT 纯 Swift 库可覆盖 6 种解压格式**,
但**RAR 与 ZIP 写入是两个缺口**,分别需要 D5/D6 决策(§5.2 / §5.3)。

---

## 1. 平台硬约束(决定后面所有设计)

| # | 约束 | 事实与依据 | 对需求的影响 |
| - | ---- | ---------- | ------------ |
| C1 | Finder 扩展只能提供**一个** NSMenu,由 Finder 挂在扩展名条目下 | `FIFinderSync.menuForMenuKind:`(SDK `FinderSync.h:144-165`);扩展无法控制父级、无法创建顶层项 | 「与 MenuRight 同级」**不可实现**。唯一替代是 Accessibility/AppleScript 注入 Finder 菜单 —— 被 `AGENTS.md:10` 明令禁止,审计也确认仓库内无此类后门 |
| C2 | 扩展菜单可含多级子菜单 | 现有 `FinderMenuBuilder` 已用 `.submenu` 并在线上工作 | 新建文件 ▸ / 常用软件 ▸ / 常用网页 ▸ / 常用文件夹 ▸ **全部可行** |
| C3 | "进入重命名/编辑状态"没有 API | Finder 只对**自己**创建的项目进入内联重命名;`NSWorkspace` 仅 `activateFileViewerSelectingURLs`(NSWorkspace.h:53) | 只能"创建 + 选中/显示",或按类型用默认应用打开 |
| C4 | App 扩展必须沙箱化;主 App 与扩展共享 App Group | 现有架构 + entitlements | 一切副作用由**主 App**执行 —— P5-1"主 App 唯一写入者"不变量必须保持 |
| C5 | 无公开 ZIP 容器 API,但 **zlib 公开可用** | 本地实测 `import zlib` 编译通过、`inflateInit` 返回 `Z_OK`(zlib 1.2.12);`usr/include/zlib.h` 在 SDK 中 | 自研 ZIP 解压/写入**零第三方依赖可行**(D6 的备选) |
| C6 | `libarchive` 在 SDK 里只有 `.tbd`,**无头文件** | `find $SDK -name archive.h` 无结果 | 用它需手写函数声明,违背"仅公开 API"原则(审计对 `PeerIdentity` 正是按此标准核验) |
| C7 | `bzlib.h` 公开;**`lzma.h` 不在 SDK** | `ls $SDK/usr/include/{bzlib.h,lzma.h}` | 原生路线的 XZ 不可行;但 D2 选定的第三方库已覆盖 XZ(见 §5.2) |
| C8 | Finder 上下文菜单**不响应快捷键** | Finder 绘制菜单,扩展只提供菜单项 | P2「快捷键」只能做全局热键,且**拿不到当前 Finder 选中项** |

---

## 2. 需求可行性台账

| 需求(原文件) | 判定 | 做法 / 依据 |
| --- | --- | --- |
| P0 空白区域右键 `MenuRight` 级联 | ✅ 已有 | `FIMenuKindContextualMenuForContainer` |
| P0 打开终端 | ✅ 可行(需 Spike S1) | 主 App `NSWorkspace.openURLs([folder], withApplicationAtURL:, configuration:)`(NSWorkspace.h:43,macOS 10.15+) |
| P0 复制文件名 / 路径 | ✅ 已有 | 容器态复制"当前文件夹名/路径";选中态复制文件名/路径/URL |
| P0 新建文件(11 种) | ⚠️ 分两类 | 文本 5 种直接生成;**docx/xlsx/pptx 用 OOXML 生成**(D1-A,需 ZIP 写入器 → D6);**pages/numbers/keynote 复制模板**(私有 IWA 格式,无法生成) |
| P0 新建后进入可编辑/重命名 | ❌ 不可实现 | 见 C3。替代:创建后选中/显示,或按类型用默认应用打开 |
| P0 选中后不再显示级联 | ⚠️ 部分可行 | 选中态菜单**完全平铺无二级**(D3-A);外层 Finder 包装(C1)去不掉 |
| P0 创建快捷方式 | ✅ 可行 | `NSURL.writeBookmarkData:toURL:options:` + `NSURLBookmarkCreationSuitableForBookmarkFile`(NSURL.h:427/459);同名冲突复用 `FileNameResolver` |
| P0 文件锁定 / 解锁 | ✅ 可行 | `NSFileImmutable`(NSFileManager.h:595)= `UF_IMMUTABLE`;必须同时提供解锁,否则用户无法删除 |
| P1 常用软件 / 网页 / 文件夹 | ✅ 可行 | App Group 设置 + 主 App `NSWorkspace` 打开;文件夹由 Finder 打开,不需额外 bookmark |
| P1 代码空格预览 | ✅ 可行,**需第三个 target** | `NSExtensionPointIdentifier=com.apple.quicklook.preview` + `QLSupportedContentTypes` + `QLPreviewingController`(SDK 头 + Xcode 模板);能否取代系统纯文本预览需 S2 |
| P1 高亮主题 | ✅ 可行 | 主题自研模型,主 App 配置 → App Group → QL 扩展读取 |
| P1 压缩文件解压 | ✅ 6 种格式已确认 | SWCompression(§5.2):ZIP/7-Zip 读、TAR 读、GZip/BZip2/XZ/LZMA/LZMA2/Zlib/LZ4/Deflate 解压。**RAR 不做(D5-R1)** |
| P1 可配置解压格式 | ✅ 可行 | 设置只列出**真正实现并实测通过**的格式 |
| P1 直接打开压缩包解压 | ⚠️ 慎做 | 需声明 `CFBundleDocumentTypes` 抢占默认打开方式;建议只做右键菜单 |
| P2 设置中心 | ✅ 可行 | 现有 SwiftUI 宿主 App + App Group |
| P2 菜单可见性配置 | ✅ 可行 | 扩展按设置裁剪;**保持 `menu(for:)` 零 IO 预算**(§4) |
| P2 快捷键与高级行为 | ⚠️ 受限 | 见 C8:只能做不依赖选中项的动作 |

---

## 3. 重排后的阶段计划

### P6 — 菜单重构 + 高频动作(原 P0)

**范围**
1. `FinderMenuBuilder` 改为"设置 + 上下文"双驱动。
2. 打开终端(主 App 执行,终端 App 可配置,默认 Terminal)。
3. 复制:容器态 = 当前文件夹名/路径;选中态 = 文件名/路径/文件 URL。
4. 新建文件 11 种:**TXT/MD/HTML/CSS/JS 直接生成** + **docx/xlsx/pptx 用最小 OOXML 生成**(由自研 `ZipWriter` 打包,D6-W1) + **pages/numbers/keynote 复制模板**(3 个 iWork 空白模板;模板缺失时该项隐藏并提示,不显示会失败的菜单项)。
5. 新建文件夹(保留)。
6. 创建快捷方式(Finder 别名)。
7. 锁定 / 解锁(`UF_IMMUTABLE`,支持批量)。

**菜单表**
- 容器/桌面空白:`打开终端` · `复制当前文件夹名称` · `复制当前文件夹路径` · `新建文件 ▸` · `新建文件夹` · `粘贴到这里`(有剪切内容才启用) · `常用软件 ▸` · `常用网页 ▸` · `常用文件夹 ▸`(空时隐藏)
- 选中文件/文件夹(**平铺,零二级**):`创建快捷方式` · `锁定`(含已锁定项时显示 `解锁`) · `复制文件名` · `复制路径` · `复制文件 URL` · `剪切`

**人工门**:终端 cwd 正确;11 类新建(文档类能用对应 App 打开且不损坏);别名双击跳转;锁定后 Finder 删除被拒;解锁后删除成功;批量锁定。

> ⚠️ **待你一句话确认的歧义**:容器菜单里的 `复制当前文件夹名称/路径` 取自你聊天里的菜单表;
> 而排期文件 P0 第 3 行写的是"空白区域无选中对象时**隐藏**"。两者冲突。当前按聊天版实现
> (等价于现有已上线的 `Copy Folder Path`);若按排期文件,则容器菜单删掉这两项。

### P7 — 设置中心 + 常用三项 + 菜单可见性(原 P1/P2)

App Group `UserDefaults(suiteName:)` 存设置 → 设置 UI(软件选择器、网页名+URL、文件夹、可见性开关、模板目录可选覆盖)→ 菜单动态渲染 → 主 App 执行打开。
**关键点**:常用软件**不在菜单构建时校验存在性**(避免 IO/延迟),改在点击时校验并给出清晰错误。
**人工门**:增删配置后菜单即时反映;软件被卸载后点击有明确报错。

### P8 — Quick Look 代码高亮 + 主题(原 P1)

新增第三个 target `MenuRightCodePreview`(Quick Look Preview Extension)嵌入主 App;轻量高亮器(按扩展名/UTI 选语言:Swift/Python/JS/TS/HTML/CSS/JSON/YAML/Markdown/Shell/SQL/C/C++/Go/Rust/Java…);主题 ≥6 套由主 App 配置、App Group 共享。
**最高风险**,先跑 S2/S3。
**人工门**:代码空格预览有高亮;切主题立即生效;大文件不卡;非代码文件回退系统预览。

### P9 — 解压(原 P1)

`ArchiveExtractor`(策略层,纯 Swift、零依赖:Zip Slip 校验、不覆盖策略、逐项结果聚合)+ `ArchiveBackend`(适配 SWCompression)。
**必须做**:Zip Slip 防御(`../`、绝对路径、符号链接逃逸一律拒绝)、**体积上限守卫**(SWCompression 是 `Data` 入参,整包进内存 → 超过阈值返回 `archiveTooLarge` 而不是 OOM)、同名冲突按现有"不覆盖"策略。
**交付格式(D5-R1)**:ZIP、7-Zip、TAR、GZip、BZip2、XZ 六种;**RAR 不实现**,菜单与设置里都不出现(README 记录原因与后续可选路径)。
**人工门**:ZIP 正常/中文名/含目录/同名/恶意 `../`;只读目标目录;1GB 压缩包给出干净错误而非卡死;7Z/XZ/BZ2 各一例。

> **落地状态(2026-10-01 补记,原文保留在上)**:P9 **已交付**。
>
> - 代码:`Shared/Archive/` 的 `ArchiveExtractor`(策略层,只 import Foundation)+
>   `ArchiveMemberSource`(SWCompression 适配);第三方**只在主 App 与测试 target 里**
>   (实测:扩展二进制无该包、pbxproj 里 appex 无 package deps)。
> - MIT 致谢(`Third-Party-Notices/SWCompression-LICENSE.txt`)与
>   `PrivacyInfo.xcprivacy` 都已在 App 包内。
> - 六种格式**全部有实测证据**:ZIP/TAR/GZ/BZ2 见 `Scripts/verify-archive-roundtrip.sh` 的
>   round-trip 与外来样本断言;7Z 由该脚本用 macOS bsdtar 造的真实 `.7z` 覆盖;
>   XZ 由 python3 `lzma` 造的 `.tar.xz` 覆盖(本机没有 xz CLI,因此不再依赖它)。
> - 两处与本文的偏离,都是有记录的处置:
>   1. **RAR 出现在设置面板**(灰行 + 写明原因),而不是"设置里也不出现"——§2 L49 与 §3 L96
>      本身冲突,按"解释清楚为什么没有"处理,README 有记录。
>   2. **压缩创建(`压缩 ▸` / 自定义压缩)不在本规划内**却已实现:ZIP/TAR/TAR.GZ/TAR.BZ2,
>      加上"保存为/标签(仅 ZIP)/位置/格式/模式"对话框;加密、分卷、固实三项在 UI 里
>      置灰并写明原因;7z/XZ 只读,不能创建。
> - 已完成:**解压侧的进度/暂停/取消**(与压缩同一套进度窗口)、**1GB 大包的内存行为(S8,用户实测通过)**、**只读目标目录(人工门,用户实测通过)**。
> - 仍未做(见 README「解压与压缩」):RAR 支持(无纯 Swift/MIT 方案)、创建 7z/xz、加密/分卷/固实压缩 —— 均在设置界面置灰并写明原因。

### P10 — 快捷键与高级行为(原 P2)

受 C8 限制,只能绑定不依赖选中项的动作;依赖选中项需要 Accessibility 权限,与 `AGENTS.md:10` 冲突。**建议降级或放弃**。

---

## 4. 架构与数据流变更

| 变更 | 说明 |
| --- | --- |
| 线上契约扩展 | `OperationKind` 新增:`createFromTemplate` / `createAlias` / `setLocked` / `extractArchive` / `openTerminal` / `openURL` / `openApplication` / `openFolder`。新增 `ErrorCode`:`templateMissing` / `archiveUnsupported` / `archiveUnsafePath` / `archiveTooLarge` / `lockFailed` / `openFailed`。`version` 保持 1(纯增量) |
| 副作用归属 | 新动作全部由主 App 执行,扩展只传路径/参数 —— 保持"扩展无文件 entitlement" |
| 设置存储 | App Group `UserDefaults(suiteName:)`;扩展在 `menu(for:)` 只读内存缓存,**禁止**文件扫描/存在性检查 |
| 模板资源 | 主 App bundle `Resources/Templates/`(pages/numbers/keynote 空白模板;可选 docx/xlsx/pptx)。模板缺失 → 该项隐藏并记录诊断 |
| 归档引擎 | `ArchiveExtractor`(纯 Swift 策略,无依赖,headless 可测)+ `ArchiveBackend`(SWCompression 适配)。**第三方库只链接进主 App 与测试 target,绝不进 Finder 扩展** |
| 第三个 target | Quick Look 扩展;**风险**:`project.pbxproj` 是手工合成 ID 结构,新增 target 建议用 Xcode GUI 添加后 review diff,并以 `plutil -lint` + `xcodebuild -list` + 构建校验 |
| 依赖引入方式 | 用 Xcode「Add Package Dependency」写入 `XCRemoteSwiftPackageReference`/`XCSwiftPackageProductDependency`(手改这段 pbxproj 风险高);提交 `Package.resolved`;MIT 许可需在 App 内致谢(About/鸣谢) |
| 菜单预算 | 禁止在菜单构建时做目录扫描/进程检查 |

---

## 5. 决策(已定 + 两个新缺口)

### 5.1 已定(D1–D4)

| 决策 | 选择 | 落地含义 |
| --- | --- | --- |
| D1 文档类新建 | **A** | 文本 5 种真实生成;docx/xlsx/pptx 用最小 OOXML;**pages/numbers/keynote 复制模板** |
| D2 解压路线 | **B** | 引入第三方库一次性覆盖多格式 → 见 §5.2 的实测结果 |
| D3 选中态菜单 | **A** | 平铺保留:创建快捷方式 · 锁定/解锁 · 复制文件名 · 复制路径 · 复制文件 URL · 剪切 |
| D4 Quick Look | **A** | 接受新增第三个 target,先跑 S2/S3 |

### 5.2 D2 落地:SWCompression 实测结果(源码已下载校验)

**SWCompression** — `MIT`许可,纯 Swift,`swift-tools-version:5.9`,`platforms: [.macOS(.v14)]`(**与我们的 deployment target 完全一致**),自带 `PrivacyInfo.xcprivacy`。

| 格式 | 能力 | 实测依据 |
| ---- | ---- | -------- |
| ZIP | **只读**(`ZipContainer.open`/`info`) | `Sources/ZIP/ZipContainer.swift:41,131`;目录下无 create API |
| 7-Zip | **只读**(`7zContainer.open`/`info`) | `Sources/7-Zip/7zContainer.swift:28,180` |
| TAR | **读 + 写**(`TarContainer.create`) | `Sources/TAR/TarContainer.swift:81,102,187` |
| GZip / XZ / Zlib | 解压(`unarchive`) | `GzipArchive.swift` / `XZArchive.swift` / `ZlibArchive.swift` |
| BZip2 / LZ4 / Deflate | 压缩 + 解压 | `compress`/`decompress`/`multiDecompress` |
| LZMA / LZMA2 | 解压(`decompress`) | `Sources/LZMA/`, `Sources/LZMA2/` |
| **RAR** | **不支持** | 全库无 RAR API(已按词边界检索确认) |

**两个结论**:
1. **RAR 不在覆盖范围内** —— 原需求"D2-B 一次性覆盖 7Z/RAR/XZ"实际只能覆盖 6 种,需要 D5(§5.3)。
2. **ZIP 写入缺失** —— 影响 D1 的 OOXML 生成,需要 D6(§5.3)。
3. **内存模型注意**:SWCompression 是 `Data` 入参(`open(container data: Data)`),整包进内存 → 必须加体积上限守卫(P9)。

### 5.3 已定(D5/D6)

**D5 = R1 — 先不做 RAR。** P9 交付六种格式;RAR 单独立项(无 MIT/纯 Swift 方案;UnrarKit 为 Objective-C 只读、基于 UnRAR 5.8.1、无 SwiftPM;libarchive 需 vendored C 且与 SWCompression 重叠)。

**D6 = W1 — 自研最小 ZIP 写入器。** `ZipWriter`(纯 Swift + zlib deflate/store + CRC32 + central directory,约 250 行,无新依赖),只覆盖我们生成的 OOXML,不支持 zip64(超 4GB 拒绝)。**验证方式**:用它生成 OOXML → 由 SWCompression 读回校验结构,双向 round-trip 单测。

---

## 6. 先做的 Spike(带验证方法与预期证据)

| # | 问题 | 方法 | 预期证据 |
| - | ---- | ---- | -------- |
| S1 | 沙箱主 App 能否让 Terminal 以指定目录开窗 | 主 App 临时调试动作调用 `NSWorkspace.openURLs(withApplicationAtURL:)` | Terminal 新窗口 `pwd` = 目标目录 |
| S2 | QL 扩展能否**取代**系统纯文本预览 | 最小 QL 扩展 + 日志/断点,对 `.swift` 按空格 | `preparePreviewOfFile` 被调用(而非系统预览) |
| S3 | QL 扩展读取被预览文件是否需额外 entitlement | 在 S2 扩展内读取并渲染内容 | 读取成功;失败则记录具体错误码 |
| S4 | 沙箱内 `Process`/`ditto` 能否写入目标目录 | 沙箱主 App 内 `Process` 调 `ditto -x -k` 解压到已授权目录 | 预期**失败**(子进程不继承 sandbox extension)→ 确认走进程内实现 |
| S5 | 别名与 `UF_IMMUTABLE` 的真实表现 | 脚本创建别名 + `chflags uchg`,Finder 中观察 | 别名双击跳转;锁定项删除被拒 |
| **S6** | SWCompression 集成(新) | Xcode 加 SPM 依赖 → 主 App + 测试 target 链接 → 对 ZIP/7Z/TAR/GZ/BZ2/XZ 各跑一次真实解压 → 检查 `Package.resolved`、隐私清单打包、构建与体积 | 6 种格式全部解出且校验一致;扩展 target 未被链接 |
| **S7** | 自研 `ZipWriter` 与 OOXML(D6-W1) | 用 `ZipWriter` 生成 docx/xlsx/pptx,再由 SWCompression 读回校验结构 | Word/Excel/PPT 能打开且不报修复;Numbers/Pages 也能打开 xlsx/docx;round-trip 一致 |
| **S8** | 大压缩包的内存行为(新) | 解一个 1GB ZIP | 命中体积上限并返回 `archiveTooLarge`,无 OOM/卡死 |

---

## 7. 测试与人工门策略

- **单测(必须)**:菜单计划(容器/选中/设置空/含锁定项/可见性关闭)、设置编解码与迁移、`ArchiveExtractor` 策略(夹具 + Zip Slip 恶意样本 + 体积上限 + 同名冲突)、别名/锁定经 `FileOperationDispatcher` 的真实临时目录用例、新错误码映射全分支。
- **依赖边界**:`ArchiveExtractor` 策略层**不 import 第三方库** → 绝大多数测试无需加载依赖;只有 backend 集成测试需要,且测试 target 需同时链接 SWCompression。
- **基线**:当前 **159 测试全绿**,每阶段只增不减;P8 后需三个 target 全部构建通过。
- **构建命令**:`xcodebuild ... build -allowProvisioningUpdates`(已实测可签名);headless 用 `CODE_SIGNING_ALLOWED=NO`。
- **人工门**:README 现有 A–J + 每阶段新增项;`Automated: PASS` 与 `Manual: PENDING/PASS` 必须分开写。
- **安全**:全部走"主 App 唯一写入者";解压必须防 Zip Slip;别名**不得**使用 `.withSecurityScope`(会把安全书签写进别名文件)。

---

## 8. 与现有已上线功能的关系(不静默砍功能)

| 现有功能 | 新需求是否出现 | 处置 |
| -------- | -------------- | ---- |
| 新建文件夹 | ❌ | **保留** |
| 粘贴到这里(Cut/Paste Here) | ❌ | **保留** |
| 复制文件 URL | ❌ | **保留**(D3-A) |
| 复制文件夹路径 | 被"复制当前文件夹路径"覆盖 | 改名保留 |
| 新建 JSON | 新列表无 JSON | **保留**;新列表补 HTML/CSS/JS |
| 侧边栏右键 | ❌ | 暂不支持 |

---

## 附:依据来源

- 本地 SDK:`FinderSync.h:144-165`、`NSWorkspace.h:43,53`、`NSURL.h:427,459`、`NSFileManager.h:595`、`QuickLookUI.framework/.../QLPreviewingController.h`、Xcode "Quick Look Preview Extension" 模板。
- 本地编译实测:`import zlib` + `inflateInit` → `Z_OK`;`libarchive` 无头文件;`lzma.h` 缺失。
- 第三方库**源码实测**:SWCompression `master` 源码包(1.2MB)已下载逐项核对 API、`Package.swift` 平台、`LICENSE`(MIT)与 `PrivacyInfo.xcprivacy`;UnrarKit README 核对(只读、基于 UnRAR 5.8.1、无 SwiftPM)。
- 本仓库现状:159 单测全绿、P5-1 主 App 唯一写入者、扩展无文件 entitlement、`Scripts/verify-ipc-peer.swift` 可复现 IPC 门校验。
- `web_search` 不可用(端点 401);上述外部信息均通过 `curl` 拉取原始文件核实,凡未核实处一律标为 Spike。
