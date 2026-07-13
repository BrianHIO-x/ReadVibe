# ReadVibe 应用协作规则

本文件适用于 `ReadVibe/` 应用目录，并继承仓库根目录的 `../AGENTS.md`。根规则是最高级约束；本文件负责补充 Flutter 应用、阅读交互和 Android 发布的具体要求。

## 一、命令与工作目录

- 默认命令环境为 PowerShell 7（`pwsh.exe`）。
- Flutter 命令默认在本目录执行：

```powershell
cd D:\0_Study\0_Stdio\0_Codex_work\1.ReadVibe_Project\ReadVibe
```

- 搜索优先使用 `rg`，修改文件使用补丁方式，不覆盖无关用户改动。

## 二、每次变更必须同步全部 Markdown

- 每次修改代码、配置、资源、依赖、版本、构建产物、功能或交互后，都必须逐一检查并同步修正整个仓库中的全部 `.md`，不得只修改 `ReadVibe/README.md` 或当前任务直接提到的文档。
- 当前必须逐一核对：
  - `../AGENTS.md`
  - `../README.md`
  - `AGENTS.md`
  - `README.md`
  - `docs/UI_OPTIMIZATION.md`
  - `windows/README.md`
- 每份文档都要检查版本号、功能描述、构建命令、文件路径、平台状态、验证结论和限制。即使确认某份内容无需实质调整，也不能跳过核对。
- 新增或删除 Markdown 后，必须立即更新根规则、应用规则和根 README 中的文档清单。
- 交付前执行：

```powershell
Push-Location ..
rg --files -g '*.md' -g '!**/build/**' -g '!**/.dart_tool/**'
Pop-Location
```

然后检查旧版本号、被禁止的公开版本后缀、已删除测试说明和失效路径。

## 三、版本与 APK

- 当前公开版本：`v0.1.8`。
- 用户可见版本号只能是三段式语义版本，不得附加 Android 内部构建编号。
- `pubspec.yaml` 的 `version` 只写三段式版本。
- Android `versionCode` 单独递增，只用于系统升级排序。
- APK 文件名固定为 `ReadVibe-Android-v主版本.次版本.修订版本-arm64-v8a.apk`。
- 当前正式产物：`dist/ReadVibe-Android-v0.1.8-arm64-v8a.apk`，37,405,495 字节，SHA-256 为 `9C052741484308E9FD0C5F0F3E44ACA85153305DD1BFF0126C7BA9BC37029496`。
- 版本发布时同步更新 `pubspec.yaml`、`android/local.properties`、全部 Markdown、构建命令和 `dist/` 产物。

## 四、平台范围

- 当前唯一正式目标端：Android `arm64-v8a`。
- Android 32 位、x86、x86_64 当前不支持。
- Windows 仅保留 `windows/README.md` 占位说明，不能运行或构建。
- iOS、macOS、Linux 和 Web 平台工程当前不存在，也不在维护范围。

## 五、阅读行为不可回退项

- TXT 默认段落之间不空行，设置顺序为“不空行 / 空一行”。
- 字体选项必须同时保留“系统字体”和“内置宋体”，并支持导入 `.ttf` / `.otf`。
- 单击正文负责呼出或关闭菜单；双击不得选中文本；长按选择和复制保留。
- 纵向滚动、横向翻章和长按选文不得被误判为菜单短按。
- 打开或关闭菜单、修改主题、字号、行距、字体、字重、页边距和段落间距时，正文不得回到顶部。
- 每章同时保存像素偏移和阅读比例；离开章节前先保存离章快照，返回时恢复该章独立位置。
- 上一章和下一章预览使用独立控制器，在离屏阶段恢复保存位置；翻页提交继承预览像素，不得先显示章首再跳转。
- 平滑翻页和仿书籍翻页必须共用正确的相邻章节内容与进度。
- 仿书籍翻页当前包含曲面折痕、真实阅读页镜像纸背、动态阴影和边缘高光，不得退回简单矩形裁切、通用线条或空白纸带效果。
- 真实纸背必须来自当前可见正文快照；纵向滚动、菜单切换、设置重排或切章后旧快照必须释放，避免显示过期位置。
- 内置宋体使用静态常规字重资源降低包体，但 glyph 数和 Unicode cmap 必须与原完整可变字体一致；禁止删减生僻字。

## 六、解析、存储和隐私

- TXT 需兼容 UTF-8、UTF-8 BOM、UTF-16 BOM、常见 GBK 和多种换行符。
- 章节识别必须避免把普通正文误判为章节，并兼容常见中文、英文和 Markdown 章节标题。
- 大文件解析和章节 JSON 编解码保持在后台 isolate，避免阻塞阅读 UI。
- 章节正文使用本地文件原子写入并支持 `.tmp` / `.bak` 恢复。
- 设置和进度写入保持最新写入优先，避免旧异步任务覆盖新状态。
- 禁止未经授权上传书籍正文、导入字体、阅读进度或个人设置。

## 七、验证方式

- 当前项目不保留 `test/`、`.dart_tool/test/` 或 `flutter_test`。
- 未经用户明确要求，不创建自动化测试，不报告测试通过数量。
- Flutter 代码变更至少执行：

```powershell
flutter analyze
flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 0.1.8 --build-number 9
```

- 构建后核对 APK 的 `versionName`、ABI、文件名、大小和 SHA-256。
- 真机验证被系统安全确认阻止时必须如实记录，不得把“设备已连接”写成“交互已验证”。
