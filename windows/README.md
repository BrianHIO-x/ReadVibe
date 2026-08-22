# Windows 目录状态

ReadVibe `v0.6.7` 的正式运行与发布目标只有 Android `arm64-v8a`，最低系统为 Android 8.0（API 26）。

本目录只保存平台状态说明，不包含 Windows Flutter runner、构建配置或发布产物，因此不执行 Windows 构建。应用的 DOC 二进制解析、PDF 页面渲染和系统外部应用调用均使用 Android 原生实现。

Android 小说阅读器的仿真模式使用固定整屏页距；章节末页仅以空白纸面补足剩余高度，随后直接切换到下一章。

Android 的 EPUB 导入按 OPF spine 与 NAV/NCX 建立章节，普通段落采用 TXT 排版规则，正文语义标题保留 EPUB 样式且不重复显示。

Android 书架支持本地搜索、阅读状态/格式筛选和文件管理器“用 ReadVibe 打开”；PDF 阅读页支持防熄屏、跳页、页码进度、文字搜索、大纲、本地书签和页码笔记。这些能力均未提供 Windows 实现。

当前 Android 正式产物为：

```text
../dist/ReadVibe-Android-v0.6.7-arm64-v8a.apk
```

相关文档：

- [项目说明](../README.md)
- [当前界面与交互](../docs/UI_OPTIMIZATION.md)
- [仓库协作规则](../AGENTS.md)
