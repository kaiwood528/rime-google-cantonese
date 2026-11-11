# Third-party notices

## Included in this repository

### Yale romanisation patch — `rime/jyut6ping3_yale.schema.yaml`

- Source: [CanCLID/rime-cantonese-schemes](https://github.com/CanCLID/rime-cantonese-schemes), file `耶魯拼音方案/jyut6ping3.custom.yaml`
- Authors: 幸延 (a0726h77), 亶父 (tanxpyox); adapted by them from `yale.schema.yaml` of rime/rime-jyutping
- License: GNU Lesser General Public License v3.0 — [LICENSES/LGPL-3.0.txt](LICENSES/LGPL-3.0.txt) (supplements [LICENSES/GPL-3.0.txt](LICENSES/GPL-3.0.txt))
- Changes made here:
  - turned the patch into a standalone schema `jyut6ping3_yale` that includes `jyut6ping3`, so it can sit beside the Jyutping schema
  - removed the preedit rules that showed the Jyutping spelling in brackets
  - added `translator/comment_format` rules that show candidate spelling hints in Yale
  - added `gcloud/*` settings for this project

## Not included (users install them separately)

| Project | Used for | License |
|---|---|---|
| [Weasel 小狼毫](https://github.com/rime/weasel) / [librime](https://github.com/rime/librime) / librime-lua | the input method itself and its Lua plugin support | GPL-3.0 / BSD-3-Clause / BSD-3-Clause |
| [rime-cantonese](https://github.com/rime/rime-cantonese) | Jyutping schema `jyut6ping3` and its dictionary | CC BY 4.0 (dictionary maps ODbL 1.0) |

## Google Input Tools

This project sends romanised input to `inputtools.google.com`, an undocumented endpoint used by Google Input Tools. This project is not affiliated with, endorsed by or supported by Google. "Google" is a trademark of Google LLC.
