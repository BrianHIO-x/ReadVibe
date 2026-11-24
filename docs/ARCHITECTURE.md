# ReadVibe 项目文件详解

ReadVibe 是一款 Flutter 编写的 Android 本地离线阅读器，支持 TXT、EPUB、MOBI、AZW、AZW3、PDF、DOCX、DOC 八种格式。本文按目录顺序逐一说明仓库内每个文件的用途，供导航与协作参考。构建缓存、IDE 配置等本地生成物不在收录范围内。功能与参数以当前代码实现为准。

## 项目分层总览

```
lib/
  main.dart            应用入口与路由
  screens/             三个全屏页面（书架、文字阅读、PDF 阅读）
  screens/reader/      文字阅读的排版、分页与选区子组件
  controllers/         阅读相关状态编排
  widgets/             可复用界面组件
  services/            解析、存储、备份、平台通道等业务服务
  services/epub/       EPUB 解包、CSS、导航与媒体存储子模块
  services/storage/    存储层的独立子模块
  repositories/        持久化接口契约
  models/              纯数据模型
  theme/               颜色、间距与动效设计系统
android/               Android 工程与原生能力
tool/                  工具脚本
docs/、design/、assets/  文档、图标源文件与静态资源
```

依赖方向整体为 screens → controllers/widgets → services → repositories(接口) → models，数据与领域层禁止反向引用页面与组件。

---

## 根目录文件

| 文件 | 作用 |
|---|---|
| `pubspec.yaml` | 项目清单。声明包名、公开版本和 Android 内部构建号、Dart 约束、运行依赖、开发依赖、字体和其他打包资源。 |
| `pubspec.lock` | 依赖解析结果快照，锁定每个依赖包的确切版本，保证构建可复现。 |
| `analysis_options.yaml` | Dart 静态分析配置。启用 `flutter_lints` 推荐规则集，未额外增删规则。 |
| `AGENTS.md` | AI 协作约定。描述项目入口目录、工作原则、版本递增规则，以及用 VS Code 的 Android 模拟器确认改动。 |
| `README.md` | 项目介绍。涵盖功能概览、安装与导入方式、隐私保护承诺。 |
| `.gitignore` | Git 忽略规则，排除构建产物与本地配置。 |
| `.metadata` | Flutter 工具记录的工程元数据（平台、模板版本），由 `flutter` 命令维护，勿手工编辑。 |
| `.flutter-plugins-dependencies` | Flutter 自动生成的插件依赖清单，列出各平台的插件注册信息。 |

---

## .github/workflows/

| 文件 | 作用 |
|---|---|
| `flutter.yml` | GitHub Actions 工作流配置。 |

---

## android/

| 文件 | 作用 |
|---|---|
| `build.gradle.kts` | Android 根构建脚本。配置 Google/Maven 仓库，并把全部构建输出重定向到项目根目录的 `build/`；所有子工程依赖 `:app` 的评估结果。 |
| `settings.gradle.kts` | Gradle 设置。读取 `local.properties` 中的 Flutter SDK 路径，声明 AGP 9.0.1 与 Kotlin 2.3.20 插件版本，仅包含 `:app` 子工程。 |
| `gradle.properties` | Gradle JVM 参数（8G 堆、4G 元空间），启用 AndroidX，关闭 Kotlin 增量编译，保留 Flutter 模板的 `newDsl=false` 与 `builtInKotlin=false` 兼容标记。 |
| `gradlew`、`gradlew.bat` | Linux/macOS 与 Windows 平台的 Gradle Wrapper 启动脚本。 |
| `key.properties` | 本地私密配置，保存正式 release 签名的密钥库路径与口令，不入库。 |
| `local.properties` | 本机 Android SDK 与 Flutter SDK 路径，自动生成。 |
| `gradle/wrapper/gradle-wrapper.jar` | Gradle Wrapper 可执行 jar。 |
| `gradle/wrapper/gradle-wrapper.properties` | Wrapper 版本声明（Gradle 9.1.0）。 |

## android/app/

| 文件 | 作用 |
|---|---|
| `build.gradle.kts` | 应用模块构建脚本。命名空间 `com.readvibe.app`，minSdk 26；release 构建强制要求 `key.properties` 正式签名并拒绝回退 debug 签名，开启 R8 混淆与资源收缩；依赖 Apache POI（旧版 DOC 解析）、PDFBox-Android（PDF 分析）与 ML Kit 中文 OCR（扫描件识别，模型随包离线内置）。 |
| `proguard-rules.pro` | R8 保留规则。忽略 POI 的桌面 AWT 可选依赖与 log4j 的可选 findbugs/OSGi/bnd 注解、PDFBox 的可选 JP2 解码器告警，保证旧版 DOC 解析在 Android 上可编译。 |
| `readvibe-release.jks` | 本地正式签名密钥库，属私密材料。 |

## android/app/src/main/

| 文件 | 作用 |
|---|---|
| `AndroidManifest.xml` | 主清单。声明 `INTERNET`、`REQUEST_INSTALL_PACKAGES` 与 `USE_BIOMETRIC` 三项权限，分别用于联网检查更新、应用内安装更新包和隐私书架的生物验证；注册不导出的 FileProvider（授权 `${applicationId}.updates`，范围见 `xml/update_paths.xml`）把下载好的安装包临时授权给系统安装程序；MainActivity 以 `singleTop` 启动，注册两组 ACTION_VIEW intent-filter 实现外部“用其他应用打开”：一组匹配声明了真实类型的发送方（含 AZW3 专属类型），另一组匹配把电子书报成 `application/octet-stream` 的文件管理器，并要求文件名以受支持扩展名结尾，避免认领任意未知文件；`<queries>` 中显式列出允许的六个 AI 翻译应用与两个浏览器包名。 |
| `java/.../GeneratedPluginRegistrant.java` | Flutter 自动生成的插件注册类，勿手工编辑。 |

## android/app/src/main/kotlin/com/readvibe/app/（原生代码）

