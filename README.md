# OCR AI

Screenshot a region, read its text with OCR, and answer with AI — in one
keypress, without leaving what you were doing.

```bash
# bind it (see "Installing" below for the Hyprland snippet)
SUPER + SHIFT + O   →  drag a region  →  the answer streams into a corner card
```

## What it does

1. You press the shortcut. A frozen screen appears and you drag a region.
2. The region is OCR'd. The recognized text goes to the clipboard, so the
   existing "OCR to clipboard" habit keeps working unchanged.
3. A small card rises in the corner and streams an AI answer about that text.
   The text itself is kept visible in a faint strip at the top, so you can
   always check what the AI actually read.

Nothing is shown while you drag — no window, no focus change, no overlay to
catch the screenshot. Cancel the drag (or select something with no text) and
the plugin exits silently, with no error and no trace.

## Requirements

| Tool | Package | Purpose |
|---|---|---|
| `hyprpicker` | `hyprpicker` | freezes the screen while you select |
| `slurp` | `slurp` | region selection |
| `grim` | `grim` | captures the region |
| `tesseract` | `tesseract` + a language pack | OCR |
| `wl-copy` | `wl-clipboard` | clipboard |

If any of these is missing the card says so instead of failing silently.

OCR language defaults to `eng`; see `ocr_langs` below. A language pack is a
separate package (e.g. `tesseract-data-chi_sim` for Simplified Chinese) — note
that language packs must be installed for the language to be selectable.

## Installing

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
| `1` – `9` | switch action and re-run on the same text |
| `Space` | collapse to a pill (the answer stays visible while you work) |
| click a chip | same as the number keys |
| `⎘` | copy the answer (not the OCR text — that is already on the clipboard) |
| `✕` | close |

Clicking anywhere else on your desktop goes to the window you clicked; the
panel only covers its own corner, so it never blocks work behind it.

## Configuration

Defaults ship in the plugin's own `config.json`. To override, create
`~/.config/omarchy/ocr-ai.json` — it is merged over the defaults key by key,
so you only list what you want to change. Keeping edits out of the plugin
directory means `omarchy plugin update` never conflicts with them.

The plugin is loaded fresh on every use, so a config change is picked up by
the next summon — no shell restart. (This is why the manifest deliberately
omits `keepLoaded`.)

```json
{
  "position": "top-right",
  "ocr_langs": "eng",
  "copy_ocr_to_clipboard": true,
  "ai_command": ["~/tools/bai", "-P", "river", "-p", "{pattern}"],
  "actions": [
    { "id": "translate", "label": "翻译", "hotkey": "1", "pattern": "fanyi", "default": true },
    { "id": "summarize", "label": "总结", "hotkey": "2", "pattern": "dcm" },
    { "id": "explain",   "label": "解释", "hotkey": "3", "pattern": "explain_terms" },
    { "id": "raw",       "label": "原文", "hotkey": "4", "pattern": "" }
  ]
}
```

| Key | Meaning |
|---|---|
| `position` | `top-right` (default), `top-left`, `bottom-right`, `bottom-left` |
| `ocr_langs` | tesseract language argument, passed straight through |
| `copy_ocr_to_clipboard` | put the OCR result on the clipboard as well |
| `ai_command` | argv template; `~` is expanded, `{pattern}` is substituted per action |
| `actions` | footer chips, in order. `hotkey` is optional and defaults to the position (`1`, `2`, …). An empty `pattern` means "show the OCR text, do not call the AI". The action marked `"default": true` runs automatically; without one, the first action does |

The AI command receives the text **on stdin**, so it can be anything that reads
stdin — `bai`, a local model, a shell one-liner:

```json
{ "ai_command": ["ollama", "run", "qwen2.5:7b"] }
```

## How it works

```
shortcut → summon claw.ocr-ai
              │
              ├─ scripts/capture-ocr.sh   hyprpicker freeze → slurp → grim → tesseract
              │                                        stdout: the text (empty = cancel)
              │
              └─ ai_command (stdin = text)  ──────────→  stdout streams into the card
```

The script is a pure "region → text" function: it never writes the clipboard,
never notifies, and touches nothing global. Presentation and follow-up are the
caller's business, which keeps the two halves independently testable:

```bash
# the capture half, on its own
plugins/claw.ocr-ai/scripts/capture-ocr.sh | head

# the AI half, on its own
printf 'text to translate' | ~/tools/bai -P river -p fanyi
```

## Notes

- `bai` records the profile it was invoked with as its "last profile". Because
  this plugin always passes `-P` explicitly, doing a lookup here also sets
  `last_profile`. Use `-s <file>` or a different `ai_command` if that matters.
- The capture script treats a second shortcut press during a drag as a no-op,
  so you cannot cancel a selection that way — press `Esc`, as with any slurp
  selection.
