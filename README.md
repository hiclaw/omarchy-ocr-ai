# OCR AI

Screenshot a region, read its text with OCR, and answer with AI — in one
keypress, without leaving what you were doing.

```
SUPER + SHIFT + O   →   drag a region   →   the answer streams into a corner card
```

## What it does

1. You press the shortcut. The screen freezes and you drag a region.
2. The region is OCR'd. The text also goes to the clipboard (unless
   `copy_ocr_to_clipboard` is off), so an existing "OCR to clipboard" habit
   keeps working.
3. A small card rises in the corner and streams an AI answer about that text.
   The recognized text stays visible in a faint strip at the top, so you can
   always check what the AI actually read.

Nothing shows while you drag — no window, no focus change, no overlay to catch
the screenshot. Cancel the drag and the plugin exits silently, with no error and
no trace. If the region has no text in it, the card says so in one muted line
instead of vanishing: "nothing happened" and "something is broken" should not
look the same.

## Requirements

| Tool | Package | Purpose |
|---|---|---|
| `hyprpicker` | `hyprpicker` | freezes the screen while you select |
| `slurp` | `slurp` | region selection |
| `grim` | `grim` | captures the region |
| `tesseract` | `tesseract` + a language pack | OCR |
| `wl-copy` | `wl-clipboard` | copies the recognized text |

If one of these is missing, the card names it instead of failing silently.

OCR defaults to `eng`. A language pack is a separate package (e.g.
`tesseract-data-chi_sim` for Simplified Chinese) and has to be installed before
that language can be selected — see `ocr_langs`.

You also need a command that reads text on stdin and answers on stdout. The
plugin ships with a placeholder for it, and says so the first time you use it:

```
AI command not found: your-ai-command
```

Set it in your own config — see [Configuration](#configuration).

## Installing

```bash
omarchy plugin add https://github.com/hiclaw/omarchy-ocr-ai --enable
```

Or copy the folder in by hand:

```bash
cp -r claw.ocr-ai ~/.config/omarchy/plugins/
omarchy-shell shell rescanPlugins
omarchy plugin enable claw.ocr-ai
```

Then bind it in `~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + SHIFT + O")
o.bind("SUPER + SHIFT + O", "OCR AI", "omarchy-shell shell summon claw.ocr-ai '{}'")
```

## Using it

| Input | Effect |
|---|---|
| `Esc` / `Q` | close |
| `1` – `9` | switch action and re-run it on the same text |
| `Space` | collapse to a pill (the answer stays visible while you work) |
| click a chip | same as the number keys |
| `⎘` | copy the answer (not the OCR text — that is already on the clipboard) |
| `✕` | close |

Clicking anywhere else goes to the window you clicked: the panel covers only its
own corner, so it never blocks the work behind it.

## Configuration

Defaults ship in the plugin's own `config.json`. To change them, create
`~/.config/omarchy/ocr-ai.json` — it is merged over the defaults one key at a
time, so you only list what you want to change. Keeping your edits out of the
plugin directory means `omarchy plugin update` never conflicts with them.

The plugin is built fresh on every summon, so a config change applies the next
time you use it — no shell restart. (That is why the manifest deliberately omits
`keepLoaded`.)

| Key | Meaning |
|---|---|
| `position` | `top-right` (default), `top-left`, `bottom-right`, `bottom-left` |
| `ocr_langs` | tesseract language argument, passed straight through |
| `copy_ocr_to_clipboard` | also put the recognized text on the clipboard |
| `ai_command` | argv template for the AI; `~` is expanded, `{pattern}` is substituted per action |
| `actions` | the footer chips, in order |

### `ai_command`

The command receives the OCR text **on stdin**, so anything that reads stdin
works:

```json
{ "ai_command": ["ollama", "run", "qwen2.5:7b"] }
```

If the template contains `{pattern}`, the action's `pattern` is passed there —
useful for commands that take a prompt or a named prompt as an argument:

```json
{ "ai_command": ["claude", "-p", "{pattern}"] }
```

### `actions`

Each action is one chip in the card's footer:

```json
"actions": [
  { "id": "translate", "label": "Translate", "hotkey": "1", "pattern": "translate", "default": true },
  { "id": "summarize", "label": "Summarize", "hotkey": "2", "pattern": "summarize" },
  { "id": "explain",   "label": "Explain",   "hotkey": "3", "pattern": "explain" },
  { "id": "raw",       "label": "Original",  "hotkey": "4", "pattern": "" }
]
```

- `pattern` is whatever your `ai_command` expects — a named prompt, an
  instruction, a flag value. An **empty** pattern means "show me the OCR text,
  do not call the AI": that is the `raw` chip above.
- `hotkey` is optional and defaults to the position (`1`, `2`, …).
- `"default": true` marks the action that runs on its own after a capture.
  Without one, the first action runs.

## How it works

```
shortcut → summon claw.ocr-ai
              │
              ├─ scripts/capture-ocr.sh   hyprpicker freeze → slurp → grim → tesseract
              │                                        stdout: the text
              │                                        exit code: how it ended
              │
              └─ ai_command (stdin = text)  ──────────→  stdout streams into the card
```

The script reports *how* it ended, so the card can tell three cases apart:

| Exit | Meaning | What you see |
|---|---|---|
| `0` with output | text recognized | the card |
| `0` with no output | you cancelled the drag | nothing at all |
| `3` | region selected, no text in it | one muted line |
| `1` | it actually failed (missing tool, capture or OCR error) | the reason, in the card |

The script is a pure "region → text" function: it never writes the clipboard,
never notifies, and touches nothing global. Presentation and everything that
follows are the caller's business, which keeps the two halves independently
testable:

```bash
# the capture half, on its own
plugins/claw.ocr-ai/scripts/capture-ocr.sh | head

# the AI half, on its own
printf 'text to translate' | my-ai-command -p translate
```

## Notes

- The card stays out of the way on purpose. Its layer-shell input region is the
  card itself, so the transparent padding around it — and the space beside the
  pill once it is collapsed — passes clicks straight through to whatever is
  behind it, and it never takes keyboard focus from the window you were using.
  That is also why the number keys work after you click the card, not before.
- The card hangs a fixed gap below (or above) the bar — bar thickness plus 8px,
  read from the live theme and bar position — and is capped so a long answer
  scrolls inside the card instead of growing past the bottom of the screen. The
  footer with the action chips stays visible at every height.
- Pressing the shortcut again while a selection is already open throws that
  selection away and starts a fresh one. Nothing can get stuck invisibly in the
  way: if a capture ever ends up in a bad state, the next press clears it.

## Uninstalling

Turn it off, but keep it installed:

```bash
omarchy plugin disable claw.ocr-ai
```

Or remove it:

```bash
omarchy plugin remove claw.ocr-ai
```

If you installed it with `omarchy plugin add`, that deletes the checkout — the
code stays on GitHub, so the same command brings it back. A folder you copied in
by hand is moved aside to
`~/.config/omarchy/plugins/.claw.ocr-ai.bak.<timestamp>` instead, so nothing is
lost if you change your mind.

Two things removing it does **not** touch:

- the binding in `~/.config/hypr/bindings.lua`. Delete those two lines yourself,
  or the shortcut stays bound to a plugin that is no longer installed.
- `~/.config/omarchy/ocr-ai.json`, if you created one. Delete it too if you are
  not coming back, so a future install starts from clean defaults.

## License

GPL-3.0. See [LICENSE](LICENSE).