| 文件 | 作用 |
|---|---|
| `MainActivity.kt` | 精简原生宿主 Activity。负责注册并释放各独立 Handler（`ReaderWindowHandler`、`BiometricHandler`、`MotionHandler`、`AppUpdateHandler`、`BookExportHandler`、`PdfChannelHandler`、`IncomingFileHandler`、`BookPickerHandler`、`DocExtractorHandler`、`SystemTextActionHandler`），以及转发生命周期回调（`onPause`、`onResume`、`onNewIntent`、`onActivityResult`、`onDestroy`）。 |
| `IncomingFileHandler.kt` | 外部文件接收通道 `incoming_file`。串行消费外部 ACTION_VIEW 文件、解析显示名并复制到应用私有缓存。 |
| `BookPickerHandler.kt` | 系统文件选择通道 `book_picker`。封装 SAF 选择（`pickBooks` 启用 `ACTION_OPEN_DOCUMENT` 与 `Intent.EXTRA_ALLOW_MULTIPLE` 多选导入，另有单选 `pickFont` 与 `pickBackup`）；复制走独立线程池，切回前台若请求悬着按取消作答，连续卡顿超时结束并清理未完成调度。 |
| `DocExtractorHandler.kt` | 旧版 Word 提取通道 `document_parser`。经单线程执行器在后台调用 Apache POI 提取 `.doc` 正文纯文本。 |
| `SystemTextActionHandler.kt` | 系统划词动作通道 `system_text_actions`。查询已安装并符合 AI 翻译与浏览器白名单的应用，使用显式组件启动防劫持。 |
| `ReaderWindowHandler.kt` | 阅读窗口通道 `reader_window`。通过 AndroidX Insets API 维持 edge-to-edge 并单独控制状态栏显隐、回报挖孔与系统栏安全区、以 `FLAG_KEEP_SCREEN_ON` 取代 `wakelock_plus` 维持屏幕常亮，并动态开关 `WindowManager.LayoutParams.FLAG_SECURE` 屏蔽截屏、录屏及多任务缩略图。 |
| `BookImportProbe.kt` | 选书前的轻量嗅探。只读 SAF 文件的头部与 ZIP 中央目录判别类型，安装包在复制前即被拒，复制时按字节回报进度供上层判断是否仍在推进。 |
| `AppUpdateHandler.kt` | 更新与版本通道 `app_update`。提供已安装版本 `appVersion` 查询（取代 `package_info_plus`），并在后台执行器完成安装包校验：须位于更新缓存目录、包名与版本名一致、构建号高于当前版本、签名相同；通过后按需引导开启未知来源安装权限，或经 FileProvider 授权调起系统安装程序，校验期间重复调用返回 `UPDATE_BUSY`。 |
| `BiometricHandler.kt` | 隐私书架的生物验证与时钟通道 `biometric`。`capabilities` 返回指纹与人脸硬件状态；`authenticate` 调起框架自带 `BiometricPrompt`（Android 11 起接受二类生物信息），点“使用密码”返回 `fallback`，串行受理验证；`clock` 返回单调运行时间、开机计数与墙钟毫秒，供 PIN 锁定倒计时校验。 |
| `MotionHandler.kt` | 动效通道 `motion`。`setHighRefreshRate` 在画面运动期间把窗口的首选显示模式设为当前分辨率下刷新率最高的一档，运动结束后改回无偏好，让系统在画面静止时降到空闲刷新率；系统省电模式开启时不发出请求。`isPowerSaveMode` 返回省电模式状态，`ACTION_POWER_SAVE_MODE_CHANGED` 广播到达时以 `powerSaveModeChanged` 通知 Dart 端。 |
| `BookExportHandler.kt` | 导出通道 `book_export`。把应用私有暂存文件写入用户经系统界面选定的位置；来源限定在导出缓存目录内，单次导出串行，重复调用返回 `EXPORT_BUSY`。 |
| `BackgroundTaskRunner.kt` | 通用后台任务边界。把工作提交到 worker 执行器、把成功与异常回传到 UI 执行器，支持 isActive 开关在销毁后抑制排队任务与迟到回调。 |
| `PdfChannelHandler.kt` | PDF 通道适配层。解析方法调用为不可变 `PdfRequest`，按操作类型分发到渲染或分析两个单线程池，`InvalidPasswordException` 统一映射为 `PDF_PASSWORD_REQUIRED` 错误码；自身不含文档逻辑。 |
| `PdfRequest.kt` | PDF 通道的类型定义。`PdfOperation` 枚举标注每个方法是否为分析类、是否修改文档（含 `PAGE_TEXT` 单页文字层提取）；`PdfRequest` 为纯数据载体，可安全跨线程传递。 |
| `PdfDocumentEngine.kt` | PDF 文档引擎（核心）。持有 PDFBox 与 Android PdfRenderer 双会话缓存、读写锁与懒加载 ML Kit 中文识别器；实现页数、页面渲染为图片、全文搜索、单页文字层提取、大纲、批注读取、密码校验、解锁、批注回写、逐页 OCR 与缓存清理。完全不依赖 Activity 与 Flutter 通道。 |


## android/app/src/main/res/

| 文件 | 作用 |
|---|---|
| `values/colors.xml` | 定义启动背景色 `#FAF7F2`（对应 `AppTheme.background`）与自适应图标底色 `#B3543A`（对应 `AppTheme.accent`）。 |
| `values/styles.xml` | 亮色 LaunchTheme 与 NormalTheme，启动窗口显示暖色背景直到 Flutter 首帧。 |
| `values-night/styles.xml` | 深色系统下的启动主题。刻意保持与亮色相同的暖色背景，避免黑到米色的启动闪屏（应用自身主题不跟随系统深色模式）。 |
| `drawable/launch_background.xml` | 纯色启动背景 drawable，取 `@color/launch_background`。 |
| `mipmap-*/ic_launcher.png` | 五档密度的传统图标，不透明方形。 |
| `mipmap-anydpi-v26/ic_launcher.xml` | 自适应图标声明，组合 `@color/launcher_background` 与 `@drawable/launcher_foreground`。 |
| `drawable/launcher_foreground.xml`、`drawable-nodpi/readvibe_mark.png` | 自适应图标前景，透明底书本位图，由 `tool/draw_launcher_icon.py` 生成。 |
| `xml/update_paths.xml` | FileProvider 授权范围。只公开缓存目录下的 `readvibe_updates/`，使系统安装程序能读取应用自己下载的安装包，其余私有文件不受影响。 |

## android/app/src/debug/ 与 android/app/src/profile/

| 文件 | 作用 |
|---|---|
| `AndroidManifest.xml` | 两个开发变体清单，仅为 Flutter 工具链追加 `INTERNET` 权限（热重载与断点调试需要）。 |

---

## assets/

| 文件 | 作用 |
|---|---|
| `fonts/SourceHanSerifSC-Regular.ttf` | 内置完整思源宋体常规字库，作为阅读页“宋体”选项与离线渲染兜底。 |
| `fonts/ARPLKaitiMGB-Regular.ttf` | 内置文鼎 PL 简中楷（AR PL KaitiM GB）字库，作为“楷体”选项。字库仅仅改动了 hhea 表的行间距，从 6 改成 0，让 SkParagraph 排出的行距与行框保持一致。其余数据都与原版相同，包括全部字形。字库覆盖 GB2312 的全部汉字、ASCII 与常用中文标点，并把缺失的字形交给系统字体补上。 |
| `licenses/arphic-public-license.txt` | 文鼎公众授权书原文。文本直接取自楷体字库的 name 表，由 `main.dart` 注册到开源许可页。 |
| `images/ai/deepseek.webp`、`chatgpt.webp`、`claude.webp`、`copilot.webp`、`gemini.webp`、`perplexity.webp` | 六个受支持 AI 翻译应用的图标，选区菜单用它标识翻译目标。 |

---

## docs/

| 文件 | 作用 |
|---|---|
| `USAGE.md` | 面向用户的操作说明。覆盖书架导入、搜索筛选、排序与信息修改、文件导出、三种阅读模式、文字选择与边缘拖选、章节编辑、PDF 阅读（缩放、跳页、书签、笔记、OCR）与更新检查入口。 |
| `ARCHITECTURE.md` | 本文件。按目录列出仓库内每个文件的用途。 |

---

## lib/（Dart 源码）

### lib/main.dart

