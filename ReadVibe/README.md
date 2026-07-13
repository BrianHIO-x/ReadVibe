# ReadVibe Flutter 应用

ReadVibe 是一个面向 Android 手机的本地离线小说阅读器 demo。应用导入 TXT 或 EPUB 后，在设备本地完成解析、分章、排版、字体加载、阅读设置和进度保存，不上传书籍正文。

## 当前版本与产物

| 项目 | 当前值 |
|---|---|
| 公开版本 | `v0.1.7` |
| Android 目标 | `arm64-v8a` |
| Release APK | `dist/ReadVibe-Android-v0.1.7-arm64-v8a.apk` |
| 文件大小 | 51,261,470 字节，约 48.9 MiB |
| SHA-256 | `B1A83E6C008BE3F115FD986BC63D1CDDF1C443D23A45A34FA6D89BF032DF2967` |

公开版本只能使用三段式语义版本。Android 内部升级编号单独维护，不能附加到公开版本号、APK 文件名或发布标题。

## 文档同步要求

任何代码、配置、资源、版本、构建产物、功能或交互变化后，都必须逐一检查并同步修正仓库内全部 Markdown。不能只修改本 README。完整规则和当前文档清单见：

- [`../AGENTS.md`](../AGENTS.md)
- [`AGENTS.md`](AGENTS.md)

技术实现和回归基线见 [`docs/UI_OPTIMIZATION.md`](docs/UI_OPTIMIZATION.md)。Windows 占位状态见 [`windows/README.md`](windows/README.md)。

## 支持范围

| 平台 | 状态 | 说明 |
|---|---|---|
| Android arm64-v8a | 正式维护 | 当前唯一构建和发布目标 |
| Android 32 位 | 不支持 | 已从构建目标删除 |
| Android x86/x86_64 | 不支持 | 不维护模拟器 ABI |
| Windows | 占位 | 原生工程已删除，当前不能运行或构建 |
| iOS / macOS / Linux / Web | 不维护 | 平台目录当前不存在 |

## 功能说明

### 书架

- 显示书名、作者、格式、章节数和阅读进度。
- 从系统文件选择器导入 `.txt` 和 `.epub`。
- 点击书籍通过封面展开动画进入阅读页。
- 长按书籍显示删除确认。
- 左上角菜单按钮或书架右滑打开全局设置。
- 书架主题与阅读主题保持一致。

### TXT 导入

- 支持 UTF-8、UTF-8 BOM、UTF-16 LE/BE BOM 和常见 GBK。
- 兼容 CR、LF、CRLF、NEL、Unicode 行分隔符和段落分隔符。
- 识别常见中文、英文和 Markdown 章节标题。
- 去掉 Markdown 标题外层的 `#` 或全角 `＃`。
- 避免把句号结尾的普通“第一卷……”或“第一节……”正文误判为章节。
- 保留首个真实章节前的开篇内容。
- 连续目录项如果没有正文，不生成可跳转的空白章节。
- 旧版“全文”记录首次打开时会重新解析、分章并迁移阅读比例。
- 正文存储使用单换行表示自然段；空行由阅读设置渲染，避免大文件重复膨胀。

TXT 的默认阅读排版是：

- 章节标题去除前导半角或全角空格；
- 正文去除原始前导空格后统一首行缩进两格；
- 段落之间默认不空行；
- 设置项固定为“不空行 / 空一行”。

### EPUB 导入

- 解压 EPUB 归档并读取 `META-INF/container.xml`。
- 解析 OPF metadata、manifest 和 spine。
- 按线性 spine 顺序提取 XHTML。
- 从标题标签和文档标题中提取章节名。
- 将 HTML 转换为干净纯文本，跳过脚本、样式和空页面。
- 跳过非线性 spine 项。
- 限制异常归档条目数量、单项大小和总解压体积。

当前 EPUB 目标是小说纯文本阅读，不完整还原复杂 CSS、图片排版、漫画或教材布局。

## 阅读页交互

