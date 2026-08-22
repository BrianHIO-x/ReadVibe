# ReadVibe 仓库协作规则

本仓库根目录就是 ReadVibe Flutter 应用根目录，本规则覆盖仓库内的应用代码、Android 原生代码、资源、文档和发布产物。

## 工作方式

- 默认命令环境为 PowerShell 7。
- 文件与文本搜索优先使用 `rg` 和 `rg --files`。
- 文本修改使用补丁；保留用户已有且与当前任务无关的改动。
- 不使用会丢失工作内容的破坏性 Git 命令。
- ReadVibe 是本地离线阅读器。书籍正文、阅读进度和设置均保存在设备本地，不加入账号、云同步或正文上传。

## 当前发布配置

- 公开版本：`v0.6.7`。
- Android 应用 ID：`com.readvibe.app`。
- 正式 ABI：`arm64-v8a`。
- 最低系统：Android 8.0（API 26）。
- Dart SDK 约束：`^3.12.2`。
- Java 与 Kotlin JVM 目标：17。
- 正式 APK：`dist/ReadVibe-Android-v0.6.7-arm64-v8a.apk`。
- 当前正式 APK 为 `60,085,390` 字节，SHA-256 为 `1113D0CBA9909FE2653DAF91A3BFE0E54BDD0119D0DCA351196C656B0D53F0C8`。
- `v0.6.7` 起 release 强制读取本机 `android/key.properties` 和忽略提交的 `android/app/readvibe-release.jks`；缺少密钥时 release 构建必须失败，不能回退 debug。发布密钥与密码文件必须由用户单独安全备份。
- 正式签名别名为 `readvibe`，证书有效期至 2076-08-21，SHA-256 指纹为 `BB3BDE2FE3978FBB033A3A0B440EC1B504A7FE30B47A6345CEFC0B4844F3EA86`。
- `pubspec.yaml` 只写公开三段式版本；Android `versionCode` 独立递增，不进入公开版本号、APK 文件名或发布标题。Flutter 的 arm64 分包在基础构建号上增加 `2000`，当前构建传入 `53`，APK 清单中的实际 `versionCode` 为 `2053`。
- `windows/` 只有平台状态说明，不是可构建的 Windows 工程。

## 代码范围

- `lib/screens/library_screen.dart`：书架、导入、书卡操作、整理顺序、延迟存储维护和可选更新检查。
- `lib/screens/reader_screen.dart`：TXT、EPUB、MOBI/AZW、DOCX、DOC 共用的小说阅读器。
- `lib/screens/reader/` 与 `lib/controllers/`：选区、仿真分页几何及阅读进度/分页/搜索/选区控制器。
- `lib/screens/pdf_reader_screen.dart`：PDF 固定版式逐页阅读器、显示主题、页码进度、跳页、书签、批注和 OCR。
- `lib/services/`：文件解析、搜索、字数、字体、存储、PDF 渲染和系统外部应用桥接。
- `lib/widgets/`：书卡、目录、搜索面板和阅读页面组件。
- `android/app/src/main/kotlin/com/readvibe/app/MainActivity.kt`：DOC、PDF 与 Android Intent 原生能力。
- `assets/fonts/`：内置宋体。
- `assets/images/ai/`：六个 AI 翻译目标图标。

## 实现约束

### 数据与存储

- 书籍和阅读数据保持本地离线，不上传正文。
- 同一设置、进度或目录状态的异步写入按键串行，旧写入不能覆盖新状态。
- 删除书籍后，仍在运行的字数或进度任务不能重新写回该书数据。
- 书籍元数据与章节正文载荷分开存储；书架启动不为缺失字数逐本加载正文。打开未统计书籍时只扫描一次各章正文，全文字数由分章结果求和，并且只在源文件大小、解析版本、章节数和格式均匹配时原子写回两项统计。
- 书架首屏完成后延迟扫描 `books/`、`epub/` 和 `pdf/`；只清理失去 metadata 引用且超过 24 小时的私有载荷。
- 删除 EPUB 同步清理应用私有图片目录；删除 PDF 同步清理受管理源文件和原生页面缓存。
- 书架对章节文件只做定长首尾与存在性检查，不在启动时解码全书；缺失或明显截断的载荷显示状态并提供删除入口。
- PDF 页码进度与小说 `ReadingProgress` 分开存储；旧 PDF 章节式进度只在打开 PDF 时迁移，书架摘要读取不触发迁移写入。PDF 书签按书串行保存并随删除清理。
- 小说正文使用版本 2 分章目录：`books/<safeId>/manifest.json` 与 `chapters/<index>.json`。写入以 `.tmp/.bak` 目录交换提交，每次最多批量编解码 16 章；旧单体 JSON 保持恢复与后台迁移能力。
- 版本 2 目录加载后以共享 LRU 的懒章节代理暴露正文，UI isolate 最多缓存 8 个已访问章节；搜索和字数在各自 worker isolate 内读取章节。目录标题、卷信息和富内容标记来自 manifest，不得为了展示目录加载正文。
- PDF 书签与页码笔记按书串行保存并随删除清理。
- 分章清单记录每章字节数、SHA-256、富内容块数量和语义标题标志；首屏检查清单结构与文件长度，30 秒后的低优先级深检再校验内容摘要。连续模式不能为取得富内容块数量提前读取所有章节。
- DOCX 图片资源保存在 `word/<bookId>/` 并按与 EPUB 相同的引用、宽限期和删除规则维护。