| 文件 | 作用 |
|---|---|
| `main.dart` | 应用入口。初始化 Flutter 绑定、切换到 `SystemUiMode.edgeToEdge` 让所有页面自绘到系统栏之下，随后启动 `ReadVibeApp`；配置 MaterialApp 的亮暗主题、锁定到 `zh-Hans-CN` 的本地化（同时决定汉字字形取简体形，避免系统语言为日文或繁体时共用码位被塑形成他区字形）与 `onGenerateRoute` 路由表：`/` 进书架，`/reader` 依据 `ReaderLaunchArgs`（或裸 `Book`）携带的封面快照与起始矩形构建书香开页过渡，PDF 书走 `PdfReaderScreen`，其余走 `ReaderScreen`。启动时一并开启 `MotionService` 与 profile 构建专用的 `FrameActivityLog`，并在 MaterialApp 的 `builder` 中接收全应用的滚动通知，作为高刷请求的依据。启动的时候，还会把楷体字库附带的文鼎公众授权书和字库改动说明注册到开源许可页。 |

### lib/models/（纯数据模型，零框架依赖或仅 Material 枚举展示）

| 文件 | 作用 |
|---|---|
| `book.dart` | 全部书籍相关模型。定义 `BookFormat`、`BookAvailability`（含丢失原因中文标签）、EPUB 富文本四件套 `EpubContentStyle`/`EpubTextRun`/`EpubContentBlock`/`EpubLinkTarget`、出版社样式安全对比度判断；`EpubTextRun.link` 记录站内跳转目标，`EpubContentBlock.anchorIds` 保存该块覆盖的元素 id 供片段定位；`Chapter` 刻意保持同一性相等（正文惰性加载，值相等要么加载全部载荷要么误判），需要稳定键的调用方使用 `index`；`Chapter` 支持延迟加载代理与 EPUB 块计数存储；`Book` 持有元数据、字数摘要、封面路径、内嵌字体映射、自定义书架分组 `groups`（配合 `normalizeBookGroups` 按每本最多 12 个、每组最多 24 字符规范化且不切开代理对）与隐私书架标记 `isPrivate`，提供 JSON 编解码与 `copyWith`。另暴露三组章节标题判定函数（卷标题、导语类、独立尾章类）与正则，供 TXT 解析与目录分组复用；`currentTxtParserVersion` 驱动旧书重新解析。 |
| `reader_bookmark.dart` | 文字书的书签与笔记模型。`ReaderBookmark` 以（章节、段落、字符）三元组锚定，与阅读位置恢复和搜索跳转共用同一套坐标，因此换字体或切模式后仍指向原句；携带摘录、笔记、章内百分比与时间。`fromJson` 对损坏记录返回 null 而非修复，`clampBookmarkText` 截断时不切开代理对，`sortedReaderBookmarks` 按正文顺序排列。上限 500 条/本。 |
| `book_content_revision.dart` | 正文修订号与冲突类型。`readContentRevision` 归一化持久化的修订号（旧书从零开始），`BookEditConflict` 表示保存时正文已被其他改动推进。 |
| `reader_settings.dart` | 阅读设置与进度模型。`ReaderSettings`（schema v6）涵盖字号、行高、主题、粗细、字体（系统/内置宋体/内置楷体/导入）、页边距、段距、阅读模式与自动检查更新，含旧版本字段迁移与字体粗细针对内置静态字体的特殊映射（宋体为 w400/w600/w900，最粗一档叠加同色阴影；楷体为 w400、w400 叠加随字号缩放的斜向同色阴影、w600）；`ReadingProgress` 保存章节进度、偏移与逐章快照；`PdfReadingProgress` 与 `PdfDisplayTheme` 独立于章节体系，`toShelfProgress()` 供书架卡片复用。 |
| `reading_paragraph.dart` | 阅读与搜索共用的段落投影。`readingParagraphs()` 统一纯文本与 EPUB 富文本两种章节为相同顺序的可见段落流；`ReadingParagraph` 携带正文与首行缩进前缀，`visibleParagraphBody()` 清理段首空隙；`contentOffsetForReadingParagraph()` 按顺序回查段落正文，把阅读坐标折回 `Chapter.content` 的字符偏移，供编辑器定位阅读行。禁止依赖 IO 与 Flutter。 |
| `search_match.dart` | 搜索结果展示契约。`SearchMatch` 接口约定标题、片段、命中文本与高亮区间，`BookSearchResult`（章节坐标）与 `PdfTextSearchResult`（页码坐标，可标 OCR）各自实现；`maxDocumentSearchResults = 500` 为统一上限，供搜索面板直接渲染。 |

| `library_filter.dart` | 书架筛选枚举 `ShelfFilter`（全部/最近/未读/四种格式）及中文标签扩展。 |
| `reader_launch_args.dart` | 书架开书时的路由参数。携带 `Book`、封面截图 `ui.Image` 与书卡在屏幕上的 `Rect`，供开页过渡做共享元素动画。 |

### lib/repositories/（接口契约层）

| 文件 | 作用 |
|---|---|
| `reader_repositories.dart` | 全部持久化接口定义（8 个抽象接口）。`LibraryRepository`（书架：列表、可用性、信息修改、排序、自定义分组读写/重命名/删除与批量设组、隐私书架归属、单本与批量删除、孤儿数据回收、书架进度与设置）、`ReaderRepository`（文字阅读：进度、目录折叠组、章节替换、字数保存、删除）、`PdfReaderRepository`（PDF 进度、书签、笔记、显示主题）、`ReaderRepository` 另含文字书书签读写、`LibraryMaintenanceRepository` 另含 `measureStorageUsage`/`clearTemporaryCaches` 与返回类型 `StorageUsageReport`、`BookImportStore`、`AppDataDirectoryProvider`、`ImportedFontStore`、`ImportedPdfStore` 与返回类型 `StorageCleanupResult`。实体类 `StorageService` 同时实现前三个大接口，各消费者按需依赖窄接口。 |

### lib/controllers/（状态编排）

| 文件 | 作用 |
|---|---|
| `chapter_editing_controller.dart` | 章节编辑事务。`save()` 归一化换行、重建 `Chapter`、使字数缓存失效、经仓库替换章节、增量重算编辑章字数并回写摘要；返回 `ChapterEditResult` 携带新书籍与字数。阅读页只保留视图缓存与锚点恢复职责。 |
| `library_maintenance_controller.dart` | 空闲书架维护编排。逐本检查、逐本发布结果，以书籍快照同一性拒绝过期结果；页面忙碌或进入后台后在书籍边界暂停，保留本轮完成项并延后续扫。深度章节校验由存储层工作线程执行。 |
| `library_selection_controller.dart` | 书架多选状态控制器。管理多选开关、已选书籍集合、当前过滤书集内的全选/清空、按目标分组与批量操作集合收敛。 |
| `library_update_controller.dart` | 书架更新检查与安装编排。管理 24 小时自动静默检查计时器、上次成功检查时间读写、前台恢复补检、手动检查节流与新版本对话框调度。 |
| `private_shelf_controller.dart` | 隐私书架会话与锁控控制器。协调进入隐私书架的生物验证与密码解锁、PIN 设置/修改/关闭与清空书架流程、退后台或系统选择器以外切出的自动锁定，以及同步调用 `ReaderWindowController.setSecure` 开关窗口安全标志。 |
| `document_search_controller.dart` | 文档搜索会话控制器。串行化耗时搜索并只发布当前查询的结果，提交期间的新提交替换待处理项；对外暴露结果、进行中、已搜索与失败四种状态。 |
| `reader_pagination_controller.dart` | 纯分页数学。把原始滚动范围取整到整视口页高，容差 0.01，供仿真模式滚动位置共用。 |
| `reader_progress_controller.dart` | 进度写序列化。把异步保存串成队列，保证旧的保存不会越过新的阅读位置落盘，错误经回调上报。 |
| `reader_search_controller.dart` | 书内搜索会话管理。保证同一时刻只有一个后台搜索会话，切换关键词即释放旧会话。 |
| `reader_selection_controller.dart` | 文字选区共享状态。以三个 `ValueNotifier`（激活、拖动中、被模态阻断）在阅读页、滚动位置与 SelectionArea 之间广播选区状态。 |
| `reader_word_count_controller.dart` | 阅读页字数状态。初始化时采用书籍已存字数，需要时后台重算逐章字数并持久化；以代数拒绝过期结果，暴露 `wordCount` 与 `chapterWordCounts` 两个监听器供目录与页脚消费。 |
| `reader_window_controller.dart` | 文字与 PDF 阅读及隐私书架共用的窗口协调器。串行提交状态栏显示请求、读取物理摄像头和系统栏 Insets、同步屏幕常亮 `setKeepScreenOn`，并通过按持有者引用的 `setSecure(owner, enabled)` 协调隐私书架与隐私阅读页动态开关原生 `FLAG_SECURE`。原生对应 `ReaderWindowHandler.kt`。 |