| 操作 | 结果 |
|---|---|
| 单击正文 | 呼出或关闭顶部、底部菜单 |
| 双击正文 | 不选中文字，不出现选择工具栏 |
| 长按正文 | 选择文本，可继续拖动和复制 |
| 上下滑动 | 滚动当前章节 |
| 向左滑动 | 尝试进入下一章 |
| 向右滑动 | 尝试返回上一章 |
| 打开目录并选择章节 | 从所选章节顶部打开 |

单击判断使用按下、移动、抬起距离和持续时间。纵向滚动、横向翻章和长按选文不会被当成菜单短按。

正文列表始终保持在稳定的 `SelectionArea` 结构中。双击通过内部手势接管与选区即时清理双层阻断；超过双击时间后才成立的长按仍可正常选择。

## 菜单和系统栏

- 阅读状态隐藏 Android 顶部状态栏。
- 底部系统手势导航小白条保留。
- 打开菜单时显示状态栏，关闭菜单后恢复沉浸状态。
- 菜单使用位移和透明度动画。
- 菜单隐藏时不参与正文命中测试和无障碍语义。
- 初次进入阅读页时保存稳定的顶部安全区，不让系统栏变化推动正文。
- 菜单切换前保存当前滚动快照，下一帧核对控制器位置，避免回到章首。

## 阅读进度模型

每本书的 `ReadingProgress` 保存：

- 当前章节索引；
- 当前滚动像素；
- 当前章节阅读比例；
- 每章独立像素表；
- 每章独立比例表；
- 最后阅读时间。

进度策略：

- 滚动监听更新内存快照，并以 500 ms 防抖写入本地。
- 页面关闭、应用进入后台和章节切换时主动保存。
- 横向手势开始时锁定离章快照。
- 切章时先排队写入离开的章节，再写目标章节。
- 返回章节时优先恢复该章保存比例或安全像素。
- 设置改变正文高度后按比例恢复，避免字号或页边距变化造成回顶。
- 页面销毁时控制器即使已经断开，也使用最后一个真实快照，不用 0 覆盖进度。

相邻章节预览：

- 上一章和下一章各有独立 `ScrollController`。
- 预览控制器不监听当前章节的进度写入，避免串写。
- 相邻章节在离屏预热时就恢复各自保存位置。
- 用户开始拖动时，目标页第一次露出就是正确进度。
- 提交翻页时，新活动页继承预览页真实像素，不进行可见的二次跳转。

## 翻页模式

### 平滑连续滑动

- 当前页与相邻页按手指位移并排移动。
- 章节首次加载后预热上一章和下一章。
- 目标页使用保存进度，而不是默认章首。
- 松手时根据超过 16% 页宽或速度阈值决定完成或回弹。

### 仿书籍翻页

仿书模式不是简单的矩形裁切。当前实现包含：

- 根据翻页进度计算的三次贝塞尔折痕；
- 根据手指纵向落点变化的折痕倾斜；
- 随翻页过程先展开再收拢的纸张背面；
- 与阅读主题匹配的纸色；
- 纸张背面淡化透印纹理；
- 目标页投影、当前页折痕阴影和纸背投影；
- 卷边暗线、柔光和纸张厚度高光；
- 上一章与下一章镜像几何；
- 与平滑模式相同的相邻章节进度预热。

## 阅读设置

- 字号：14、16、18、20、24。
- 行距：1.4、1.6、1.8、2.0、2.2。
- 字重：细、常规、粗。
- 页边距：窄、中、宽，默认中档。
- 段落间距：不空行、空一行，默认不空行。
- 翻页方式：平滑、仿书籍。
- 主题：跟随系统、浅色、暖色、深色。
- 字体：系统字体、内置宋体、用户导入字体。

设置面板使用紧凑的分段控件，并延迟约一个短动画周期再重排正文。字号、行距、字重、字体、页边距和段落间距改变后，阅读页按原阅读比例恢复。

## 字体

