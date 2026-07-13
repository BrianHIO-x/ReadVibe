# ReadVibe

ReadVibe 是一个用 Flutter 制作的本地离线小说阅读器 demo。它把 TXT 和 EPUB 文件导入私人书架，在设备本地完成解析、排版、阅读设置和进度保存，不上传书籍正文。

当前版本号：v0.1.7。

## 版本命名规则

- 用户可见版本号统一使用三段式语义版本：`v主版本.次版本.修订版本`。
- 公开版本号不得附加 Android 内部构建编号。
- APK 文件名统一为 `ReadVibe-Android-v主版本.次版本.修订版本-arm64-v8a.apk`。
- Android `versionCode` 只负责系统升级排序，单独递增，不写入公开版本号和安装包文件名。
- 完整硬性规则见 `AGENTS.md`。

## 当前目标端

当前仓库已经按 demo 阶段收敛平台范围：

| 平台 | 状态 | 说明 |
|---|---|---|
| Android arm64-v8a | 保留并维护 | 当前唯一正式 demo 目标端；不考虑 32 位 Android 和 x86/x86_64 模拟器兼容 |
| Windows | 仅占位空壳 | windows/ 目录只保留说明文件，不含 Flutter Windows 原生工程，暂不能构建 |
| iOS / macOS / Linux / Web |暂不维护|

如果以后重新需要 Windows 端，可以在项目根目录运行：

~~~powershell
flutter create --platforms=windows .
~~~

如果以后重新需要其它平台，也建议在明确产品目标后再用 flutter create --platforms=<platform> . 重新生成，而不是提前保留默认模板。

## 现在能做什么

- 导入 .txt 和 .epub 文件。
- 自动识别 UTF-8、UTF-8 BOM、UTF-16 BOM 和常见 GBK 中文 TXT，并兼容 CR/LF、Unicode 行分隔符等换行。
- 自动识别常见中文/英文章节标题，包括 `# 第1章`、`## 第二章 ##` 等 Markdown 形式。
- TXT 导入后自动整理小说排版：
  - 删除章节标题前原文本自带的半角/全角空格；
  - 自然段正文默认首行缩进两格；
  - 默认段落之间不空行，也可在阅读设置中切换为空一行。
- EPUB 按正式阅读顺序（spine）解析为纯文本章节。
- 书架显示书名、作者、格式、章节数和阅读进度。
- 阅读页点击页面只呼出/关闭顶部和底部菜单，不再点击翻页，避免误触。
- 阅读页通过左右滑动切换上一章/下一章，底部上一章/下一章按钮已删除。
- 支持两种翻页模式：
  - 平滑连续滑动；
  - 仿书籍翻页。
- 阅读页隐藏 Android 状态栏，保留底部系统手势导航小白条。
- 保存当前章节和滚动位置。
- 支持阅读设置：
  - 字号；
  - 行距；
  - 字重三档；
  - 页边距三档，默认中档；
  - 段落空行开关；
  - 翻页模式；
  - 阅读主题。
- 支持系统深色/浅色自动跟随，也可手动选择浅色、暖色、深色。
- 支持系统字体、内置宋体、全局字体设置，以及导入 .ttf / .otf 字体。
- 书架左上角使用三条横杠菜单按钮打开全局设置；在书架页右滑也可以打开全局设置。
- 长按书架中的书籍可以删除。

## 最近重点优化

### 阅读体验

- 点击阅读页只负责呼出菜单；翻章必须左右滑动。
- 菜单打开后再次短按正文会立即关闭；长按选文、纵向滚动和横向翻章不会误触发。
- 双击正文只作为普通阅读手势处理，不再触发词语选中；长按选择和复制仍然保留。
- 修复正文滚动后开关菜单导致列表重新附着并回到章节顶部的问题；菜单开关前会锁定当前位置，正文组件层级保持不变。
- 删除阅读章节页底部“上一章/下一章”按钮。
- 修复章节切换时旧章节和新章节短暂残留、重叠的问题。
- 修复点击呼出上下栏时正文轻微下移的问题。
- 修复新书不翻章时不保存进度、翻章时章节滚动位置串写的问题。
- 修复相邻页预热或翻页结构变化导致当前章节回到顶部的问题。
- 修复页面退出时用 0 覆盖最后阅读位置的问题。
- 设置调整后按阅读比例恢复位置，字号、行距、字体或页边距变化不再回到顶部。
- 各章节同时记录滚动像素与阅读比例，来回切章和重新打开书籍都能恢复各章位置。
- 横向翻章在手势开始时就保存离章快照，上一章位置先于目标章节切换写入本地，翻页动画期间的重建不会再覆盖离章进度。
- 上一章和下一章使用独立的离屏滚动控制器，在用户开始拖动前就恢复到各自保存的位置；平滑翻页和仿书籍翻页不再先露出章首。
- 翻章提交后直接继承手势中已经显示的目标页像素，不再切换完成后进行可见的二次进度跳转。
- 章节标题统一删除前导空格，避免不同章节标题位置不齐。
- 修复以“第一卷/第一节”开头的普通句子被误当成章节、生成空白阅读页的问题。
- 保留首个真实章节前的开篇文字，并过滤没有正文的伪目录项。
- 旧版本中已经存成“全文”的 TXT 会在首次打开时自动使用新规则重新分章，并按整书阅读比例迁移当前进度。
- 读者设置面板加入字体、字重、页边距、段落空行、翻页模式等选项。
- 设置面板缩小了各项高度，尽量控制在手机屏幕的下半部分内。

### 动画与 UI