### lib/services/

| 文件 | 作用 |
|---|---|
| `storage_service.dart` | 持久化实现门面与书架状态核心。组合 `ChapterDiskStore`（章节分块落盘、按需解码与过期载荷清理）与 `StorageUsageService`（存储占用统计与临时缓存清理）；书架元数据存于应用数据目录的 `library.json`（tmp/bak/rename 原子提交，静态按根目录缓存解码结果，首次读取时从旧的 `readvibe_books` 偏好键一次性迁移并删除该键），避免高频进度写入连带重写整个书架；实现普通书架与隐私书架互不互通的自定义分组读/写/重命名/删除、单本与批量删除（`deleteBooks`）、恢复书籍元数据校验写入（`getAllBookMetadataRecords`/`upsertRestoredBookRecord`/`clearDeletedBookMarker`）与删除关联资源回收。写路径用全局队列串行化书架级操作与逐书章节写入，实现书架、阅读、PDF 三个仓库接口。`setBooksPrivate` 只改写书架元数据里的隐私标记，不会触碰章节载荷。 |
| `private_shelf_lock.dart` | 隐私书架的密码与验证设置。6 位数字密码只以加盐的 PBKDF2-HMAC-SHA256 摘要保存在偏好里，并在 `Isolate.run` 中完成派生计算。连续输错 5 次以后，密码键盘锁定 30 秒并在后续错输时倍增（最长 15 分钟），同时写入墙钟截止时间与经 `biometric` 通道 `clock` 读取的单调运行时间及开机计数，防止调改系统时间提前解除锁定。`PrivateShelfConfig` 记录已开启的指纹、人脸与默认验证方式，生物验证经 `biometric` 通道交给原生层。 |
| `library_backup_service.dart` | 本地 `.zip` 备份与非破坏性合并恢复服务。`exportBackup` 按 `BackupOptions` 收集书架元数据、章节与封面资源（将路径规范化为 `{{READVIBE_ROOT}}` 可移植占位符）、书签笔记、进度、目录折叠状态、普通/隐私书架独立分组与可选字体/设置，经 `ZipFileEncoder` 流式打包并交由系统保存；`inspectBackup` 做路径穿越校验与摘要统计后返回 `BackupPreview`；`restoreBackup` 逐项解压、重定根目录并重算恢复 `manifest.json` 内章节与资源的 `bytes` 及 `sha256` 摘要，按保留现有书库的非破坏性合并策略写回，绝不导出或覆盖隐私锁密码配置。 |
| `motion_service.dart` | 动效的显示与电源提示。任何运动的部件在运动期间持有一个理由，至少有一个理由时请求最高刷新率，最后一个理由释放 0.6 秒后撤回请求；理由 1.5 秒内未续期即自动过期，到期时间按单调时钟计算，系统改时间也不会让请求滞留。`handleScroll` 处理全应用的滚动通知，`powerSaveMode` 对外提供系统省电模式状态。原生对应 `MotionHandler.kt`。 |
| `frame_activity_log.dart` | profile 构建的帧数日志。每 10 秒输出一次这段时间绘制的帧数与最慢的构建、光栅耗时，画面静止时没有输出；release 与 debug 构建不启动。 |
| `reader_preferences_store.dart` | SharedPreferences 中的阅读态存取。管理文字进度、文字书书签与笔记、PDF 进度（含旧记录一次性迁移）、PDF 书签、笔记、显示主题、目录折叠组、普通书架与隐私书架各自独立的自定义分组列表，以及阅读设置；静态写版本队列保证旧写不会覆盖新写，已删书的读取一律短路返回空。 |
| `managed_book_resources.dart` | 导入二进制资源的生命周期。提供字体保存（.ttf/.otf、64MB 上限、文件名消毒）、PDF 副本保存（1GB 上限、原子 tmp 重命名）与删除；删除 PDF 源前先经网关清渲染缓存，路径白名单限定在应用私有目录内，防止误删兄弟资源。 |
| `book_id.dart` | 导入书籍的身份。`nextBookId` 在时钟重复或回拨时仍产出唯一 id（进程内单调序号加随机后缀），因为 id 同时用作章节目录、PDF 副本、内嵌字体族和阅读状态的键；`uniqueLibraryTitle` 为重复导入的同名书编号，不超过重命名上限且不切开代理对。 |
| `chinese_text.dart` | 中文检索折叠。`foldFullWidth` 把 U+FF01–FF5E 的全角 ASCII 映射回半角，折叠后符文数不变以保证高亮回映；`。`、`、`等中文标点保留原样。书架搜索与书内搜索共用。 |
| `resource_presence.dart` | 导入资源存在性缓存。封面、EPUB 背景图等文件只在导入时写入、随书删除，其存在性是路径的属性；`importedResourceExists` 每个路径只做一次 stat，避免 `build` 内逐帧同步 IO。 |
| `book_import_coordinator.dart` | 格式中立导入事务。按扩展名分发到各解析器，统一走 `BookImportStore` 落盘；识别、解析、保存三步经 `BookImportProgress` 上报，保存阶段带已落盘章节数，书架据此显示进度并判断导入是否还在推进；失败时回滚已导入的私有资源并保留原始解析错误；PDF 密码由书架层弹窗索取后重试。 |
| `android_book_picker.dart` | Android 选书与文件选择通道的 Dart 封装。`pickBooks` 调用原生多选 `book_picker` 取回一批缓存副本路径及单本错误列表，`pickFont` 与 `pickBackup` 分别用于单选字体和 `.zip` 备份包，取消返回 null，平台错误转成中文 `FormatException`。 |
| `book_export_service.dart` | 书籍导出。PDF 直接复制当前副本；文字书在 isolate 中按章节顺序写出 UTF-8 TXT（卷标题、富文本标题块、图片替代文本俱到，分块写入避免代理对截断），先落私有暂存再经 `BookExportDestination`（Android SAF 通道）由用户选择保存位置，完成后清理暂存。文件名净化并截 60 字符。 |
| `book_search_service.dart` | 书内全文搜索。一次会话把书籍与其规范化段落一次性送入 isolate worker，后续关键词只传查询串；规范化折叠大小写与空白，命中区间映射回原始 UTF-16 偏移保证高亮精确；LPM 缓存约 12MB 章节段落，单次扫描上限 500 条。`removeObsoleteData` 清理旧版搜索遗留目录。 |
| `epub_parser.dart` | EPUB 解析器库入口，通过 `part` 组织 `lib/services/epub/` 下的五个专职子模块（解包与工具、CSS 样式解析、文档/NCX/OPF 解析、媒体落地及目录/锚点链接解析）。在 isolate 中运行，处理清单资源与站点锚点引用；资源限额（输入 256MB、条目 2 万、展开 512MB、单图 64MB）可注入，失败时清理已落地资源目录。 |
| `epub/epub_archive_utils.dart` | EPUB 归档流式读取、路径规范化及大小/条目安全校验助手。 |
| `epub/epub_css_resolver.dart` | 出版商安全 CSS 子集解析（字号/行高/对齐/缩进/粗斜/颜色/背景图/字库规则），映射为 `EpubContentStyle`。 |
| `epub/epub_document_parser.dart` | XHTML 内容文档遍历、富文本块构建与图片/脚注元素采集。 |
| `epub/epub_media_store.dart` | EPUB 内嵌封面、插图与 `@font-face` 字库落地存储与清理。 |
| `epub/epub_navigation.dart` | OPF spine/manifest 读取、NCX/Nav 目录生成以及跨章节锚点与站内 `<a href>` 链接解析。 |
| `mobi_parser.dart` | Kindle 解析入口。支持无 DRM 的 MOBI 7、AZW、AZW3/KF8；扩展元数据取标题作者，按 MobiEncoding 解码 HTML 压制为纯文本后复用 `buildBookFromText` 章节规则；加密书籍显式报错且不会写入空书架条目。 |
| `pdf_import_service.dart` | PDF 导入。校验文件后存入私有 pdf 目录，经渲染网关获取页数；仅权限加密（空用户密码）自动本地解锁，真密码保护时抛出 `PdfPasswordRequiredException` 由上层索取密码；失败清理副本。 |
| `pdf_renderer_service.dart` | PDF 平台网关。上半部定义 `PdfRendererGateway` 抽象与数据类（搜索结果、大纲项、批注），`PlatformPdfRendererGateway` 注入到阅读页；下半部 `PdfRendererService` 静态封装 `com.readvibe.app/pdf_renderer` 通道的页数、渲染、搜索、大纲、批注、解锁、OCR、单页文字层提取与缓存清理调用。 |
| `txt_parser.dart` | TXT 解析与章节识别。探测 UTF-8/UTF-16/GBK/Big5 编码：先按 NUL 填充的奇偶结构判定无 BOM 的 UTF-16（拉丁文两种读法都能解码，仅靠内容评分会误选落在 CJK 区的那一种），其余交给常用汉字评分——评分只在开头 192KB 的字节上做，胜出的编码才读整本，因此候选编码的数量不再乘进一次导入的耗时；Big5 交给 `dart3_big5` 时按 2KB 分片并在双字节边界切开，该包逐字符拼接字符串，整本交给它的代价随字数平方增长，百万字的旧编码小说会一直卡在解析正文；256MB 上限；四组章节标题正则（`第X章/卷X/Chapter N/番外` 等）仅去除 Markdown 装饰后判定，以句读等散文特征排除伪标题；`buildBookFromText` 供 DOC/DOCX、Kindle 复用同一章节规则；`upgradeLegacyTxtBook` 用旧版本号驱动重解析。 |
| `word_parser.dart` | Word 文档导入。DOCX 经 `InputFileStream` 按需读包，正文 `document.xml` 解压落盘后以 `xml_events` 逐标记流式读取，`_DocxBodyReader` 只持有当前段落或表格，内存与书的长度无关；提取标题、元数据、样式段落、表格、脚注与内容控件包裹的正文并落地图片；正文上限 192MB，解压写入受 `_BoundedFileOutput` 限额保护；旧版二进制 DOC 委托 POI 通道在 Android 后台提取纯文本；两条路径统一走 `buildBookFromText`，正文不出设备。 |
| `word_count_service.dart` | 字数统计服务。按 Unicode scalar 计数（代理对不重复计，排除空白），isolate 后台执行；结果按 `书ID:大小:解析版本:章节数` 缓存并去重在途请求，编辑章后以代数失效；含千分位格式的全文与逐章展示函数。 |
| `font_service.dart` | 字体导入与加载。直接复用原生 `AndroidBookPicker.pickFont()` 选入 `.ttf`/`.otf`（已移除 `file_picker`），经 `ImportedFontStore` 保存并以时间戳命名家族注册到 Flutter 引擎，加载失败自动回退系统字体且不丢其他设置；静态去重防止重复注册与并发重复加载。 |
| `incoming_file_service.dart` | 外部 ACTION_VIEW 文件接收。原生复制到缓存后经通道通知，静态处理器串行消费避免两个文件管理器启动竞态；单个文件解析失败只跳过该文件，队列中其余文件继续导入，通道本身不可用才停止本轮；结构化错误经回调上报。 |
| `system_text_action_service.dart` | 系统文字动作服务。经 PackageManager 查询可接收翻译/搜索的应用，产品白名单圈定六个 AI 应用与 Edge/Chrome/系统浏览器；支持记住默认目标、清除默认与显式启动校验。 |
| `update_service.dart` | 更新检查。通过原生 `app_update` 通道 `appVersion` 查询本机版本（已移除 `package_info_plus`），同时请求国内镜像线路（`feedMirrorHosts`）与 GitHub Releases 接口，第一条取到正式版 JSON 后再给其余线路 800 毫秒，在全部答复里取最新版本，避免镜像缓存的旧版本盖过新版本；三轮段比较版本号，解析 arm64 APK 资产并校验下载地址确实指向本仓库的发布路径，安装包摘要优先取资产自带的 `digest`，缺失时回退发布说明里的 `SHA-256：` 行；给出“有新版/已最新/检查失败”三态结果，同一时刻只保留一次在途检查。 |
| `update_download_service.dart` | 安装包下载与安装。线路依次为国内镜像（`mirrorHosts`）与 GitHub 直连，默认优先沿用 `SharedPreferences` 中记住的上一次成功下载线路（首次下载或旧线路失效时选用主国内镜像），不提前测速直接开始取包。仅当当前线路不可用，或连续 `slowWindow`（6 秒）低于 `lowSpeedThreshold`（512 KB/s）时，才在当前续传偏移处并发向其余备用线路各取至多 1 MB 样本测速（3 秒超时，首条完成后再等 800 毫秒，GitHub 直连速度先除以 1.5 再比对），并切换到最快路线，测速样本与已落盘字节直接通过 `Range` 续传接续；已测速阶段持续落后于下一条备选一半速度达六秒也会继续切换，接近完成时不再换线。字节先写入会话目录内的 `.part` 文件，长度、ZIP 魔数与 SHA-256 全部通过后改名为正式 APK 并记住本次完成下载的线路；跨线路续传只在存在摘要时启用，失败即删除本次会话目录，两天前的旧会话在开始时清理；支持取消与进度回调，安装经 `app_update` 通道转交原生层。 |
| `storage/chapter_disk_store.dart` | 章节分块存储引擎。实现 `LazyChapterStore`/`LazyChapter` 按需解码、分批在 worker isolate 同步编码/校验/落盘、30 秒 IO 超时、LRU 章节缓存及损坏/写半截载荷识别，随书创建/替换原子目录。 |
| `storage/storage_usage_service.dart` | 存储占用测算、临时缓存目录枚举清理（PDF 渲染与 OCR 缓存、下载更新、选中字体临时文件、`readvibe_backup_import` 临时目录等）与孤儿资源回收。 |
| `storage/obsolete_search_cleanup.dart` | 独立小模块。删除旧版全文搜索在应用数据目录遗留的 `search/` 目录，含路径越界防护。 |
| `storage/chapter_payload_codec.dart` | 章节载荷编解码。`encodeChapterPayload` 写入章节 JSON（富文本块含全部可见文本时不重复写纯文本），`decodeChapterPayload` 还原章节数据并为损坏的富文本重建兜底纯文本；禁止依赖 IO 与 Flutter。 |
| `storage/chapter_revision_cleanup.dart` | 过期章节载荷回收。在持有章节写队列时执行，正常清单与备份清单引用的载荷一律保留，清单损坏即放弃本次回收。 |

