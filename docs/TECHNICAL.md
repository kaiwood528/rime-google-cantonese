# 技術細節

## 架構

```
小狼毫 (librime-lua)                           背景程式
lua/gcloud.lua ── 需要查詢時寫入 ──> request.txt ──> rime-gcloud.exe ──> inputtools.google.com
      ^                                                    │
      └──────── 讀取 cache\q_<拼音>.txt <───────────────────┘
```

librime-lua 不能上網，亦沒有計時器，所以插件透過 `%APPDATA%\Rime\gcloud\` 裏面的檔案與背景程式溝通：

| 檔案 | 寫入者 | 內容 |
|---|---|---|
| `request.txt` | Lua | `<拼音>\n<序號>\n<push 0/1>\n<引擎>\n`。拼音為空表示「用家正在打字」，背景程式只保持連線，不會查詢 |
| `cache\q_<拼音>.txt`、`cache\q_yale_<拼音>.txt` | 背景程式 | `OK` 加每行 `<匹配長度>\t<候選>\t<註解>`，或 `ERR\t<原因>` |
| `heartbeat.txt` | 背景程式 | 每2秒更新的時間戳，Lua 用來判斷背景程式是否在運行 |
| `cache_version.txt` | 背景程式 | 引擎設定版本；版本改變時自動清空快取 |

### 背景程式 `rime-gcloud.exe`

- 原始碼是 `daemon/RimeGcloud.cs`，只用 C# 5 語法，安裝時由 .NET Framework 4.x 內置的 `csc.exe` 編譯到 `%LOCALAPPDATA%\Programs\rime-google-cantonese\rime-gcloud.exe`。用家不用裝 Python，亦不會下載任何 `.exe`，所以不會觸發 SmartScreen。
- 用 `FileSystemWatcher` 監察 `request.txt`，不用輪詢；每2秒更新心跳時順便檢查一次，以防漏掉事件。閒置時約用0.1%一個 CPU 核心、約39 MB 記憶體（舊 Python 版約0.5%）。
- 以3條工作執行緒處理查詢（最新的請求優先，最多保留4個未處理請求），共用一個 `HttpClient` 保持 HTTPS 長連線，一般查詢約250–450ms。
- 最近10分鐘內有打字，每45秒向 Google 送一次固定的 `nei` 保持連線；收到「正在打字」通知而連線已閒置超過45秒，會即時重新連線。
- 快取超過30,000個檔案時刪除最舊的；以具名 mutex `Local\RimeGoogleCantoneseDaemon` 確保只有一個背景程式。
- 加上 `[assembly: TargetFramework(".NETFramework,Version=v4.8")]`，否則沒有目標框架資訊的程式會以 .NET 4.0 的舊設定運行，可能不使用 TLS 1.2；程式亦會明確開啟 TLS 1.2／1.3。

### 自動刷新（F24）

小狼毫只會在有按鍵時重新產生候選。需要自動顯示 Google 結果的模式（`rime_slot`、`cloud_first`、`cloud_only`）會在請求中設定 push；背景程式收到該請求的結果後，若它仍是最新請求且不超過3秒，就用 `SendInput` 發送一下 `F24`。插件在組字中截住 `F24` 並刷新候選；不在組字時放行。

### 雙擊左 Shift

處理器排在 `ascii_composer` 之前。第一下照常交給 `ascii_composer`（組字中即臨時切換英文，輸入會被重新分段為 `raw`），第二下若在 `double_shift_ms` 內且輸入沒有改變，就攔截、還原中文模式，並用第一下記下的拼音反轉雲端／本地。librime-lua 沒有 sleep，等待 Google 結果時只能忙等，最多 `timeout_ms`。

### 候選如何排列

- `rime_first`／`cloud_first`：翻譯器 `lua_translator@gcloud_translator` 排在最前，完整匹配的 ☁ 候選 quality 為1000。Rime 按起點、終點（長者先）、quality 合併候選，所以 ☁ 候選排最前。
- `cloud_only`：`lua_filter@gcloud_filter` 排在所有 filter 最前；該段有 ☁ 候選時只放行 ☁ 候選，放行完就停。翻譯器必須在第一個 `yield` 之前記下候選數目，因為 librime-lua 在 Query 時已經執行到第一個 `yield`。
- `rime_slot`：翻譯器不出候選，只記下 Google 第一個候選；`lua_filter@gcloud_slot_filter` 排在所有 filter 最後（`uniquifier` 之後），把它插入第 `slot` 格，所以即使和小狼毫的候選重複也不會被刪走。

## Google 引擎

| Google 名稱 | 代碼 | 拼法 | 例子 |
|---|---|---|---|
| 粵拼 | `yue-hant-t-i0-jyutping` | 粵拼：j = 日，z = 咗 | `jat` → 日，`jyutjyusyujapfaat` → 粵語輸入法 |
| 廣東話 | `yue-hant-t-i0-und` | 以耶魯拼音為底：j = 粵拼的 z | `jau` → 走，`yahtbun` → 日本 |

每個方案用 `gcloud/engine` 指定：

- `jyutping`（預設）：先用粵拼引擎；沒有結果時（例如首字母簡拼 `sjfm`）才改用「廣東話」引擎。
- `yale`：只用「廣東話」引擎。耶魯輸入不可交給粵拼引擎，例如 `jau` 會變成「有」而不是「走」。

## 耶魯拼音方案 `jyut6ping3_yale`

`rime/jyut6ping3_yale.schema.yaml` 以 `__include: jyut6ping3.schema:/` 引用粵拼方案（因此會一併套用 `jyut6ping3.custom.yaml` 的插件設定），再用 `__patch` 加上 CanCLID 耶魯補丁的拼寫規則：j = 粵拼 z，ch = 粵拼 c，eu = 粵拼 eo/oe，y = 粵拼 j。它有自己的 `translator/prism`，所以可以和粵拼方案並存。

- 原補丁在輸入欄括號顯示對應的粵拼；這裏刪掉了，只顯示用家打的耶魯拼法。
- `translator/comment_format` 把候選旁的拼音提示由粵拼轉成耶魯寫法（聲調用數字）。
- 預設 `gcloud/mode: rime_first`、`gcloud/engine: yale`。

`jyut6ping3_ipa` 同樣透過 `__include` 引用 `jyut6ping3`，會自動套用同一份 patch；**不要**另外建立 `jyut6ping3_ipa.custom.yaml`，否則元件會被加入兩次。

## 設定

設定位於 `rime/schema.custom.yaml`，安裝後成為 `%APPDATA%\Rime\jyut6ping3.custom.yaml`。修改後重新執行 `install.ps1`。

| 項目 | 預設 | 說明 |
|---|---|---|
| `mode` | `rime_first` | `rime_first`、`rime_slot`、`cloud_first` 或 `cloud_only` |
| `prefetch` | `auto` | `auto`：`rime_first` 只在雙 Shift 時查詢，其他模式打字途中預先查詢；`true`／`false` 強制開／關 |
| `slot` | 每頁候選數 | `rime_slot`：Google 候選放在第幾格；預設是第一頁最後一格（`menu/page_size`，安裝程式設為6） |
| `engine` | `jyutping` | `jyutping` 或 `yale` |
| `double_shift` | `true` | 組字中連按兩下左 Shift 切換雲端／本地 |
| `double_shift_ms` | `500` | 兩下 Shift 之間最多相隔多久（毫秒） |
| `trigger` | `none` | 另外指定單鍵觸發（例如 `Tab`）；`none` 表示不用 |
| `timeout_ms` | `1500` | 雙 Shift 要求雲端候選後最多等多久（毫秒） |
| `push_refresh` | `true` | Google 結果到達時由背景程式發 `F24` 提示刷新 |
| `refresh_key` | `F24` | 刷新鍵，要和 `daemon/RimeGcloud.cs` 的 `VK_F24` 一致 |
| `show_annotation` | `true` | ☁ 候選後面顯示 Google 的拼音註解 |
| `max_candidates` | `15` | ☁ 候選數量上限 |
| `auto_cached` | `false` | 舊設定：有快取時自動顯示 ☁ 候選 |

## 安裝程式參數

`setup.cmd` 以 `-Interactive` 執行 `install.ps1`：

1. 找不到小狼毫時，問用家是否用 `winget install Rime.Weasel` 安裝。
2. 找不到 `jyut6ping3.schema.yaml` 時，問用家是否下載 `rime/rime-cantonese`；缺少 `loengfan`、`luna_pinyin`、`stroke`、`cangjie5`（`jyut6ping3` 的依賴方案）也會一併下載。安裝程式自己用 `Invoke-WebRequest` 下載 GitHub 的 ZIP（先試 `main` 分支，再試 `master`），把 `*.yaml`、`*.txt` 和 `opencc\` 檔案複製到用戶資料夾。不用小狼毫附帶的 `rime-install.bat`，因為它假設分支叫 `master`，遇到 `CanCLID/rime-loengfan`（`main` 分支）會下載了卻甚麼都沒裝。
3. 問拼音（粵拼／耶魯）和用法（`rime_first`／`rime_slot`／`cloud_only`），然後以 `-Autostart -AddToSchemaList` 安裝。

`install.ps1`、`uninstall.ps1` 和 `diagnose.ps1` 只可用 ASCII 字元，問答的中英文字串放在 `setup/messages.txt`（UTF-8）：`key=中文`，`key_en=English`。`Say` 先印中文、再以灰色印英文；提示和錯誤訊息用 `TB` 合成「中文 / English」一行。

小狼毫 0.16 起可以更改用戶資料夾（`HKCU\Software\Rime\Weasel\RimeUserDir`）。Lua 用 `rime_api.get_user_data_dir()`，安裝程式、移除程式、診斷工具和 `rime-gcloud.exe` 都讀取同一個登錄值，沒有設定時才用 `%APPDATA%\Rime`。

`diagnose.ps1`（`diagnose.cmd`）把系統、小狼毫、方案、插件設定、背景程式狀態、Google 連線測試和最近的記錄寫到桌面的 `rime-google-cantonese-report.txt`，並把用戶資料夾路徑、Windows 用戶名和電腦名稱換成佔位字。全新電腦的測試步驟見 [TESTING.md](TESTING.md)。

| 參數 | 作用 |
|---|---|
| `-Interactive` | 問答式安裝（`setup.cmd` 使用） |
| `-Mode <模式>` | 把這次安裝的方案都設成該模式；不加則保留已安裝的模式（全新安裝用預設）。`rime_slot` 會同時把每頁候選數設為6 |
| `-Yale` | 安裝耶魯方案；已安裝過的耶魯方案每次都會更新 |
| `-AddToSchemaList` | 把 `jyut6ping3`（及耶魯方案）加到 `default.custom.yaml` 的方案清單最前（先備份）；檔案不存在時會連同小狼毫原本的預設方案一併寫入 |
| `-Autostart` | 在「啟動」資料夾加捷徑，登入時自動執行背景程式。已有捷徑時每次都會更新 |
| `-Schemas` | 要套用插件的方案，預設 `jyut6ping3` |
| `-NoDeploy` | 不重新部署小狼毫 |

`uninstall.ps1`（`uninstall.cmd`）會停止背景程式、刪除程式資料夾和自動啟動捷徑、插件檔案和 patch，並把耶魯方案移出方案清單；小狼毫和 rime-cantonese 保留。

## 背景程式命令列

程式編譯成沒有視窗的程式，測試時用 `--out` 把結果寫到檔案：

```bash
"%LOCALAPPDATA%\Programs\rime-google-cantonese\rime-gcloud.exe" --once ngodeigamjat --out result.txt
```

```bash
"%LOCALAPPDATA%\Programs\rime-google-cantonese\rime-gcloud.exe" --once yahtbun --engine yale --out result.txt
```

`--verbose` 會在記錄檔記下每個查詢的拼音（預設不記錄）。

## 檔案

| 檔案 | 用途 |
|---|---|
| `rime/lua/gcloud.lua` | Rime 翻譯器、filter 及按鍵處理 |
| `rime/rime.lua.snippet` | 在 `rime.lua` 登記元件 |
| `rime/schema.custom.yaml` | schema patch 及設定範本 |
| `rime/jyut6ping3_yale.schema.yaml` | 耶魯拼音方案 |
| `daemon/RimeGcloud.cs` | 背景查詢程式（安裝時編譯成 `rime-gcloud.exe`） |
| `setup.cmd`、`uninstall.cmd`、`diagnose.cmd` | 雙擊安裝／移除／產生診斷報告 |
| `install.ps1`、`uninstall.ps1` | 安裝及移除（只可用 ASCII 字元：Windows PowerShell 5.1 會以 ANSI 讀取沒有 BOM 的腳本） |
| `setup/messages.txt` | 安裝及移除程式的中文字串 |
| `web/index.html` | 「日」字點打？選擇頁（中英切換：瀏覽器語言決定預設，選擇記在 `localStorage` 的 `rgc-lang`） |
