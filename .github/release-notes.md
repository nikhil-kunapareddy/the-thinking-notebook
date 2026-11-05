A Mac notebook that thinks with you. Highlight any part of your writing and press Return; the AI leaves short questions in the margin beside it.

## Install

1. Download `TheThinkingNotebook-<version>.dmg` below and open it.
2. Drag **The Thinking Notebook** into **Applications**.
3. Open it. The first time, macOS warns that it can't verify the app, because it isn't signed with an Apple Developer ID yet. To open it anyway:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to The Thinking Notebook.
   - Or, in Terminal: `xattr -dr com.apple.quarantine "/Applications/The Thinking Notebook.app"`

## Set up an AI

Open **Settings (⌘,) → AI** and pick one:

- **Claude Code** or **Codex CLI**: uses the CLI you already have installed and logged in.
- **Ollama**: runs models locally on your Mac.
- **Anthropic, OpenAI, Google Gemini, xAI, Mistral, DeepSeek, Groq, OpenRouter**, or any OpenAI-compatible endpoint: paste an API key. It's stored in your macOS Keychain.

Then press **Test connection**.

Requires macOS 14 or later. Runs on Apple silicon and Intel.
