# Windows 目录状态

ReadVibe `v0.6.2` 的正式运行与发布目标只有 Android `arm64-v8a`，最低系统为 Android 8.0（API 26）。

本目录只保存平台状态说明，不包含 Windows Flutter runner、构建配置或发布产物，因此不执行 Windows 构建。应用的 DOC 二进制解析、PDF 页面渲染和系统外部应用调用均使用 Android 原生实现。

Android 小说阅读器的仿真模式使用固定整屏页距；章节末页仅以空白纸面补足剩余高度，随后直接切换到下一章。

Android 的 EPUB 导入按 OPF spine 与 NAV/NCX 建立章节，普通段落采用 TXT 排版规则，正文语义标题保留 EPUB 样式且不重复显示。

当前 Android 正式产物为：

```text
../dist/ReadVibe-Android-v0.6.2-arm64-v8a.apk
```

相关文档：

- [应用说明](../README.md)
- [当前界面与交互](../docs/UI_OPTIMIZATION.md)
- [仓库说明](../../README.md)
