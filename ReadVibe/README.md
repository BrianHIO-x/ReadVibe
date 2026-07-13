# ReadVibe Android 应用

ReadVibe 是面向本地小说阅读的 Flutter Android 应用。TXT、EPUB、阅读进度、字体、设置和书架元数据均在设备本地处理。

## 发布信息

| 项目 | 当前值 |
|---|---|
| 公开版本 | `v0.3.0` |
| `pubspec.yaml` | `version: 0.3.0` |
| Android 基础构建号 | `14` |
| arm64 APK 清单 | `versionName=0.3.0`，`versionCode=2014` |
| ABI | `arm64-v8a` |
| APK | [`dist/ReadVibe-Android-v0.3.0-arm64-v8a.apk`](dist/ReadVibe-Android-v0.3.0-arm64-v8a.apk) |
| 文件大小 | 38,061,331 字节（约 36.30 MiB） |
| SHA-256 | `F60CDF556B4C5AE371BC42B3E7CDE2BE930E977254B80812693DA1A0F98315BD` |

## 功能说明

### 书架

- 启动时只加载轻量书架元数据，点击书籍后再读取章节正文。
- 书卡显示作者、章节数、阅读比例和全文字数。
- 缺少字数时立即显示可点击书卡，并在后台逐本统计。
- 长按书籍打开操作面板，可修改本地书名或删除书籍。
- 改名只原子更新 metadata 中的 `title`，不会重写大型章节 JSON。
- 删除书籍同步清理正文、阅读进度和目录折叠状态。

### 后台全文字数

- 统计范围为全部章节标题与正文。
- 按 Unicode scalar value 计数，并排除 Unicode 空白字符。
- 使用 isolate 执行，避免占用 UI 主线程。
- 同一本书的并发统计任务去重；书架队列一次处理一本书。
- 开书 Future 不等待字数结果。
- 结果只更新 metadata 的 `wordCount` 字段，不覆盖并发完成的书名修改。
- 阅读页通过 `ValueNotifier<int?>` 将结果实时推送给已经打开的目录。

### TXT 导入

- 支持 UTF-8、UTF-8 BOM、UTF-16 LE/BE BOM 和常见 GBK。
- 支持 CR、LF、CRLF、NEL、Unicode 行分隔符和段落分隔符。
- 识别 `第1章`、`第一回`、`Chapter 1`、`# 第1章` 等常见标题。
- 普通句子不会仅因包含“卷”或“节”而被当作章节。
- 首个章节前的有效内容保留为开篇内容。
- 连续标题没有正文时不生成可跳转的空白章节。
- 纯卷标题写入后续章节的 `volumeTitle`，用于建立目录层级。
- 大文件读取、解码、解析和 JSON 编解码在 isolate 中执行。

### EPUB 导入

- 解压和解析在 isolate 中执行。
- 从 `META-INF/container.xml` 定位 OPF。
- 读取 metadata、manifest 和 spine。
- 按线性 spine 顺序提取 XHTML 文本。
- 跳过空白内容、脚本、样式和非线性页面。
- 块级 HTML 转换为适合小说阅读的段落换行。
- 对归档条目数、单项体积和总解压体积设置保护边界。

EPUB 按小说纯文本模式呈现，不复刻原文件的复杂 CSS 和图文排版。

### 阅读页手势

| 手势 | 行为 |
|---|---|
| 单击正文 | 打开或关闭顶部、底部菜单 |
| 双击正文 | 不选择文本，不显示选择工具栏 |
| 长按正文 | 选择文本，显示五项系统操作 |
| 上下滑动 | 滚动当前章节 |
| 左右滑动 | 切换上一章或下一章 |
| 点击目录章节 | 从章首打开所选章节 |

正文 `ListView` 始终位于稳定的 `SelectionArea` 层级。菜单切换前保存当前像素和比例，布局完成后核对同一滚动控制器，避免系统栏变化带来位置偏移。

