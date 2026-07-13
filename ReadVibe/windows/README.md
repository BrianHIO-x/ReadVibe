# ReadVibe Windows 平台占位说明

## 当前状态

`windows/` 当前不是 Flutter Windows 原生工程，只保留本说明文件作为平台占位。

ReadVibe `v0.1.8` 的唯一正式目标端是 Android `arm64-v8a`。本版的真实镜像纸背翻页与 APK 字体资源精简都只针对 Android 发布产物；Windows Runner、CMake 配置、插件注册文件和桌面资源已经删除，因此以下命令当前不能使用：

```powershell
flutter run -d windows
flutter build windows
```

不要把本目录描述为“已支持 Windows”，也不要在普通 Android 修复中自动重新生成 Windows 工程。

## 为什么只保留占位

- 当前产品交互围绕 Android 手机触摸、系统栏和手势导航设计。
- 阅读页的上下滚动、左右翻章、长按选择和沉浸式系统栏逻辑需要针对桌面键鼠重新设计。
- 保留未维护的 Flutter 平台模板会扩大构建范围并产生误导。
- 当前发布、静态检查结论和 APK 产物只针对 Android arm64-v8a。

## 以后恢复 Windows 的前提

只有用户明确决定重新支持桌面端时，才在 `ReadVibe/` 根目录执行：

```powershell
flutter create --platforms=windows .
```

重新生成平台工程后，至少需要单独处理：

- Windows 文件选择与文件权限；
- 可调整窗口尺寸和最小窗口约束；
- 鼠标滚轮、触控板、键盘翻章和快捷键；
- 双击、拖选、右键菜单与长按选择的桌面等价交互；
- 标题栏、窗口背景和深浅色主题；
- 桌面端阅读栏宽度和大屏排版；
- Windows 字体发现与用户字体导入；
- 安装包、图标、签名和更新方式；
- Windows 专属静态检查、运行验证和发布流程。

完成这些工作之前，不能把 Windows 写入受支持平台列表。

## 文档同步规则

恢复、删除或改变 Windows 平台状态属于项目级变更。根据仓库根目录 `../../AGENTS.md` 和应用规则 `../AGENTS.md`，每次相关变更都必须逐一检查并同步修正仓库内全部 Markdown，包括：

- `../../AGENTS.md`
- `../../README.md`
- `../AGENTS.md`
- `../README.md`
- `../docs/UI_OPTIMIZATION.md`
- 当前文件

同时需要更新平台表、项目结构、构建命令、验证口径和发布产物说明，不能只修改本文件。
