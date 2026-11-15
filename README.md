# DualTranslate（双译）

轻量的 KOReader 整书 / 逐章双语翻译插件，为 EPUB 建立独立的译文覆盖层，**不修改原书**。
本项目由上游 **KoTranslate**（v1.2.11，GPL-3.0）改造而来：移除 Kindle 专属依赖（shell/unzip/awk）、去掉辅助阅读与词典功能、改用纯 Lua 实现，可在 KOReader 支持的全平台（Kindle / Android / iOS / Linux / macOS / Windows）运行。

> 注意：当前代码仓库与历史交付版本为**非破坏式 overlay 方案**（译文注入排版，不生成双语 EPUB 文件），与旧版 KoTranslate 的"生成双语 EPUB"行为不同。

## 翻译引擎

插件只保留两个无需 API 密钥的在线服务：

| 引擎 | 说明 | 默认 |
| --- | --- | --- |
| microsoft_free（Microsoft Edge 免费） | `edge.microsoft.com/translate/translatetext`，批量 ≤12 条 / ≤4000 字节，批量失败自动降级逐条重试 | ✓ 默认 |
| system（系统翻译） | 调用 KOReader 内置 `ui/translator`，逐段请求 | |

目标语言归一化：`zh-Hans → zh`、`zh-Hant → zh-TW`，与 KOReader 内置翻译一致。

## 功能

- **整书翻译**：后台队列逐章翻译，可断点续跑（意外退出后再次翻译会合并已有结果）。
- **逐章翻译**：从当前章节开始翻译，翻到新章节时自动续译，可随时停止。
- **章节选择**：从 EPUB 目录多选章节（全选本书/本页、反选），只翻译所选章节；一次性任务，不影响翻页续译。
- **按服务保留译文**：每个翻译服务独立保存（`manifest.json` + `entries/<provider>.json`），切换引擎不会覆盖其他服务的译本；「显示译文」可选择显示哪个服务、缺失段落是否回退。
- **译文覆盖层**：通过 CSS `::after` 注入排版，原 EPUB 永不被改写；译文随设置显示/隐藏。
- **翻译队列**：查看进度、**取消**任务（取消保留已翻译部分）。
- **进度显示**：整书/逐章翻译均有进度条；点开队列可弹进度条，点进度条弹操作窗口（取消），点外部收起。
- **译文样式**：字号（原生 SpinWidget 增减控件 8–40）、字体、颜色独立设置，不受全局排版影响。
- **按书缓存**：译文存 SQLite（WAL），`book_translations` 表按书隔离；覆盖层按「书 + 目标语言」独立目录。
- **删除本书全部译文**（管理译文字菜单）：同时删除所有服务的覆盖层、缓存与遗留翻译任务，原书不受影响。

## 安装

KOReader 的插件目录是安装根目录下的 `plugins/` 文件夹，目录名匹配 `*.koplugin` 即被识别为插件。各平台常见位置：

| 平台 | plugins/ 目录 |
| --- | --- |
| Kindle | `/mnt/us/koreader/plugins/` |
| Android | 内部存储 `/storage/emulated/0/koreader/plugins/`（即 `sdcard/koreader/plugins/`） |
| Linux / macOS / Windows | 发行包解压目录 `koreader/plugins/`（与 `koreader` 可执行文件同级） |
| 其他平台 | KOReader 安装根目录下的 `plugins/` |

### 安装步骤

