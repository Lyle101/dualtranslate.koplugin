-- The small, keyless provider core used by DualTranslate.
local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local logger = require("logger")
local socketutil = require("socketutil")
local _ = require("gettext")

local Providers = {}

Providers.list = {
    -- `hint` is the one-line "what does this engine need" note the engine menu
    -- shows after the name: with three keyless engines a reader cannot tell
    -- which one to pick, and picking blind costs a 5 s timeout per paragraph.
    { id = "system", name = "KOReader 内置翻译", requires_api_key = false,
      hint = "跟随 KOReader 设置 · 逐段 · 需能访问 Google",
      description = _("Use KOReader's built-in translator engine (configured in KOReader -> Translation)") },
    { id = "microsoft_free", name = "Microsoft Edge（免费）", requires_api_key = false,
      hint = "无需代理 · 支持批量",
      description = _("Microsoft Edge web endpoint (no API key)") },
    { id = "google_free", name = "Google（免费）", requires_api_key = false,
      hint = "需能访问 Google · 支持批量",
      description = _("Google's free web endpoint; no API key, batch capable") },
}

-- ---------------------------------------------------------------------------
-- KOReader built-in translator (frontend/ui/translator.lua).
-- Uses whatever engine the user picked in KOReader -> Translation settings
-- (the built-in only ships Google, but users may point trans_server at a
-- mirror/custom endpoint).  It exposes single-text translate() only, so the
-- batch path below loops over it.
-- ---------------------------------------------------------------------------
local function getSystemTranslator()
    local ok, Translator = pcall(require, "ui/translator")
    if ok and Translator then return Translator end
    return nil
end

-- Map DualTranslate's BCP-47 codes onto the ones Google uses (its built-in
-- SUPPORTED_LANGUAGES and the free web endpoints both prefer "zh" / "zh-TW").
-- Anything unknown passes through untouched.
local function normalizeGoogleLang(lang)
    if lang == "zh-Hans" then return "zh" end
    if lang == "zh-Hant" then return "zh-TW" end
    return lang
end

function Providers.translate_system(text, source_lang, target_lang)
    local Translator = getSystemTranslator()
    if not Translator then
        return nil, { message = _("KOReader 内置翻译器不可用（ui/translator 加载失败）") }
    end
    -- The built-in translator manages its own target/source language from
    -- G_reader_settings.  We still forward explicit langs when provided, so
    -- DualTranslate's per-book settings win when set.
    local ok, translated = pcall(Translator.translate, Translator, text,
        normalizeGoogleLang(target_lang), normalizeGoogleLang(source_lang))
    if not ok or not translated or translated == "" then
        logger.warn("dualtranslate: system translator failed:", translated)
        -- The built-in engine has no mirror: if Google is unreachable every
        -- paragraph fails.  Name that cause so the user knows the fix is a
        -- different engine, not a retry.
        return nil, { message = _("KOReader 内置翻译失败（需能访问 Google），请检查网络与 KOReader 翻译设置，或改用「翻译引擎 → Microsoft Edge（免费）」/「Google（免费）」") }
    end
    return { translated_text = translated, source_lang = source_lang,
        target_lang = target_lang, provider = "system" }
end

-- Batch loop over the built-in translator.  The built-in translator exposes
-- only a single-text translate(), so system mode always loops one request per
-- paragraph; it never uses a native batch endpoint.  (The separately
-- selectable Microsoft Edge provider has its own native batch path.)
function Providers.translate_system_batch(texts, source_lang, target_lang)
    local result = {}
    for i, text in ipairs(texts) do
        local translated, err = Providers.translate_system(text, source_lang, target_lang)
        if not translated then
            return nil, err
        end
        result[i] = translated.translated_text
    end
    return result
end

