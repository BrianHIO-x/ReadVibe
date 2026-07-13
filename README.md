# ReadVibe — 本地离线小说阅读器

ReadVibe 是一个使用 Flutter 构建的 Android 本地小说阅读器。它支持导入 TXT 和 EPUB，在设备本地完成解析、分章、排版、阅读设置和进度保存，不依赖账号、服务器或云同步。

## 当前发布状态

| 项目 | 当前值 |
|---|---|
| 公开版本 | `v0.1.7` |
| 正式目标端 | Android `arm64-v8a` |
| APK | `ReadVibe/dist/ReadVibe-Android-v0.1.7-arm64-v8a.apk` |
| APK 大小 | 51,261,470 字节，约 48.9 MiB |
| SHA-256 | `B1A83E6C008BE3F115FD986BC63D1CDDF1C443D23A45A34FA6D89BF032DF2967` |
| 静态检查 | `flutter analyze` 已通过 |
| Release 构建 | Android arm64 release 已成功生成 |

公开版本号只允许使用三段式语义版本。Android 内部升级编号独立维护，不得拼接到公开版本或 APK 文件名中。

## 仓库结构

```text
1.ReadVibe_Project/
├── AGENTS.md                         仓库级协作与文档同步规则
├── README.md                         当前文件，仓库入口
└── ReadVibe/
    ├── AGENTS.md                     Flutter 应用级协作规则
    ├── README.md                     功能、开发、构建和数据说明
    ├── android/                      当前唯一可发布的平台工程
    ├── lib/                          Dart / Flutter 主代码
    ├── docs/UI_OPTIMIZATION.md       阅读交互与性能实现说明
    ├── windows/README.md             Windows 占位状态与恢复步骤
    ├── samples/                      示例 TXT
    ├── dist/                         本地 APK 发布产物
    ├── pubspec.yaml
    └── analysis_options.yaml
```

当前仓库没有 `test/` 目录，也不包含 `flutter_test` 依赖。未经用户明确要求，不重新创建自动化测试，不使用测试通过数量作为交付依据。

## 文档导航

- [`AGENTS.md`](AGENTS.md)：仓库最高级规则，包括“每次变更必须同步全部 Markdown”的硬性要求。
- [`ReadVibe/AGENTS.md`](ReadVibe/AGENTS.md)：应用级版本、交互、验证和发布规则。
- [`ReadVibe/README.md`](ReadVibe/README.md)：完整功能、目录结构、开发环境和构建命令。
- [`ReadVibe/docs/UI_OPTIMIZATION.md`](ReadVibe/docs/UI_OPTIMIZATION.md)：阅读页稳定性、进度、翻页、性能与回归检查说明。
- [`ReadVibe/windows/README.md`](ReadVibe/windows/README.md)：Windows 端为何不能构建，以及以后如何恢复。

任何代码、配置、资源、版本、构建产物或交互变化后，都必须逐一检查并同步修正上述全部 Markdown。详细规则见根目录和应用目录的两个 `AGENTS.md`。

## 产品原则

### 本地与私有

- 书籍正文、书架元数据、阅读进度和阅读设置保存在设备本地。
- 当前不提供账号、云同步或远程服务器。
- Android 系统云备份已禁用，避免私人书籍正文被自动备份到设备账号。
- 卸载应用通常会同时删除书籍、进度和导入字体。

### 小说阅读优先

- TXT 自动识别编码、章节和段落，统一为稳定的小说排版。
- EPUB 按 spine 顺序提取为纯文本阅读版。
- 复杂 EPUB CSS、漫画、教材和图文混排不会完整还原原版版式。
- 正文默认首行缩进两格，段落之间默认不空行；用户可以切换为“空一行”。

### 沉浸与位置稳定

- 阅读时隐藏顶部状态栏，保留 Android 底部手势导航区域。
- 单击正文只控制菜单显示和关闭。
- 双击正文不会选中文字；长按仍可选择和复制。
- 纵向滚动阅读，左右滑动切换上一章或下一章。
- 菜单、主题、字体和排版设置变化不得把正文重置到章节顶部。

## 主要功能

### 书籍导入

- 导入 `.txt` 和 `.epub`。
- TXT 支持 UTF-8、UTF-8 BOM、UTF-16 LE/BE BOM 和常见 GBK。
- 兼容 CR、LF、CRLF、NEL、Unicode 行分隔符和段落分隔符。
- 识别常见中文、英文和 Markdown 章节标题，例如 `第1章`、`Chapter 1`、`# 第1章`。
- 避免把句号结尾的普通“第一卷……。”或“第一节……。”误判成章节。
- 保留首个真实章节前的开篇文字，过滤没有正文的伪目录项。
- 旧版被存为“全文”的 TXT 首次打开时会按新解析器重新分章，并迁移阅读比例。
- EPUB 按线性 spine 顺序读取，跳过非线性或空白页面，并限制异常归档的条目数和解压体积。

### 阅读与菜单

