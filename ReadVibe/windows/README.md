# Windows placeholder

这个目录目前只作为 Windows 端占位空壳保留。

ReadVibe v0.1 demo 的正式目标端暂时只有 Android arm64-v8a。此前 Flutter 自动生成的 Windows 原生工程文件已经移除，因此当前不能执行 `flutter run -d windows` 或 `flutter build windows`。

如果以后重新需要 Windows 端，可以在项目根目录运行：

```powershell
flutter create --platforms=windows .
```

然后再按新的桌面端目标重新接入文件导入、窗口尺寸、键鼠交互和桌面端打包流程。