- 全局整理动效节奏，避免“只是一味变快”。
- 阅读页菜单、设置面板、书架侧边设置抽屉都使用更平滑的动效。
- 设置按钮/分段控件改为更顺滑的高亮滑动效果，并延后昂贵的正文重排，减少第一次滑动或切换设置后的卡顿感。
- 平滑翻页模式支持手指拖动时页面跟随手指移动，并能在滑动过程中同时看到相邻章节内容。
- 仿书籍翻页已改为跟随手指纵向落点变化的曲面折痕，并加入纸张背面、透印纹理、动态投影、卷边明暗和边缘高光。
- 书籍打开/关闭动画重做：
  - 点击书架封面后，先截取原封面画面并放大到阅读页大小；
  - 随后一页以左边缘为轴，从右向左打开；
  - 打开完成后阅读页接管全屏，状态栏才隐藏；
  - 关闭时先恢复书架所需的状态栏，再按同一套时间轴反向合页并回到书架位置。

### 性能与数据可靠性

- 书架启动只读取书籍元数据，点击书籍后才按需读取正文，减少多书书架的启动时间和常驻内存。
- 大章节改为按视口懒加载段落，并缓存最近章节的段落拆分结果。
- TXT / EPUB 解析放到后台 isolate，导入大文件时不再阻塞界面动画。
- 大文件章节 JSON 的编码和解码放到后台 isolate，本地读取保护时间扩展到 30 秒。
- TXT 段落以单换行规范化存储，空行效果交由阅读设置渲染，避免大书导入后的无意体积膨胀。
- 正文原子写入支持从 `.tmp` / `.bak` 自动恢复；并发设置和进度写入不会让旧值覆盖新值。
- TXT 新增 UTF-16 BOM 和 CR 换行兼容；EPUB 跳过非线性 spine 页面并限制异常解压体积。
- 字体导入增加文件类型 / 大小校验、并发加载去重和旧字体文件清理。
- Android 禁用系统云备份，避免私人书籍正文被自动备份到设备账号。

### APK 体积和目标架构

- Android release 构建只保留 arm64-v8a。
- 删除 32 位 Android、x86、x86_64 的兼容目标。
- Android release 开启代码/资源收缩。
- 当前 release APK 约 48.8MB。

## 项目结构

~~~text
android/                         Android 原生外壳，当前唯一正式目标端
windows/                         Windows 占位空壳，暂不构建
lib/
  main.dart                       应用入口和页面导航
  models/                         书籍、章节、阅读设置、进度、启动参数
  screens/library_screen.dart     书架、导入、全局设置入口
  screens/reader_screen.dart      正文阅读页、翻页、阅读菜单
  services/txt_parser.dart        TXT 编码识别、章节解析、段落整理
  services/epub_parser.dart       EPUB/XML/HTML 解析
  services/storage_service.dart   本地书籍、进度和设置存储
  services/font_service.dart      字体导入和加载
  theme/                          颜色、间距、圆角、动效令牌
  widgets/                        书卡、目录、设置面板、字体设置等组件
docs/
  UI_OPTIMIZATION.md              优化记录和当前设计说明
samples/
  readvibe-demo.txt               示例 TXT
dist/                             本地构建产物目录，默认被 git 忽略
~~~

## 本机环境

默认命令环境：PowerShell 7 / pwsh.exe。

Flutter 已安装在：

~~~text
D:\flutter
~~~

Android 构建环境：

~~~text
Java 17:     C:\Program Files\Eclipse Adoptium\jdk-17.0.19.10-hotspot
Android SDK: D:\Android\Sdk
Android API: 34、35、36
~~~

如果新开的 PowerShell 找不到 flutter，当前窗口可临时执行：

~~~powershell
$env:Path = 'D:\flutter\bin;' + $env:Path
~~~

## 常用命令

进入项目：

~~~powershell
cd D:\0_Study\0_Stdio\0_Codex_work\1.ReadVibe_Project\ReadVibe
~~~

安装依赖和静态检查：

~~~powershell
flutter pub get
flutter analyze
~~~

连接 Android 真机后运行：

~~~powershell
flutter devices
flutter run -d <设备编号>
~~~

构建 Android arm64 release APK：

~~~powershell
flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 0.1.7 --build-number 8
~~~

构建产物位于：

~~~text
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
~~~

常用复制命令：

~~~powershell
New-Item -ItemType Directory -Force -Path dist | Out-Null
Copy-Item build\app\outputs\flutter-apk\app-arm64-v8a-release.apk dist\ReadVibe-Android-v0.1.7-arm64-v8a.apk -Force
~~~

当前本地最新 APK：

~~~text
dist\ReadVibe-Android-v0.1.7-arm64-v8a.apk
~~~

把 APK 复制到 64 位 Android 手机并允许“安装未知应用”即可安装预览。当前包用于本地 demo 测试；正式发布前需要创建并妥善保管发布签名。

## 本地数据

- 书架元数据、阅读进度和阅读设置：平台偏好设置。
- 章节正文：应用文档目录下的 ReadVibe/books/。
- 导入字体：应用文档目录内的字体文件，并通过设置记录当前选择。
- 早期草稿产生的章节偏好数据：第一次读取时会自动迁移为正文文件。

卸载应用通常会删除这些本地数据。当前版本没有账号、云同步或远程服务器。

## 当前边界

这是 ReadVibe v0.1 demo，不是完整阅读器产品。当前暂未实现：

- 真实封面图片提取和管理；
- 书签、批注、全文搜索；
- 云同步、账号系统；
- 听书；
- 复杂 EPUB CSS/图文版式还原；
- Android 平板专门布局；
- Windows/iOS/macOS/Linux/Web 正式端。

EPUB 当前提取为干净的纯文本阅读版，适合小说类书籍；高度复杂的教材、漫画或图文电子书不会完整还原原始版式。
