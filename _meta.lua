local _ = require("gettext")
-- No `name` here: KOReader derives it from the plugin directory name and
-- logs "name in _meta.lua, is deprecated and will be ignored" on every start.
return {
    fullname = _("DualTranslate"),
    description = _([[Whole-book and chapter-by-chapter bilingual translation with a chapter picker, per-service caches, a choice of the built-in KOReader translator or Microsoft Edge Free, and an MCP engine that translates on a PC.]]),
    version = "3.2.2",
}
