# ReadVibe 仓库协作规则

本规则覆盖仓库根目录和 `ReadVibe/` 应用目录。

## 工作方式

- 默认命令环境为 PowerShell 7。
- 文件与文本搜索优先使用 `rg` 和 `rg --files`。
- 文本修改使用补丁；保留用户已有且与当前任务无关的改动。
- 不使用会丢失工作内容的破坏性 Git 命令。
- ReadVibe 是本地离线阅读器。书籍正文、阅读进度和设置均保存在设备本地，不加入账号、云同步或正文上传。

## Markdown 同步

代码、配置、资源、依赖、版本、构建方式、发布产物或用户可见行为发生变化时，必须使用 `rg --files -g '*.md'` 检查并同步全部 Markdown。文档只写当前源码中已经存在的功能、当前构建方式和真实验证结果。

当前 Markdown 文件为：

- `AGENTS.md`
- `README.md`
- `ReadVibe/AGENTS.md`
- `ReadVibe/README.md`
- `ReadVibe/docs/UI_OPTIMIZATION.md`
- `ReadVibe/windows/README.md`

新增、删除、移动或重命名 Markdown 时，同时更新本清单、根 README 的文档导航和相关链接。

## 发布基线

- 公开版本为 `v0.6.6`。
- 唯一正式目标为 Android `arm64-v8a`，最低 Android 8.0（API 26）。
- 正式产物路径为 `ReadVibe/dist/ReadVibe-Android-v0.6.6-arm64-v8a.apk`。
- 用户可见版本采用 `v主版本.次版本.修订版本`。`ReadVibe/pubspec.yaml` 只保存三段式版本；Android `versionCode` 独立递增，不进入公开版本号、APK 文件名或发布标题。Flutter 的 arm64 分包会在基础构建号上增加 `2000`，当前基础构建号为 `52`，APK 清单中的实际 `versionCode` 为 `2052`。
- APK 文件名固定为 `ReadVibe-Android-v主版本.次版本.修订版本-arm64-v8a.apk`。
- `ReadVibe/windows/` 只有平台状态说明，不是可构建的 Windows 工程。

## 当前功能边界

- 书架导入 TXT、EPUB、PDF、DOCX 和 DOC；手机布局每行三本书。
- TXT、EPUB、DOCX 和 DOC 共用小说阅读器、目录、书内全文搜索、文本选择、阅读设置、三种阅读模式和进度模型。
- EPUB 在本地读取 OPF spine 与 NAV/NCX 目录，普通段落按 TXT 阅读设置排版，语义标题保留 EPUB 颜色与强调样式，包内图片参与正文；远程资源不加载。
- PDF 使用独立固定版式阅读器，支持逐页浏览、缩放和页码进度。
- 小说阅读模式为“分章 / 滚动 / 仿真”，默认“分章”。仿真模式提供“仿真翻页 / 平滑翻页”，默认“仿真翻页”；纸页按当前字体实际基线距离建立固定整屏页距，章节标题吸附同一行网格，章尾以空白纸面补齐，不裁切或重叠重复正文。
- 阅读设置包含系统、浅色、暖色、深色主题，系统字体、内置宋体和本地导入字体，字号 `16 / 18 / 20 / 22 / 24`，以及字重、行高、页边距和段落空行。
- 小说全文搜索在用户提交关键词后直接于后台 isolate 扫描当前书籍的全部章节正文。
- 书架顺序、书名、阅读进度、设置、目录展开状态和后台字数统计均持久化到本地。

## 修改与验证

- 阅读页变更必须保护当前章节、当前视口正文位置、每章独立进度和跨章保存顺序。
- 菜单、主题、字体、排版与阅读模式变化不能把正文重置到章节顶部。
- 异步存储只允许最新状态覆盖同一数据项；已删除书籍的后台任务不得重新写回元数据或进度。
- 当前项目包含 `test/parser_sanity_test.dart`、`test/update_service_test.dart` 和 `flutter_test` 依赖。未经用户明确要求，不新增自动化测试，也不以测试数量作为交付结论。
- Dart、Flutter、Android 或原生代码变更后至少执行 `flutter analyze`、现有 `flutter test`，并构建 Android arm64 release APK。
- 交付前核对公开版本、ABI、最低系统、APK 文件名、实际体积和 SHA-256，并再次盘点全部 Markdown。