### 小说阅读器

- TXT、EPUB、MOBI、AZW、AZW3、DOCX 和 DOC 只能进入同一个 `ReaderScreen`，共享目录、搜索、文本选择、设置、三种阅读模式和进度模型。
- 阅读模式顺序为“分章 / 滚动 / 仿真”，默认“分章”。仿真模式显示“仿真翻页 / 平滑翻页”，默认“仿真翻页”。
- 菜单、主题、字体、字号、字重、行高、页边距、段落空行或阅读模式变化后，正文恢复到变更前的字符锚点，不能回到章节顶部。
- 分章模式只滚动当前章；滚动模式用一个连续纵向流承载全书；仿真模式按完整正文行分页。
- 进入或离开仿真模式，以及在仿真模式内修改字体或排版时，重新创建阅读控制器，通过当前视口顶部正文字符确定目标页或目标滚动位置，不复用另一排版的像素偏移。
- 搜索跳转、相邻章预览和阅读恢复在页面可见前完成目标定位，不先显示章节开头再二次跳转。
- EPUB 搜索段落顺序必须与阅读器的全部非空文本块一致，包括正文标题块。

### 仿真翻页

- 仿真页包含章节小字页眉、上下纸页留白和完整行正文视口；行网格使用当前字体实际排出的相邻基线距离，不能用 `字号 × 行高倍率` 的理论值代替。
- 章节标题块必须扩展到正文行网格的整数倍；仿真模式内的字体与排版变化立即使用最终文本指标，不对会影响行盒的样式做插值动画。
- 仿真页先按整章文本或 EPUB 内容块的实际排版高度确定滚动范围，再扩展到整数个正文视口；翻页只在整屏边界间移动，章尾不足一页的区域使用空白纸面补齐，不使用惰性列表的估算范围生成重复末页。
- 左滑前翻折回当前页；右滑后翻由上一页展开并覆盖当前页。
- 双向翻页共用直线纸边、垂直折痕、裁切和阴影几何；页面不使用弯曲、斜折或波浪纸边。
- 纸背显示运动纸页的水平镜像反向字迹。快照未完成时使用绑定同一章节和位置的镜像页面层，不能变成纯色纸带或平移翻页。
- 快照只属于当前页面和手势；正文位置、设置、章节、菜单或手势状态变化时失效。
- 平滑翻页不捕获纸背快照，但继续使用仿真模式的分页、页眉和进度模型。
- 跨章向前回翻固定落在上一章实际最后一页，不能混用历史 offset 与 `progress = 1`。
- 目录、设置、搜索和选区外部操作统一进入 reader modal 视口锁，关闭后才释放仿真高度。
- EPUB 仿真文本块使用按正文基线整数倍扩展的强制 strut；块起点、内部行盒和块总高都不能让纸页边界切过半行字。

### 文本选择

- 双击不选择文本；长按只有形成非空、非纯空白选区后才显示复制、分享、全选、翻译和搜索。
- 选区活动期间，系统选择手势优先，横向翻页和底层手指滚动不能改变阅读位置。
- 分章模式的连续框选限制在当前章；滚动模式可沿全书连续框选；仿真模式的选择范围固定在当前纸页。
- 仿真模式中，选区活动期间滚动范围收敛到当前像素，边缘选择不能驱动正文上下移动、跨页或递归滚动动画。

### EPUB 与 PDF

