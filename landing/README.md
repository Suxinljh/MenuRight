# MenuRight 落地页（HTML 单文件版）

这是 MenuRight 落地页的**评审稿**，用于先在本地定稿文案与排版，再搬进 Astro 站点。

- 文件：`landing/menuright.html`（唯一交付物，单文件、无构建步骤）
- 状态：文案与结构已定稿待审；**截图仍是占位块**（见下方清单）
- 目标线上位置：`suxin-apps` 项目的 `/menuright`（`https://app.ljhsu.xin/menuright`），
  或按 App 内「产品网站」指向 `https://create.ljhsu.xin/menuright`

## 怎么预览

直接双击 `landing/menuright.html` 用浏览器打开即可（Tailwind 走 CDN，需要联网）。
如果想用真实 http 环境（避免 `file://` 的各种小差异）：

```bash
cd landing && python3 -m http.server 8000
# 然后打开 http://localhost:8000/menuright.html
```

页面右上角有 **中文 / EN** 切换，选择记在 `localStorage["menuright-lang"]`；
首次访问按 `navigator.language` 判断，并把结果同步到 `<html lang>` 与 `document.title`。

## 页面结构（锚点）

| 锚点 | 内容 |
| --- | --- |
| `#top` | Hero：一句话定位 + 核心不变量 + CSS 手搓的右键菜单 mock（两个 tab：选中文件 / 空白处） |
| — | 「为什么需要它」3 张对照卡（以前怎么做 / 现在怎么做） |
| `#features` | 功能总览 6 卡（右键菜单 / 常用项图标 / 代码预览 / 压缩与解压 / 新建文件 / 菜单栏与更新） |
| `#menu` | 右键菜单详解：两张完整菜单清单 + 压缩 / 解压 / 新建文件三张说明卡 |
| `#preview` | 空格预览：真实 Swift 样例 + One Dark 配色 |
| `#archive` | 压缩与解压：格式支持表、安全策略、中文文件名乱码的来龙去脉 |
| `#security` | 权限与隐私 4 卡（扩展不写文件 / 未授权路径写不进去 / 不收集数据 / 只有两个网络行为） |
| `#install` | 安装 5 步（含「未公证，首次需右键打开」） |
| `#faq` | 7 条 `<details>` 折叠问答 |
| `#download` | 下载 CTA（Apple Silicon / Intel 两个按钮 → GitHub Releases） |

## 待补截图清单

页面里所有占位都是 `.shot` > `.shot-box` + `<figcaption>`，搜索 `TODO(screenshot` 可逐个定位。
换图时把 `<div class="shot-box">Sx · 16:10</div>` 整块替换成
`<img src="…" alt="…" class="w-full rounded-xl border border-line" />` 即可（`.shot-box` 的虚线样式随之失效）。

| 编号 | 内容 | 建议尺寸 | 怎么拍 |
| --- | --- | --- | --- |
| S1 | 设置中心 · 通用设置（Finder 扩展状态 + 更新一行） | 16:10 | 主应用 → 设置 ⌘, → 通用设置 |
| S2 | 设置中心 · 代码主题（预览区真实高亮 + 主题下拉） | 16:10 | 设置 → 代码预览 |
| S3 | 空格预览（Quick Look） | 16:10 | 访达里选中 `Greeting.swift` 按空格 |
| S4 | 自定义压缩对话框 | 4:3 | 右键选中文件 → 压缩 → 自定义压缩… |
| S5 | 菜单栏下拉三项（打开设置 / 检查更新 / 退出） | 3:2 | 点菜单栏图标后截图 |
| S6（可选） | 真实右键菜单 | — | 目前 Hero 用 CSS mock 代替，若要换成实拍可替换整个 `#menu-mock` |

截图建议统一用深色外观（系统设置 → 外观 → 深色），并放在 `public/assets/menuright/` 下再引用。

## 移植到 Astro（`suxin-apps`）的映射

| 本文件里的东西 | 移植到 |
| --- | --- |
| `<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4">` | **删掉**（站点已用 `@tailwindcss/vite` 编译） |
| `<style type="text/tailwindcss">@theme {…}</style>` | **删掉**（令牌已在 `src/styles/global.css`，内容逐字一致） |
| 页面骨架 | `src/pages/menuright/index.astro` |
| 头部 / 页脚 | 照 `src/layouts/PoopyShell.astro` 抽 `src/layouts/MenuRightShell.astro`（复用站点 `Header.astro` / `Footer.astro`） |
| Hero 菜单 mock | `src/components/MenuMock.astro` |
| FAQ 7 条 | frontmatter 里的数组 + `map()`（参考 `src/pages/poopy/support.astro`） |
| 截图 | `public/assets/menuright/`，占位换成真实 `<img>` |
| 入口 | `src/pages/index.astro` 的 App & Web 网格加一张 MenuRight 卡片 |

移植时注意：

1. **语言显隐规则**：本文件自带 `.lang-zh` / `.lang-en` 与 `html[data-lang]` 规则，和站点
   `global.css` 里的写法一致，移植后直接删掉本文件的 `<style>` 里那几行即可（站点已定义）。
2. **菜单 mock 的 tab 用的是 CSS `:has()`**，不是 Tailwind `peer-checked`。原因写在文件注释里：
   label 和 panel 不在同一个父节点下，`peer` 编译成兄弟选择器只能覆盖一层，`:has()` 挂在卡片上两层都能覆盖
   （Chrome 105+ / Safari 15.4+ / Firefox 121+）。
3. **`og:image` 现在是占位**（指向站点 `/og.png`），上线前要换成真实的分享图。
4. 页面内所有链接都是绝对 URL，两个域名（`app.ljhsu.xin` / `create.ljhsu.xin`）都能直接搬。
5. 图标是**内联的 Lucide SVG path**（不是 emoji，也不是图标库依赖）—— MenuRight 的第三方许可里已经credit 了 Lucide(ISC)。

## 文案的事实来源

页面所有功能描述都对着仓库里的真实实现写，主要依据：

- `README.md`（功能主来源）
- `MenuRightFinder/FinderMenuBuilder.swift` —— `static func plan(...)` 决定菜单条目与顺序
- `Shared/Settings/Localization.swift` —— 菜单文案的中英逐字对照
- `Shared/CodePreview/CodePreviewSamples.swift` —— `#preview` 里那段 Swift 样例
- `Config/Version.xcconfig` —— Hero 上的 `v1.0 (1)`

有意**没有**写的东西：定价（仓库没有定价信息）、开源许可证徽章（仓库里没有 `LICENSE` 文件）、
自动更新（产品只做「检查 → 提示 → 打开下载页」）。

## 已验证 / 未验证

已做：

- 结构校验：0 处未闭合 / 错配标签，所有 `#` 锚点都有对应 `id`
- i18n：`.lang-zh` / `.lang-en` 配对检查，除 `<title>`、语言按钮「中文」与 JS 注释外没有漏标的 CJK 文本
- 语言切换的持久化逻辑（`localStorage` 读回后能正确区分 zh / en）
- 无头 Chrome 渲染：1440 / 820 / 390 三档宽度，无横向溢出（390 下 `scrollWidth == 390`）
- 中英两种模式分别截图检查过，英文模式下无中文残留

未做：

- 真实截图（见上方清单）
- Safari / Firefox 实机渲染（`:has()` 与 `aspect-ratio` 都是现代基线，理论上没问题）