### 文本选择菜单

长按选择工具栏只显示：

1. 复制
2. 分享
3. 全选
4. 翻译
5. 搜索

复制、分享和全选复用 Flutter 在 Android 上的平台选择回调。翻译通过 Android `ACTION_TRANSLATE` 调用系统服务，搜索通过 `ACTION_WEB_SEARCH` 调用系统搜索；系统无对应处理器时使用平台回退路径。应用只在用户点击操作后传递当前选中文字。

### 目录

- 有明确卷信息时，卷为一级菜单，章节为缩进的二级菜单。
- 没有卷信息时直接显示单层章节列表。
- 简介、作品简介、前言、序言、序章、楔子等卷外内容位于目录顶部。
- 后记、尾声、附录和番外等内容保持独立一级项。
- 卷默认展开，点击卷标题折叠或展开。
- 折叠集合以书籍 ID 为作用域写入 `SharedPreferences`。
- 当前章节属于折叠卷时，目录定位到卷标题并保留用户选择。
- 标题区显示章节数与全文字数；统计完成后无需关闭目录即可刷新。

### 阅读进度

每本书保存：

- 当前章节索引；
- 当前滚动像素；
- 当前归一化阅读比例；
- 每章独立像素映射；
- 每章独立比例映射；
- 最后阅读时间。

活动章节滚动时更新内存快照，本地写入使用防抖与串行队列。开始横向翻章、应用进入后台或关闭阅读页时主动保存。提交切章前先固定离章章节、像素和比例，避免控制器与章节索引串写。

### 相邻章节预览

- 上一章和下一章使用独立预览控制器。
- 预览页在屏幕外完成布局并恢复该章保存位置。
- 翻页提交时读取预览控制器的真实像素和比例。
- 新活动页从预览位置接管，动画前后保持同一画面位置。
- 主题或排版变化后按保存比例重新核对活动页和预览页。

### 平滑翻页

- 当前页与相邻预览页位于同一 `Stack`。
- 水平位移由 `ValueNotifier<double>` 驱动。
- 松手后根据位移比例和速度完成切章或回弹。
- 动画期间保持离章快照和目标预览状态一致。

### 仿书籍翻页

- `_BookCurlGeometry` 根据页面尺寸、进度、方向和手指纵向位置计算折页几何。
- 三次贝塞尔曲线形成倾斜折痕。
- `_BookPageClipper` 裁切尚未翻起的当前页。
- `_BookCurlPainter` 绘制目标页投影、折痕暗部、高光和纸张厚度。
- 当前活动页由稳定 `GlobalKey` 的 `RepaintBoundary` 包裹。
- 每次手势只复用一个异步 `toImage()` 捕获任务。
- 纸背围绕实时折痕轴反射当前可见页快照，显示真实标题、正文、字体、主题和滚动位置。
- 滚动、菜单、设置、章节或手势结束后立即使快照失效。
- 快照尚未完成或捕获失败时，同一手势继续使用平滑过渡，保证翻页始终可操作。

### 阅读设置

| 设置 | 选项 |
|---|---|
| 字号 | 16、18、20、22、24；默认 20 |
| 行距 | 1.4、1.6、1.8、2.0、2.2 |
| 字重 | 细、常规、粗 |
| 页边距 | 窄、中、宽；默认中 |
| 段落间距 | 不空行、空一行；默认不空行 |
| 翻页 | 平滑、仿书籍 |
| 主题 | 跟随系统、浅色、暖色、深色 |
| 字体 | 系统字体、内置宋体、导入字体 |

字号、行距、字体、字重、页边距和段落间距会改变正文高度。应用设置前保存阅读比例，重排后按新的最大滚动范围恢复同一比例。

### 字体

- “系统字体”和“内置宋体”始终并列显示。
- 内置 `SourceHanSerifSC-Regular.ttf` 保留 65,535 个 glyph 和 44,748 个 Unicode cmap 映射。
- 支持导入 `.ttf` 和 `.otf`。
- `FontLoader` 对并发加载去重。
- 字体文件不可用时安全回退系统字体。

