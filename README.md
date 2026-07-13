# ReadVibe — 本地离线小说阅读器

ReadVibe 是一个用 Flutter 构建的本地离线小说阅读器。它把 TXT 和 EPUB 文件导入私人书架，在设备本地完成解析、排版、阅读设置和进度保存，不接入服务器、账号或云同步。

**版本**：v0.1.0+2 | **目标平台**：Android arm64-v8a | **Release APK**：约 48.8MB

---

## 目录

- [设计理念](#设计理念)
- [技术栈](#技术栈)
- [项目结构](#项目结构)
- [架构概览](#架构概览)
  - [数据模型](#数据模型)
  - [服务层](#服务层)
  - [UI 层](#ui-层)
  - [设计系统](#设计系统)
- [核心流程](#核心流程)
  - [导入书籍](#导入书籍)
  - [阅读体验](#阅读体验)
  - [设置系统](#设置系统)
  - [数据持久化](#数据持久化)
- [翻页与动画系统](#翻页与动画系统)
  - [平滑翻页](#平滑翻页)
  - [仿书翻页](#仿书翻页)
  - [开书 / 关书转场](#开书--关书转场)
- [主题系统](#主题系统)
- [字体系统](#字体系统)
- [测试](#测试)
- [构建与部署](#构建与部署)
- [当前边界与后续规划](#当前边界与后续规划)

---

## 设计理念

**私有优先**：书籍正文、阅读进度、个人设置全部留在设备本地。不接入网络，不需要账号。

**小说优先**：EPUB 提取为纯文本阅读版，TXT 自动整理为标准小说排版（首行缩进两格、段落空行）。不试图完整还原复杂图文版式。

**沉浸优先**：阅读时隐藏 Android 状态栏；翻页不依赖按钮，靠左右滑动；点击只呼出 / 关闭菜单，无多余 UI 元素。

---

## 技术栈

| 层面 | 技术 |
|------|------|
| 框架 | Flutter 3.x / Dart 3.12+ |
| 渲染 | Material 3（自定义暖色主题，关闭水波纹） |
| 状态管理 | `StatefulWidget` + `setState`（无第三方状态库） |
| 本地存储 | `SharedPreferences`（元数据 / 设置 / 进度）+ 文件系统（章节正文） |
| 文件选择 | `file_picker` |
| EPUB 解析 | `archive`（ZIP 解压） + `xml`（OPF 解析） + `html`（XHTML → 纯文本） |
| TXT 编码 | Dart 原生 `utf8` + `fast_gbk`（中文 GBK 回退） |
| 字体加载 | Flutter `FontLoader`（动态加载用户导入的 .ttf / .otf） |

---

## 项目结构

```
ReadVibe/
├── android/                          # Android 原生工程（唯一正式目标端）
│   └── app/
│       ├── build.gradle.kts          # arm64-v8a only, minify + shrinkResources
│       └── src/main/
│           ├── AndroidManifest.xml
│           └── kotlin/com/readvibe/app/MainActivity.kt
├── windows/                          # Windows 占位空壳，暂不构建
├── lib/
│   ├── main.dart                     # 应用入口、路由配置（/ 和 /reader）
│   ├── models/
│   │   ├── book.dart                 # Book、Chapter、BookFormat 枚举
│   │   ├── reader_settings.dart      # ReaderSettings、ReadingProgress、全部枚举
│   │   └── reader_launch_args.dart   # 开书路由参数（书本 + 封面位置 + 截图）
│   ├── screens/
│   │   ├── library_screen.dart       # 书架页：导入、删除、全局设置、开书
│   │   └── reader_screen.dart        # 阅读页：正文渲染、翻页、菜单、设置
│   ├── services/
│   │   ├── storage_service.dart      # 本地持久化（SharedPreferences + JSON 文件）
│   │   ├── txt_parser.dart           # TXT 编码检测 + 章节识别 + 段落整理
│   │   ├── epub_parser.dart          # EPUB spine 顺序解析 + XHTML → 纯文本
│   │   └── font_service.dart         # 导入字体文件 + FontLoader 动态加载
│   ├── theme/
│   │   ├── app_theme.dart            # 色板、阅读主题、Material ThemeData
│   │   ├── app_spacing.dart          # 间距 token（xs ~ xxl）+ 圆角 token
│   │   └── app_motion.dart           # 动效 token + 开书 / 关书自定义路由转场
│   └── widgets/
│       ├── book_card.dart            # 书架卡片（封面、进度条、无障碍语义）
│       ├── chapter_list.dart         # 目录底部弹窗（章节列表 + 当前定位）
│       ├── reader_settings_sheet.dart # 阅读设置面板（全部选项）
│       ├── global_settings_sheet.dart # 全局字体设置抽屉
│       ├── font_settings_section.dart # 系统 / 内置宋体 / 导入字体切换组件
│       ├── pressable_scale.dart      # 按压缩放反馈（不拦截手势）
│       └── reading_progress_bar.dart # 阅读页顶部细进度条
├── test/                             # 48 项自动化测试
│   ├── widget_test.dart              # 端到端 UI 回归测试（13 项）
│   ├── txt_parser_test.dart          # TXT 解析单元测试（8 项）
│   ├── epub_parser_test.dart         # EPUB 解析单元测试（1 项）
│   ├── storage_service_test.dart     # 存储服务单元测试（7 项）
│   ├── reader_settings_model_test.dart # 设置 / 进度容错测试（6 项）
│   ├── reader_settings_sheet_test.dart # 设置面板回调测试（9 项）
│   └── book_card_test.dart           # 书架卡片渲染 / 无障碍测试（4 项）
├── docs/
│   └── UI_OPTIMIZATION.md            # 优化记录
├── samples/
│   └── readvibe-demo.txt             # 示例 TXT
├── dist/                             # 本地 APK 输出目录（git 忽略）
├── pubspec.yaml
└── analysis_options.yaml
```

---

## 架构概览

### 数据模型

```
Book
├── id: String                       # 格式：{format}_{microsecondsSinceEpoch}
├── title: String
├── author: String
├── format: BookFormat { txt, epub }
├── chapters: List<Chapter>
│   ├── index: int
│   ├── title: String
│   └── content: String              # 已整理为纯文本的章节正文
├── importDate: DateTime
└── fileSize: int

ReaderSettings                       # 阅读偏好（11 个字段）
├── fontSize: double                 # 14 / 16 / 18 / 20 / 24
├── lineHeight: double               # 1.4 / 1.6 / 1.8 / 2.0 / 2.2
├── theme: ReaderThemeMode           # system / light / warm / dark
├── fontWeight: ReaderFontWeight     # light / regular / bold
├── fontFamily: String               # 'system' 或导入字体 family 名
├── importedFontFamily: String?      # FontLoader 注册名
├── importedFontName: String?        # 原始文件名（用于 UI 显示）
├── importedFontPath: String?        # 本地存储路径
├── pageMargin: ReaderPageMargin     # compact / medium / wide
├── paragraphSpacing: ...            # blankLine / none
└── pageTurnMode: ReaderPageTurnMode # smooth / book

ReadingProgress
├── bookId: String
├── chapterIndex: int
├── scrollOffset: double
└── lastReadDate: DateTime
```

所有枚举都有中文 label 扩展和对应的 `FontWeight` / `horizontalPadding` 等映射值。

### 服务层

| 服务 | 职责 |
|------|------|
| `TxtParser` | 在后台 isolate 解码 UTF-8 / UTF-16（含 BOM）→ GBK 回退；识别中英文章节标题；兼容 CR/LF 换行；段落统一整理 |
| `EpubParser` | 在后台 isolate 解压 ZIP → 解析 `container.xml` / OPF → 按线性 spine 顺序提取 XHTML → 纯文本；限制异常解压体积 |
| `StorageService` | 书架只加载元数据，打开书时再读取正文；设置 / 进度防止旧异步写入覆盖新值；章节原子写入并从 `.tmp` / `.bak` 自动恢复；遗留数据自动迁移 |
| `FontService` | 用 `FilePicker` 选 .ttf/.otf → 校验大小 → 复制并注册到 Flutter 引擎；并发加载去重，替换后清理旧字体文件 |

### UI 层

```
ReadVibeApp (MaterialApp)
├── / (LibraryScreen)          书架页
│   ├── BookCard × N           每个书本卡片（封面 + 进度条 + 格式徽章）
│   ├── GlobalSettingsSheet    左侧滑出抽屉（全局字体设置）
│   └── → /reader              点击封面以动画方式打开阅读页
│
└── /reader (ReaderScreen)     阅读页
    ├── ReadingProgressBar     顶部 2px 进度条（始终可见）
    ├── 正文区域                 章节标题 + 段落列表
    │   ├── 平滑模式             跟手滑动 + 相邻章预热
    │   └── 仿书模式             裁切 + 阴影 + 折页高光
    ├── 顶部菜单栏               返回按钮 + 书名（点击呼出 / 关闭）
    ├── 底部菜单栏               目录按钮 + 设置按钮
    ├── ChapterListSheet        目录底部弹窗
    └── ReaderSettingsSheet     设置底部弹窗（字号 / 行距 / 字重 / 页边距 / 段落 / 翻页 / 主题）
```

### 设计系统

所有视觉 token 集中在 `lib/theme/` 下，不散落在组件中：

**间距**：`AppSpacing` — xs (4) / sm (8) / md (12) / lg (16) / xl (24) / xxl (32)

**圆角**：`AppRadius` — sm (8) / md (12) / lg (16) / pill (24)

**动效**：`AppMotion` — 从 96ms（按压反馈）到 680ms（开书转场），含多条自定义贝塞尔曲线。所有手写动画使用同一套 token，没有第三方动画库。

**色板**（Claude-inspired 暖色系）：

| Token | 颜色 | 用途 |
|-------|------|------|
| `background` | `#FAF7F2` | 暖米色背景 |
| `surface` | `#FFFFFF` | 卡片 / 面板底色 |
| `textPrimary` | `#3D3229` | 正文文字 |
| `textSecondary` | `#6F6358` | 次要信息 |
| `accent` | `#B3543A` | 赤陶色强调（按钮、徽章） |
| `error` | `#B04545` | 错误提示 |
| `success` | `#4F7D60` | 成功状态 |

**阅读主题**：四个预设（浅色 / 暖色 / 深色 / 跟随系统），每个预设独立定义背景、文字、次要色、标题栏色、边框、强调色。

**去水波纹**：全局关闭 Material 水波纹效果（`NoSplash.splashFactory` + 透明 overlay/highlight/hover），避免阅读页出现不需要的视觉反馈。

---

## 核心流程

### 导入书籍

1. 用户在书架页点击 "导入"，`FilePicker` 弹出系统文件选择器（过滤 .txt / .epub）
2. 根据扩展名路由到 `parseTxt()` 或 `parseEpub()`
3. 解析器返回 `Book` 对象（含章节列表、元数据）
4. `StorageService.saveBook()` 先把章节内容写入文件（原子写入），再把书架元数据写入 SharedPreferences
5. 刷新书架列表，新书出现在最前面

**TXT 解析细节**：

```
读取文件字节
  ├── 检查 UTF-8 / UTF-16 LE / UTF-16 BE BOM
  ├── 无 BOM 时尝试 strict UTF-8 解码
  └── 失败 → GBK 回退
分割为行
  ├── 正则识别章节标题（第N章 / Chapter N / 第N回 / 卷N ...）
  ├── 单标题 → 保留为唯一章节名
  ├── 无标题 → 整书为一章 "全文"
  └── 多标题 → 在边界处切分
段落整理（normalizeTxtContent）
  ├── 删除每行前导空格
  ├── 统一添加全角缩进 "　　"
  ├── 段落间用 \n\n 分隔
  └── 空行丢弃
```

**EPUB 解析细节**：

```
读取 ZIP bytes → ZipDecoder 解压
  ├── 解析 META-INF/container.xml → 获取 OPF 路径
  ├── 解析 OPF
  │   ├── 提取 metadata（title, creator）
  │   ├── 构建 manifest（id → 文件路径映射，处理 URL 编码）
  │   └── 按 spine 顺序提取 itemref idref 列表
  ├── 按 spine 顺序逐个解析 XHTML 文件
  │   ├── 编码检测（UTF-8 / UTF-16 LE / BE / BOM）
  │   ├── html_parser 解析 DOM
  │   ├── 提取章节标题（h1 → h2 → h3 → <title> 回退）
  │   └── 递归遍历 DOM → 纯文本（识别块级元素插入换行，跳过 script/style/head）
  └── 返回 Book（空章节的 spine 项自动跳过）
```

### 阅读体验

**翻章交互**：

- **点击正文中央** → 呼出 / 关闭顶部和底部菜单栏
- **左右滑动** → 切换上一章 / 下一章
- **菜单打开时状态栏自动显示**，菜单关闭时状态栏重新隐藏
- 页面底部无翻页按钮，避免误触

**菜单栏**：

- 顶部：返回按钮 + 书名（居中对齐，右侧留空平衡）
- 底部：目录按钮（显示当前章节号）+ 设置按钮（显示当前字号）
- 菜单以 `AnimatedSlide` + `AnimatedOpacity` 滑入 / 滑出
- 菜单隐藏时通过 `IgnorePointer` + `ExcludeSemantics` 完全不影响正文触摸

**布局稳定性**：

- 开书时先在构建时快照 `viewPadding.top`（状态栏仍在），之后状态栏被隐藏后继续使用快照值
- 确保正文区域从上到下始终固定，不因状态栏消失而跳动

**阅读进度**：

- `ScrollController` 监听滚动 → 500ms 防抖 → 同时保存章节像素偏移、0–100% 阅读比例和最后阅读时间
- 应用进入后台 / 页面关闭时立即保存
- 打开书籍时自动恢复到上次阅读位置
- 每章滚动位置独立保存；目录跳转从顶部开始，左右翻章恢复该章原位置
- 设置改变正文高度后按阅读比例重新定位；页面卸载时使用最后一次真实滚动快照，不会再以 0 覆盖进度
- 顶部 2px 进度条实时显示当前章节滚动进度（不依赖菜单开关，始终可见）
- 长章节通过懒加载列表渲染，正文拆分结果使用小型 LRU 缓存

### 设置系统

**设置存放位置**：

- `ReaderSettings` → SharedPreferences（全局共享）
- 书架全局设置（字体）和阅读页设置（字号 / 行距 / 主题等）读同一份设置
- 修改即保存（`onChange` → 同时 `setState` + `_storage.saveSettings`）

**设置延迟应用**：

阅读页设置变更后不立即重排正文，而是通过 `_queueSettingsApply` 用 120ms Timer 延迟执行。这保证了设置面板自身的选择动画（高亮滑动）有干净的前几帧，不会被昂贵的正文布局计算拖慢。

**设置面板**：

- 每个选项是 `_buildSegmentedControl` — 一个高亮块在等宽槽位间滑动，选项本身不单独变色
- 字号：14 / 16 / 18 / 20 / 24
- 行距：1.4 / 1.6 / 1.8 / 2.0 / 2.2
- 字重：细 / 常规 / 粗（对应 FontWeight.w300 / w400 / w600）
- 页边距：窄 (16) / 中 (24) / 宽 (32)
- 段落空行：不空行（默认）/ 空一行
- 翻页模式：平滑 / 翻书
- 主题：系统 / 浅色 / 暖色 / 深色
- 字体：系统字体 / 内置宋体 / 导入字体 + 导入按钮

### 数据持久化

```
SharedPreferences:
├── readvibe_books         → JSON 列表（书架元数据，不含正文）
├── readvibe_settings      → JSON（ReaderSettings）
├── readvibe_progress_{id} → JSON（ReadingProgress）
└── [legacy] readvibe_chapters_{id} → 第一次读取时迁移到文件后删除

文件系统 (ReadVibe/):
├── books/{base64(id)}.json  → JSON 列表（Chapter 完整数据）
│   └── 原子写入：.tmp → .bak 备份 → rename → 清理 .bak
└── fonts/{timestamp}_{name}.ext → 用户导入的字体文件
```

**遗留数据迁移**：早期版本把章节正文也存 SharedPreferences，会导致 key-value 过大和性能问题。`StorageService._loadChapters()` 首次读取时自动迁移到文件，并清理遗留 key。

**故障恢复**：如果应用在原子替换正文文件的过程中被系统终止，下次读取会依次检查主文件、完整的 `.tmp` 和 `.bak`，恢复成功后重新写回标准主文件。

---

## 翻页与动画系统

所有动效由 `AppMotion` 统一管理 tokens，不散落硬编码 duration / curve。

### 平滑翻页

- **跟手拖动**：手指左右滑动时页面跟随移动（`_handleHorizontalDragUpdate`）
- **相邻章预热**：章节首次加载后通过 `_scheduleAdjacentWarmup` 触发相邻章节布局，确保翻页时页面已就绪
- **门限判断**：松手时检查滑动距离（>16% 页宽）或滑动速度（>260 px/s）决定翻章或回弹
- **动画回弹**：回弹动画 220ms，`AppMotion.standard` 曲线

### 仿书翻页

- **页面裁切**：`_BookPageClipper` — 用 `quadraticBezierTo` 在页面边缘形成轻微弧线，模拟书页弯曲
- **折页阴影**：`_BookCurlPainter` — 在翻页接缝处绘制阴影渐变（`shadowOpacity` 随翻页进度变化）
- **高光**：翻页面靠近折痕处加白色半透明高光，模拟光线在书页上的反射
- **自适应**：动画阶段只播放于距离判定后的 settle 动画，拖动阶段仍然跟手

### 开书 / 关书转场

这是项目中工程量最大的动画系统，位于 [app_motion.dart](lib/theme/app_motion.dart) 的 `buildFadeScaleRoute` 中。设计参考了 HarmonyOS 动效原则中的共享元素与一镜到底。

**打开（680ms）分四段**：

1. **Pickup (0–22%)**：书架封面截图从原位放大 1.08× 并上浮 8px（`bookPickupCurve`）
2. **Travel (2–48%)**：封面从书架位置移动到全屏位置（`AppMotion.standard`）
3. **Cover Open (38–96%)**：封面页以左缘为轴做 3D Y 轴旋转 -90° 翻开（`bookCoverCurve`，含 `Matrix4.rotateY` + perspective）
4. **Content Reveal (46–92%)**：阅读内容渐显，替换封面（`AppMotion.standard`）

同时伴随：
- 背景渐变暗（0–58%，0.16 透明度）
- 阴影从卡片阴影过渡到全屏展开阴影再消退
- 圆角从 16px 线性过渡到 0

**页面打开的内部结构**（`_OpeningPage`）：

- 封面截图铺满（若有）或渐变底色
- 折缝处渐变阴影（模拟书页翻起的折痕）
- 书脊侧窄条阴影（0.11 宽度比，模拟书脊厚度投影）

**关闭（520ms）**：同时间轴反向执行，先恢复状态栏再收回封面。

**路由特性**：

- `opaque: false` — 转场时书架背景可见，关闭时不会闪黑
- `AbsorbPointer(absorbing: progress < 0.995)` — 转场期间禁止点击
- `RepaintBoundary` 包裹子组件，隔离重绘范围

---

## 主题系统

**应用级**：`AppTheme.theme` / `AppTheme.darkTheme` — Material 3 ThemeData，跟随系统深浅色。

**阅读页级**：`ReaderThemeColors` — 独立于应用主题的四个阅读预设：

| 模式 | 背景 | 文字 | 强调色 |
|------|------|------|--------|
| 浅色 | `#FFFFFF` | `#3D3229` | `#B3543A` |
| 暖色 | `#FAF7F2` | `#3D3229` | `#B3543A` |
| 深色 | `#1A1816` | `#E8DFD4` | `#E3936F` |
| 跟随系统 | 深色模式 → 深色，否则 → 暖色 | | |

书架页和阅读页使用同一份阅读主题色，视觉一致。

---

## 字体系统

1. **系统字体**：使用 Android 系统默认中文字体（fontFamily 设为 null）
2. **导入字体**：用户通过 `FilePicker` 选择 .ttf 或 .otf → 复制到 `ReadVibe/fonts/` → `FontLoader` 注册为 `ReadVibeImported_{timestamp}` → 切换到该字体
3. **持久化**：字体设置（含导入字体路径）保存在 `ReaderSettings` 中
4. **启动恢复**：`FontService.ensureImportedFontLoaded()` 在每次读设置时被调用，确认导入字体文件仍在 → 若文件丢失则安全回退到系统字体
5. **已加载缓存**：`_loadedFamilies` 静态集合防止重复加载同一字体

---

## 测试

**48 项测试全部通过**，覆盖范围：

| 类别 | 测试 | 数量 |
|------|------|------|
| TXT 解析 | UTF-8 / UTF-16 BOM、GBK 回退、CR/LF、空文件、章节识别、段落格式化 | 8 |
| EPUB 解析 | 元数据 + 线性 spine 顺序 + HTML 实体解码 + 非线性页面跳过 | 1 |
| 存储 | 正文 / 摘要按需读取、主文件 / 备份恢复、删除、迁移、字体清理 | 7 |
| 设置 / 进度模型 | 默认值与旧版迁移、损坏数值、偏移 / 比例容错与原子进度快照 | 6 |
| 书架卡片 | 标题渲染、InkWell、无障碍语义、损坏进度容错 | 4 |
| 设置面板 | 字号 / 行距 / 宋体 / 主题 / 页边距 / 字重 / 段落顺序 / 翻页模式等 | 9 |
| 端到端 | App 启动、390px 视口、菜单 / 设置、设置重排定位、章节双向及重启恢复、大章节懒加载等 | 13 |

运行命令：

```bash
flutter test --reporter expanded
```

注意：测试中书架页的空状态动画是无限循环的 `AnimationController.repeat()`，必须用固定 `pump(duration)` 而非 `pumpAndSettle()`，否则测试会永远等待。

---

## 构建与部署

**目标架构**：仅 Android arm64-v8a（已删除 32 位、x86、x86_64 兼容）

**构建命令**：

```bash
flutter build apk --release --split-per-abi --target-platform android-arm64
```

**产物位置**：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`

**体积优化**：

- Release 构建开启 `isMinifyEnabled = true` 和 `isShrinkResources = true`
- ProGuard 规则 `proguard-rules.pro`
- 当前 Release APK 约 48.8MB

**安装**：将 APK 传输到 64 位 Android 手机，开启 "允许安装未知应用"，即可安装。当前使用 debug 签名，正式发布前需要创建 release 签名。

---

## 当前边界与后续规划

**v0.1 定位**：私人小说阅读器 demo。以下内容暂不在范围内：

- 真实封面图片提取和管理
- 书签、批注、全文搜索
- 云同步、账号系统
- 听书 / TTS
- 复杂 EPUB CSS / 图文版式还原
- Android 平板专门布局
- Windows / iOS / macOS / Linux / Web 端

**后续优先级高**：

- 真机体验开书 / 关书动画，微调翻转角度和阴影
- 低端设备快速连续滑动翻章的帧率观察
- 完善异常提示（导入字体失败、EPUB 格式异常等）
- 设计正式 App 图标

**中期考虑**：

- 书签、批注、全文搜索
- 封面图片提取
- 更完整的 EPUB CSS 支持
- Android 平板布局
- 如需桌面端，重新生成 Windows 平台工程

---

## 开发环境

- **Flutter SDK**：stable channel，`D:\flutter`
- **Java**：Eclipse Adoptium JDK 17
- **Android SDK**：`D:\Android\Sdk`（API 34 / 35 / 36）
- **Shell**：PowerShell 7 / `pwsh.exe`

常用命令：

```powershell
# 进入项目
cd D:\0_Study\0_Stdio\0_Codex_work\1.ReadVibe_Project\ReadVibe

# 安装依赖
flutter pub get

# 静态检查
flutter analyze

# 运行测试
flutter test --reporter expanded

# 连接设备后运行
flutter run -d <device-id>

# 构建 Release APK
flutter build apk --release --split-per-abi --target-platform android-arm64
```
