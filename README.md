# ReadVibe — 本地离线小说阅读器

ReadVibe 是使用 Flutter 构建的 Android 本地小说阅读器。应用支持导入 TXT 和 EPUB，并在设备本地完成解析、分章、排版、阅读设置、全文字数统计和进度保存。

## 当前发布

| 项目 | 当前值 |
|---|---|
| 公开版本 | `v0.3.0` |
| 正式目标 | Android `arm64-v8a` |
| APK | [`ReadVibe-Android-v0.3.0-arm64-v8a.apk`](ReadVibe/dist/ReadVibe-Android-v0.3.0-arm64-v8a.apk) |
| APK 大小 | 38,061,331 字节（约 36.30 MiB） |
| SHA-256 | `F60CDF556B4C5AE371BC42B3E7CDE2BE930E977254B80812693DA1A0F98315BD` |
| 静态检查 | `flutter analyze` 已通过 |
| Release 构建 | Android arm64 release 已成功生成 |
| 真机状态 | 交付检查时没有连接 ADB 设备，交互路径尚未完成真机目视确认 |

公开版本使用三段式语义版本；Android 内部 `versionCode` 独立维护，不写入公开版本或 APK 文件名。

## 当前功能

### 本地书架

- 导入 `.txt` 与 `.epub`。
- 书卡显示作者、章节数、阅读比例和全文字数。
- 字数尚未完成时显示“全文字数统计中…”，书籍仍可立即打开。
- 全文字数按书排队，在后台 isolate 中统计章节标题和正文的非空白 Unicode 字符。
- 长按书卡可修改书名或删除书籍；改名只更新本地元数据。

### TXT 与 EPUB

- TXT 支持 UTF-8、UTF-8 BOM、UTF-16 LE/BE BOM 和常见 GBK 文本。
- 兼容 CR、LF、CRLF、NEL、Unicode 行分隔符和段落分隔符。
- 识别常见中文、英文和 Markdown 章节标题。
- 纯卷标题保存为目录结构，不生成空白阅读页。
- EPUB 按 spine 顺序提取为适合小说阅读的纯文本内容。
- 解析、解压和较大的 JSON 编解码在后台 isolate 中运行。

### 阅读与进度

| 手势 | 行为 |
|---|---|
| 单击正文 | 显示或关闭阅读菜单 |
| 双击正文 | 不选中文本，不显示选择工具栏 |
| 长按正文 | 选择文本，并显示复制、分享、全选、翻译、搜索 |
| 上下滑动 | 阅读当前章节 |
| 左右滑动 | 切换相邻章节 |
| 点击目录项 | 从章首打开指定章节 |

- 每章独立保存滚动像素和归一化阅读比例。
- 切章前先保存离章状态，相邻章节在预览阶段恢复自身位置。
- 菜单、主题、字体和排版设置变化后继续保持当前阅读位置。
- 翻页提交后沿用预览页的真实位置，不先显示章首再跳转。

### 目录

- 有明确卷标题时显示卷与章节两级目录。
- 没有卷标题时显示单层章节列表。
- 简介、前言、序言等卷外内容作为顶部一级项。
- 卷默认展开，折叠状态按书保存。
- 标题区显示章节总数和全文字数；后台统计完成后原地刷新。

### 翻页

- “平滑”模式让当前页跟随手指横向移动。
- “仿书籍”模式绘制曲面折痕、动态阴影、纸张高光和真实文字纸背。
- 纸背来自当前可见阅读页快照的镜像，继承字体、主题、标题、正文和滚动位置。
- 快照未就绪时使用可操作的平滑过渡，保证左右拖动和切章不中断。

### 阅读设置

- 字号：16、18、20、22、24，默认 20。
- 行距：1.4、1.6、1.8、2.0、2.2。
- 字重：细、常规、粗。
- 页边距：窄、中、宽。
- 段落间距：不空行、空一行，默认不空行。
- 翻页模式：平滑、仿书籍。
- 主题：跟随系统、浅色、暖色、深色。
- 字体：系统字体、内置宋体、用户导入的 `.ttf` / `.otf`。

### 主题安全转场

- 开书与关书使用同一条 680 ms 正反时间线。
- 当前阅读主题同步用于阅读页、过渡纸面、书架底层和系统栏。
- 关闭书籍时，转场资源保留到反向动画完全结束。
- 深色主题下不会主动插入浅色纸面作为过渡背景。

## 隐私与数据

- 书籍正文、书架元数据、设置、字体和阅读进度保存在应用本地目录。
- Android 系统云备份关闭。
- 只有用户主动点击长按菜单中的“翻译”或“搜索”后，所选文字才会交给 Android 系统服务处理。
- 删除书籍时同步清理正文、进度和目录展开状态。

## 技术结构

```text
1.ReadVibe_Project/
├── AGENTS.md
├── README.md
└── ReadVibe/
    ├── AGENTS.md
    ├── README.md
    ├── android/
    ├── lib/
    ├── docs/UI_OPTIMIZATION.md
    ├── windows/README.md
    ├── samples/
    ├── dist/
    ├── pubspec.yaml
    └── analysis_options.yaml
```

| 层面 | 实现 |
|---|---|
| UI | Flutter / Material 3 |
| TXT | Dart 编码处理、`fast_gbk` 回退、后台 isolate |
| EPUB | `archive`、XML、HTML、后台 isolate |
| 元数据与设置 | SharedPreferences |
| 章节正文 | 应用文档目录中的 JSON 文件 |
| 字体 | 内置宋体、本地字体复制、Flutter `FontLoader` |
| 翻页 | 手势状态、相邻页预热、页面快照、CustomClipper、CustomPainter |
| 发布 | Android `arm64-v8a` release APK |

## 开发与构建

默认命令环境为 PowerShell 7。

```powershell
cd D:\0_Study\0_Stdio\0_Codex_work\1.ReadVibe_Project\ReadVibe
flutter pub get
flutter analyze
flutter devices
```

构建当前正式产物：

```powershell
flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 0.3.0 --build-number 14
New-Item -ItemType Directory -Force -Path dist | Out-Null
Copy-Item build\app\outputs\flutter-apk\app-arm64-v8a-release.apk dist\ReadVibe-Android-v0.3.0-arm64-v8a.apk -Force
```

## 文档导航

- [`AGENTS.md`](AGENTS.md)：仓库级协作、版本、验证和全量文档同步规则。
- [`ReadVibe/AGENTS.md`](ReadVibe/AGENTS.md)：Flutter 应用级实现与发布约束。
- [`ReadVibe/README.md`](ReadVibe/README.md)：应用功能、代码结构、数据和构建说明。
- [`ReadVibe/docs/UI_OPTIMIZATION.md`](ReadVibe/docs/UI_OPTIMIZATION.md)：当前阅读交互与渲染实现基线。
- [`ReadVibe/windows/README.md`](ReadVibe/windows/README.md)：Windows 平台状态说明。

任何实现、配置、版本、产物或交互变化后，都要重新检查并同步全部 Markdown。文档只保留当前有效信息，不作为旧版本修复记录使用。
