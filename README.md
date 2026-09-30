<p align="center">
  <img src="MenuRight/Resources/BrandAssets.xcassets/menuright-logo.imageset/menuright-logo.svg" alt="MenuRight" width="128">
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

- **压缩 ▸**：压缩为 ZIP / TAR / TAR.GZ / TAR.BZ2，或「自定义压缩…」打开对话框
- **解压 ▸**：解压到当前文件夹，或「解压到指定位置…」自己挑目录
- **自定义压缩**：保存为、标签（写入 ZIP 归档注释）、位置、压缩格式、压缩模式（快速/标准/极限）；
  加密压缩、分卷压缩、固实压缩三项**置灰并写明原因**（需要自研 ZIP 加密或 7-Zip 写入能力，本版本没有）
- **新建文件 ▸**：Word / Excel / PowerPoint（自研 OOXML 生成）以及 Pages / Numbers / Keynote（基于空白模板）
- **常用文件夹/软件/网页 ▸**：在设置里配置，右键直达

### 设置

- **权限与安全**：文件权限、文件夹权限（哪些操作允许出现在菜单里、授权哪些文件夹）
- **新建文件**：启用哪些类型、默认文件名
- **常用文件夹 / 常用软件 / 常用网页**：收藏目标，支持分组
- **代码主题**：复制代码时使用的配色
- **解压缩管理**：允许的压缩格式、解压位置、同名文件策略、解压后删除原包、跳过 `__MACOSX` 与 `.DS_Store`、体积上限
- **通用设置**：界面语言（跟随系统/中文/英文）、登录时自动启动、Finder 扩展状态、文件操作通道状态、关于（产品网站、开源许可）

## 安装与使用

1. 下载对应架构的压缩包（Apple Silicon 或 Intel），解压后把 **MenuRight.app** 拖进「应用程序」。
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
- 复制文件 URL 使用 `file://` 形式；「粘贴到这里」对应的是剪切板里的文件操作。

## 从源码构建

```bash
xcodebuild -project MenuRight.xcodeproj -scheme MenuRight -configuration Release build
```

- 要求 Xcode 26 及以上、Swift 6.2 工具链。
- 唯一的第三方依赖是 [SWCompression](https://github.com/tsolomko/SWCompression)（MIT，仅主应用与测试 target 链接）。
- 测试：`xcodebuild -project MenuRight.xcodeproj -scheme MenuRight test`
- 可复现的验证脚本见 `Scripts/`（`verify-archive-roundtrip.sh`、`preview-finder-menu.sh`、`check-icons.sh` 等）。

## 开源许可

- 侧边栏图标来自 [Lucide](https://lucide.dev)（ISC）与 [Phosphor](https://phosphoricons.com)（MIT）
- 解压/压缩使用 [SWCompression](https://github.com/tsolomko/SWCompression) 与 [BitByteData](https://github.com/tsolomko/BitByteData)（均为 MIT）

完整许可全文随应用打包，可在「通用设置 → 关于 → 开源许可」中查看。
