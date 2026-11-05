# The Thinking Notebook

A Mac notebook that thinks with you. Highlight any part of your writing and press Return: the AI leaves short questions in the margin beside it. Click a margin note to push back, ask why, and keep the thread going.

## Download

**[Download the latest .dmg](https://github.com/nikhil-kunapareddy/the-thinking-notebook/releases/latest)**: open it and drag the app into Applications. Requires macOS 14+, on Apple silicon or Intel.

The app isn't signed with an Apple Developer ID yet, so the first launch shows a warning. Open **System Settings → Privacy & Security** and click **Open Anyway**.

## Build from source

```bash
./scripts/build-app.sh --open      # build/The Thinking Notebook.app
./scripts/make-dmg.sh              # build/TheThinkingNotebook-<version>.dmg
```

Needs the Swift toolchain (Command Line Tools are enough; Xcode is not required), and one AI provider (below).

## Releases

CI (`.github/workflows/build.yml`) builds a universal app and a .dmg on every push; the .dmg is attached to the run as an artifact. To publish a release anyone can download:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

## Using it

| Action | How |
|---|---|
| Get a margin note | Highlight text, press Return (or ⌘Return, per Settings). Return with nothing highlighted is a normal new line. |
| Open a thread | Click a margin note. Esc or a click on the page collapses it. |
| Move a note | Right-click it → Move to Left/Right Margin. |
| New note | ⌘N |
| Settings | ⌘, or the gear at the bottom of the sidebar. |

## Settings

- **General:** send key (Return or ⌘Return); what the AI sees (only the highlight, or the highlight plus the whole note as background); custom instructions added to every request.
- **AI:** pick a provider, then a model. Use Test connection to check it.
  - On this Mac: **Claude Code** (`claude` CLI, your login), **Codex CLI** (`codex`, your login), **Ollama** (local models).
  - Cloud APIs: **Anthropic**, **OpenAI**, **Google Gemini**, **xAI**, **Mistral**, **DeepSeek**, **Groq**, **OpenRouter**, or any **OpenAI-compatible** endpoint (Azure OpenAI, LM Studio, Together…). API keys are stored in the macOS Keychain.
- **Notes:** the folder notes live in (default `~/Documents/Thinking Notebook`), with Change… and Reveal in Finder.
- **Appearance:** theme (System / Light / Dark), page text size, margin note size.

## Page rules

- By default the AI sees only what you highlight, plus its own margin threads. The rest of the note never leaves your Mac unless you turn on "plus the rest of the note" in Settings → General.
- The page holds only your plain text. Pasting or dropping images, files or rich text is blocked.
- The AI writes only in the margins, never on the page. Notes go in whichever margin is emptier near their words. Narrow windows fold everything into the right margin.
- The page shows no marks from the AI. A note's words get a light tint only while you hover over or open that note.

## Files on disk

- Each note is a plain Markdown file in the notes folder, named after its first line (`Signup redesign.md`, `Signup redesign 2.md` for a duplicate title). Renaming the first line renames the file.
- Margin notes live in a hidden `.thinking/` folder beside them: `.thinking/<file>.md.json`.
- Edits made in other apps (Obsidian, VS Code, iCloud sync) show up when you switch back to the app.
- Deleting a note moves its file to the Trash.
- Notes from the first version (JSON in `~/Library/Application Support/The Thinking Notebook/Notes/`) are copied into the folder once. The old files are left in place.

## How it works

- `LLM.swift`: the provider list, the `LLMProvider` interface, and Keychain storage.
- `CLIProviders.swift`: runs `claude -p` (no tools, no user settings or hooks, no MCP, no session history) and `codex exec` (read-only sandbox, ephemeral).
- `APIProviders.swift`: Anthropic Messages API over HTTP (structured output via `output_config.format`, SSE streaming, refusal fallbacks), plus one OpenAI-compatible client for every other cloud provider and Ollama.
- `Thinker.swift`: prompts and per-note logic (sending highlights, anchoring quotes, picking a margin, threads).
- `NoteStore.swift`: Markdown files, sidecars, renames, reloads, migration.
- `NoteTextEditor.swift`: a TextKit 1 `NSTextView` page with both margins hosted inside it, so notes scroll with their words.

Build note: the macOS 27 SDK turns `@State` into a macro whose plugin ships only with Xcode. The code uses `@ViewState`, a typealias for the underlying property wrapper, so it builds with the Command Line Tools alone.
