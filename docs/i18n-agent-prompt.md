# Vox.md — Add Localization for {{LANGUAGE_NAME}} ({{LANGUAGE_CODE}})

## Your assignment

You are adding a single language translation to the Vox.md iOS app.
**Your language: {{LANGUAGE_NAME}} — locale code `{{LANGUAGE_CODE}}`**

Work entirely within the repo at `/Users/codybontecou/projects/Vox.md`.
Create a branch, add translations to two JSON files, register the locale in
the Xcode project, commit, and stop. Do not change any Swift source files.

---

## Language assignments

Run one agent per row. Each agent substitutes its row's values for
`{{LANGUAGE_NAME}}` and `{{LANGUAGE_CODE}}` throughout this prompt.

| # | Language | `{{LANGUAGE_CODE}}` | Notes |
|---|---|---|---|
| 1 | Spanish | `es` | Latin-American Spanish |
| 2 | Simplified Chinese | `zh-Hans` | Mainland China |
| 3 | Hindi | `hi` | Devanagari script |
| 4 | Arabic | `ar` | Modern Standard Arabic; RTL |
| 5 | Bengali | `bn` | Bangladesh / West Bengal |
| 6 | Portuguese (Brazil) | `pt-BR` | Brazilian Portuguese |
| 7 | Russian | `ru` | |
| 8 | Japanese | `ja` | Use kanji + kana naturally |
| 9 | Traditional Chinese | `zh-Hant` | Taiwan / Hong Kong |
| 10 | French | `fr` | Metropolitan French |
| 11 | German | `de` | Standard German |
| 12 | Korean | `ko` | Hangul |
| 13 | Vietnamese | `vi` | |
| 14 | Turkish | `tr` | |
| 15 | Italian | `it` | |
| 16 | Polish | `pl` | |
| 17 | Indonesian | `id` | Bahasa Indonesia |
| 18 | Ukrainian | `uk` | |
| 19 | Dutch | `nl` | |
| 20 | Thai | `th` | Thai script |
| 21 | Urdu | `ur` | Nastaliq / RTL |
| 22 | Tamil | `ta` | Tamil script |

---

## Step 1 — Create a feature branch

```bash
cd /Users/codybontecou/projects/Vox.md
git checkout main
git pull
git checkout -b i18n/{{LANGUAGE_CODE}}
```

---

## Step 2 — Translate the strings

You must provide translations for **two files**. Both use the same
[`.xcstrings` JSON format](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog).

### Format for adding a translation

For every key in the file, add a new sibling entry under `"localizations"`
alongside the existing `"en"` block:

```json
"{{LANGUAGE_CODE}}" : {
  "stringUnit" : {
    "state" : "translated",
    "value" : "YOUR TRANSLATION HERE"
  }
}
```

### Format specifiers — do not translate, do not remove

Strings containing `%.1f`, `%d`, `%@` are printf-style placeholders:

| Specifier | Meaning | Example |
|---|---|---|
| `%.1f` | Decimal number with one fractional digit | `3.2` |
| `%d` | Integer | `5` |
| `%@` | String (model name) | `whisper-base` |

Keep specifiers **in the same position** unless your language requires the
number to appear in a different grammatical position. If you reorder, use
positional specifiers: `%1$d` = first argument, `%2$d` = second argument.

Example reorder for a language where "ago" comes before the number:
```
"ago %dm" → "%1$dm" can stay as "%dm" if order is same,
or swap to "hace %dm" (Spanish keeps same order, no change needed)
```

### 2a — Main app: `Voxboard/Localizable.xcstrings`

Below is the **complete current state** of the file. For each key, add your
`{{LANGUAGE_CODE}}` translation block. The English values are your source.

**String reference table (key → English value | context):**

| Key | English value | Context / notes |
|---|---|---|
| `just now` | `just now` | Relative timestamp < 60 s ago |
| `%dm ago` | `%dm ago` | Relative timestamp N minutes ago (e.g. "5m ago") |
| `%dh ago` | `%dh ago` | Relative timestamp N hours ago (e.g. "2h ago") |
| `%ds` | `%ds` | Duration: seconds only (e.g. "42s") |
| `%dm %ds` | `%dm %ds` | Duration: minutes and seconds (e.g. "1m 23s") |
| `%.1f / 15 MIN FREE` | `%.1f / 15 MIN FREE` | Usage meter — ALL CAPS by design; keep caps in translation |
| `%.1f / 15 min free used` | `%.1f / 15 min free used` | Settings upgrade row |
| `%.1f min free remaining.` | `%.1f min free remaining.` | Paywall status sentence |
| `(cleared)` | `(cleared)` | Debug log placeholder after clearing |
| `(empty)` | `(empty)` | Debug log placeholder when empty |
| `App preferences, upgrade, about, and debug` | `App preferences, upgrade, about, and debug` | Accessibility hint — Settings tab |
| `Configure automatic transcript file export` | `Configure automatic transcript file export` | Accessibility hint — Files tab |
| `Could not access microphone` | `Could not access microphone` | Mic permission error |
| `Download and select Whisper or Parakeet AI models` | `Download and select Whisper or Parakeet AI models` | Accessibility hint — Model tab |
| `Failed to load model` | `Failed to load model` | AI model init error |
| `Free Tier` | `Free Tier` | Status badge — user on free plan |
| `Limit Reached` | `Limit Reached` | Status badge — free limit hit |
| `Listening` | `Listening` | Status badge — mic is active |
| `Mic unavailable` | `Mic unavailable` | IPC error message |
| `Model load failed` | `Model load failed` | IPC error response |
| `Model not found` | `Model not found` | IPC error response |
| `Model not found: %@` | `Model not found: %@` | Error with model ID appended |
| `No audio captured` | `No audio captured` | IPC error — no audio data |
| `No audio was captured` | `No audio was captured` | User-facing recording error |
| `No speech detected` | `No speech detected` | Transcription found silence |
| `Not set` | `Not set` | Folder picker placeholder |
| `Off` | `Off` | Status badge — listening disabled |
| `Opens an email draft to contact support with app diagnostics` | `Opens an email draft to contact support with app diagnostics` | Accessibility hint — Feedback button |
| `Record and transcribe audio in real time` | `Record and transcribe audio in real time` | Accessibility hint — Listen tab |
| `Send Feedback` | `Send Feedback` | Accessibility label — Feedback button |
| `Something went wrong` | `Something went wrong` | Generic error fallback |
| `TRANSCRIBING` | `TRANSCRIBING` | Animated indicator base text — ALL CAPS by design |
| `Unlimited` | `Unlimited` | Status badge — purchased |
| `Unlimited is already unlocked on this device.` | `Unlimited is already unlocked on this device.` | Paywall status sentence |
| `You've used all your free transcription time.` | `You've used all your free transcription time.` | Paywall limit sentence |