### lib/theme/

| 文件 | 作用 |
|---|---|
| `app_theme.dart` | 全局设计系统。定义暖米色调色板常量、阅读主题色 `ReaderThemeColors`（背景/正文/次级/头部/边框/强调；浅色、暖色、深色与 OLED 纯黑四套，跟随系统时在暖色与深色之间选择）、`getReaderTheme`（系统主题解析）、`systemUiOverlayStyle`（透明状态栏与导航栏，按背景亮度选择图标亮度），以及完整亮/暗两套 `ThemeData`（无水波纹、自绘 SnackBar 透明）。 |
| `app_motion.dart` | 动效令牌与开书过渡。集中全部时长与曲线令牌，例如按压 96ms、翻页 300ms、开书 680ms 与合书 540ms；`sheetCurve` 是贴边面板与抽屉共用的 iOS 面板曲线 `Cubic(0.32, 0.72, 0, 1)`，`exitOf` 给倒放关闭的路由换上翻转曲线，让退场也从快到慢；抽屉关闭 `drawerClose` 比打开更短；`buildFadeScaleRoute` 实现三阶段书香开页路由：封面快照提起放大、单页绕左缘翻开、阅读面接管，关闭按同一时间线倒放，时长为开书的 0.8 倍。路由本身不透明：开合动画进行时书架照常露出，停稳后书架退出画面、其动画暂停，过渡层也不再绘制暗化层、外阴影、底色与圆角裁剪；内部 `_BookRouteTransition`、`_BookRouteFrame`、`_OpeningPage` 管理阴影、圆角、折页阴影与封面 RawImage。 |
| `app_overlay_theme.dart` | 阅读主题下的界面覆盖层。`AppOverlayTheme` 依据 `ReaderThemeColors` 现场派生整套主题（按钮、输入框、对话框、抽屉、菜单、Tooltip、滑条、ListTile），并提供 `isDark`、`danger`、`barrier`、`shape` 静态助手，保证任何页面上浮出的控件与当前阅读纸色一致。 |
| `app_spacing.dart` | 间距与圆角令牌。`AppSpacing`（4/8/12/16/24/32）与 `AppRadius`（8/12/16/24 胶囊）。 |

