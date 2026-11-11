**中文** · [English](README.en.md)

# 小狼毫 × Google 粵語雲端候選

本專案為 Windows 輸入法[小狼毫](https://github.com/rime/weasel)（Rime）的粵語拼音加入 Google 輸入工具的粵語候選字詞（以 ☁ 標示）。打字和選字仍由小狼毫負責；遇到拼寫不準確、長句或新詞時，只需連按兩下左 Shift，即可借助 Google 的模糊匹配和詞庫。

> **非官方專案。** 本專案與 Google 無關，亦未獲 Google 認可。本專案使用 Google 輸入工具未公開的介面，Google 可能隨時更改或停止提供；屆時小狼毫仍可照常使用，只是不再顯示 ☁ 候選。本專案屬個人業餘項目，不保證持續維護。

## 功能

- **四種模式**，可按個人習慣選擇：

  | 模式 | 平時 | 連按兩下左 Shift | 適合對象 |
  |---|---|---|---|
  | `rime_first`（預設） | 只顯示小狼毫候選，次序固定 | 加入 Google 候選，並排在最前 | 熟悉拼音的用家 |
  | `rime_slot` | 每頁顯示 6 個候選：前 5 個來自小狼毫，第 6 個固定為 Google 的首選 | 加入完整的 Google 候選 | 熟悉拼音、希望隨時看到 Google 首選的用家 |
  | `cloud_first` | Google 候選排在最前，小狼毫候選排在其後 | 只顯示小狼毫候選 | — |
  | `cloud_only` | 有 Google 結果時只顯示 Google 候選 | 只顯示小狼毫候選 | 初學者；容錯能力最強 |

- **兩套拼音方案**：粵拼（`jat` = 日），以及耶魯拼音（`yat` = 日，另行安裝「粵語拼音（耶魯）」方案）。
- **離線不影響打字**：無法連接 Google 時，會自動只使用小狼毫的候選。

## 私隱：哪些內容會傳送給 Google

| 模式 | 傳送的內容 |
|---|---|
| `rime_first` | **只在你連按兩下左 Shift 時**，才傳送當時正在輸入的拼音。平時打字不會傳送任何拼音（背景程式只會定時向 Google 傳送一個固定的測試字，以保持連線） |
| `rime_slot`、`cloud_first`、`cloud_only` | 輸入期間每打一個字母，都會把當時的拼音傳送查詢 |

- 只會傳送拼音（例如 `ngodeigamjat`），不會傳送已輸入的文字、視窗內容或任何個人資料。
- 查詢結果會暫存於 `%APPDATA%\Rime\gcloud\cache\`；記錄檔預設不會記下你輸入的內容。
- 按 `` Ctrl+` `` 或 `F4` 開啟方案選單，可隨時把「☁雲端」切換為「本地」，完全停止查詢。

## 系統要求

- Windows 10 或 11
- [小狼毫](https://rime.im/download/) 0.15 或以上（目前只在 0.15.0 測試）。如尚未安裝，安裝程式可透過 winget 代為安裝。
- 粵語拼音方案 [rime-cantonese](https://github.com/rime/rime-cantonese)。小狼毫並未附帶此方案；如尚未安裝，安裝程式可代為下載。

毋須另外安裝 Python 或其他軟件：背景程式會在安裝時以 Windows 內置的 .NET Framework 編譯。

## 安裝

1. 下載本專案（Code → Download ZIP）並解壓縮。
2. 雙擊 `setup.cmd`。如 Windows 提示「這個檔案來自互聯網」，請選擇「執行」。
3. 回答兩個問題：
   - 你使用哪一套拼音方案：1) 粵拼（日 = jat）或 2) 耶魯拼音（日 = yat）。可輸入號碼，亦可直接輸入 `jat` 或 `yat`。
   - 你想使用哪一種用法：1) 保留小狼毫選字，另加第 6 個候選，由 Google 輸入工具建議（推薦，即 `rime_slot`）；2) 保留小狼毫選字，連按兩下左 Shift 才轉用 Google 輸入工具選字（保障私隱，即 `rime_first`）；3) 改用 Google 輸入工具選字（適合新手，即 `cloud_only`）。

   之後可隨時再次執行 `setup.cmd` 重新選擇，次數不限。