| 手势 | 行为 |
|---|---|
| 单击正文 | 呼出或关闭顶部、底部菜单 |
| 双击正文 | 不选择文本，不显示选择工具栏 |
| 长按正文 | 选择文本并保留复制能力 |
| 上下滑动 | 阅读当前章节 |
| 左右滑动 | 切换上一章或下一章 |
| 点击目录项 | 打开指定章节并从章首开始 |

正文列表始终保持在稳定的 `SelectionArea` 层级中。菜单开关前会记录当前像素和阅读比例，并在布局完成后核对滚动位置，避免系统栏或组件重建造成回顶。

### 章节进度

- 每章独立保存滚动像素和归一化阅读比例。
- 手势开始时锁定离章快照，并在切换章节前先排队保存离开的章节。
- 设置变化导致正文高度改变时，按阅读比例恢复，而不是复用失效像素。
- 退出页面时使用最后一个真实滚动快照，避免控制器断开后用 0 覆盖进度。
- 上一章和下一章分别使用独立的离屏预览控制器。
- 相邻章节在进入翻页画面前就恢复到各自保存位置。
- 翻页提交时，新活动页继承预览页真实像素，不会先显示章首再突然跳到进度。

### 翻页模式

平滑翻页：

- 当前页跟随手指水平移动。
- 相邻章节预热后参与同一画面。
- 松手后根据滑动距离和速度决定完成翻章或回弹。

仿书籍翻页：

- 折痕使用三次贝塞尔曲线。
- 折痕倾斜方向跟随手指纵向落点。
- 翻动页包含独立纸张背面和淡化透印纹理。
- 当前页、目标页和纸张背面分别使用动态明暗与投影。
- 卷边绘制暗边、柔光和纸张厚度高光。
- 向前、向后翻章使用镜像几何，并继续使用正确的相邻章节进度。

### 阅读设置

- 字号：14、16、18、20、24。
- 行距：1.4、1.6、1.8、2.0、2.2。
- 字重：细、常规、粗。
- 页边距：窄、中、宽，默认中档。
- 段落间距：不空行、空一行，默认不空行。
- 翻页模式：平滑、仿书籍。
- 主题：跟随系统、浅色、暖色、深色。
- 字体：系统字体、内置宋体、用户导入的 `.ttf` / `.otf`。

## 技术架构

| 层面 | 实现 |
|---|---|
| UI | Flutter / Material 3 / StatefulWidget |
| TXT 解析 | Dart 编码处理、`fast_gbk` 回退、后台 isolate |
| EPUB 解析 | `archive`、XML、HTML、后台 isolate |
| 书架与设置 | SharedPreferences |
| 章节正文 | 应用文档目录中的 JSON 文件 |
| 字体 | 本地文件复制与 Flutter `FontLoader` |
| 翻页 | 手势驱动页面组合、CustomClipper、CustomPainter |
| 发布 | Android arm64-v8a release APK |

存储采用“元数据轻量加载、正文按需读取”的方式。章节文件使用原子替换，并能从完整的 `.tmp` 或 `.bak` 恢复；较大的章节 JSON 编解码在后台 isolate 中执行。

## 平台状态

| 平台 | 状态 |
|---|---|
| Android arm64-v8a | 当前唯一正式维护与发布目标 |
| Android 32 位 | 不支持 |
| Android x86/x86_64 | 不支持 |
| Windows | 仅占位说明，当前不能构建 |
| iOS / macOS / Linux / Web | 平台工程已删除，当前不维护 |

## 快速开始

默认环境为 PowerShell 7。

```powershell
cd D:\0_Study\0_Stdio\0_Codex_work\1.ReadVibe_Project\ReadVibe
flutter pub get
flutter analyze
flutter devices
flutter run -d <设备编号>
```

构建当前 Android arm64 release：

```powershell
flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 0.1.7 --build-number 8
```

复制为规范发布文件名：

```powershell
New-Item -ItemType Directory -Force -Path dist | Out-Null
Copy-Item build\app\outputs\flutter-apk\app-arm64-v8a-release.apk dist\ReadVibe-Android-v0.1.7-arm64-v8a.apk -Force
```

APK 清单必须显示 `versionName='0.1.7'` 和 `native-code: 'arm64-v8a'`。正式对外发布前还需要配置并妥善保管正式签名；当前产物用于本地 demo 和真机预览。

## 验证口径

- Flutter 代码变更：至少执行静态分析和 Android arm64 release 构建。
- 阅读手势、进度、系统栏和动画：优先在 Android 真机验证。
- 如果手机厂商安全页要求人工确认安装，必须明确记录未完成的真机步骤，不得宣称已经通过。
- 文档变更：全量盘点全部 Markdown，检查版本、路径、命令、功能、平台状态和交叉链接。
- 当前不运行或恢复自动化测试，除非用户明确要求。

## 当前边界

ReadVibe 仍是 `v0.1` 阶段的本地小说阅读器 demo，暂未实现：

- 真实封面图片提取和管理；
- 书签、批注和全文搜索；
- 听书或 TTS；
- 云同步和账号系统；
- 复杂 EPUB CSS 与图文版式还原；
- Android 平板专门布局；
- Windows、iOS、macOS、Linux 或 Web 正式版本。
