# 小狼毫 × Google 粵語雲端候選

在 Windows 的[小狼毫](https://github.com/rime/weasel)（Rime）粵語拼音上，加入 Google 輸入工具的粵語候選字（☁ 標記）。小狼毫照常負責打字和選字，Google 的模糊匹配和詞庫負責補救：拼得不準、長句、新詞，連按兩下左 Shift 就可以叫 Google 幫手。

*A plugin for the Weasel (Rime) input method on Windows that adds Cantonese candidates from Google Input Tools. Rime stays in charge; double-tap Left Shift to bring in Google's fuzzy-matching suggestions. Supports Jyutping and Yale.*

> **非官方專案。** 本專案與 Google 無關，亦未獲 Google 認可。它使用的是 Google 輸入工具未公開的介面，Google 隨時可能更改或停止提供；屆時小狼毫照常可用，只是不再出現 ☁ 候選。這是個人業餘專案，不保證維護。

## 功能

- **四種模式**，按你的習慣揀：

  | 模式 | 平時 | 連按兩下左 Shift | 適合 |
  |---|---|---|---|
  | `rime_first`（預設） | 只顯示小狼毫候選，次序固定 | 加入 Google 候選，排在最前 | 熟手 |
  | `rime_slot` | 每頁6個候選：頭5個是小狼毫，第6個固定是 Google 的首選 | 加入整串 Google 候選 | 熟手，想隨時見到 Google 首選 |
  | `cloud_first` | Google 候選排最前，小狼毫候選排後面 | 只顯示小狼毫候選 | — |
  | `cloud_only` | 有 Google 結果就只顯示 Google 候選 | 只顯示小狼毫候選 | 新手，容錯最強 |

- **兩套拼音**：粵拼（`jat` = 日），以及耶魯拼音（`yat` = 日，另裝「粵語拼音（耶魯）」方案）。
- **斷線不影響打字**：查不到 Google 時，自動只用小狼毫候選。

## 私隱：甚麼會送去 Google

| 模式 | 送出的內容 |
|---|---|
| `rime_first` | **只有你連按兩下左 Shift 時**，才會送出當時那組拼音。平時打字不會送出任何拼音（背景程式只會定時向 Google 送一個固定的測試字，保持連線） |
| `rime_slot`、`cloud_first`、`cloud_only` | 組字途中每打一個字母，都會把當時的拼音送去查詢 |

- 只會送出拼音（例如 `ngodeigamjat`），不會送出已上屏的文字、視窗內容或任何個人資料。
- 查詢結果會快取在 `%APPDATA%\Rime\gcloud\cache\`；記錄檔預設不記下你打的內容。
- 按 `` Ctrl+` `` 或 `F4` 打開方案選單，可以隨時把「☁雲端」切換成「本地」，完全停止查詢。

## 系統要求

- Windows 10 或 11
- [小狼毫](https://rime.im/download/) 0.15 或以上（目前只在 0.15.0 測試過）
- 粵語方案 [rime-cantonese](https://github.com/rime/rime-cantonese)（小狼毫本身沒有附帶）
- [Python 3](https://www.python.org/downloads/windows/)（暫時需要；計劃改為免安裝）

## 安裝

1. 安裝小狼毫和 rime-cantonese，確認可以用「粵語拼音」打字。
2. 下載本專案（Code → Download ZIP）並解壓。
3. 在解壓後的資料夾打開 PowerShell，按你想要的配搭執行其中一行：

   ```bash
   powershell -ExecutionPolicy Bypass -File install.ps1 -Mode rime_first -Autostart
   ```

   ```bash
   powershell -ExecutionPolicy Bypass -File install.ps1 -Mode rime_slot -Autostart
   ```

   ```bash
   powershell -ExecutionPolicy Bypass -File install.ps1 -Mode cloud_only -Autostart
   ```

   用耶魯拼音的話，加上 `-Yale`：

   ```bash
   powershell -ExecutionPolicy Bypass -File install.ps1 -Yale -Mode rime_first -Autostart
   ```

4. 用耶魯拼音的話，在小狼毫「輸入法設定」勾選「粵語拼音（耶魯）」。

安裝程式會複製插件、設定小狼毫、啟動背景程式，然後重新部署小狼毫。`-Autostart` 會令背景程式隨 Windows 登入自動啟動。

## 用法

- **連按兩下左 Shift**（0.5 秒內）：按上表切換這組拼音的雲端／本地，再按兩下切回。只對當時那組拼音有效，打下一組字會回復預設。
- `rime_first` 下按雙 Shift 時才去查詢，一般約0.3秒有結果，這段時間輸入會停一停。
- 單按 Shift 的功能不變：未組字時切換中／英；組字途中單按左 Shift 臨時切換英文，單按右 Shift 把字母直接上屏。
- Google 的部分匹配（例如只匹配「我哋」）也可以選，餘下的拼音會繼續組字。

## 更改模式／移除

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode cloud_only
```

```bash
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

不加 `-Mode` 重新執行 `install.ps1`（例如更新版本後）會保留目前的模式。`uninstall.ps1` 會還原所有改動，加 `-PurgeCache` 會連快取一併刪除。

## 已知限制

- 小狼毫要有按鍵才會更新候選，所以 `rime_slot`、`cloud_first`、`cloud_only` 的 Google 候選要等約0.3秒，由背景程式發送一下 `F24` 鍵提示刷新。不在組字時 `F24` 會傳到目前的程式，一般程式不會有反應。
- 刷新那一刻，選字游標會回到第一個候選。
- 連按兩下左 Shift 時，狀態圖示可能閃一下「英」。
- 連按五下 Shift 會觸發 Windows「相黏鍵」提示，建議在「設定 → 協助工具 → 鍵盤」關閉相黏鍵的快速鍵。
- 耶魯方案不支援耶魯的聲調寫法（例如 `yaht` 的 h）；這類輸入可以交給 Google，Google 認得。

## 授權與鳴謝

- 本專案程式碼以 [MIT](LICENSE) 授權。
- `rime/jyut6ping3_yale.schema.yaml` 的拼寫規則來自 [CanCLID/rime-cantonese-schemes](https://github.com/CanCLID/rime-cantonese-schemes)，以 [LGPL-3.0](LICENSES/LGPL-3.0.txt) 授權。
- 詳見 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。感謝小狼毫、librime、librime-lua 和 rime-cantonese 的開發者。

技術細節（架構、引擎、全部設定項目）見 [docs/TECHNICAL.md](docs/TECHNICAL.md)。本專案的程式碼主要由 Claude（Anthropic）編寫，各階段用過的模型版本和設計決定見 [docs/DEVELOPMENT_LOG.md](docs/DEVELOPMENT_LOG.md)。
