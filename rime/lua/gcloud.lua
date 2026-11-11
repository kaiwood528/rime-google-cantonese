-- gcloud.lua — Google 粵語雲端候選 for Rime / 小狼毫 (librime-lua)
--
-- 四種模式（gcloud/mode）：
--   rime_first  平時只顯示小狼毫候選；輸入期間連按兩下左 Shift 才加入 Google 候選（☁，排在最前）。
--   rime_slot   與 rime_first 相同，但第一頁最後一格（預設第 6 個）固定保留給 Google 的首個候選；
--               小狼毫前幾個候選的次序不變。雙擊 Shift 同樣會加入完整的 Google 候選。
--   cloud_first 平時 Google 候選排在最前；連按兩下左 Shift 則只顯示小狼毫候選。
--   cloud_only  有 Google 結果時只顯示 Google 候選（由 filter 隱藏小狼毫候選）；
--               未有結果（等待中、離線或查詢失敗）時顯示小狼毫候選。雙擊 Shift 同樣只顯示小狼毫候選。
-- 雙擊 Shift 只適用於當時正在輸入的拼音（再雙擊一次即可切換回來），下一輪組字會恢復預設。
--
-- gcloud/prefetch 預設為 auto：rime_first 只在雙擊 Shift 時才把拼音傳送給 Google；其他模式在輸入期間查詢。
-- 查詢時會把拼音寫入 %APPDATA%\Rime\gcloud\request.txt，由背景程式 rime-gcloud.exe（daemon/RimeGcloud.cs）
-- 向 Google 查詢並存入 cache\。rime_slot／cloud_first／cloud_only 模式下，背景程式收到結果後會發送 F24 鍵，
-- 本處理器攔截 F24 後刷新候選，因此 Google 結果到達時會自動顯示，毋須再按鍵。
-- librime-lua 本身不能連接網絡，因此透過檔案與背景程式溝通。

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
local override_query = nil -- 以雙擊 Shift 反轉了預設模式的拼音

-- eng = gcloud/engine（jyutping／yale），須與 daemon/RimeGcloud.cs 的 CachePath 一致
local function cache_file(q, eng)
  if eng == nil or eng == "jyutping" then return CACHE_PREFIX .. q .. ".txt" end
  return CACHE_PREFIX .. eng .. "_" .. q .. ".txt"
end

-- 只保留粵拼字母。q / v / x 在 jyut6ping3 方案中代表聲調或喉塞音，Google 無法辨認，須予刪除。
-- pos[i] = 第 i 個查詢字母在原始輸入中的位置，用於把 Google 的 matched_length 對應回原始輸入。
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
      -- q 可以是聲調（第 3／6 聲），亦可以是下一個音節的喉塞音；其後接元音時視為屬於下一個音節
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

-- push = true：要求背景程式在結果到達時發送 F24 提示刷新
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

-- 不預先查詢時使用：通知背景程式「用家正在打字」，讓它保持與 Google 的連線，
-- 雙擊 Shift 時毋須重新建立連線。只寫入空查詢，不會傳送任何拼音；最多每 20 秒一次。
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

-- 傳回候選表；false = 雲端查詢失敗；nil = 尚未有結果
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

-- librime-lua 沒有 sleep 功能，只能忙等；只在用家以雙擊 Shift 要求雲端候選時使用，最多等待 timeout_ms。
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
    engine = str("gcloud/engine", "jyutping"), -- jyutping = 粵拼引擎；yale = 耶魯拼音（Google「廣東話」引擎）
  }
  if not c.engine:find("^[a-z]+$") then c.engine = "jyutping" end
  -- 舊設定 auto_cached: true 等同「有結果就顯示」，即 cloud_first 但不會主動刷新
  c.cloud_default = (c.mode == "cloud_first") or (c.mode == "cloud_only") or c.auto_cached
  -- auto：rime_first 平時不顯示 Google 候選，因此只在雙擊 Shift 時查詢；其他模式在輸入期間查詢
  if c.prefetch == nil then c.prefetch = (c.mode ~= "rime_first") or c.auto_cached end
  c.slot_mode = (c.mode == "rime_slot")
  -- Google 候選放在第幾格：預設為第一頁最後一格（menu/page_size）
  c.slot = cfg:get_int("gcloud/slot") or cfg:get_int("menu/page_size") or 6
  if c.slot < 2 then c.slot = 2 end
  c.push = c.push_refresh and (c.mode == "cloud_first" or c.mode == "cloud_only" or c.slot_mode)
  c.hide_local = (c.mode == "cloud_only")
  return c
