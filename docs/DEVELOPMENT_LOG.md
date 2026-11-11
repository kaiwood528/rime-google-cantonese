# 開發紀錄

本專案由 [kaiwood528](https://github.com/kaiwood528) 提出構想、決定設計及在實際環境測試，程式碼主要由 AI（Anthropic 的 Claude，透過 Claude Code）編寫。下面記下每個階段用過的模型版本、做過的決定和容易出錯的地方，方便日後的維護者（包括將來的模型）檢查及修改。

## 模型版本

| 日期 | 模型 | 工作 |
|---|---|---|
| 2026-11-04 | Claude Opus 5.5（`claude-opus-5-5`） | 插件初版（Lua 翻譯器／處理器、Python 背景程式、安裝及移除腳本）；改用 Google 粵拼引擎；自動啟動；雙擊左 Shift；`cloud_first` 和 F24 自動刷新；`cloud_only` filter；耶魯拼音方案及按方案選擇 Google 引擎；「日」字怎樣打？選擇頁 |
| 2026-11-05 | Claude Opus 5.5（`claude-opus-5-5`） | 實測 CPU、記憶體和流量 |
| 2026-11-11 | Claude Fable 5.2（`claude-fable-5-2`） | 開源計劃；`rime_slot` 模式（第6格固定是 Google 首選） |
| 2026-11-11 | Claude Opus 5.5（`claude-opus-5-5`） | 開源準備：`prefetch: auto`（`rime_first` 只在雙 Shift 才查詢）和「正在打字」連線保持；授權、鳴謝、公開版說明文件 |
| 2026-11-11 | Claude Opus 5.5（`claude-opus-5-5`） | 安裝問答改版：拼音方案題直接問「粵拼（日 = jat）／耶魯拼音（日 = yat）」，可輸入號碼、`jat`、`yat`、「粵拼」等；用法改為 1 `rime_slot`（推薦）／2 `rime_first`／3 `cloud_only`，並提示可隨時重新安裝；選擇頁按新編號更新；`gcloud.lua` 註解改用書面語，整個倉庫統一 |
| 2026-11-11 | Claude Opus 5.5（`claude-opus-5-5`） | 文字規範：README 分為繁體中文書面語（`README.md`）及英文（`README.en.md`）兩版；選擇頁、安裝程式問答、設定檔註解及耶魯方案說明一律改用書面語，不用粵語口語 |
| 2026-11-11 | Claude Opus 5.5（`claude-opus-5-5`） | 選擇頁重寫：中英切換，按三類讀者（已會用拼音打字／會說粵語但未用拼音打字／正在學習粵語）重寫文案，加入常見問題；安裝程式問答改為中英對照 |
| 2026-11-11 | Claude Opus 5.5（`claude-opus-5-5`） | 全新電腦測試準備：支援小狼毫 0.16+ 的自訂用戶資料夾；安裝程式自行下載粵語方案（取代 `rime-install.bat`）；`diagnose.cmd` 診斷報告；`docs/TESTING.md` 測試清單 |
| 2026-11-11 | Claude Opus 5.5（`claude-opus-5-5`） | 一鍵安裝：背景程式由 Python 改寫成 C#（安裝時用內置 `csc.exe` 編譯，`FileSystemWatcher` 取代輪詢）；`setup.cmd` 問答式安裝（自動安裝小狼毫及 rime-cantonese、加入方案清單）；`uninstall.cmd` |

## 設計決定

| 決定 | 原因 |
|---|---|
| 做成小狼毫插件，不另寫輸入法 | 小狼毫已經穩定；Google 斷線時打字不受影響 |
| 用檔案和背景程式溝通 | librime-lua 不能上網，亦沒有計時器 |
| Google 預設用「粵拼」引擎（`yue-hant-t-i0-jyutping`） | 「廣東話」引擎（`und`）以耶魯為底，`jat` 會變成「則」 |
| 耶魯方案只用「廣東話」引擎 | 粵拼引擎會誤讀耶魯：`jau` → 有（應為走） |
| 預設 `rime_first`，並且只在雙 Shift 才查詢 | 熟手重視候選次序固定；平時不送出任何拼音，私隱最好 |
| `cloud_only` 未有 Google 結果時仍顯示小狼毫候選 | 候選欄空白時按空格會把英文字母直接上屏 |
| 耶魯方案做成獨立 schema，並刪掉括號內的粵拼 | 可與粵拼並存；括號顯示粵拼會令新手混亂 |
| 第6格的 Google 候選即使重複也照樣顯示 | 用家要一眼看到 Google 的首選；filter 因此排在 `uniquifier` 之後 |
| 背景程式用 C# 原始碼、安裝時才編譯 | 每部 Windows 10/11 都有 .NET Framework 4.x 和 `csc.exe`；用家不用裝 Python，也不用下載未簽署的 `.exe`（避免 SmartScreen 警告） |
| 選擇頁先問「你現在如何輸入中文」，再分流 | 原本假設讀者已懂粵拼；改為照顧未用過拼音的人和學習粵語的外國人。已會用拼音打字 → 問「日」字拼法 → 以小狼毫為主；會說粵語但未用拼音打字 → 比較耶魯拼音和粵拼 → 以 Google 為主；正在學習粵語 → 問課本使用哪一套拼音（不確定則建議粵拼）→ 以 Google 為主 |
| 面向用家的中文一律用繁體書面語 | 維護者要求：正式文字不用粵語口語，以保持正規感覺。粵語只出現在例子本身（例如候選「我哋今日去食飯」）；程式註解亦已統一為書面語 |
| 安裝時推薦「保留小狼毫選字，另加 Google 第 6 個候選」（`rime_slot`） | 維護者實際使用後認為最方便；重視私隱或想減輕 CPU 及網絡負擔的用家可選 `rime_first`，新手可選 `cloud_only`。命令列安裝不加 `-Mode` 時，預設仍為 `rime_first`（不預先查詢，最保守） |
| 選擇頁和安裝程式都要中英對照 | 外國學習者要看懂問題；安裝程式的選項號碼和選擇頁一致 |
| 程式裝在 `%LOCALAPPDATA%\Programs\rime-google-cantonese` | 用家安裝後可以刪掉下載的資料夾；不需要管理員權限 |

## 容易出錯的地方

- **librime-lua 翻譯器在 Query 時已經執行到第一個 `yield`**；要給 filter 讀的狀態，必須在第一個 `yield` 之前記下。
- **雙擊 Shift 的第二下找不到 `abc` 段**：第一下令 `ascii_composer` 把輸入重新分段為 `raw`，所以要沿用第一下記下的拼音（以 `ctx.input` 未變為條件）。
- **`Start-Process WeaselDeployer.exe /deploy` 會打開設定視窗而不是部署**（ShellExecute）；要用 `ProcessStartInfo` 並設 `UseShellExecute = false`。
- **`jyut6ping3_ipa` 會繼承 `jyut6ping3.custom.yaml`**（`__include` 會套用被引用資源的自動 patch）；另外建立它的 custom 檔會令元件加入兩次。耶魯方案同樣會繼承，所以只需覆寫 `gcloud/*`。
- **耶魯方案要有自己的 `translator/prism`**，否則會和粵拼方案互相覆蓋。
- **安裝及移除腳本只可用 ASCII 字元**：Windows PowerShell 5.1 會以 ANSI 讀取沒有 BOM 的腳本，中文註解會令腳本無法解析。
- **`csc.exe` 只支援 C# 5**：不可用字串插值（`$""`）、`?.`、`nameof`、expression-bodied 成員等新語法。
- **沒有 `TargetFramework` 屬性的 .NET 程式會用 4.0 的舊預設值**（包括 TLS 版本），所以 `RimeGcloud.cs` 加了該屬性並明確開啟 TLS 1.2／1.3。
- **小狼毫附帶的 `rime-install.bat` 假設 GitHub 分支叫 `master`**：`CanCLID/rime-loengfan` 用 `main`，下載的 ZIP 根目錄是 `rime-loengfan-main`，腳本找不到 `rime-loengfan-master` 資料夾，結果甚麼都沒裝（只印出「The system cannot find the path specified」）。安裝程式因此自己下載。
- **小狼毫 0.16 起可以把用戶資料夾移到別處**（`HKCU\Software\Rime\Weasel\RimeUserDir`）；背景程式必須和 Lua 看同一個資料夾，否則雙方的檔案對不上。
- **Windows 的 CPU 時間以約15.6毫秒為單位計算**，量度背景程式閒置用量時要用較長時間（例如一分鐘）。
- **小狼毫崩潰紀錄**：2026-11-04 測試雙擊 Shift 期間，WeaselServer 0.15.0 在 `rime.dll` 崩潰過一次（0xc0000005），原因未能確定，可能與連按五下 Shift 觸發的相黏鍵提示有關。插件已避免使用 `update_notifier:connect`。

## 未驗證

- 只在小狼毫 0.15.0 測試過；未在其他版本或全新安裝的電腦上測試。
- `rime_first` 新的「只在雙 Shift 查詢」流程未在實際畫面測試（開發者當時使用 `rime_slot`）。
- `setup.cmd` 的問答流程已由開發者在已安裝小狼毫和 rime-cantonese 的電腦上測試正常（2026-11-11，粵拼＋`rime_slot`）。下載粵語方案的函數曾在暫存資料夾測試（5個套件、約16秒），但**未在全新電腦上經 `setup.cmd` 完整執行過；用 winget 自動安裝小狼毫亦未執行過**。修改方案清單的函數曾用四種檔案格式測試。
- 未在 winget 目前提供的小狼毫 0.17.x 上測試。