安裝程式會檢查小狼毫和粵語拼音方案（如有缺少，會詢問是否自動安裝），然後複製插件、編譯並啟動背景程式、設定登入 Windows 時自動啟動、把所選方案放到方案選單最前，最後重新部署小狼毫。

亦可略過問答，直接以命令安裝，例如：

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode rime_first -Autostart -AddToSchemaList
```

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Yale -Mode cloud_only -Autostart -AddToSchemaList
```

## 使用方法

- **連按兩下左 Shift**（0.5 秒內）：按上表切換當前拼音的雲端或本地候選，再按兩下即可切換回來。設定只適用於當時正在輸入的拼音，輸入下一組字時會恢復預設。
- 在 `rime_first` 模式下，按兩下 Shift 時才會查詢，一般約 0.3 秒內有結果，期間輸入會短暫停頓。
- 單按 Shift 的功能不變：未輸入時切換中英文；輸入期間單按左 Shift 會臨時切換英文，單按右 Shift 則直接輸出字母。
- 亦可選擇 Google 的部分匹配結果（例如只匹配「我哋」），其餘拼音會繼續組字。

## 更改模式及移除

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode cloud_only
```

如要移除，請雙擊 `uninstall.cmd`。它會還原本插件的所有改動，小狼毫和粵語拼音方案則會保留。

不加 `-Mode` 重新執行 `install.ps1`（例如更新版本後）會保留目前的模式。執行 `uninstall.ps1` 時加上 `-PurgeCache`，會一併刪除暫存的查詢結果。

## 已知限制

- 小狼毫需要有按鍵才會更新候選，因此在 `rime_slot`、`cloud_first` 和 `cloud_only` 模式下，Google 候選約需 0.3 秒，並由背景程式模擬按下 `F24` 鍵提示刷新。未輸入時，`F24` 會傳送到目前使用中的程式，一般程式不會有任何反應。
- 刷新的一刻，選字游標會回到第一個候選。
- 連按兩下左 Shift 時，狀態圖示可能短暫顯示「英」。
- 連按五下 Shift 會觸發 Windows 的「相黏鍵」提示，建議在「設定 → 協助工具 → 鍵盤」關閉相黏鍵的快速鍵。
- 背景程式 `rime-gcloud.exe` 會模擬按下 `F24` 鍵，個別防毒軟件可能因此發出提示，可將其加入信任清單。
- 耶魯拼音方案不支援耶魯的聲調寫法（例如 `yaht` 中的 h）；這類輸入可交由 Google 處理，Google 能夠辨認。

## 回報問題

雙擊 `diagnose.cmd`，桌面會出現 `rime-google-cantonese-report.txt`。報告只包含版本、設定、檔案檢查和最近的記錄，不包含你輸入過的內容，Windows 用戶名稱和電腦名稱亦已隱去。回報問題時請附上此檔案。

## 授權與鳴謝

- 本專案的程式碼以 [MIT](LICENSE) 授權發佈。
- `rime/jyut6ping3_yale.schema.yaml` 的拼寫規則來自 [CanCLID/rime-cantonese-schemes](https://github.com/CanCLID/rime-cantonese-schemes)，以 [LGPL-3.0](LICENSES/LGPL-3.0.txt) 授權。
- 詳見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。感謝小狼毫、librime、librime-lua 及 rime-cantonese 的開發者。

技術細節（架構、引擎及全部設定項目）見 [docs/TECHNICAL.md](docs/TECHNICAL.md)。本專案的程式碼主要由 Claude（Anthropic）編寫，各階段使用的模型版本及設計決定見 [docs/DEVELOPMENT_LOG.md](docs/DEVELOPMENT_LOG.md)。
