local _ = require("gettext")
-- No `name` here: KOReader derives it from the plugin directory name and
-- logs "name in _meta.lua, is deprecated and will be ignored" on every start.
return {
    fullname = _("DualTranslate"),
    description = _([[Whole-book and chapter-by-chapter bilingual translation with a chapter picker, per-service caches, and a choice of the built-in KOReader translator or Microsoft Edge Free.]]),
    version = "3.1.0",
}