### 开书、关书与主题

- 开书时截取书架中的封面画面，并从书卡位置展开。
- 封面以左侧为轴进行 3D 开页，阅读内容随后接管画面。
- 关闭使用同一条 680 ms 时间线反向播放。
- 路由纸面、加载占位、阅读页、书架和系统栏共享当前 `ReaderThemeColors`。
- 书内切换主题时，书架底层和转场主题同步更新。
- 路由采用非 opaque 背景，使书架在页面收拢时连续显露。
- 封面快照和主题监听器保留到 `TransitionRoute.completed` 后释放。

## 本地数据

| 数据 | 存储方式 |
|---|---|
| 书架 metadata | SharedPreferences |
| 阅读设置 | SharedPreferences |
| 阅读进度 | SharedPreferences |
| 目录折叠状态 | SharedPreferences |
| 章节正文 | 应用文档目录 JSON |
| 导入字体 | 应用文档目录字体文件 |

章节正文采用原子替换写入，可从完整的 `.tmp` 或 `.bak` 文件恢复。设置、进度和轻量 metadata 更新使用最新状态优先，避免异步写入覆盖用户后续操作。Android 云备份关闭。

## 代码结构

```text
ReadVibe/
├── android/                         Android arm64 发布工程
├── lib/
│   ├── main.dart                   应用入口
│   ├── models/                     书籍、章节、进度和设置模型
│   ├── screens/                    书架页与阅读页
│   ├── services/                   解析、存储、字数与系统文本操作
│   ├── theme/                      主题和动效
│   └── widgets/                    书卡、目录与设置组件
├── docs/UI_OPTIMIZATION.md         阅读交互实现基线
├── windows/README.md               Windows 平台状态
├── samples/                        示例 TXT
├── dist/                           正式 APK
├── pubspec.yaml
└── analysis_options.yaml
```

## 开发环境

- PowerShell 7
- Flutter stable
- Android SDK 与签名环境
- 一台 Android arm64 设备用于交互检查

```powershell
cd D:\0_Study\0_Stdio\0_Codex_work\1.ReadVibe_Project\ReadVibe
flutter pub get
flutter analyze
flutter devices
```

## Release 构建

```powershell
flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 0.3.0 --build-number 14
```

Flutter 输出：

```text
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

规范产物：

```powershell
New-Item -ItemType Directory -Force -Path dist | Out-Null
Copy-Item build\app\outputs\flutter-apk\app-arm64-v8a-release.apk dist\ReadVibe-Android-v0.3.0-arm64-v8a.apk -Force
```

发布核对：

```powershell
Get-FileHash dist\ReadVibe-Android-v0.3.0-arm64-v8a.apk -Algorithm SHA256
```

## 当前验证状态

| 检查 | 结果 |
|---|---|
| `flutter analyze` | 通过 |
| Android arm64 release 构建 | 通过 |
| APK `versionName` | `0.3.0` |
| APK `versionCode` | `2014` |
| APK native code | `arm64-v8a` |
| 真机交互 | 交付检查时没有连接 ADB 设备，未执行目视验证 |

需要在真机检查长按五项菜单、系统翻译与搜索目标、后台字数原地刷新、书架改名、进度恢复、仿书纸背和深色关书转场。未执行的路径不能标记为已经通过。

## 相关文档

- [`../AGENTS.md`](../AGENTS.md)：仓库最高级规则。
- [`AGENTS.md`](AGENTS.md)：应用协作约束。
- [`../README.md`](../README.md)：仓库入口与发布摘要。
- [`docs/UI_OPTIMIZATION.md`](docs/UI_OPTIMIZATION.md)：阅读交互与渲染细节。
- [`windows/README.md`](windows/README.md)：Windows 平台状态。