1. 从 [Releases](https://github.com/enneaa/dualtranslate.koplugin/releases) 下载 `dualtranslate.koplugin.zip`。
2. **删除** KOReader `plugins/` 中旧的 `dualtranslate.koplugin`（或 `kotranslate.koplugin`）目录（如有）。
3. 将 zip 内容解压到 `plugins/dualtranslate.koplugin/`，最终目录结构应为：
   ```
   plugins/dualtranslate.koplugin/
   ├── main.lua
   ├── dualtranslate_reader.lua
   ├── ...（其余 .lua）
   └── _meta.lua
   ```
   > 注意不要多套一层目录（`plugins/dualtranslate.koplugin/dualtranslate.koplugin/…` 不会被加载）。
4. **完全退出并重启 KOReader**（不是返回书架，是彻底退出进程）。

### 验证安装

重启后打开任意 EPUB，菜单栏出现 **DualTranslate** 菜单即安装成功；菜单项显示「翻译引擎：Microsoft Edge（免费）」为默认状态。

### 升级注意事项

- 升级只替换 `plugins/dualtranslate.koplugin/` 目录即可；译文、缓存、队列与设置保存在 KOReader 数据目录，**不会丢失**。
- 若从旧版 KoTranslate 升级：旧配置 `dualtranslate_configuration.lua` 会自动迁移；旧译文数据不会被读取，需重新翻译（overlay 方案与旧版不兼容）。
- 本版 P0 修复后，缓存查询与 overlay 续跑会记录 `provider`。升级前已存在的 overlay 没有 `provider` 字段：打开书时先看它自己有没有记录，没有再看这本书在缓存库里是否只有一个服务——唯一才认领给该服务，否则记到 `legacy`（不猜）；如果希望按新服务强制重译，请先执行「管理译文 → 删除本书全部译文」。
  例外：如果翻译任务在书被打开之前就消费了这份旧 overlay（队列续跑），`Epub.translate_overlay` 会按**当前引擎**认领并在写入时固化进 v3 entries——这条老路径只在「书没打开过但要续跑」时出现。
- 译文按服务分文件保存（`manifest.json` + `entries/<provider>.json`）：切换「翻译引擎」不再覆盖其他服务已有的译文，可以同时保留多个服务的译本，并在「显示译文」里选择显示哪一个。
- 旧版单文件 `overlay.json` 会在打开书时自动迁移为 v3 格式（原文件备份为 `overlay.v2.bak`）；某个服务的请求全部失败时不会写入空 checkpoint 覆盖已有数据。

## 使用

打开 EPUB 后，菜单栏出现 **DualTranslate** 菜单：

- 第一项为插件开关（复选框）；停用不会删除译文、缓存、队列或设置。
- 选择「翻译引擎」「源语言」「目标语言」。
- 「翻译本书」子菜单包含三种范围：「翻译整本」「翻译当前章节」「选择章节…」（多选章节后一次性翻译，不影响后续翻页）。
- 勾选「逐章模式」后，「翻译当前章节」会随翻页自动续译后续章节；整书翻译不受该开关影响。
- 「翻译队列」查看进度与取消任务。
- 「显示译文」切换译文可见性；子菜单可按服务选择显示哪一个译本，并控制缺失段落是否回退到其他服务。
- 「管理译文」按服务查看段数、删除某个服务的译文，或对本书译文数据执行修复。
- 「译文字号/字体/颜色」调整译文样式。
- 「管理译文 → 删除本书全部译文」彻底删除本书（所有服务）的翻译数据；对话框标题仍显示为“清除本书译文”。

## 数据位置

- 译文数据：KOReader 数据目录 `cache/dualtranslate/books/<hash>/` 下的 `manifest.json`（服务列表、完成度、显示选择）与 `entries/<provider>.json`（各服务的译文条目）；旧版 `overlay.json` 迁移后保留为 `overlay.v2.bak`
- 译文数据库：KOReader 数据目录 `dualtranslate_cache.sqlite3`（WAL 模式）
- 进度文件：`cache/dualtranslate/progress_*.txt`
- 配置：KOReader 原生 `settings/dualtranslate.lua`（`dualtranslate_` 前缀键），旧版 `dualtranslate_configuration.lua` 自动迁移

## 从源码构建 / 测试

```sh
# 语法检查
luac -p *.lua

# 单元测试（无需 KOReader 环境，纯 Lua 5.1/5.3 均可）
lua tests/loadtest.lua
lua tests/fulltest.lua
lua tests/epub_test.lua
lua tests/state2_test.lua
lua tests/cache_test.lua
lua tests/cache_provider_test.lua
lua tests/clear_path_test.lua
lua tests/overlay_provider_test.lua
lua tests/langmenu_test.lua
lua tests/callcheck.lua
lua tests/queueui_test.lua
lua tests/clear_test.lua

# 打包（排除 tests 与迁移配置）
zip -q -r ../dualtranslate.koplugin.zip . -x "./.*" -x "./tests/*" \
    -x "./dualtranslate_configuration.lua" -x "./dualtranslate_configuration_sample.lua"
```

## 许可

GPL-3.0，与上游 KoTranslate 一致。详见 [LICENSE](LICENSE)。

完整版本变更记录见 [XPLATFORM.md](XPLATFORM.md)。
