-- gcloud.lua — Google 粵語雲端候選 for Rime / 小狼毫 (librime-lua)
--
-- 四種模式（gcloud/mode）：
--   rime_first  平時只顯示小狼毫候選；組字中連按兩下左 Shift 先加入 Google 候選（☁，排最前）。
--   rime_slot   同 rime_first，但第一頁最後一格（預設第 6 個）固定留俾 Google 第一個候選；
--               小狼毫頭幾個候選次序不變。雙 Shift 同樣係加入成串 Google 候選。
--   cloud_first 平時 Google 候選排最前；連按兩下左 Shift 改返純小狼毫候選。
--   cloud_only  有 Google 結果就只顯示 Google 候選（filter 收起小狼毫候選）；
--               未有結果（等緊／斷線／查詢失敗）先顯示小狼毫候選。雙 Shift 同樣改返純小狼毫。
-- 雙 Shift 只對當時嗰組拼音生效（再按一次雙 Shift 會切返），下一輪組字回復預設。
--
-- gcloud/prefetch 預設 auto：rime_first 只喺雙 Shift 先把拼音送去 Google；其他模式要邊打邊查。
-- 查詢時會把拼音寫入 %APPDATA%\Rime\gcloud\request.txt，由背景程式 gcloud_daemon.py
-- 向 Google 查詢並存入 cache\。cloud_first／cloud_only 模式下，背景程式收到結果後會發送 F24 鍵，
-- 本處理器截住 F24 就刷新候選，所以 Google 結果到咗會自己出現，唔使再按鍵。
-- librime-lua 本身不能上網，所以透過檔案同背景程式溝通。

local M = {}

local SEP = package.config:sub(1, 1)

local function user_dir()
  local ok, dir = pcall(function() return rime_api.get_user_data_dir() end)
  if ok and dir and dir ~= "" then return dir end
  return (os.getenv("APPDATA") or ".") .. SEP .. "Rime"
end

local BASE = user_dir() .. SEP .. "gcloud"
local REQUEST = BASE .. SEP .. "request.txt"
local HEARTBEAT = BASE .. SEP .. "heartbeat.txt"
local CACHE_PREFIX = BASE .. SEP .. "cache" .. SEP .. "q_"
local MAX_QUERY_LEN = 60
local XK_Shift_L = 0xffe1

local seq = 0
local last_request = nil
local last_ping = 0
local PING_EVERY_SECONDS = 20
local override_query = nil -- 用雙 Shift 反轉咗預設模式嘅拼音

-- eng = gcloud/engine（jyutping／yale），要同 gcloud_daemon.py 嘅 cache_path 一致
local function cache_file(q, eng)
  if eng == nil or eng == "jyutping" then return CACHE_PREFIX .. q .. ".txt" end
  return CACHE_PREFIX .. eng .. "_" .. q .. ".txt"
end

