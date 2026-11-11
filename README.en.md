[中文](README.md) · **English**

# Weasel × Google Cantonese Suggestions

This project adds Cantonese suggestions from Google Input Tools (marked ☁) to the Cantonese romanization input of [Weasel 小狼毫](https://github.com/rime/weasel) (Rime) on Windows. Weasel still handles typing and picking words. When your spelling is off, or you need a long phrase or a new word, tap the left Shift key twice to use Google's fuzzy matching and vocabulary.

> **Unofficial project.** This project is not affiliated with or endorsed by Google. It uses an undocumented Google Input Tools service that Google may change or stop at any time; Weasel keeps working without it, you just won't see the ☁ suggestions. This is a personal hobby project with no guarantee of maintenance.

## Features

- **Four modes** to match how you type:

  | Mode | Normally | Tap left Shift twice | Best for |
  |---|---|---|---|
  | `rime_first` (default) | Only Weasel's suggestions, in a fixed order | Adds Google's suggestions at the top | People who already type with a romanization |
  | `rime_slot` | 6 suggestions per page: the first 5 from Weasel, the 6th always Google's top pick | Adds the full list of Google's suggestions | Experienced typists who want to see Google's top pick at all times |
  | `cloud_first` | Google's suggestions first, Weasel's after them | Only Weasel's suggestions | — |
  | `cloud_only` | Only Google's suggestions when Google has a result | Only Weasel's suggestions | Beginners and learners; the most forgiving |

- **Two romanization systems**: Jyutping (`jat` = 日) and Yale (`yat` = 日, installed as a separate "粵語拼音（耶魯）" schema).
- **Works offline**: when Google can't be reached, only Weasel's suggestions are used.

## Privacy: what is sent to Google

| Mode | What is sent |
|---|---|
| `rime_first` | The letters you are typing, **only when you tap left Shift twice**. Nothing you type is sent otherwise (the background program only sends a fixed test word now and then to keep its connection open) |
| `rime_slot`, `cloud_first`, `cloud_only` | The letters you are typing, after every keystroke |

- Only the letters are sent (for example `ngodeigamjat`), never text you have already entered, window contents or personal data.
- Results are cached in `%APPDATA%\Rime\gcloud\cache\`. The log file does not record what you type by default.
- Press `` Ctrl+` `` or `F4` to open the schema menu and switch "☁雲端" (cloud) to "本地" (local) at any time to stop all lookups.

## Requirements

- Windows 10 or 11
- [Weasel](https://rime.im/download/) 0.15 or later (only tested with 0.15.0 so far). If it isn't installed, the installer can install it for you with winget.
- The Cantonese schema [rime-cantonese](https://github.com/rime/rime-cantonese). Weasel doesn't include it; if it's missing, the installer can download it for you.

No Python or other software is needed: the background program is compiled during installation with the .NET Framework built into Windows.

## Install

1. Download this project (Code → Download ZIP) and unzip it.
2. Double-click `setup.cmd`. If Windows warns that the file came from the internet, choose Run.
3. Answer two questions (shown in Chinese and English):
   - Which romanization you use: 1) Jyutping (日 = jat) or 2) Yale (日 = yat). Type the number, or simply `jat` or `yat`.
   - How you want to use it: 1) keep Weasel's suggestions and add a 6th one from Google Input Tools (recommended; `rime_slot`); 2) keep Weasel's suggestions and tap left Shift twice to switch to Google (more private; `rime_first`); 3) use Google's suggestions (for beginners; `cloud_only`).

   You can run `setup.cmd` again at any time to choose differently, as often as you like.

The installer checks for Weasel and the Cantonese schema (and offers to install them if missing), copies the plugin, compiles and starts the background program, starts it automatically when you sign in to Windows, puts the chosen schema at the top of the schema menu, and finally redeploys Weasel.

You can also skip the questions and install from the command line, for example:

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode rime_first -Autostart -AddToSchemaList
```

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Yale -Mode cloud_only -Autostart -AddToSchemaList
```

## Usage

- **Tap left Shift twice** (within 0.5 seconds) to switch the current input between cloud and local suggestions as shown in the table above; tap twice again to switch back. It applies only to the letters you are typing at the time; the next word goes back to the default.
- In `rime_first` mode the lookup only starts when you tap Shift twice. Results usually arrive in about 0.3 seconds, during which input pauses briefly.
- A single Shift press works as before: when you are not typing it switches between Chinese and English; while typing, left Shift switches to English temporarily and right Shift enters the letters as they are.
- You can also pick one of Google's partial matches (for example just 我哋); the remaining letters stay in the input.

## Changing the mode and removing

```bash
powershell -ExecutionPolicy Bypass -File install.ps1 -Mode cloud_only
```

To remove the plugin, double-click `uninstall.cmd`. It undoes all of the plugin's changes; Weasel and the Cantonese schema stay installed.

Running `install.ps1` again without `-Mode` (for example after updating) keeps your current mode. Add `-PurgeCache` to `uninstall.ps1` to delete cached results as well.

## Known limitations

- Weasel only refreshes its suggestions after a key press, so in `rime_slot`, `cloud_first` and `cloud_only` modes Google's suggestions take about 0.3 seconds and are shown when the background program presses the `F24` key. When you are not typing, `F24` goes to the active program, which normally ignores it.
- At the moment of that refresh, the selection moves back to the first suggestion.
- When you tap left Shift twice, the status icon may briefly show "英" (English).
- Pressing Shift five times triggers the Windows Sticky Keys prompt. Turn off the Sticky Keys shortcut in Settings → Accessibility → Keyboard.
- Because `rime-gcloud.exe` simulates the `F24` key, some antivirus programs may flag it; you can add it to the allowed list.
- The Yale schema doesn't accept Yale tone spellings (such as the h in `yaht`). Google understands them, so tap left Shift twice for such input.

## Reporting problems

Double-click `diagnose.cmd` and a file named `rime-google-cantonese-report.txt` appears on your Desktop. It contains versions, settings, file checks and recent log lines only, nothing you typed, and your Windows user name and PC name are hidden. Please attach it when you report a problem.

## License and credits

- The code in this project is released under the [MIT](LICENSE) license.
- The spelling rules in `rime/jyut6ping3_yale.schema.yaml` come from [CanCLID/rime-cantonese-schemes](https://github.com/CanCLID/rime-cantonese-schemes) and are licensed under [LGPL-3.0](LICENSES/LGPL-3.0.txt).
- See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for details. Thanks to the developers of Weasel, librime, librime-lua and rime-cantonese.

Technical details (architecture, engines and every setting) are in [docs/TECHNICAL.md](docs/TECHNICAL.md), written in Chinese. Most of the code was written by Claude (Anthropic); the model versions used at each stage and the design decisions are recorded in [docs/DEVELOPMENT_LOG.md](docs/DEVELOPMENT_LOG.md).