- TXT 先严格尝试 UTF-8，并识别 UTF-16 BOM；失败后对 GBK 与 Big5 候选做替换字符、控制字符、常用中文与章节形态评分，不能固定把传统中文 Big5 当作 GBK。
- EPUB 按 OPF spine 本地解析 XHTML，目录标题优先来自 EPUB3 NAV 或 EPUB2 NCX；没有导航标题时回退到正文语义标题或文档标题。
- EPUB 普通段落使用与 TXT 一致的用户排版设置；正文语义标题保留层级、颜色和强调样式，并替代阅读器额外生成的章节标题，不能在同章重复显示。
- 外部 CSS 文本、解析规则和元素声明在一次导入内缓存；相邻同样式文本合并，结构化块落盘时不重复保存完整纯文本副本。
- EPUB 输出结构化正文块并在加载时恢复搜索、字数和字符定位所需的纯文本；它与 TXT 共用阅读页面和手势。
- EPUB 封面优先读取 EPUB3 `cover-image`，其次读取 EPUB2 `meta name="cover"`，提取到该书私有资源目录并保存为书架 metadata。
- EPUB 只解析包内相对资源和 base64 图片，不加载网络资源。
- EPUB 在读取压缩包前限制输入为 256 MB，展开后总量限制为 512 MB；单张图片限制为 64 MB，data URI 在 Base64 解码前先校验编码长度对应的最大体积。
- EPUB `encryption.xml` 中指向 OPF 或 spine 的加密条目必须作为 DRM/加密正文明确拒绝；不能尝试移除 DRM。
- EPUB 未加密 TTF/OTF `@font-face` 可提取到书籍私有目录并动态加载；不支持的字体容器或加密字体必须安全回退。
- DOCX 保留核心书名/作者、标题层级、常见行内样式、表格、脚注和包内图片；旧 DOC 在 Android 通过 POI 提取正文与核心元数据，不冒充完整固定版式。
- 无 DRM 的 MOBI、AZW 与 AZW3/KF8 通过本地解析器展开；输入上限 256 MB，展开正文上限 512 MB，DRM/加密内容明确拒绝。
- PDF 使用独立固定版式页面阅读器，原生渲染任务按文件、页码和目标宽度缓存；PDFBox-Android `2.0.27.0` 在本地提供文字搜索、大纲、已有批注读取及页笔记写回。
- PDF 原文件字号不可修改，界面提供缩放与原始/纸张/深色显示主题。密码只在导入时用于生成私有已解锁副本，不持久化密码。
- 扫描 PDF 使用随 APK 打包的 ML Kit 中文模型做离线当前页识别或 OCR 全文搜索；页面图像不得上传，OCR 缓存按 PDF 内容指纹和页码隔离。
- DOC 解析与 PDF 渲染使用不同的原生单线程执行器；同一 PDF 生命周期内复用一个 `PdfRenderer`，缓存键包含规范路径、大小、修改时间和首尾内容指纹。

### 搜索与外部应用

- 小说搜索面板使用一个按面板生命周期存在的后台 isolate；书籍只在首次查询时传入一次，后续关键词复用按约 12M 字符 LRU 保存的规范化章节，最多返回 500 条。
- 搜索结果以章节、段落和原始 UTF-16 字符位置作为跳转锚点；摘要高亮使用 worker 返回的原文范围，不能用未规范化 query 二次查找。
- 翻译和网页搜索目标由 Android 系统查询真实可处理 Intent 的应用，Flutter 只展示允许的 AI 应用及 Edge、Chrome、系统浏览器。
- 记住的默认目标在启动前再次校验；启动失败时清除失效默认值并重新显示选择界面。
- 自动检查更新默认关闭；只有用户手动检查或自行开启开关时才连接 GitHub Releases。发现版本后只打开 HTTPS 发布页，不申请 `REQUEST_INSTALL_PACKAGES`，不在应用内下载或安装 APK。
- Android `ACTION_VIEW` 声明 TXT、EPUB、MOBI/AZW、PDF、DOCX 和 DOC MIME；外部 `content://` 先限量复制到私有缓存，再串行调用现有导入器，临时副本在完成后删除。

## Markdown 同步

代码、配置、资源、依赖、版本、构建方式、发布产物或用户可见行为发生变化时，必须使用 `rg --files -g '*.md'` 检查并同步全部 Markdown。文档只写当前源码中已经存在的功能、当前构建方式和真实验证结果。

当前 Markdown 文件为：

- `AGENTS.md`
- `README.md`
- `docs/UI_OPTIMIZATION.md`
- `windows/README.md`

新增、删除、移动或重命名 Markdown 时，同时更新本清单和相关链接。

## 修改与验证

- 阅读页变更必须保护当前章节、当前视口正文位置、每章独立进度和跨章保存顺序。
- 菜单、主题、字体、排版与阅读模式变化不能把正文重置到章节顶部。
- 异步存储只允许最新状态覆盖同一数据项；已删除书籍的后台任务不得重新写回元数据或进度。
- 当前测试目录包含 parser、存储、搜索、字数、更新、外部导入、EPUB 字体、FontService、MOBI、Word、ReaderScreen/controller、PdfReaderScreen/PdfRenderer 测试和 `flutter_test` 依赖。未经用户明确要求，不新增自动化测试，也不以测试数量作为交付结论。
- `.github/workflows/flutter.yml` 在 push 到 `main` 或创建拉取请求时执行依赖解析、`flutter analyze --no-pub`、`flutter test --no-pub`、Android debug APK 和使用临时 CI 证书的 arm64 release smoke APK 构建；临时证书只用于编译验证，不能替代正式发布密钥。
- Dart、Flutter、Android、原生代码或工程结构变更后至少执行 `flutter analyze`、现有 `flutter test`，并构建 Android arm64 release APK。
- 交付前核对公开版本、ABI、最低系统、APK 文件名、实际体积和 SHA-256，并再次盘点全部 Markdown。

在仓库根目录执行：

```powershell
flutter analyze
flutter test
flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 0.6.7 --build-number 53
```

构建完成后把 `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk` 复制为 `dist/ReadVibe-Android-v0.6.7-arm64-v8a.apk`，并核对版本名、内部版本码、最低 SDK、ABI、签名、体积和 SHA-256。