local function httpRequest(method, url, body, headers)
    local response_body = {}
    headers = headers or {}
    headers["Accept"] = headers["Accept"] or "application/json"
    if body and not headers["Content-Length"] then
        headers["Content-Length"] = tostring(#body)
    end
    socketutil:set_timeout(15, 15)
    local code, resp_headers, status = http.request{
        url = url, method = method, headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    local raw = table.concat(response_body)
    local ok, data = pcall(json.decode, raw)
    if not ok or not data then
        logger.warn("dualtranslate: provider HTTP error", code, status, raw:sub(1, 160))
        return nil, { code = code,
            message = (not code or code == 1)
                and "翻译服务连接失败，请检查网络"
                or string.format("翻译服务返回 HTTP %s", tostring(code)) }
    end
    if data.error then
        local message = type(data.error) == "table" and data.error.message or data.error
        return nil, { code = code, message = tostring(message or "翻译服务错误") }
    end
    return data
end

local function urlEncode(value)
    return require("socket.url").escape(tostring(value or ""))
end

local function jsonPost(url, payload)
    return httpRequest("POST", url, json.encode(payload), {
        ["Content-Type"] = "application/json",
    })
end

function Providers.translate_microsoft_free(text, source_lang, target_lang)
    local url = "https://edge.microsoft.com/translate/translatetext?isEnterpriseClient=false&to="
        .. urlEncode(target_lang)
    if source_lang and source_lang ~= "auto" then
        url = url .. "&from=" .. urlEncode(source_lang)
    end
    local data, err = jsonPost(url, { text })
    if not data then return nil, err end
    if data[1] and data[1].translations and data[1].translations[1] then
        return { translated_text = data[1].translations[1].text,
            source_lang = source_lang, target_lang = target_lang,
            provider = "microsoft_free" }
    end
    return nil, { message = _("Microsoft Edge returned no translation") }
end

function Providers.translate_microsoft_free_batch(texts, source_lang, target_lang)
    local url = "https://edge.microsoft.com/translate/translatetext?isEnterpriseClient=false&to="
        .. urlEncode(target_lang)
    if source_lang and source_lang ~= "auto" then
        url = url .. "&from=" .. urlEncode(source_lang)
    end
    local data, err = jsonPost(url, texts)
    if not data then return nil, err end
    local result = {}
    for index, item in ipairs(data) do
        if not item.translations or not item.translations[1]
            or not item.translations[1].text then
            return nil, { message = _("Microsoft Edge returned an incomplete batch") }
        end
        result[index] = item.translations[1].text
    end
    if #result ~= #texts then
        return nil, { message = _("Microsoft Edge returned an incomplete batch") }
    end
    return result
end

-- ---------------------------------------------------------------------------
-- Google, free web endpoint (no API key).
--
-- The path KOReader's built-in translator uses
-- (/translate_a/single?client=gtx&...&q=...) answers Google's "Sorry" 429 page
-- as soon as the exit IP is busy.  The sibling path /translate_a/t takes the
-- texts in the POST body and answers one entry per q= parameter, so a whole
-- group of paragraphs travels in one request — the same trade-off the
-- Immersive Translate extension makes.  An entry is normally
-- [translated_text, detected_lang], but the endpoint also answers bare strings,
-- so the parser accepts both shapes.
-- ---------------------------------------------------------------------------
local GOOGLE_FREE_URL = "https://translate.googleapis.com/translate_a/t"
local GOOGLE_FREE_LIMITS = { items = 12, bytes = 4000 }
local GOOGLE_FREE_RETRY_DELAY = 1.5
local GOOGLE_FREE_LIMITED = _("Google 免费接口限流，稍后重试或改用「翻译引擎 → Microsoft Edge（免费）」")

local function sleepSeconds(seconds)
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.sleep then socket.sleep(seconds) end
end

local function googleFreeRequest(url, body)
    local response_body = {}
    socketutil:set_timeout(20, 20)
    -- luasocket returns (1, http_status, headers, status_line); unlike the JSON
    -- helper above this keeps the status code, because "429" and "no network"
    -- deserve different messages and different retry handling.
    local ok, done, code = pcall(http.request, {
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Accept"] = "application/json",
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response_body),
    })
    socketutil:reset_timeout()
    if not ok or not done then
        return nil, { message = _("翻译服务连接失败，请检查网络") }
    end
    if code == 429 then
        return nil, { code = 429, retryable = true, message = GOOGLE_FREE_LIMITED }
    end
    if code ~= 200 then
        return nil, { code = code,
            message = string.format(_("Google 免费接口返回 HTTP %s"), tostring(code)) }
    end
    local decoded_ok, data = pcall(json.decode, table.concat(response_body))
    if not decoded_ok or type(data) ~= "table" then
        return nil, { code = code, message = _("Google 免费接口返回了无法解析的数据") }
    end
    return data
end

local function parseGoogleFree(data, expected)
    if #data ~= expected then return nil end
    local result = {}
    for index = 1, expected do
        local item = data[index]
        local value
        if type(item) == "table" then
            value = item[1]
        elseif type(item) == "string" then
            value = item
        end
        if type(value) ~= "string" or value == "" then return nil end
        result[index] = value
    end
    return result
end

function Providers.translate_google_free_batch(texts, source_lang, target_lang, opts)
    opts = opts or {}
    if type(texts) ~= "table" or #texts == 0 then return {} end
    local parts = {}
    for _, text in ipairs(texts) do
        parts[#parts + 1] = "q=" .. urlEncode(text)
    end
    local url = GOOGLE_FREE_URL .. "?client=gtx&dt=t&sl="
        .. urlEncode(source_lang == "auto" and "auto" or normalizeGoogleLang(source_lang))
        .. "&tl=" .. urlEncode(normalizeGoogleLang(target_lang))
    local body = table.concat(parts, "&")

    local data, err = googleFreeRequest(url, body)
    if not data and err and err.retryable then
        -- One backoff plus one retry: the limit is per exit IP and usually
        -- clears in a second or two, unlike a dead network.
        local delay = opts.retry_delay
        if delay == nil then delay = GOOGLE_FREE_RETRY_DELAY end
        if delay > 0 then sleepSeconds(delay) end
        data, err = googleFreeRequest(url, body)
    end
    if not data then return nil, err end
    local result = parseGoogleFree(data, #texts)
    if not result then
        return nil, { message = _("Google 返回条数与请求不符") }
    end
    return result
end

function Providers.translate_google_free(text, source_lang, target_lang)
    local result, err = Providers.translate_google_free_batch({ text }, source_lang, target_lang)
    if not result then return nil, err end
    return { translated_text = result[1], source_lang = source_lang,
        target_lang = target_lang, provider = "google_free" }
end

-- Which engine can take several paragraphs in one request, and how many.
local BATCH_LIMITS = {
    microsoft_free = { items = 12, bytes = 4000 },
    google_free = GOOGLE_FREE_LIMITS,
}

function Providers.has_batch(provider_id)
    return BATCH_LIMITS[provider_id] ~= nil
end

function Providers.batch_limits(provider_id)
    return BATCH_LIMITS[provider_id]
end

function Providers.translate_batch(provider_id, texts, source_lang, target_lang)
    if provider_id == "microsoft_free" then
        return Providers.translate_microsoft_free_batch(texts, source_lang, target_lang)
    elseif provider_id == "google_free" then
        return Providers.translate_google_free_batch(texts, source_lang, target_lang)
    end
    return nil, { message = _("该引擎不支持批量翻译") }
end

-- Split texts into request-sized groups.  A single text longer than the byte
-- budget still gets a group of its own; the callers split long paragraphs
-- before reaching this point.
function Providers.split_groups(texts, limits)
    limits = limits or GOOGLE_FREE_LIMITS
    local groups, current, total = {}, {}, 0
    for index, text in ipairs(texts) do
        local size = #tostring(text)
        if #current >= limits.items
            or (#current > 0 and total + size > limits.bytes) then
            groups[#groups + 1] = current
            current, total = {}, 0
        end
        current[#current + 1] = index
        total = total + size
    end
    if #current > 0 then groups[#groups + 1] = current end
    return groups
end

function Providers.translate(provider_id, text, source_lang, target_lang)
    if provider_id == "system" then
        return Providers.translate_system(text, source_lang, target_lang)
    elseif provider_id == "microsoft_free" then
        return Providers.translate_microsoft_free(text, source_lang, target_lang)
    elseif provider_id == "google_free" then
        return Providers.translate_google_free(text, source_lang, target_lang)
    end
    return nil, { message = "未知翻译服务，请选择 KOReader 内置、Microsoft Edge（免费）或 Google（免费）" }
end

function Providers.getProviderById(id)
    for _, provider in ipairs(Providers.list) do
        if provider.id == id then return provider end
    end
end

function Providers.getProviderName(id)
    local provider = Providers.getProviderById(id)
    return provider and provider.name or "未知翻译服务"
end

function Providers.isProviderEnabled(id)
    return Providers.getProviderById(id) ~= nil
end

return Providers