### lib/widgets/

| 文件 | 作用 |
|---|---|
| `app_toast.dart` | 应用统一轻提示。基于透明 SnackBar 自绘卡片（信息/成功/错误/加载四种图标与配色的时长），支持阅读纸色注入与宽屏居中限制，加载态 30 秒常驻、点击可消。 |
| `app_dialog.dart` | 应用统一对话框。`showAppDialog` 捕获主题上下文并控制入场/退场时长与遮罩透明度，`_AppDialogRoute` 在淡入的同时从 96% 尺寸居中放大，退场使用翻转曲线；`AppDialog` 规范内边距与最大宽度；`AppDestructiveButton` 以错误色呈现破坏性操作（填充或描边两态）。 |
| `app_sheet.dart` | 应用统一底部面板。`showAppSheet` 以 `ModalBottomSheetRoute` 承载可滚动面板并保留禁用动画降级，调用方未指定曲线时补上 `sheetCurve` 入场与其翻转曲线退场；`AppSheetSurface` 定制 24dp 圆角纸面；`AppSheetHeader` 提供标题与关闭钮；`AppActionSheet` 为多子项动作列表；面板不再裁掉底部安全区，改由滚动内容自行留白，纸面一直铺到屏幕底缘。 |
| `app_popup_menu.dart` | 主题化弹出菜单。`AppPopupMenuButton` 自行计算锚点矩形后调用 `showMenu`，限定宽度并绘制选中态（勾选图标与强调底色）；可选的 `menuRightInset` 把菜单右缘钉在距屏幕右边固定距离处，用于与下方内容列对齐；`AppMenuEntry` 携带值、标签、图标与选中标记。 |
| `pressable_scale.dart` | 纯视觉按压缩放反馈。用 Listener 监听原始指针事件，不注册手势识别器，可包裹 InkWell/按钮而不劫持点击；禁用态自动复位。 |
| `side_drawer.dart` | 左侧滑出抽屉。`showSideDrawer` 推入自绘遮罩的弹出路由：拖动时面板与手指 1:1 同步，遮罩透明度由同一拖动量换算；松手时速度超过 200 像素/秒按方向决定，否则拖过四成宽度才关闭；关闭从松手位置接着滑出，未关闭则以临界阻尼弹簧带着松手速度回位，回位途中可以再次抓住。书架全局设置使用它。 |
| `book_card.dart` | 书架书卡。封面区域复现背景书脊与渐变遮罩（三明治分层供开书动画采样），显示封面图或首字占位；以章节进度与章内进度折算整体百分比，PDF 显示页数口径；可用性受损时角标提示丢失原因；支持 `selectionMode` 多选状态，在封面叠层边缘描边并在右下角绘制圆点勾选徽标（不改变 `paintedHeight` 高度计算）；语义化拼接无障碍标签。 |
| `chapter_list.dart` | 全屏目录面板。列表底部按系统手势条高度补白，章节行可滚动至手势条之下。`_TocDirectory` 把章节组织为两级卷目录（卷标题聚合、导语类与卷间散章分区），无卷则退化为平铺列表；卷头为 pinned 固定头可折叠并回传展开状态；行尾显示逐章字数（监听 `chapterWordCounts`）；章节行与卷头都使用固定行高，并随系统字号同步增大。目录行采用较小的字号和收窄的边距，从而给标题留出更多宽度。打开目录或点“回到当前章”时，当前章节会按行高算出精确位置并置顶显示。当前章位于展开的卷内时，置顶位置会让出固定卷头的高度。 |
| `chapter_editor_sheet.dart` | 章节编辑器。顶栏由关闭键、章节标题输入框、查找替换开关与保存按钮组成；正文框不自动聚焦，打开时按 `initialAnchorOffset` 把阅读所在行钉到视口顶部（读取 `RenderEditable` 的光标矩形，天然对齐整行）；查找替换面板在当前章内定位匹配，`_FindHighlightController` 直接在文本跨度上着色，因此未聚焦也能看到命中，支持上一个、下一个、单次替换与全部替换（上限 500 处）；深度处理 Android 系统栏：键盘弹出时恢复编辑区、路由非当前或退后台时暂停，并以 1.1 秒延时重试恢复；富文本章节保存前弹确认（本章转纯文本）；脏内容关闭时询问放弃；保存失败原样展示错误。 |
| `reader_bookmark_sheet.dart` | 文字书书签列表面板。按正文顺序展示章节、摘录、笔记、章内百分比与时间；行尾菜单可补写笔记或删除。自身不做持久化，全部经回调交回阅读页，保证书签列表只有一个写入方。同文件的 `showReaderNoteDialog` 负责新建与编辑笔记，返回空串表示清除笔记但保留书签。 |
| `pdf_page_text_sheet.dart` | PDF 单页文字面板。PDF 按位图渲染，页面本身无法承载选区；该面板把同一页的文字放进普通 `SelectionArea`，恢复复制、分享与系统文字动作，并标明来源是文字层还是识别结果，附带整页复制。 |
| `book_search_sheet.dart` | 书内搜索面板。泛型绑定 `SearchMatch`，防重复提交与过期回包（串号丢弃）；按命中区间绘制加粗高亮片段；结果为空、尚未搜索或出错分态展示，达上限提示缩小关键词。 |
| `reader_settings_sheet.dart` | 阅读设置面板。字号、行高、字体（组合 `FontSettingsSection`）、粗细、页边距、段距、阅读模式与翻页效果、主题全部用自绘滑块式分段控件（高亮块以 `TweenAnimationBuilder` 平移切换）；`_RollingModeDescription` 用于阅读模式说明的上下滚动切换；仿真模式才显示翻页效果选项。系统省电模式开启且选中仿真翻页时，翻页效果下方提示暂以平滑翻页显示。 |
| `font_settings_section.dart` | 字体选择区。系统/宋体/楷体/导入四选一卡片加导入按钮，导入卡副标题显示字体名并在无导入字体时禁用，选中卡片微放大并描边强调。 |
| `global_settings_sheet.dart` | 全局设置侧栏（书架右上打开），根部使用带圆角与底色的 `Material` 以消除内部 `SwitchListTile.adaptive` 在 Debug 下的水波纹断言与遮挡。集中隐私书架入口、本地备份与恢复入口（`onOpenBackup`）、字体区、外部应用默认项清除、自动检查更新开关、手动检查更新入口、存储空间区与开源许可页入口；版本号由书架层传入。同文件的 `StorageUsageSection` 自行异步统计并展示分类占用，提供清理缓存与重新统计；`formatStorageBytes` 负责字节展示。 |
| `library_backup_sheet.dart` | 本地备份与恢复面板。提供“导出备份”与“从备份恢复”双页签；导出按需勾选书籍文件/封面、设置/字体及隐私书架（先经隐私验证解锁，清理系统临时备份拷贝）；恢复通过 `AndroidBookPicker.pickBackup` 选包预览后执行非破坏性合并恢复。 |
| `library_batch_bar.dart` | 书架多选底栏。多选模式下提供批量设组（“分组”）、“移入隐私”/“移出隐私”与批量“删除”操作。 |
| `library_group_bar.dart` | 书架分组筛选与管理控件。包含水平分组胶囊栏 `LibraryGroupBar`、自定义分组管理面板 `showShelfGroupManagerSheet`（新建/重命名/删除）及单本与三态批量分配面板 `showAssignBookGroupsSheet`。 |
| `library_reorder_grid.dart` | 书架网格展示、拖动排序视图与固定视口物理边界 `PinnedShelfScrollPhysics`。 |
| `private_shelf_sheets.dart` | 隐私书架的交互面板。`_PinSheet` 自绘 6 位数字键盘，同时承担创建密码和验证密码两种用途。由于键盘是自绘的，系统输入法接触不到密码。`unlockPrivateShelf` 先调起默认的生物验证，失败或取消后再显示密码键盘。忘记密码的时候，已开启的生物验证可以用来重设密码。两种验证都没开启时，只能交由调用方清空隐私书架。`showPrivateShelfSettings` 负责开关指纹和人脸、选择默认方式、修改密码与关闭隐私书架，开启某一种之前会先验证一次。 |
| `library_search_controls.dart` | 书架搜索与筛选用控件。`LibraryFilterButton` 弹出筛选菜单（当前项在菜单中打勾），菜单右缘与书架网格右边线对齐；`LibrarySearchControls` 组合圆角搜索框（可清除）与激活筛选 `InputChip`。 |
| `app_update_dialog.dart` | 新版本对话框。展示安装包体积与发布说明（限高滚动），一个按钮串起下载、校验与调起安装三步；测速阶段显示不定进度条，下载中显示线路、百分比与实时速率且可随时取消；下载成功后失败重试不再重复下载，安装权限缺失时提示去系统设置开启后直接重试。 |

