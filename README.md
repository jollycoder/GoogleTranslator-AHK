# Google Translate for AutoHotkey v2

A Google Translate client for Windows that lets you translate selected text in any application with a hotkey or work in a separate translator window. It supports speech for both the source text and the translation. No registration or personal API key is required.

## Quick start

1. Install AutoHotkey v2.0 and run the script.
2. On the first run, wait while the language data is prepared. If the language selection window opens, review the suggested pair or choose the languages yourself, then click **Save**.
3. To translate text in any application, select it and press `Ctrl+C+C`: hold `Ctrl` and press `C` twice in succession. The translation appears in the translator window.
4. Double-click the program's tray icon to open the translator window.

## Language setup

To choose the translation direction automatically, the program uses a “native language — second language” pair. The native language is your primary language, into which foreign text is usually translated; the second is the language you work with most often. For example, with a Russian–English pair, English text is translated into Russian and Russian text into English. If the direction cannot be determined, the program translates into the native language.

The language pair sets the default direction but does not restrict manual selection: you can choose any supported source and target languages in the translator window.

On the first run, the program tries to select the pair automatically. It first checks the Windows preferred language list. If two distinct supported languages are found, the first two are saved automatically. If the program needs additional information to complete the pair—such as the Windows display language, regional settings, the current keyboard layout, or English as a fallback—it shows a prefilled selection window and asks you to confirm the suggestion. If the second language cannot be inferred reliably, you need to choose it yourself. The selected pair is saved and used on subsequent runs.

You can change the pair at any time: right-click the program's tray icon, select `Languages...`, choose the native and second languages, and click **Save**. The program restarts with the new pair. You can also open the language selection window at startup by passing the `--language-setup` parameter to the script.

### Automatic translation direction

When translating selected text, the program tries to determine which language in the pair it belongs to and selects the other language as the target. It considers the writing system and characteristic clues for certain languages, while Google continues to detect the source language automatically. If the direction remains ambiguous, the program first translates into the native language. If Google detects the source language as matching the selected target, the program retries once in the opposite direction.

## Translator window

In the top field, you can type or paste the source text, select the source and target languages, then click the translate button or press `Enter`. If a fragment is selected in the field, that fragment is translated. To insert a line break, press `Shift+Enter`.

The reverse translation button translates text from the bottom field in the opposite direction. Pressing `Enter` in the bottom field does the same. The buttons next to the language lists swap the source and target languages.

You can resize the window with the mouse: dragging the top edge enlarges the top text field, while dragging the bottom edge enlarges the bottom field. To change the font size of an individual field, point to it, hold `Ctrl`, and scroll the mouse wheel.

## Tray menu

Right-click the program's tray icon to open the settings menu. The main commands are:

| Command | Purpose |
| --- | --- |
| `Open GUI` | Open the translator window |
| `Languages...` | Change the “native language — second language” pair |
| `Dark Theme` | Switch between dark and light themes |
| `Use Multiple GUIs` | Open a separate window for each new translation |
| `Windowless Mode` | Translate selected text without showing the window and replace the selection with the translation. If you switch to another window or field before the translation arrives, it is only copied to the clipboard |
| `Copy Main Translation` | Automatically copy the main translation to the clipboard |
| `Add To Startup` | Enable or disable starting the program with Windows |
| `Clear Cache` | Clear cached translations and speech |

Double-clicking the icon runs `Open GUI`. The menu also provides commands for opening the script folder, reloading the program, and exiting. When the source `.ahk` file is running, the `Edit This Script` command is also shown.

## Key features

- The program automatically chooses the direction within the saved language pair.
- Additional meanings and translation variants may be shown for individual words.
- Long text is automatically split into request-sized parts and assembled into a single translation.
- Line breaks inside a sentence, as in text copied from PDF files or e-mail, are joined before translation, so the sentence is translated as a whole. The source text itself is shown unchanged.
- Dark and light themes, multiple translator windows, and windowless operation are supported.

## Cache

Translations and speech are stored in a cache on disk and remain available after the program restarts. When the cache fills up, the oldest entries are replaced. Its size is limited to 100 MB by default; you can change this value with `Cache Size MB` in `settings.ini`. Use `Clear Cache` in the tray menu to clear it.

## Speech

The playback buttons next to the text fields let you hear the source text or translation, pause playback, and stop it. For individual English words, Oxford dictionary pronunciation is used when available; Google TTS is used otherwise.

Speech playback uses Windows Media Foundation components. Windows N/KN editions may require the Media Feature Pack.

## System requirements

- Windows 10/11
- AutoHotkey v2.0 when running the source `.ahk` file
- An internet connection for initial setup, new translations, and speech
- A writable script folder: settings, the language list, and the cache are stored there

Text being translated or spoken is sent to Google services. The program uses the same Google Translate interfaces as Google's own browser-side clients (Google Translate website translation and the Google Dictionary extension), so a personal API key is not required. The API keys in the source code are the public keys built into those Google clients, not the author's personal keys: they are not linked to anyone's Google Cloud account, and nobody is billed for using the program. Google may change these interfaces. This is an unofficial project and is not affiliated with or endorsed by Google.

## Author and license

Author: jollycoder (known as teadrinker on the AutoHotkey forums).

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
