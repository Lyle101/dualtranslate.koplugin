# DualTranslate 测试套件

纯 Lua + stub 环境，无需 KOReader。在 kotranslate_xplatform/ 目录下运行：

    lua tests/loadtest.lua      # 加载 + init + 设置读写 + 菜单构建 + 全项渲染
    lua tests/fulltest.lua      # 文本切分 / Overlay CSS / Tools hash / Languages / 队列 / Providers
    lua tests/epub_test.lua     # EPUB resolve / 段落收集 / 锚点路径缓存（3 槽 LRU）/ translate_overlay 完整流程
    lua tests/listindent_test.lua # 列表父项缩进：书 CSS / 内联 style / marker 宽度 / 选择器匹配
    lua tests/outline_test.lua  # P2-a：extract_entries 按需抽取 / NCX/nav/spine 目录 / 映射去重 / 失败清理 / outline 磁盘缓存 / 100 章性能
    lua tests/chapter_picker_test.lua # P2-b：getBookOutline 内存缓存 / 目录条目页号缓存（3 槽 LRU）/ 选择器状态与分页 / 对话框流程
    lua tests/state2_test.lua   # loadConfig 迁移 / loadQueue 边界
    lua tests/cache_test.lua    # SQLite cache（mock）
    lua tests/cache_provider_test.lua  # P0：缓存查询按 provider 隔离
    lua tests/migration_test.lua # P1-a：真实 SQLite 的 v3 schema / v2→v3 迁移 / providers
    lua tests/lock_test.lua     # P1-b：书目录锁（互斥/超时/陈旧回收/异常释放）
    lua tests/overlay_v3_test.lua # P1-b：manifest/entries 读写 / buildCss v3 / 迁移分支
    lua tests/overlay_entries_cache_test.lua # entries 解析缓存：命中 / save/delete/mtime 失效 / 预算淘汰
    lua tests/overlay_revision_test.lua # revision 缓存键 / 模板替换 / 命中与失效 / 8MB LRU
    lua tests/template_gc_test.lua # 模板磁盘回收：过期 / 50MB 上限 / 跳过当前书 / 节流
    lua tests/glossary_test.lua # 术语表/风格指南：解析（空行/重复/全角等号/上限）/ 原子写 / 与 manifest 解耦
    lua tests/store_delete_test.lua # P1-b：真实 SQLite 的按 provider 删除 / intent 收尾 / reconcile
    lua tests/p1c_switch_test.lua # P1-c：按服务切换主链（State/PageTrans/Reader v3/Epub checkpoint/菜单）
    lua tests/context_test.lua    # P1-c：context 透传契约（Epub → translate(_batch) / 缓存 meta / 只切分一次）
    lua tests/queueui_test.lua    # 翻译队列子菜单：进行中行重开进度框、排队/失败行带取消项
    lua tests/clear_path_test.lua      # P0：清除路径必须传书路径
    lua tests/clear_test.lua      # 清除后重翻：complete 标记与残留译文不能再拦住整书翻译
    lua tests/overlay_provider_test.lua # P0：overlay 续跑按 provider 隔离
    lua tests/langmenu_test.lua # 语言子菜单闭包
    lua tests/google_free_test.lua # google_free：请求形状 / 响应三态 / 429 退避 / 切组边界
    lua tests/mcp_job_test.lua  # P3-a：Tools.split_text 边界 / Epub.collect_segments / job.json
    lua tests/mcp_import_test.lua # P3-b：导入校验 / part 拼回 / DB+entries+manifest / reload.seq
    lua tests/mcp_menu_test.lua # P3-c：mcp_external 分流 / 隐私确认 / reload seq / 任务列表 / 批量删除
    lua tests/manage_menu_test.lua # 管理译文：删除后菜单保持打开、原地重建（keep_menu_open / refreshMenuPage）
    lua tests/dtctl_test.lua    # P3-d：headless CLI 的 stdout / 白名单 / forced command
    lua tests/bench_test.lua    # tools/bench.lua：--work 拒绝 / --only 校验 / .dtbench 清理 / --overlay 冒烟
    lua tests/callcheck.lua     # 方法调用完整性