### lib/screens/

| 文件 | 作用 |
|---|---|
| `library_screen.dart` | 书架页视图协调核心。委托 `PrivateShelfController`、`LibraryUpdateController` 与 `LibrarySelectionController` 管理隐私锁与窗口安全、更新检查及多选批量操作；组合 `LibraryGroupBar`、`LibraryBatchBar`、`LibraryReorderGrid` 与 `showLibraryBackupSheet` 承担导入（支持一次多选 `pickBooks` 与 `导入 i/N` 进度及 100 秒静音看门狗）、外部来书串行接收、书香开页过渡、按宽度推导列数的响应式网格与长按操作，底层保留 `PinnedShelfScrollPhysics` 固定滚动与系统手势条避让。 |
| `reader_screen.dart` | 文字阅读页库入口与核心状态（通过 `part` 拆分为 `lib/screens/reader/` 下的四个专职子文件），打开隐私书籍（`book.isPrivate`）时经 `ReaderWindowController.setSecure` 同步启用 `FLAG_SECURE`。承担设置装载与防抖持久化、多通道阅读进度恢复、书签笔记、EPUB 站内链接与脚注就地展开、五面板联动、翻页拖拽与弹簧惯性、省电模式下平滑翻页回退、沉浸式系统栏、行界对齐、字体加载回退及选区保活，状态编排分散于多个 controller。 |
| `pdf_reader_screen.dart` | PDF 阅读页。同步按 `book.isPrivate` 调用 `ReaderWindowController.setSecure`（并用其 `setKeepScreenOn` 取代 `wakelock_plus`）；加载进度、书签、笔记、显示主题与内嵌批注五源合并；`PageView` 翻页配双指缩放、进度滑杆、跳页对话框、书签笔记列表、大纲、双通道搜索（文本层或逐页 OCR）、本页文字面板、显示主题切换与源文件丢失兜底删除；渲染任务按 `页:宽度` 去重并限在途 18 个。 |

### lib/screens/reader/

