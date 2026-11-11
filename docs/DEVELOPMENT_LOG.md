# 開發紀錄

本專案由 [kaiwood528](https://github.com/kaiwood528) 提出構想、決定設計及在實際環境測試，程式碼主要由 AI（Anthropic 的 Claude，透過 Claude Code）編寫。下面記下每個階段用過的模型版本、做過的決定和容易出錯的地方，方便日後的維護者（包括將來的模型）檢查及修改。

## 模型版本

| 日期 | 模型 | 工作 |
|---|---|---|
| 2026-11-04 | Claude Opus 5.5（`claude-opus-5-5`） | 插件初版（Lua 翻譯器／處理器、Python 背景程式、安裝及移除腳本）；改用 Google 粵拼引擎；自動啟動；雙擊左 Shift；`cloud_first` 和 F24 自動刷新；`cloud_only` filter；耶魯拼音方案及按方案選擇 Google 引擎；「日」字點打？選擇頁 |
| 2026-11-05 | Claude Opus 5.5（`claude-opus-5-5`） | 實測 CPU、記憶體和流量 |
| 2026-11-11 | Claude Fable 5.2（`claude-fable-5-2`） | 開源計劃；`rime_slot` 模式（第6格固定是 Google 首選） |
| 2026-11-11 | Claude Opus 5.5（`claude-opus-5-5`） | 開源準備：`prefetch: auto`（`rime_first` 只在雙 Shift 才查詢）和「正在打字」連線保持；授權、鳴謝、公開版說明文件 |
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
- **Windows 的 CPU 時間以約15.6毫秒為單位計算**，量度背景程式閒置用量時要用較長時間（例如一分鐘）。
- **小狼毫崩潰紀錄**：2026-11-04 測試雙擊 Shift 期間，WeaselServer 0.15.0 在 `rime.dll` 崩潰過一次（0xc0000005），原因未能確定，可能與連按五下 Shift 觸發的相黏鍵提示有關。插件已避免使用 `update_notifier:connect`。

## 未驗證

- 只在小狼毫 0.15.0 測試過；未在其他版本或全新安裝的電腦上測試。
- `rime_first` 新的「只在雙 Shift 查詢」流程未在實際畫面測試（開發者當時使用 `rime_slot`）。
- `setup.cmd` 的問答流程已由開發者在已安裝小狼毫和 rime-cantonese 的電腦上測試正常（2026-11-11，粵拼＋`rime_slot`）；**自動安裝小狼毫和 rime-cantonese 的兩個步驟未實際執行過**。修改方案清單的函數曾用四種檔案格式測試。
- 未在 winget 目前提供的小狼毫 0.17.x 上測試。