**Example — adding Spanish to one entry:**

```json
"just now" : {
  "comment" : "Relative timestamp for events less than 60 seconds ago",
  "extractionState" : "manual",
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "just now"
      }
    },
    "es" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "ahora mismo"
      }
    }
  }
}
```

Apply this pattern to every key in the file using the Read and Edit tools.
Read the full file first, then write all changes at once using the Write tool
to avoid partial edits.

### 2b — Keyboard extension: `Voxboard Keyboard/Localizable.xcstrings`

Smaller file — only 4 strings. Same format as above.

| Key | English value | Context |
|---|---|---|
| `Limit reached — open Vox.md to unlock` | `Limit reached — open Vox.md to unlock` | Keyboard toolbar error — free limit hit |
| `No Model` | `No Model` | Keyboard toolbar — no model downloaded |
| `No speech detected` | `No speech detected` | Transcription error in keyboard extension |
| `Transcription timed out — try again` | `Transcription timed out — try again` | Keyboard toolbar error — timeout |

---

## Step 3 — Register the locale in the Xcode project

Open `Voxboard.xcodeproj/project.pbxproj` and find the `knownRegions` array
(search for `knownRegions`). It currently looks like:

```
knownRegions = (
    en,
    Base,
);
```

Add `{{LANGUAGE_CODE}}` as a new entry:

```
knownRegions = (
    en,
    Base,
    {{LANGUAGE_CODE}},
);
```

Use the Edit tool with the exact surrounding text to avoid clobbering other
agents' additions if they have already been merged. Only add your code;
do not remove any existing entries.

---

## Step 4 — Verify JSON validity

After editing both `.xcstrings` files, run:

```bash
python3 -c "import json; json.load(open('Voxboard/Localizable.xcstrings'))" && echo "main app OK"
python3 -c "import json; json.load(open('Voxboard Keyboard/Localizable.xcstrings'))" && echo "keyboard OK"
```

Both must print their `OK` line. Fix any JSON syntax errors before continuing.

---

## Step 5 — Commit

```bash
cd /Users/codybontecou/projects/Vox.md
git add Voxboard/Localizable.xcstrings \
        "Voxboard Keyboard/Localizable.xcstrings" \
        Voxboard.xcodeproj/project.pbxproj
git commit -m "i18n: add {{LANGUAGE_NAME}} ({{LANGUAGE_CODE}}) translations"
```

---

## Quality guidelines

- **Natural, not literal.** Translate meaning, not word-for-word.
- **Audience:** Mobile app users — keep translations concise and clear.
- **ALL CAPS strings** (`TRANSCRIBING`, `%.1f / 15 MIN FREE`, `Limit Reached`,
  etc.) are ALL CAPS intentionally (app design aesthetic). Translate the text
  but preserve ALL CAPS. Exception: scripts that have no case distinction
  (Arabic, Hindi, Thai, Japanese, etc.) — just translate naturally.
- **Format specifiers** (`%d`, `%.1f`, `%@`) must be preserved exactly.
- **Accessibility hints** are full sentences — use natural punctuation for
  your language.
- **Error messages** should be brief and actionable.
- **RTL languages** (Arabic `ar`, Urdu `ur`): provide right-to-left text
  naturally; iOS handles layout direction automatically.
- Do not add any keys that are not already in the English file.
- Do not remove or modify existing `"en"` entries.

---

## What NOT to do

- Do not modify any `.swift` source files.
- Do not modify `Info.plist`.
- Do not add new keys to the `.xcstrings` files beyond those listed above.
- Do not run `xcodebuild` — translation work only.
- Do not push to `main` directly — commit to your `i18n/{{LANGUAGE_CODE}}` branch only.

---

## Done

When the commit is made and both JSON files pass validation, your task is
complete. A human reviewer will merge all `i18n/*` branches into `main`.