| 文件 | 作用 |
|---|---|
| `reader_mode_views.dart` | 文字阅读页三种阅读模式（分章、滚动、仿真）视图构建与布局对齐实现。 |
| `reader_overlay_bars.dart` | 文字阅读页顶部/底部浮动菜单栏及按行界自动计算内边距的展开逻辑。 |
| `reader_page_turn.dart` | 仿真/平滑翻页手势拖拽处理、页角跟随、弹簧惯性收尾及邻页预热渲染。 |
| `reader_sheets_and_links.dart` | 文字阅读页目录/搜索/书签/编辑/设置五面板协调、EPUB 站内引用跳转与脚注弹窗。 |

| 文件 | 作用 |
|---|---|
| `reader_epub_layout.dart` | EPUB 排版引擎。测量（按基行数取整的块高）、锚点映射（标题优先的章内定位）、渲染（富文本块到 Widget：安全对比度前景色、混合出版商背景、图片高度钳制与替代文本兜底）；左对齐与两端对齐的文本块交给 `ReaderJustifiedText`；含链接的块改由 `_EpubLinkedText` 有状态渲染，它持有并释放 `TapGestureRecognizer`，测量路径不生成识别器；行高基准由仿真模式下注入的函数解析，与用户的字体设置联乘。 |
| `reader_justified_text.dart` | 正文两端对齐。先按原样排版找出换行位置，再给每个自动换行的行设置单独的字距，把余量分到汉字之间和单词之后的空格上，换行位置因此保持不变，分页与文字坐标不受影响。段首空白缩进不参与拉伸，行末全角后标点以负字距收成半宽，字体支持 `halt` 时行首前标点改用半宽字形。结果用第二次排版核对，连写字形吞掉间距的行按实测比例重新分配一次，仍不吻合的行保持原样，换行变化时整段放弃对齐。结果按文本、宽度与样式缓存。默认文本样式动画途中保持原排版；所在列表正在滚动的长文本与标记为远离视口的文本只取已有结果，列表静止或回到视口附近后再补算。 |
| `reader_pagination_support.dart` | 分页与翻页支持（15 类）。`SimulationLayoutSignature` 判定布局参数变化；`ExactScrollExtentSliverChildBuilderDelegate` 把未知章尾的滚动估值锁到精确页高，避免最后页“回跳”；`FullViewportPagingScrollController` 把滚动范围补齐整页（补尾空白纸）；`SelectionAwareScrollController` 在选区存在时保持滚动位置不丢失；`ReadingTextAnchor`/`ScrollSnapshot` 描述恢复锚点；`SmoothTurnPages` 与 `CurlBookTurnPages` 分别实现位移翻页，以及跟随手指卷起页角的仿真翻页。卷页几何 `PageCurlGeometry` 在折痕坐标系中构造平铺正面、纸背与下层页三块区域，并按带宽裁剪来避开竖直折痕的无穷远控制点。`PageCurlClipper` 负责裁出平铺正面与纸背，供页面和镜像背面使用。`PageCurlPainter` 在底层绘制下层阴影与纸色，再在顶层叠上卷曲高光。翻起页投在平铺页上的影子由沿其自由边铺开的顶点条带一次绘出：各圈顶点的透明度按高斯衰减计算，在卷折附近与尖角处按纸片厚度和角度减弱，因此不需要离屏模糊。 |
| `reader_layout_cache.dart` | 阅读会话缓存。以章节序号（而非 Chapter 对象）为键缓存段落与测量高度，容量受章节数与字符数双上限约束；正文变化整体失效，排版与宽度签名单独失效已测高度。仿真模式的测量结果是 `ChapterItemExtents`：标题、每个正文块（含段距）与收尾项各自的高度，以及全章总高。页面列表用它作 `itemExtentBuilder`，翻页时新建的目标页与纸背列表直接从所在页开始排版，不再从章首逐段排到当前页。 |
| `reader_selection_support.dart` | 文字选区组件。`ReaderSelectionArea` 包裹正文并为长按/双击选区定制工具栏：折叠或超界时换到安全位置，菜单提供复制、分享、全选与六个受控翻译/搜索目标（AI 图标置入，记住默认目标可勾选），选择“记住”后下次直达；边缘拖选经 `ReaderSelectionEdgeScroller` 协同，模态打开即挂起选区。 |
| `reader_selection_edge_scroller.dart` | 边缘拖选自动滚动。手柄或拖选位置进入上下 56px 边缘带时，以 Ticker 驱动最高 420px/s 的速度滚动；由选区状态启动停止、按键与机型顶栏变化重算夹持，`_EdgeSelectionDelegate` 替换 SelectionArea 的默认边缘行为。 |
| `reader_selectable_block.dart` | 保活选区块。实现 `SelectionRegistrar` 透传注册并监听所有子文本Selectable，被选中内容（含屏外端点）由 `AutomaticKeepAliveClientMixin` 保留，防止 sliver 回收导致选区断裂；取消选择即释放缓存。它还负责绘制选区高亮，并把段落自带的高亮设为透明。选中的每一行会合并成一条色带，并以该行最宽的字体段作为高度。遇到回退字体渲染的标点时，色带也保持同一高度。 |

---

## samples/

| 文件 | 作用 |
|---|---|
| `readvibe-demo.txt` | 演示用示例书。三章短文本用于手动走通导入、阅读与退出续读流程。 |

---

## tool/

| 文件 | 作用 |
|---|---|
| `check_release_package.py` | 发布包校验脚本。核对 PDFBox 依赖的 SIKE 数据表与类、Picnic 裁剪残留、OCR 模型与单一 ABI（`arm64-v8a`），并逐字节比对宋体与楷体两个内置字库。 |
| `draw_launcher_icon.py` | 图标生成脚本。用贝塞尔路径绘制 1024 母版，`--install` 同时导出五档 mipmap 与自适应前景，全部尺寸从同一张 4096 渲染降采样，底色与 `colors.xml` 逐字节一致。 |

## design/

| 文件 | 作用 |
|---|---|
| `readvibe-icon.png` | 图标 1024 母版，由 `tool/draw_launcher_icon.py` 生成，用于商店素材与设计参考。 |
| `README.md` | 图标生成流程说明。记录出图命令、三处输出的用途与底色同步要求。 |

---

## 命名与协作速查

- **协议通道**：`com.readvibe.app/` 前缀下的 `incoming_file`、`book_picker`、`system_text_actions`、`document_parser`、`app_update`、`book_export`、`pdf_renderer`、`biometric`、`motion` 分别承载平台能力；`reader_window` 由阅读窗口协调器访问。
- **文档级不变量**：正文与解析全部本地执行；章节编辑只改私有副本；导出位置由用户经系统界面选择；签名材料不入库。
- **worker 闭包**：交给 `Isolate.run` 的闭包一律写在顶层或类级函数里，参数只收可传递的值。写在方法体内会与该方法的捕获上下文共用，凡是那里放着的回调、Future、Timer 或界面状态都会被一起发送，AOT 正式包因此抛 `Illegal argument in isolate message`，且只在真机或模拟器的 release 构建上暴露。
- **版本约定**：当前公开版本系列为 `0.8.X`，Android 内部构建号同步递增，唯一来源为 `pubspec.yaml`；release 构建缺 `key.properties` 即失败。
- **发布包**：正式包必须放到 `D:\0_Study\0_Stdio\0_Codex_work\1.ReadVibe_Project\dist`，按 `ReadVibe-Android-v<公开版本>-arm64-v8a.apk` 命名。
- **改动确认**：用 VS Code 连接的 Android 模拟器直接运行即可。