-- 只保留粵拼字母。q / v / x 喺 jyut6ping3 方案代表聲調或喉塞，Google 唔識，要剔走。
-- pos[i] = 第 i 個查詢字母喺原始輸入嘅位置，用嚟將 Google 嘅 matched_length 對返原始輸入。
local function normalize(raw)
  local chars, pos = {}, {}
  for i = 1, #raw do
    local c = raw:sub(i, i)
    if c:find("^[a-pr-uwyz]$") then
      chars[#chars + 1] = c
      pos[#chars] = i
    end
  end
  return table.concat(chars), pos
end

local function raw_end(raw, pos, qlen, matched)
  if matched >= qlen then return #raw end
  if matched <= 0 then return 0 end
  local e = pos[matched]
  while e < #raw do
    local c = raw:sub(e + 1, e + 1)
    if c == "v" or c == "x" or c == "'" or c == " " then
      e = e + 1
    elseif c == "q" then
      -- q 可以係聲調（3/6 聲），亦可以係下一個音節嘅喉塞；後面接元音就當屬下一個音節
      local j = e + 1
      while j <= #raw and raw:sub(j, j) == "q" do j = j + 1 end
      local nxt = raw:sub(j, j)
      if nxt ~= "" and nxt:find("^[aeiou]$") then break end
      e = j - 1
    else
      break
    end
  end
  return e
end

-- push = true：叫背景程式結果到咗就發 F24 提示刷新
local function write_request(q, eng, force, push)
  local key = eng .. ":" .. q
  if not force and key == last_request then return end
  last_request = key
  seq = seq + 1
  local f = io.open(REQUEST, "wb")
  if f then
    f:write(q, "\n", tostring(seq), "\n", push and "1" or "0", "\n", eng, "\n")
    f:close()
  end
end

-- 唔預先查詢時用：話俾背景程式知「用家打緊字」，等佢保持同 Google 嘅連線，
-- 雙 Shift 時唔使重新握手。只寫空查詢，唔會送任何拼音出去；最多每 20 秒一次。
local function write_ping(eng)
  local now = os.time()
  if now - last_ping < PING_EVERY_SECONDS then return end
  last_ping = now
  last_request = nil
  seq = seq + 1
  local f = io.open(REQUEST, "wb")
  if f then
    f:write("\n", tostring(seq), "\n0\n", eng, "\n")
    f:close()
  end
end

-- 回傳候選表；false = 雲端查詢失敗；nil = 未有結果
local function read_cache(q, eng)
  local f = io.open(cache_file(q, eng), "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then return nil end
  if data:sub(1, 3) == "ERR" then return false end
  if data:sub(1, 2) ~= "OK" then return nil end
  local list = {}
  for line in data:gmatch("[^\n]+") do
    local len, text, note = line:match("^(%d+)\t([^\t]+)\t?(.*)$")
    if len then
      list[#list + 1] = { len = tonumber(len), text = text, note = note, rank = #list + 1 }
    end
  end
  return list
end

local function daemon_alive()
  local f = io.open(HEARTBEAT, "rb")
  if not f then return false end
  local t = tonumber(f:read("*l") or "")
  f:close()
  return t ~= nil and math.abs(os.time() - t) < 8
end

-- librime-lua 冇 sleep，只能忙等；只會喺用戶用雙 Shift 要求雲端候選時用，最多等 timeout_ms。
local function wait_for(q, eng, timeout_ms)
  local deadline = os.clock() + timeout_ms / 1000
  local next_check = 0
  while true do
    local now = os.clock()
    if now >= deadline then return nil end
    if now >= next_check then
      local r = read_cache(q, eng)
      if r ~= nil then return r end
      next_check = now + 0.008
    end
  end
end

local function load_config(env)
  local cfg = env.engine.schema.config
  local function bool(path, default)
    local v = cfg:get_bool(path)
    if v == nil then return default end
    return v
  end
  local function str(path, default)
    local v = cfg:get_string(path)
    if v == nil or v == "" then return default end
    return v
  end
  local c = {
    mode = str("gcloud/mode", "rime_first"),
    double_shift = bool("gcloud/double_shift", true),
    double_shift_ms = cfg:get_int("gcloud/double_shift_ms") or 500,
    trigger = str("gcloud/trigger", "none"),
    refresh_key = str("gcloud/refresh_key", "F24"),
    push_refresh = bool("gcloud/push_refresh", true),
    timeout_ms = cfg:get_int("gcloud/timeout_ms") or 1500,
    auto_cached = bool("gcloud/auto_cached", false),
    prefetch = cfg:get_bool("gcloud/prefetch"), -- true / false；其他值（例如 auto）= 由模式決定
    show_note = bool("gcloud/show_annotation", true),
    max_candidates = cfg:get_int("gcloud/max_candidates") or 15,
    off_option = str("gcloud/off_option", "gcloud_off"),
    engine = str("gcloud/engine", "jyutping"), -- jyutping = 粵拼引擎；yale = 耶魯（Google「廣東話」）
  }
  if not c.engine:find("^[a-z]+$") then c.engine = "jyutping" end
  -- 舊設定 auto_cached: true 等同「有就顯示」，即 cloud_first 但唔主動刷新
  c.cloud_default = (c.mode == "cloud_first") or (c.mode == "cloud_only") or c.auto_cached
  -- auto：rime_first 平時唔顯示 Google，所以只喺雙 Shift 先查詢；其他模式要邊打邊查
  if c.prefetch == nil then c.prefetch = (c.mode ~= "rime_first") or c.auto_cached end
  c.slot_mode = (c.mode == "rime_slot")
  -- Google 候選放第幾格：預設係第一頁最後一格（menu/page_size）
  c.slot = cfg:get_int("gcloud/slot") or cfg:get_int("menu/page_size") or 6
  if c.slot < 2 then c.slot = 2 end
  c.push = c.push_refresh and (c.mode == "cloud_first" or c.mode == "cloud_only" or c.slot_mode)
  c.hide_local = (c.mode == "cloud_only")
  return c
end

-- 呢組拼音而家應唔應該顯示雲端候選
local function cloud_wanted(cfg, q)
  if override_query == q then return not cfg.cloud_default end
  return cfg.cloud_default
end

local function current_abc_segment(ctx)
  local comp = ctx.composition
  if comp:empty() then return nil end
  local seg = comp:back()
  if not seg:has_tag("abc") then return nil end
  return seg
end

-- ------------------------------------------------------------ translator

-- cloud_shown[段起點] = { input = 當時完整輸入, n = 呢段出咗幾多個 ☁ 候選 }。
-- translator 每次查詢都會重設；cloud_only 嘅 filter 靠佢判斷要唔要收起小狼毫候選。
local cloud_shown = {}
-- slot_pick[段起點] = { input = 當時完整輸入, cand = Google 第一個候選 }，rime_slot 模式由 slot_filter 插入。
local slot_pick = {}

local function translate(input, seg, env)
  cloud_shown[seg.start] = nil
  slot_pick[seg.start] = nil
  local cfg = env.gcloud
  local ctx = env.engine.context
  if ctx:get_option(cfg.off_option) then return end
  if not seg:has_tag("abc") then return end
  local q, pos = normalize(input)
  if #q == 0 or #q > MAX_QUERY_LEN then return end

  local wanted = cloud_wanted(cfg, q)
  local show = wanted or cfg.slot_mode -- 畫面上會用到 Google 結果
  local list = show and read_cache(q, cfg.engine) or nil
  if cfg.prefetch or show then
    -- 要顯示但未有結果：叫背景程式結果到咗就提示刷新（rime_first 平時唔顯示，所以唔使）
    write_request(q, cfg.engine, false, show and list == nil and cfg.push)
  else
    write_ping(cfg.engine)
  end
  if not list then return end

  -- 長匹配排先（同 Rime 合併候選嘅規則一致），同長度保留 Google 原本次序
  table.sort(list, function(a, b)
    if a.len ~= b.len then return a.len > b.len end
    return a.rank < b.rank
  end)
  local cands = {}
  for _, item in ipairs(list) do
    local e = raw_end(input, pos, #q, item.len)
    if e > 0 then
      local comment = "☁"
      if cfg.show_note and item.note ~= "" then comment = "☁ " .. item.note end
      local cand = Candidate("gcloud", seg.start, seg.start + e, item.text, comment)
      cand.quality = (item.len >= #q) and 1000 or 0
      cands[#cands + 1] = cand
      if #cands >= cfg.max_candidates then break end
    end
  end
  if #cands == 0 then return end
  if not wanted then
    -- rime_slot：呢度唔出候選，只記低 Google 第一個，由 slot_filter 放入第一頁最後一格
    slot_pick[seg.start] = { input = ctx.input, cand = cands[1] }
    return
  end
  -- 要喺第一個 yield 之前記低：librime-lua 喺 Query 時已經行到第一個 yield，filter 之後先讀
  cloud_shown[seg.start] = { input = ctx.input, n = #cands }
  for _, cand in ipairs(cands) do yield(cand) end
end

M.translator = {
  init = function(env) env.gcloud = load_config(env) end,
  func = function(input, seg, env)
    local ok, err = pcall(translate, input, seg, env)
    if not ok and log then log.error("gcloud translator: " .. tostring(err)) end
  end,
}

-- ------------------------------------------------------------ filter (cloud_only)

-- 排喺所有 filter 最前。呢段有 ☁ 候選，就只放行 ☁ 候選；出齊 n 個即停，
-- 唔使行晒小狼毫後面成串候選。其他模式、或者呢段冇 ☁ 候選，就原封不動放行。
local function filter(input, env)
  local cfg = env.gcloud
  local remaining = nil
  local first = true
  for cand in input:iter() do
    if first then
      first = false
      local rec = cfg.hide_local and cloud_shown[cand.start] or nil
      if rec and rec.n > 0 and rec.input == env.engine.context.input then
        remaining = rec.n
      end
    end
    if not remaining then
      yield(cand)
    elseif cand.type == "gcloud" then
      yield(cand)
      remaining = remaining - 1
      if remaining <= 0 then return end
    end
  end
end

M.filter = {
  init = function(env) env.gcloud = load_config(env) end,
  func = function(input, env)
    local ok, err = pcall(filter, input, env)
    if not ok then
      if log then log.error("gcloud filter: " .. tostring(err)) end
      for cand in input:iter() do yield(cand) end -- 出錯就放行餘下候選，唔好令候選欄變空
    end
  end,
}

-- ------------------------------------------------------------ filter (rime_slot)

-- 排喺所有 filter 最後（uniquifier 之後），所以就算 Google 第一個候選同小狼毫頭幾個重複，
-- 都唔會被剔走：第 slot 格永遠係 Google 第一個候選。小狼毫候選唔夠 slot-1 個就排喺最尾。
local function slot_filter(input, env)
  local cfg = env.gcloud
  local pick = nil
  local n = 0
  for cand in input:iter() do
    if n == 0 and cfg.slot_mode then
      local rec = slot_pick[cand.start]
      if rec and rec.input == env.engine.context.input then pick = rec.cand end
    end
    if pick and n == cfg.slot - 1 then
      yield(pick)
      pick = nil
    end
    n = n + 1
    yield(cand)
  end
  if pick then yield(pick) end
end

M.slot_filter = {
  init = function(env) env.gcloud = load_config(env) end,
  func = function(input, env)
    local ok, err = pcall(slot_filter, input, env)
    if not ok then
      if log then log.error("gcloud slot filter: " .. tostring(err)) end
      for cand in input:iter() do yield(cand) end
    end
  end,
}

-- ------------------------------------------------------------ processor

local kRejected, kAccepted, kNoop = 0, 1, 2

-- 目前組字中（abc 段）嘅查詢拼音；唔喺組字或者雲端已關就回傳 nil
local function composing_query(ctx, cfg)
  if not ctx:is_composing() or ctx:get_option(cfg.off_option) then return nil end
  local seg = current_abc_segment(ctx)
  if not seg then return nil end
  local q = normalize(ctx.input:sub(seg.start + 1, seg._end))
  if #q == 0 or #q > MAX_QUERY_LEN then return nil end
  return q
end

-- 反轉呢組拼音嘅模式；如果變成要顯示雲端候選而未有結果，就等一陣
local function toggle_cloud(ctx, cfg, q)
  if override_query == q then override_query = nil else override_query = q end
  if cloud_wanted(cfg, q) then
    local cached = read_cache(q, cfg.engine)
    if cached == false then
      os.remove(cache_file(q, cfg.engine)) -- 之前失敗過，重試
      cached = nil
    end
    if cached == nil then
      write_request(q, cfg.engine, true, false)
      if daemon_alive() then
        wait_for(q, cfg.engine, cfg.timeout_ms)
      elseif log then
        log.warning("gcloud: daemon not running (heartbeat stale)")
      end
    end
  end
  ctx:refresh_non_confirmed_composition()
end

local function process(key, env)
  local cfg = env.gcloud
  local ctx = env.engine.context
  local repr = key:repr()

  -- 新一輪組字開始（未組字時按鍵）：清除上一輪雙 Shift 嘅反轉。
  -- 唔用 update_notifier:connect，避免由 C++ 事件回調入 Lua（較易令 rime.dll 出事）。
  if not key:release() and not ctx:is_composing() then override_query = nil end

  -- 背景程式發嚟嘅刷新鍵（F24）：組字中就截住並刷新；唔喺組字就放行（F24 對一般程式冇作用）
  if repr == cfg.refresh_key or repr == "Release+" .. cfg.refresh_key then
    if not ctx:is_composing() then return kNoop end
    if not key:release() then
      local q = composing_query(ctx, cfg)
      if q and (cloud_wanted(cfg, q) or cfg.slot_mode) and type(read_cache(q, cfg.engine)) == "table" then
        ctx:refresh_non_confirmed_composition()
        if log then log.info("gcloud: refresh key, cloud candidates shown") end
      end
    end
    return kAccepted
  end

  -- 雙擊左 Shift。第一下照常交俾 ascii_composer（組字中即係臨時切換英文），
  -- 第二下喺時限內就攔截：還原中文模式並反轉雲端／本地。右 Shift 唔受影響。
  if cfg.double_shift and key.keycode == XK_Shift_L then
    local other_mod = key:ctrl() or key:alt() or key:super()
    if not key:release() then
      env.shift_clean = not other_mod
      return kNoop
    end
    local clean = env.shift_clean and not other_mod
    env.shift_clean = false
    if not clean or not ctx:is_composing() or ctx:get_option(cfg.off_option) then
      env.last_tap = nil
      return kNoop
    end
    local now = os.clock()
    -- 第二下：第一下已經令組字臨時變成英文（raw 段，唔再係 abc），所以唔可以再搵 abc 段；
    -- 只要組字內容同第一下時一樣，就用第一下記低嘅拼音。
    if env.last_tap and env.last_tap_input == ctx.input
        and (now - env.last_tap) * 1000 <= cfg.double_shift_ms then
      local q = env.last_tap_q
      env.last_tap = nil
      if ctx:get_option("ascii_mode") then ctx:set_option("ascii_mode", false) end
      if log then log.info("gcloud: double shift, toggled cloud/local") end
      toggle_cloud(ctx, cfg, q)
      return kAccepted
    end
    local q = composing_query(ctx, cfg)
    if not q then
      env.last_tap = nil
      return kNoop
    end
    env.last_tap = now
    env.last_tap_q = q
    env.last_tap_input = ctx.input
    return kNoop
  end

  if not key:release() then
    env.last_tap = nil -- 兩下 Shift 之間按咗其他鍵，就唔算雙擊
    env.shift_clean = false
  end

  -- 可選嘅單鍵觸發（gcloud/trigger，預設 none）
  if cfg.trigger ~= "none" and not key:release() and repr == cfg.trigger then
    local q = composing_query(ctx, cfg)
    if not q then return kNoop end
    toggle_cloud(ctx, cfg, q)
    return kAccepted
  end
  return kNoop
end

M.processor = {
  init = function(env) env.gcloud = load_config(env) end,
  func = function(key, env)
    local ok, res = pcall(process, key, env)
    if ok then return res end
    if log then log.error("gcloud processor: " .. tostring(res)) end
    return kNoop
  end,
}

return M
