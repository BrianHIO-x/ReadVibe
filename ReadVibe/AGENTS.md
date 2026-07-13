# ReadVibe 项目协作规则

## 命令环境

- 默认命令环境为 PowerShell 7（`pwsh.exe`）。

## 版本命名硬性规则

- 用户可见版本号只能使用三段式语义版本：`v主版本.次版本.修订版本`。
- 禁止在公开版本号后使用加号追加构建编号。
- `pubspec.yaml` 的 `version` 字段只写三段式版本，不附加构建编号。
- Android APK 文件名固定为：`ReadVibe-Android-v主版本.次版本.修订版本-arm64-v8a.apk`。
- Android `versionCode` 是只供系统判断升级顺序的内部整数，必须单独递增，不得出现在公开版本号、APK 文件名或发布标题中。
- 每次发布必须同步更新 `pubspec.yaml`、`README.md`、`docs/UI_OPTIMIZATION.md` 和 `dist/` 中的 APK 文件名。
- 交付前必须检查项目文档和发布产物，确认不存在把内部构建编号拼接到公开版本号后的写法。

## 验证方式

- 当前项目不保留自动化测试目录和 `flutter_test` 依赖。
- 未经用户明确要求，不得重新创建自动化测试，也不得再用自动化测试通过数量作为交付结论。
- 代码变更至少执行静态检查和 Android release 编译；阅读交互问题应以真实设备操作路径为准。