end

-- 這組拼音目前是否應顯示雲端候選
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

-- cloud_shown[段起點] = { input = 當時的完整輸入, n = 這一段產生了多少個 ☁ 候選 }。
-- translator 每次查詢都會重設；cloud_only 的 filter 據此判斷是否隱藏小狼毫候選。
local cloud_shown = {}
-- slot_pick[段起點] = { input = 當時的完整輸入, cand = Google 的首個候選 }，rime_slot 模式下由 slot_filter 插入。
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
  local show = wanted or cfg.slot_mode -- 畫面上會用到 Google 的結果
  local list = show and read_cache(q, cfg.engine) or nil
  if cfg.prefetch or show then
    -- 需要顯示但尚未有結果：要求背景程式在結果到達時提示刷新（rime_first 平時不顯示，因此毋須刷新）
    write_request(q, cfg.engine, false, show and list == nil and cfg.push)
  else
    write_ping(cfg.engine)
  end
  if not list then return end

  -- 較長的匹配排在前面（與 Rime 合併候選的規則一致），長度相同時保留 Google 的原有次序
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
    -- rime_slot：此處不產生候選，只記下 Google 的首個候選，由 slot_filter 放入第一頁最後一格
    slot_pick[seg.start] = { input = ctx.input, cand = cands[1] }
    return
  end
  -- 須在第一個 yield 之前記下：librime-lua 在 Query 時已執行至第一個 yield，filter 之後才讀取
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

-- 排在所有 filter 最前。這一段有 ☁ 候選時只放行 ☁ 候選，放行 n 個後即停止，
-- 毋須逐一處理小狼毫其後的大量候選。其他模式或這一段沒有 ☁ 候選時，則原樣放行。
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
      for cand in input:iter() do yield(cand) end -- 出錯時放行餘下候選，避免候選欄變成空白
    end
  end,
}

-- ------------------------------------------------------------ filter (rime_slot)

-- 排在所有 filter 最後（uniquifier 之後），因此即使 Google 的首個候選與小狼毫前幾個候選重複，
-- 亦不會被刪除：第 slot 格永遠是 Google 的首個候選。小狼毫候選不足 slot-1 個時，則放在最後。
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

-- 目前組字中（abc 段）的查詢拼音；未在組字或已關閉雲端時傳回 nil
local function composing_query(ctx, cfg)
  if not ctx:is_composing() or ctx:get_option(cfg.off_option) then return nil end
  local seg = current_abc_segment(ctx)
  if not seg then return nil end
  local q = normalize(ctx.input:sub(seg.start + 1, seg._end))
  if #q == 0 or #q > MAX_QUERY_LEN then return nil end
  return q
end

-- 反轉這組拼音的模式；如變為需要顯示雲端候選而尚未有結果，則稍作等待
local function toggle_cloud(ctx, cfg, q)
  if override_query == q then override_query = nil else override_query = q end
  if cloud_wanted(cfg, q) then
    local cached = read_cache(q, cfg.engine)
    if cached == false then
      os.remove(cache_file(q, cfg.engine)) -- 之前曾經失敗，重新嘗試
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

  -- 新一輪組字開始（未組字時按鍵）：清除上一輪雙擊 Shift 的反轉。
  -- 不使用 update_notifier:connect，以免由 C++ 事件回調進入 Lua（較易導致 rime.dll 出錯）。
  if not key:release() and not ctx:is_composing() then override_query = nil end

  -- 背景程式發出的刷新鍵（F24）：組字中攔截並刷新；未在組字時放行（F24 對一般程式沒有作用）
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

  -- 雙擊左 Shift。第一下照常交由 ascii_composer 處理（組字中即臨時切換英文），
  -- 第二下如在時限內則予以攔截：還原中文模式並反轉雲端／本地。右 Shift 不受影響。
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
    -- 第二下：第一下已令組字臨時變為英文（raw 段，不再是 abc），因此無法再找到 abc 段；
    -- 只要組字內容與第一下時相同，就沿用第一下記下的拼音。
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
    env.last_tap = nil -- 兩下 Shift 之間按了其他鍵，則不算雙擊
    env.shift_clean = false
  end

  -- 可選的單鍵觸發（gcloud/trigger，預設為 none）
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
