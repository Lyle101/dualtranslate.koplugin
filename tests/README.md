# DualTranslate 测试套件

纯 Lua + stub 环境，无需 KOReader。在 kotranslate_xplatform/ 目录下运行：

    lua tests/loadtest.lua      # 加载 + init + 设置读写 + 菜单构建 + 全项渲染
    lua tests/fulltest.lua      # 文本切分 / Overlay CSS / Tools hash / Languages / 队列 / Providers
    lua tests/epub_test.lua     # EPUB resolve / 段落收集 / translate_overlay 完整流程
    lua tests/outline_test.lua  # P2-a：extract_entries 按需抽取 / NCX/nav/spine 目录 / 映射去重 / 失败清理 / outline 磁盘缓存 / 100 章性能
    lua tests/chapter_picker_test.lua # P2-b：getBookOutline 内存缓存 / 选择器状态与分页 / 对话框流程
    lua tests/state2_test.lua   # loadConfig 迁移 / loadQueue 边界
    lua tests/cache_test.lua    # SQLite cache（mock）
    lua tests/cache_provider_test.lua  # P0：缓存查询按 provider 隔离
    lua tests/migration_test.lua # P1-a：真实 SQLite 的 v3 schema / v2→v3 迁移 / providers
    lua tests/lock_test.lua     # P1-b：书目录锁（互斥/超时/陈旧回收/异常释放）
    lua tests/overlay_v3_test.lua # P1-b：manifest/entries 读写 / buildCss v3 / 迁移分支
    lua tests/overlay_revision_test.lua # P1-b：revision 缓存键 / 命中与失效 / 8MB LRU
    lua tests/store_delete_test.lua # P1-b：真实 SQLite 的按 provider 删除 / intent 收尾 / reconcile
    lua tests/p1c_switch_test.lua # P1-c：按服务切换主链（State/PageTrans/Reader v3/Epub checkpoint/菜单）
    lua tests/context_test.lua    # P1-c：context 透传契约（Epub → translate(_batch) / 缓存 meta / 只切分一次）
    lua tests/queueui_test.lua    # 翻译队列子菜单：进行中行重开进度框、排队/失败行带取消项
    lua tests/clear_path_test.lua      # P0：清除路径必须传书路径
    lua tests/clear_test.lua      # 清除后重翻：complete 标记与残留译文不能再拦住整书翻译
    lua tests/overlay_provider_test.lua # P0：overlay 续跑按 provider 隔离
    lua tests/langmenu_test.lua # 语言子菜单闭包
    lua tests/callcheck.lua     # 方法调用完整性

注意：
- 测试读写 /tmp 下临时目录（/tmp/dt_data、/tmp/dt_state_test、/tmp/dualtranslate_epub_test 等）。
- migration_test.lua / store_delete_test.lua / p1c_switch_test.lua 用真实 SQLite；lock_test.lua /
  overlay_v3_test.lua / overlay_revision_test.lua / outline_test.lua 用真实 lfs + json。
  均依赖 KOReader 自带库（默认 /Applications/KOReader.app/Contents/koreader，可用 KO_ROOT 覆盖），
  需用 luajit 运行，缺失时打印 SKIP 并退出 0；
  checkpoint 冲突用例要等 busy_timeout 重试，migration_test 整体约 20 秒。
- outline_test.lua 前半用 archiver stub（内存书）覆盖解析/映射/缓存全部分支，
  后半用真实 libarchive 造真 EPUB 跑端到端与 100 章性能（5 次冷解析取中位数），
  libarchive 不可用时只跳过后半。
- G_reader_settings 桩必须用冒号调用签名 (self, key[, value])。
- 新增模块级函数后，把函数名加入 callcheck.lua 的 attached 白名单。
- 新增模块后若 /tmp 被清，测试脚本可从本目录复制回去（或直接在此运行）。
