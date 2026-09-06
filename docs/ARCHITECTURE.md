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
  services/            解析、存储、平台通道等业务服务
  services/storage/    存储层的独立子模块
  repositories/        持久化接口契约
  models/              纯数据模型
  theme/               颜色、间距与动效设计系统
android/               Android 工程与原生能力
test/                  Flutter 单元与组件测试
tool/                  发布检查脚本
docs/、design/、assets/  文档、图标源文件与静态资源
```

依赖方向整体为 screens → controllers/widgets → services → repositories(接口) → models，数据与领域层禁止反向引用页面与组件，该约束由 `test/architecture_boundaries_test.dart` 强制执行。

---

## 根目录文件

| 文件 | 作用 |
|---|---|
| `pubspec.yaml` | 项目清单。声明包名 `readvibe`、版本 `0.6.20+66`（`+` 后为 Android 内部构建号）、Dart 约束，以及全部运行依赖（file_picker、archive、shared_preferences、path_provider、path、fast_gbk、dart3_big5、dart_mobi、crypto、html、xml、wakelock_plus、package_info_plus）与开发依赖（flutter_test、flutter_lints）。 |
| `pubspec.lock` | 依赖解析结果快照，锁定每个依赖包的确切版本，保证构建可复现。 |
| `analysis_options.yaml` | Dart 静态分析配置。启用 `flutter_lints` 推荐规则集，未额外增删规则。 |
| `AGENTS.md` | AI 协作约定。描述项目入口目录、工作原则、版本递增规则与验证要求。 |
| `README.md` | 项目介绍。涵盖功能概览、安装与导入方式、隐私保护承诺。 |
| `.gitignore` | Git 忽略规则，排除构建产物与本地配置。 |
| `.metadata` | Flutter 工具记录的工程元数据（平台、模板版本），由 `flutter` 命令维护，勿手工编辑。 |
| `.flutter-plugins-dependencies` | Flutter 自动生成的插件依赖清单，列出各平台的插件注册信息。 |

---

## .github/workflows/

| 文件 | 作用 |
|---|---|
| `flutter.yml` | CI 工作流，push 到 main 与所有 PR 触发。步骤包括：安装并缓存指定版本的 Flutter（版本锁定为 `.metadata` 记录的 SDK，避免 stable 频道自行前移）、`flutter pub get`、`flutter analyze`、`flutter test`、构建 Android debug APK、运行 Android 原生单元测试（`:app:testDebugUnitTest`）、生成临时 CI 签名密钥、构建 arm64 release 冒烟 APK、调用 `tool/check_release_package.py` 校验发布包体积预算与必需离线资源。 |

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
| `proguard-rules.pro` | R8 保留规则。忽略 POI 的桌面 AWT 可选依赖与 findbugs 注解、PDFBox 的可选 JP2 解码器告警，保证旧版 DOC 解析在 Android 上可编译。 |
| `readvibe-release.jks` | 本地正式签名密钥库，属私密材料。 |

## android/app/src/main/

| 文件 | 作用 |
|---|---|
| `AndroidManifest.xml` | 主清单。声明 `INTERNET` 与 `REQUEST_INSTALL_PACKAGES` 两项权限，后者供应用内安装更新包使用；注册不导出的 FileProvider（授权 `${applicationId}.updates`，范围见 `xml/update_paths.xml`）把下载好的安装包临时授权给系统安装程序；MainActivity 以 `singleTop` 启动，注册 ACTION_VIEW intent-filter 接收八种电子书 MIME 类型实现外部“用其他应用打开”；`<queries>` 中显式列出允许的六个 AI 翻译应用与两个浏览器包名。 |
| `java/.../GeneratedPluginRegistrant.java` | Flutter 自动生成的插件注册类，勿手工编辑。 |

## android/app/src/main/kotlin/com/readvibe/app/（原生代码）

| 文件 | 作用 |
|---|---|
| `MainActivity.kt` | 原生宿主 Activity。注册三个 MethodChannel：`incoming_file`（串行消费外部 ACTION_VIEW 文件并复制到应用缓存）、`system_text_actions`（查询并启动系统翻译/搜索目标）、`document_parser`（经单线程执行器调用 Apache POI 提取旧版 DOC 正文），更新安装通道交给 `AppUpdateHandler`。内含 AI 与浏览器包名白名单，换用显式组件启动防劫持。 |
| `AppUpdateHandler.kt` | 更新安装通道 `app_update`。校验放在后台执行器：安装包须位于缓存内的更新目录、包名与版本名同更新信息一致、构建号高于已安装版本、签名与当前应用相同；通过后按需引导用户开启未知来源安装权限，或经 FileProvider 授权打开系统安装程序，校验期间重复调用返回 `UPDATE_BUSY`。 |
| `BookExportHandler.kt` | 导出通道 `book_export`。把应用私有暂存文件写入用户经系统界面选定的位置；来源限定在导出缓存目录内，单次导出串行，重复调用返回 `EXPORT_BUSY`。 |
| `BackgroundTaskRunner.kt` | 通用后台任务边界。把工作提交到 worker 执行器、把成功与异常回传到 UI 执行器，支持 isActive 开关在销毁后抑制排队任务与迟到回调。PDF 通道与单元测试共用。 |
| `PdfChannelHandler.kt` | PDF 通道适配层。解析方法调用为不可变 `PdfRequest`，按操作类型分发到渲染或分析两个单线程池，`InvalidPasswordException` 统一映射为 `PDF_PASSWORD_REQUIRED` 错误码；自身不含文档逻辑。 |
| `PdfRequest.kt` | PDF 通道的类型定义。`PdfOperation` 枚举标注每个方法是否为分析类、是否修改文档；`PdfRequest` 为纯数据载体，可安全跨线程传递。 |
| `PdfDocumentEngine.kt` | PDF 文档引擎（核心）。持有 PDFBox 与 Android PdfRenderer 双会话缓存、读写锁与懒加载 ML Kit 中文识别器；实现页数、页面渲染为图片、全文搜索、大纲、批注读取、密码校验、解锁、批注回写、逐页 OCR 与缓存清理。完全不依赖 Activity 与 Flutter 通道。 |
| `src/test/kotlin/.../BackgroundTaskRunnerTest.kt` | 原生单元测试。验证任务先完成再回传、异常在回传线程交付、销毁后抑制排队任务与迟到回调三种边界。 |

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
| `fonts/SourceHanSerifSC-Regular.ttf` | 内置完整思源宋体常规字库，作为阅读页“宋体”选项与离线渲染兜底；CI 检查其与源文件逐字节一致。 |
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
| `main.dart` | 应用入口。初始化 Flutter 绑定、切换到 `SystemUiMode.edgeToEdge` 让所有页面自绘到系统栏之下，随后启动 `ReadVibeApp`；配置 MaterialApp 的亮暗主题、中文本地化代理与 `onGenerateRoute` 路由表：`/` 进书架，`/reader` 依据 `ReaderLaunchArgs`（或裸 `Book`）携带的封面快照与起始矩形构建书香开页过渡，PDF 书走 `PdfReaderScreen`，其余走 `ReaderScreen`。 |

### lib/models/（纯数据模型，零框架依赖或仅 Material 枚举展示）

| 文件 | 作用 |
|---|---|
| `book.dart` | 全部书籍相关模型。定义 `BookFormat`、`BookAvailability`（含丢失原因中文标签）、EPUB 富文本三件套 `EpubContentStyle`/`EpubTextRun`/`EpubContentBlock`、出版社样式安全对比度判断；`Chapter` 支持延迟加载代理与 EPUB 块计数存储；`Book` 持有元数据、字数摘要、封面路径与内嵌字体映射，提供 JSON 编解码与 `copyWith`。另暴露三组章节标题判定函数（卷标题、导语类、独立尾章类）与正则，供 TXT 解析与目录分组复用；`currentTxtParserVersion` 驱动旧书重新解析。 |
| `book_content_revision.dart` | 正文修订号与冲突类型。`readContentRevision` 归一化持久化的修订号（旧书从零开始），`BookEditConflict` 表示保存时正文已被其他改动推进。 |
| `reader_settings.dart` | 阅读设置与进度模型。`ReaderSettings`（schema v6）涵盖字号、行高、主题、粗细、字体（系统/内置宋体/导入）、页边距、段距、阅读模式与自动检查更新，含旧版本字段迁移与字体粗细针对内置静态宋体的特殊映射（w300/w600/w900 叠加同色阴影）；`ReadingProgress` 保存章节进度、偏移与逐章快照；`PdfReadingProgress` 与 `PdfDisplayTheme` 独立于章节体系，`toShelfProgress()` 供书架卡片复用。 |
| `reading_paragraph.dart` | 阅读与搜索共用的段落投影。`readingParagraphs()` 统一纯文本与 EPUB 富文本两种章节为相同顺序的可见段落流；`ReadingParagraph` 携带正文与首行缩进前缀，`visibleParagraphBody()` 清理段首空隙；`contentOffsetForReadingParagraph()` 按顺序回查段落正文，把阅读坐标折回 `Chapter.content` 的字符偏移，供编辑器定位阅读行。禁止依赖 IO 与 Flutter，由架构测试保证。 |
| `search_match.dart` | 搜索结果展示契约。`SearchMatch` 接口约定标题、片段、命中文本与高亮区间，`BookSearchResult`（章节坐标）与 `PdfTextSearchResult`（页码坐标，可标 OCR）各自实现；`maxDocumentSearchResults = 500` 为统一上限，供搜索面板直接渲染。 |
| `library_filter.dart` | 书架筛选枚举 `ShelfFilter`（全部/最近/未读/四种格式）及中文标签扩展。 |
| `reader_launch_args.dart` | 书架开书时的路由参数。携带 `Book`、封面截图 `ui.Image` 与书卡在屏幕上的 `Rect`，供开页过渡做共享元素动画。 |

### lib/repositories/（接口契约层）

| 文件 | 作用 |
|---|---|
| `reader_repositories.dart` | 全部持久化接口定义（8 个抽象接口）。`LibraryRepository`（书架：列表、可用性、信息修改、排序、删除、孤儿数据回收、书架进度与设置）、`ReaderRepository`（文字阅读：进度、目录折叠组、章节替换、字数保存、删除）、`PdfReaderRepository`（PDF 进度、书签、笔记、显示主题）、`BookImportStore`、`AppDataDirectoryProvider`、`ImportedFontStore`、`ImportedPdfStore` 与返回类型 `StorageCleanupResult`。实体类 `StorageService` 同时实现前三个大接口，各消费者按需依赖窄接口。 |

### lib/controllers/（状态编排，全部带测试）

| 文件 | 作用 |
|---|---|
| `chapter_editing_controller.dart` | 章节编辑事务。`save()` 归一化换行、重建 `Chapter`、使字数缓存失效、经仓库替换章节、增量重算编辑章字数并回写摘要；返回 `ChapterEditResult` 携带新书籍与字数。阅读页只保留视图缓存与锚点恢复职责。 |
| `library_maintenance_controller.dart` | 书架维护编排。开架 30 秒后触发一次维护：清理遗留搜索数据、回收孤儿文件、逐本深度检查可用性（每本间隔 120ms），用代数与同一性判断丢弃过期扫描结果；支持取消、合并重复执行与随页面销毁。 |
| `document_search_controller.dart` | 文档搜索会话控制器。串行化耗时搜索并只发布当前查询的结果，提交期间的新提交替换待处理项；对外暴露结果、进行中、已搜索与失败四种状态。 |
| `reader_pagination_controller.dart` | 纯分页数学。把原始滚动范围取整到整视口页高，容差 0.01，供仿真模式滚动位置与测试共用。 |
| `reader_progress_controller.dart` | 进度写序列化。把异步保存串成队列，保证旧的保存不会越过新的阅读位置落盘，错误经回调上报。 |
| `reader_search_controller.dart` | 书内搜索会话管理。保证同一时刻只有一个后台搜索会话，切换关键词即释放旧会话。 |
| `reader_selection_controller.dart` | 文字选区共享状态。以三个 `ValueNotifier`（激活、拖动中、被模态阻断）在阅读页、滚动位置与 SelectionArea 之间广播选区状态。 |
| `reader_word_count_controller.dart` | 阅读页字数状态。初始化时采用书籍已存字数，需要时后台重算逐章字数并持久化；以代数拒绝过期结果，暴露 `wordCount` 与 `chapterWordCounts` 两个监听器供目录与页脚消费。 |

### lib/services/

| 文件 | 作用 |
|---|---|
| `storage_service.dart` | 持久化实现核心。元数据与小状态入 SharedPreferences，章节正文按章节落为独立 JSON 文件（30 秒 IO 超时、SHA-256 校验、带大小上限的 LRU 章节缓存）；`_LazyChapter` 让大书只有被阅读到的章节才解码。写路径用全局队列串行化书架级操作与逐书章节写入，删除书时联动清理字体、PDF 源与渲染缓存，并复用 `ReaderPreferencesStore` 与 `ManagedBookResources`。实现上同时满足书架、阅读、PDF 三个仓库接口，并 `export` 出 `StorageCleanupResult`。 |
| `reader_preferences_store.dart` | SharedPreferences 中的阅读态存取。管理文字进度、PDF 进度（含旧记录一次性迁移）、PDF 书签、笔记、显示主题、目录折叠组与阅读设置；静态写版本队列保证旧写不会覆盖新写，已删书的读取一律短路返回空。 |
| `managed_book_resources.dart` | 导入二进制资源的生命周期。提供字体保存（.ttf/.otf、64MB 上限、文件名消毒）、PDF 副本保存（1GB 上限、原子 tmp 重命名）与删除；删除 PDF 源前先经网关清渲染缓存，路径白名单限定在应用私有目录内，防止误删兄弟资源。 |
| `book_import_coordinator.dart` | 格式中立导入事务。按扩展名分发到各解析器，统一走 `BookImportStore` 落盘；失败时回滚已导入的私有资源并保留原始解析错误；PDF 密码由书架层弹窗索取后重试。 |
| `book_export_service.dart` | 书籍导出。PDF 直接复制当前副本；文字书在 isolate 中按章节顺序写出 UTF-8 TXT（卷标题、富文本标题块、图片替代文本俱到，分块写入避免代理对截断），先落私有暂存再经 `BookExportDestination`（Android SAF 通道）由用户选择保存位置，完成后清理暂存。文件名净化并截 60 字符。 |
| `book_search_service.dart` | 书内全文搜索。一次会话把书籍与其规范化段落一次性送入 isolate worker，后续关键词只传查询串；规范化折叠大小写与空白，命中区间映射回原始 UTF-16 偏移保证高亮精确；LPM 缓存约 12MB 章节段落，单次扫描上限 500 条。`removeObsoleteData` 清理旧版搜索遗留目录。 |
| `epub_parser.dart` | EPUB 解析器（9 类）。在 isolate 中解包，保留安全的出版商 CSS 子集（字号/行高/对齐/缩进/粗斜/颜色/背景图），映射为 `EpubContentBlock` 富文本块；处理清单资源、图片落地、本地 @font-face 字体提取；资源限额（输入 256MB、条目 2 万、展开 512MB、单图 64MB）可注入便于测试；失败时清理已落地资源目录。 |
| `mobi_parser.dart` | Kindle 解析入口。支持无 DRM 的 MOBI 7、AZW、AZW3/KF8；扩展元数据取标题作者，按 MobiEncoding 解码 HTML 压制为纯文本后复用 `buildBookFromText` 章节规则；加密书籍显式报错且不会写入空书架条目。 |
| `pdf_import_service.dart` | PDF 导入。校验文件后存入私有 pdf 目录，经渲染网关获取页数；仅权限加密（空用户密码）自动本地解锁，真密码保护时抛出 `PdfPasswordRequiredException` 由上层索取密码；失败清理副本。 |
| `pdf_renderer_service.dart` | PDF 平台网关。上半部定义 `PdfRendererGateway` 抽象与数据类（搜索结果、大纲项、批注），`PlatformPdfRendererGateway` 注入到阅读页便于测试；下半部 `PdfRendererService` 静态封装 `com.readvibe.app/pdf_renderer` 通道的页数、渲染、搜索、大纲、批注、解锁、OCR 与缓存清理调用。 |
| `txt_parser.dart` | TXT 解析与章节识别。探测 UTF-8/UTF-16/GBK/Big5 编码（含常见中文常用字评分），256MB 上限；四组章节标题正则（`第X章/卷X/Chapter N/番外` 等）仅去除 Markdown 装饰后判定，以句读等散文特征排除伪标题；`buildBookFromText` 供 DOC/DOCX、Kindle 复用同一章节规则；`upgradeLegacyTxtBook` 用旧版本号驱动重解析。 |
| `word_parser.dart` | Word 文档导入。DOCX 在 Dart 内用 archive+xml 解包 document.xml，提取标题、元数据、样式段落、表格与脚注并落地图片；旧版二进制 DOC 委托 POI 通道在 Android 后台提取纯文本；两条路径统一走 `buildBookFromText`，正文不出设备。 |
| `word_count_service.dart` | 字数统计服务。按 Unicode scalar 计数（代理对不重复计，排除空白），isolate 后台执行；结果按 `书ID:大小:解析版本:章节数` 缓存并去重在途请求，编辑章后以代数失效；含千分位格式的全文与逐章展示函数。 |
| `font_service.dart` | 字体导入与加载。经 `ImportedFontStore` 保存所选字体并以时间戳命名家族注册到 Flutter 引擎，加载失败自动回退系统字体且不丢其他设置；静态去重防止重复注册与并发重复加载。 |
| `incoming_file_service.dart` | 外部 ACTION_VIEW 文件接收。原生复制到缓存后经通道通知，静态处理器串行消费避免两个文件管理器启动竞态；结构化错误经回调上报。 |
| `system_text_action_service.dart` | 系统文字动作服务。经 PackageManager 查询可接收翻译/搜索的应用，产品白名单圈定六个 AI 应用与 Edge/Chrome/系统浏览器；支持记住默认目标、清除默认与显式启动校验。 |
| `update_service.dart` | 更新检查。依次请求 GitHub Releases 接口与镜像线路，任一线路取到正式版 JSON 即停止；三轮段比较版本号，解析 arm64 APK 资产并校验下载地址确实指向本仓库的发布路径，安装包摘要优先取资产自带的 `digest`，缺失时回退发布说明里的 `SHA-256：` 行；给出“有新版/已最新/检查失败”三态结果，同一时刻只保留一次在途检查。 |
| `update_download_service.dart` | 安装包下载与安装。下载前并发向全部线路各取一段 512 KB 样本，按首包之后的实测吞吐排序，未应答的线路退到队尾保底，随后从最快的一条开始下载；下载中每秒统计一次速率，持续落后于下一条线路一半速度达六秒即换线，已落盘的字节通过 `Range` 续传接续，接近完成时不再换线；字节先写入会话目录内的 `.part` 文件，长度、ZIP 魔数与 SHA-256 全部通过才改名为正式 APK；跨线路续传只在存在摘要时启用，失败即删除本次会话目录，两天前的旧会话在开始时清理；支持取消与进度回调，安装经 `app_update` 通道转交原生层。 |
| `storage/obsolete_search_cleanup.dart` | 独立小模块。删除旧版全文搜索在应用数据目录遗留的 `search/` 目录，含路径越界防护。 |
| `storage/chapter_payload_codec.dart` | 章节载荷编解码。`encodeChapterPayload` 写入章节 JSON（富文本块含全部可见文本时不重复写纯文本），`decodeChapterPayload` 还原章节数据并为损坏的富文本重建兜底纯文本；禁止依赖 IO 与 Flutter，由架构测试锁定。 |
| `storage/chapter_revision_cleanup.dart` | 过期章节载荷回收。在持有章节写队列时执行，正常清单与备份清单引用的载荷一律保留，清单损坏即放弃本次回收。 |

### lib/theme/

| 文件 | 作用 |
|---|---|
| `app_theme.dart` | 全局设计系统。定义暖米色调色板常量、四种阅读主题色 `ReaderThemeColors`（背景/正文/次级/头部/边框/强调）、`getReaderTheme`（系统主题解析）、`systemUiOverlayStyle`（透明状态栏与导航栏，按背景亮度选择图标亮度），以及完整亮/暗两套 `ThemeData`（无水波纹、自绘 SnackBar 透明）。 |
| `app_motion.dart` | 动效令牌与开书过渡。集中全部时长与曲线令牌（按压 96ms、书架重排、菜单、底部抽屉、翻 300ms、开书 680ms 等）；`buildFadeScaleRoute` 实现三阶段书香开页路由：封面快照提起放大、单页绕左缘翻开、阅读面接管，关闭为逐帧倒放；内部 `_BookRouteTransition`、`_BookRouteFrame`、`_OpeningPage` 管理阴影、圆角、折页阴影与封面 RawImage。 |
| `app_overlay_theme.dart` | 阅读主题下的界面覆盖层。`AppOverlayTheme` 依据 `ReaderThemeColors` 现场派生整套主题（按钮、输入框、对话框、抽屉、菜单、Tooltip、滑条、ListTile），并提供 `isDark`、`danger`、`barrier`、`shape` 静态助手，保证任何页面上浮出的控件与当前阅读纸色一致。 |
| `app_spacing.dart` | 间距与圆角令牌。`AppSpacing`（4/8/12/16/24/32）与 `AppRadius`（8/12/16/24 胶囊）。 |

### lib/widgets/

| 文件 | 作用 |
|---|---|
| `app_toast.dart` | 应用统一轻提示。基于透明 SnackBar 自绘卡片（信息/成功/错误/加载四种图标与配色的时长），支持阅读纸色注入与宽屏居中限制，加载态 30 秒常驻、点击可消。 |
| `app_dialog.dart` | 应用统一对话框。`showAppDialog` 捕获主题上下文并控制入场/退场时长与遮罩透明度；`AppDialog` 规范内边距与最大宽度；`AppDestructiveButton` 以错误色呈现破坏性操作（填充或描边两态）。 |
| `app_sheet.dart` | 应用统一底部面板。`showAppSheet` 以 `ModalBottomSheetRoute` 承载可滚动面板并保留禁用动画降级；`AppSheetSurface` 定制 24dp 圆角纸面；`AppSheetHeader` 提供标题与关闭钮；`AppActionSheet` 为多子项动作列表；面板不再裁掉底部安全区，改由滚动内容自行留白，纸面一直铺到屏幕底缘。 |
| `app_popup_menu.dart` | 主题化弹出菜单。`AppPopupMenuButton` 自行计算锚点矩形后调用 `showMenu`，限定宽度并绘制选中态（勾选图标与强调底色）；可选的 `menuRightInset` 把菜单右缘钉在距屏幕右边固定距离处，用于与下方内容列对齐；`AppMenuEntry` 携带值、标签、图标与选中标记。 |
| `pressable_scale.dart` | 纯视觉按压缩放反馈。用 Listener 监听原始指针事件，不注册手势识别器，可包裹 InkWell/按钮而不劫持点击；禁用态自动复位。 |
| `book_card.dart` | 书架书卡。封面区域复现背景书脊与渐变遮罩（三明治分层供开书动画采样），显示封面图或首字占位；以章节进度与章内进度折算整体百分比，PDF 显示页数口径；可用性受损时角标提示丢失原因；语义化拼接无障碍标签。 |
| `chapter_list.dart` | 全屏目录面板。列表底部按系统手势条高度补白，章节行可滚动至手势条之下。`_TocDirectory` 把章节组织为两级卷目录（卷标题聚合、导语类与卷间散章分区），无卷则退化为平铺列表；卷头为 pinned 固定头可折叠并回传展开状态；行尾显示逐章字数（监听 `chapterWordCounts`）；打开时按当前章定位可见行并保持卷头可见。 |
| `chapter_editor_sheet.dart` | 章节编辑器。顶栏由关闭键、章节标题输入框、查找替换开关与保存按钮组成；正文框不自动聚焦，打开时按 `initialAnchorOffset` 把阅读所在行钉到视口顶部（读取 `RenderEditable` 的光标矩形，天然对齐整行）；查找替换面板在当前章内定位匹配，`_FindHighlightController` 直接在文本跨度上着色，因此未聚焦也能看到命中，支持上一个、下一个、单次替换与全部替换（上限 500 处）；深度处理 Android 系统栏：键盘弹出时恢复编辑区、路由非当前或退后台时暂停，并以 1.1 秒延时重试恢复；富文本章节保存前弹确认（本章转纯文本）；脏内容关闭时询问放弃；保存失败原样展示错误。 |
| `book_search_sheet.dart` | 书内搜索面板。泛型绑定 `SearchMatch`，防重复提交与过期回包（串号丢弃）；按命中区间绘制加粗高亮片段；结果为空、尚未搜索或出错分态展示，达上限提示缩小关键词。 |
| `reader_settings_sheet.dart` | 阅读设置面板。字号、行高、字体（组合 `FontSettingsSection`）、粗细、页边距、段距、阅读模式与翻页效果、主题全部用自绘滑块式分段控件（高亮块以 `TweenAnimationBuilder` 平移切换）；`_RollingModeDescription` 用于阅读模式说明的上下滚动切换；仿真模式才显示翻页效果选项。 |
| `font_settings_section.dart` | 字体选择区。系统/宋体/导入三选一卡片加导入按钮，导入卡副标题显示字体名并在无导入字体时禁用，选中卡片微放大并描边强调。 |
| `global_settings_sheet.dart` | 全局设置侧栏（书架右上打开）。字体区、外部应用默认项清除、自动检查更新开关、手动检查更新入口与开源许可页入口；版本号由书架层传入。 |
| `library_search_controls.dart` | 书架搜索与筛选用控件。`LibraryFilterButton` 弹出筛选菜单（当前项在菜单中打勾），菜单右缘与书架网格右边线对齐；`LibrarySearchControls` 组合圆角搜索框（可清除）与激活筛选 `InputChip`。 |
| `reading_progress_bar.dart` | 阅读页顶部细进度条。矮 2dp 固定于最上端，`ValueListenableBuilder` 局部重建，任何阅读模式都随滚动推进，不随菜单开关隐藏。 |
| `app_update_dialog.dart` | 新版本对话框。展示安装包体积与发布说明（限高滚动），一个按钮串起下载、校验与调起安装三步；测速阶段显示不定进度条，下载中显示线路、百分比与实时速率且可随时取消；下载成功后失败重试不再重复下载，安装权限缺失时提示去系统设置开启后直接重试。 |

### lib/screens/

| 文件 | 作用 |
|---|---|
| `library_screen.dart` | 书架页。书架网格与拖动排序区在底部留出系统手势条高度，内容滚动到手势条之下。经三个可注入依赖（仓库、更新器、导出器）初始化门面服务；负责书籍装载与串号保护、文件选择导入、外部来书导入、开书（含封面截屏快照与书香开页路由）、长按动作面板（改名/排序/删除/导出）、拖动排序网格与焦点自动滚动、搜索与筛选、维护调度、更新检查（3 秒后台静默检查、 dismissed 三天静默）与全局设置侧栏、四种空态（无书/无结果/导入中/打开中）与入场动画。 |
| `reader_screen.dart` | 文字阅读页（核心）。三种阅读模式：分章（横滑切章、可编辑）、滚动（跨章连续）、仿真（整页分页、仿真/平滑翻页）。职责涵盖：设置装载与防抖持久化（键盘瞬时内嵌不触发重排）、阅读进度记录与恢复（文字锚点与偏移多通道）、目录/搜索/编辑/设置四面板联动、翻页拖拽手势与速度惯性、相邻页与相邻章预热渲染、顶部进度条与沉浸式系统栏、字体加载回退、Epub 排版委托与保活保留选区等。状态编排分散于五个 controller，滚动控制器重建与预加载缓存集中在本 State。 |
| `pdf_reader_screen.dart` | PDF 阅读页。加载进度、书签、笔记、显示主题与内嵌批注五源合并；`PageView` 翻页配双指缩放（缩放页横向拖动锁定为平移）、进度滑杆、跳页对话框、书签笔记列表、大纲（缩进层级）、双通道搜索（文件文本或逐页 OCR，OCR 结果做空白规范化）、逐页识别弹窗、显示主题切换与源文件丢失兜底删除；渲染任务按 `页:宽度` 去重并限在途 18 个。 |

### lib/screens/reader/

| 文件 | 作用 |
|---|---|
| `reader_epub_layout.dart` | EPUB 排版引擎。测量（按基行数取整的块高）、锚点映射（标题优先的章内定位）、渲染（富文本块到 Widget：安全对比度前景色、混合出版商背景、图片高度钳制与替代文本兜底）；行高基准由仿真模式下注入的函数解析，与用户的字体设置联乘。 |
| `reader_pagination_support.dart` | 分页与翻页支持（16 类）。`SimulationLayoutSignature` 判定布局参数变化；`ExactScrollExtentSliverChildBuilderDelegate` 把未知章尾的滚动估值锁到精确页高，避免最后页“回跳”；`FullViewportPagingScrollController` 把滚动范围补齐整页（补尾空白纸）；`SelectionAwareScrollController` 在选区存在时保持滚动位置不丢失；`ReadingTextAnchor`/`ScrollSnapshot` 描述恢复锚点；`SmoothTurnPages` 与 `StraightBookTurnPages` 分别实现位移翻页与直页书翻页（含页叶裁剪 `_StraightLeafFrontClipper`、背面绘制 `StraightPaperPainter` 与 `StraightLeafGeometry` 翻页几何）。 |
| `reader_layout_cache.dart` | 阅读会话缓存。按章缓存段落与测量高度，容量受章节数与字符数双上限约束；正文变化整体失效，排版与宽度签名单独失效已测高度。 |
| `reader_selection_support.dart` | 文字选区组件。`ReaderSelectionArea` 包裹正文并为长按/双击选区定制工具栏：折叠或超界时换到安全位置，菜单提供复制、分享、全选与六个受控翻译/搜索目标（AI 图标置入，记住默认目标可勾选），选择“记住”后下次直达；边缘拖选经 `ReaderSelectionEdgeScroller` 协同，模态打开即挂起选区。 |
| `reader_selection_edge_scroller.dart` | 边缘拖选自动滚动。手柄或拖选位置进入上下 56px 边缘带时，以 Ticker 驱动最高 420px/s 的速度滚动；由选区状态启动停止、按键与机型顶栏变化重算夹持，`_EdgeSelectionDelegate` 替换 SelectionArea 的默认边缘行为。 |
| `reader_selectable_block.dart` | 保活选区块。实现 `SelectionRegistrar` 透传注册并监听所有子文本Selectable，被选中内容（含屏外端点）由 `AutomaticKeepAliveClientMixin` 保留，防止 sliver 回收导致选区断裂；取消选择即释放缓存。 |

---

## samples/

| 文件 | 作用 |
|---|---|
| `readvibe-demo.txt` | 演示用示例书。三章短文本用于手动走通导入、阅读与退出续读流程。 |

---

## test/

| 文件 | 覆盖内容 |
|---|---|
| `architecture_boundaries_test.dart` | 架构边界静态校验：models/repositories/services 禁止 import screens/widgets；搜索面板不依赖 services；章节编解码与段落投影禁 IO/Flutter；原生 PDF 桥经 `runner.submit` 分发且引擎不接触通道。 |
| `app_feedback_test.dart` | 书架确认弹窗、危险操作提示与轻提示在各阅读主题下用正确纸色；键盘弹窗内容滚动不遮操作按钮。 |
| `book_content_transaction_test.dart` | 正文事务：旧字数结果与过期编辑器都无法覆盖已提交内容；已有惰性快照在编辑后保持可读；删除与编辑并发不留元数据与复活载荷。 |
| `book_export_service_test.dart` | 导出最新懒加载章节、UTF-8 与安全文件名；EPUB 标题不重复；PDF 导出当前字节且取消不动源文件。 |
| `book_search_service_test.dart` | 规范化空白映射回精确高亮；单会话多关键词；EPUB 与阅读同段序（含标题）。 |
| `chapter_editor_insets_test.dart` | 编辑器正文无纵向留槽、导航区背景与恢复系统栏，键盘复现时停止延迟刷新。 |
| `chapter_editor_layout_test.dart` | 编辑器充满整页且头部在刘海下；键盘可见时保留输入并确认保存。 |
| `chapter_revision_recovery_test.dart` | 修订恢复：元数据提交前中断由清单修订号胜出；字数缓存跟随已提交修订；旧载荷按宽限时间与清单引用回收；清单损坏即停止回收；旧书重解析先重映射进度。 |
| `document_search_controller_test.dart` | 搜索控制器：只有最新提交的查询跟随在途任务；换关键词丢弃已显示与在途的旧结果；销毁后的错误与回调不外泄；失败的当前查询可重试。 |
| `epub_embedded_font_test.dart` | EPUB 本地 @font-face TTF 提取并保留字体族。 |
| `font_service_test.dart` | 导入字体缺失时回退系统字体且不丢其他设置。 |
| `incoming_file_service_test.dart` | ACTION_VIEW 排队文件被串行消费。 |
| `library_export_test.dart` | 筛选保持输入稳定且导出用最新存储内容；书架信息与删除确认跟随所选主题。 |
| `library_maintenance_controller_test.dart` | 扫描合并与被替换书结果剔除；销毁抑制在途扫描；定时维护随宿主取消。 |
| `library_search_controls_test.dart` | 各筛选下输入宽度与主题；筛选菜单主题化圆面与右缘对齐位置。 |
| `managed_book_resources_test.dart` | PDF 缓存先关再删源；删除不出私有目录白名单；平台清理失败不复活已删资源。 |
| `mobi_parser_test.dart` | Kindle 超限先拒；无效容器不产生空书。 |
| `parser_sanity_test.dart` | 章节切分综合用例：卷与导语标题识别、形似标题的散文不误切、相邻重复编号标题合并。 |
| `pdf_reader_screen_test.dart` | PDF 页进度、跳页与书签交互跟随所选显示主题。 |
| `pdf_renderer_service_test.dart` | 通道返回文本与大纲校验；密码、OCR、内嵌批注调用原始通道；密码保护页数抛专用异常。 |
| `reader_controller_test.dart` | 仿真滚动范围取整；进度写按提交序；选区 notifier 同步更新。 |
| `reader_feedback_viewport_test.dart` | 仿真视口在全部抽屉与键盘弹出下保持页偏移稳定。 |
| `reader_large_selection_test.dart` | 大部头真实选区在各模式与格式下可用（含复制首段）。 |
| `reader_layout_cache_test.dart` | 布局缓存：正文失效同时清空段落与测量缓存；字体或视口尺寸变化不复用旧分页。 |
| `reader_mode_cache_transition_test.dart` | 字体变化与全部阅读模式互切后恢复原阅读位置。 |
| `reader_screen_test.dart` | 文字阅读页渲染内容并暴露共享工具入口。 |
| `reader_selection_edge_scroller_test.dart` | 滚动后保留选区可继续拖手柄；普通滑动不劫持；进选区先停弹道滚动。 |
| `reading_paragraph_test.dart` | 纯文本段序与前缀稳定； 富文本标题、空块、图片共用搜索坐标； 章节编解码先校验后建对象。 |
| `search_match_sheet_test.dart` | PDF 搜索结果仅携带页码目标即可跳页。 |
| `search_query_change_test.dart` | 搜索面板替换在途关键词时不展示过期命中。 |
| `storage_service_test.dart` | tmp 中断写入恢复； 新书写清单+独立章节文件； 正文惰性直到访问。 |
| `update_service_test.dart` | 版本三轮段比较：补丁/次级更新判新、同版本不更新。 |
| `word_count_service_test.dart` | 单次章扫描同时供逐章与全书计数。 |
| `word_parser_test.dart` | DOCX 保留元数据、标题、样式、表格、脚注与图片。 |

## tool/

| 文件 | 作用 |
|---|---|
| `check_release_package.py` | 发布包校验脚本。检查 APK 体积预算、必需条目（libflutter/libapp、ML Kit OCR 管线、内置完整宋体）、ABI 仅 arm64、中文 OCR 模型在包内、抬除的 BouncyCastle PQC 数据未回包，内置字体与源逐字节一致，并在 R8 mapping 中确认排除算法不可达；输出体积与最大条目摘要。 |
| `draw_launcher_icon.py` | 图标生成脚本。用贝塞尔路径绘制 1024 母版，`--install` 同时导出五档 mipmap 与自适应前景，全部尺寸从同一张 4096 渲染降采样，底色与 `colors.xml` 逐字节一致。 |

## design/

| 文件 | 作用 |
|---|---|
| `readvibe-icon.png` | 图标 1024 母版，由 `tool/draw_launcher_icon.py` 生成，用于商店素材与设计参考。 |
| `README.md` | 图标生成流程说明。记录出图命令、三处输出的用途与底色同步要求。 |

---

## 命名与协作速查

- **协议通道**：`com.readvibe.app/` 前缀下共六个 MethodChannel——`incoming_file`、`system_text_actions`、`document_parser`、`app_update`、`book_export`、`pdf_renderer`，Dart 端各在对应 service 中静态封装（`book_export` 的封装在 `BookExportService` 内）。
- **文档级不变量**：正文与解析全部本地执行；章节编辑只改私有副本；导出位置由用户经系统界面选择；签名材料不入库。
- **版本约定**：公开版本按 `0.6.X` 递增，Android 内部构建号同步递增；release 构建缺 `key.properties` 即失败。
- **修改验证**：Dart 改动跑 `flutter analyze` 与 `flutter test`，平台与发布改动加跑 Gradle 单测与 `tool/check_release_package.py`。