默认全部离线。唯一联网的是可选冒烟（默认 SKIP 并退出 0）：

    DT_LIVE=1 lua tests/smoke_live.lua                          # 本机
    DT_LIVE=1 KO_ROOT=/mnt/us/koreader ./luajit tests/smoke_live.lua   # 设备
    DT_LIVE=1 DT_PROXY=http://<host>:7890 ...                   # 顺带验 google_free

它给每个服务翻一句真实文本，断言译文非空、`provider` 字段与引擎一致，并打印耗时。

退出码约定：**不设 `DT_LIVE` 才 SKIP（退出 0）**；一旦设成 `DT_LIVE=1`，KOReader 库、
`providers` 模块加载失败都按 FAIL 退出 1 —— 否则 CI 里设了 `DT_LIVE=1` 也只会看到
一片绿。唯一仍报 SKIP 的是内置引擎（`system`）：headless 缺 `ui/translator` 需要的
reader 进程，macOS 的 SDL 版连 `socketutil → device` 都过不去（`SDL window` 为 nil），
所以这个脚本实际只能在设备上跑（macOS 上会以 FAIL 退出 1，这是预期）。

注意：
- 测试读写 /tmp 下临时目录（/tmp/dt_data、/tmp/dt_state_test、/tmp/dualtranslate_epub_test 等）。
- 用真实 KO_ROOT 的套件会在仓库根留下八个空目录（cache/ clipboard/ data/ ota/ plugins/
  screenshots/ settings/ styletweaks/）：KOReader 的 `datastorage` 一被 require 就执行
  `initDataDir()`，而测试里没有把数据目录指到别处的 reader 设置，解析出来就是 "."。
  它们已收进 `.gitignore`（不进 `git status`）；想跑完连目录都不留，先在 shell 里
  `export KO_HOME=/tmp/dt_kohome`（datastorage 优先读这个变量）。
- migration_test.lua / store_delete_test.lua / p1c_switch_test.lua 用真实 SQLite；lock_test.lua /
  overlay_v3_test.lua / overlay_revision_test.lua / template_gc_test.lua / glossary_test.lua /
  outline_test.lua 用真实 lfs + json。
  均依赖 KOReader 自带库（默认 /Applications/KOReader.app/Contents/koreader，可用 KO_ROOT 覆盖），
  需用 luajit 运行，缺失时打印 SKIP 并退出 0。设备上要同时设 `KO_ROOT` 与 `LUA_CPATH`
  （`KO_ROOT=/mnt/us/koreader LUA_CPATH="/mnt/us/koreader/common/?.so;/mnt/us/koreader/libs/?.so;;"`），
  否则 `json` 依赖的 `lpeg.so` 找不到，套件会直接 SKIP（看起来像通过）；
  checkpoint 冲突用例要等 busy_timeout 重试，migration_test 整体约 20 秒。
- bench_test.lua 还会用 KO_ROOT 下的 luajit 启动 `tools/bench.lua` 子进程，检查
  `--work/--only/.dtbench/--overlay` 的 CLI 边界；它依赖 POSIX shell（`sh`/`rm` 可用），
  并在 `--overlay` 用例里验证基准结束会恢复原 `css-template.css`。
- outline_test.lua 前半用 archiver stub（内存书）覆盖解析/映射/缓存全部分支，
  后半用真实 libarchive 造真 EPUB 跑端到端与 100 章性能（5 次冷解析取中位数），
  libarchive 不可用时只跳过后半。
- G_reader_settings 桩必须用冒号调用签名 (self, key[, value])。
- 新增模块级函数后，把函数名加入 callcheck.lua 的 attached 白名单。
- 新增模块后若 /tmp 被清，测试脚本可从本目录复制回去（或直接在此运行）。