- “系统字体”和“内置宋体”始终作为并列选项存在。
- 可以导入 `.ttf` 或 `.otf`。
- 导入前检查扩展名、文件存在性和大小。
- 字体复制到应用文档目录后，通过 `FontLoader` 动态注册。
- 同一字体的并发加载会去重。
- 替换导入字体后清理旧文件。
- 启动时如果字体文件丢失，安全回退到系统字体。

## 本地存储和隐私

```text
SharedPreferences
├── 书架元数据
├── ReaderSettings
└── 每本书的 ReadingProgress

应用文档目录/ReadVibe
├── books/   章节正文 JSON
└── fonts/   用户导入字体
```

- 书架启动只读取元数据；打开书籍时才按需加载章节正文。
- 章节文件使用 `.tmp`、主文件和 `.bak` 的原子替换流程。
- 主文件损坏或中断时，可以从完整临时文件或备份恢复。
- 较大的章节 JSON 编解码放在后台 isolate。
- 设置与进度写入采用最新写入优先，避免旧异步结果覆盖新值。
- Android 云备份关闭。
- 当前没有账号、网络上传或云同步。

## 代码结构

```text
lib/
├── main.dart                         应用入口和路由
├── models/
│   ├── book.dart                     书籍与章节模型
│   ├── reader_settings.dart          设置与阅读进度模型
│   └── reader_launch_args.dart       开书动画参数
├── screens/
│   ├── library_screen.dart           书架、导入和全局设置
│   └── reader_screen.dart            阅读、进度、菜单和翻页
├── services/
│   ├── txt_parser.dart               TXT 编码、章节与段落
│   ├── epub_parser.dart              EPUB、XML 与 HTML
│   ├── storage_service.dart          本地持久化和迁移
│   └── font_service.dart             字体导入与加载
├── theme/                            颜色、间距和动效令牌
└── widgets/                          书卡、目录、设置和进度条
```

当前没有自动化测试目录和 `flutter_test` 依赖。未经用户明确要求，不创建自动化测试，也不在文档中保留测试数量或测试通过声明。

## 本机开发环境

- Shell：PowerShell 7 / `pwsh.exe`。
- Flutter SDK：`D:\flutter`。
- Android SDK：`D:\Android\Sdk`。
- Java：JDK 17。

如果当前 PowerShell 找不到 Flutter：

```powershell
$env:Path = 'D:\flutter\bin;' + $env:Path
```

安装依赖和静态检查：

```powershell
flutter pub get
flutter analyze
```

连接 Android 真机运行：

```powershell
flutter devices
flutter run -d <设备编号>
```

## Release 构建

当前版本的 Android arm64 release 命令：

```powershell
flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 0.1.7 --build-number 8
```

构建输出：

```text
build\app\outputs\flutter-apk\app-arm64-v8a-release.apk
```

复制到 `dist/`：

```powershell
New-Item -ItemType Directory -Force -Path dist | Out-Null
Copy-Item build\app\outputs\flutter-apk\app-arm64-v8a-release.apk dist\ReadVibe-Android-v0.1.7-arm64-v8a.apk -Force
```

发布前核对：

- `versionName` 为 `0.1.7`；
- 原生 ABI 只有 `arm64-v8a`；
- APK 文件名只包含公开三段式版本和 ABI；
- `dist/` 不保留旧版同类 APK；
- 文件大小和 SHA-256 与文档一致；
- 全部 Markdown 已同步检查。

## 当前验证状态

- `flutter analyze`：通过。
- Android arm64 release 构建：通过。
- APK 清单版本和 ABI：已核对。
- 连接设备：`V2454A`，Android 16，arm64。
- 真机安装：vivo 外部来源安全页要求在手机上人工勾选确认，ADB 不允许代替该安全操作，因此没有宣称 `v0.1.7` 交互已经完成真机验证；手机原有版本未被覆盖。

## 当前未实现

- 真实封面图片提取和管理；
- 书签、批注和全文搜索；
- 听书或 TTS；
- 账号和云同步；
- 复杂 EPUB CSS 与图文版式；
- Android 平板专门布局；
- Windows、iOS、macOS、Linux 和 Web 正式端。
