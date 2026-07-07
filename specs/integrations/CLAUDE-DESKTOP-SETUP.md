# Connect Claude Desktop to your MetaWhisp vault

Once MetaWhisp syncs voices / meetings / tasks / memories into your Obsidian vault (ITER-035), any MCP-compatible AI client can read this "second memory" as a folder of markdown files. No custom server, no build — just config.

This guide is for **Claude Desktop**. The equivalent for Cursor is in `CURSOR-SETUP.md`.

## What you get

In Claude Desktop you can ask:
- *"What calls did I have this week?"* — Claude reads the `MetaWhisp/2026-05-DD/meetings/` files for the week.
- *"What did I note about the MetaWhisp project?"* — Claude finds every `Memories/MetaWhisp/*.md`.
- *"Show me my active task list"* — `MetaWhisp/<today>/tasks/`.
- *"Read my call with Sam on Wednesday and pull out the action items"* — file read + summarize.

Claude only sees the contents of the vault (read-only). It can't write back into MetaWhisp; that needs ITER-037 Option B (a separate iteration — a native Swift MCP server).

## Requirements

- macOS 13+
- Claude Desktop installed → https://claude.ai/download
- In MetaWhisp Settings → **Obsidian Sync**: sync enabled, vault path set, and **"Export everything to vault"** clicked at least once (otherwise the vault is empty)

## Steps

### 1. Install Node.js (if you don't have it)

Anthropic's `filesystem-MCP` runs via `npx`. Check:

```bash
which node
which npx
```

If empty, install Node 22+:
```bash
brew install node
```

### 2. Find the absolute path to your MetaWhisp vault

Open MetaWhisp Settings → Obsidian Sync. Copy the path shown there. Append `/MetaWhisp` — that's the subdirectory where the app's files live (we don't give Claude access to your **whole** vault, only the MetaWhisp data).

Example full path:
```
/Users/you/Documents/Obsidian Vault/MetaWhisp
```

### 3. Open the Claude Desktop config

```bash
open ~/Library/Application\ Support/Claude/
```

Find (or create) `claude_desktop_config.json`. If the file doesn't exist:

```bash
mkdir -p ~/Library/Application\ Support/Claude
touch ~/Library/Application\ Support/Claude/claude_desktop_config.json
```

### 4. Add the MetaWhisp MCP server to the config

Open `claude_desktop_config.json` in any editor. If the file is empty, paste:

```jsonc
{
  "mcpServers": {
    "metawhisp-vault": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/ABSOLUTE/PATH/TO/YOUR/Obsidian Vault/MetaWhisp"
      ]
    }
  }
}
```

**Replace** the path in the last `args` entry with your real one.

If you already have other MCP servers in this file, just add the `"metawhisp-vault": {...}` block inside the existing `"mcpServers"` object.

### 5. Restart Claude Desktop

Cmd-Q → launch again. On first launch Claude downloads the `@modelcontextprotocol/server-filesystem` package (1-2 seconds).

### 6. Check that it works

In Claude Desktop, ask:

> *Read the file MetaWhisp/README.md from my vault.*

If Claude's reply shows the vault structure — you're connected. If it says "I don't have access to files", the config didn't load; check:

- `claude_desktop_config.json` is valid JSON (run `cat ~/Library/Application\ Support/Claude/claude_desktop_config.json | python3 -m json.tool` — it should print without errors).
- The path exists (`ls "/ABSOLUTE/PATH"` — should show `README.md`, `2026-05-DD/`, `Memories/`, etc).
- You restarted Claude **fully** (Cmd-Q, not just closing the window).

## Security

- Filesystem-MCP is **read-only by default** in this version. Claude can't **write** to your vault or delete anything.
- Access is limited to **only the given path** — the `/MetaWhisp` folder, not your whole vault with your other notes.
- No data leaves your local machine (unless you explicitly ask Claude to publish something).

## What's next

- **To let Claude see fresh data** — just dictate / record calls in MetaWhisp as usual. ITER-035 v2 hooks write new files into the vault automatically, and Claude picks them up on the next request.
- **If you want semantic search** (Claude finding mentions of "Alex" via embeddings, without an exact name match) — that isn't covered by filesystem-MCP yet. It's coming in ITER-036 RAG lifetime chat (via ChatService inside MetaWhisp) OR in the native Swift MCP server (ITER-037 Option B, a separate iteration).

## If something doesn't work

- **"Cannot find module" in the Claude logs** — `npx` isn't on PATH. Run `which npx` in Terminal; if empty, `brew install node`.
- **"ENOENT: no such file or directory"** — the vault path is wrong or the vault doesn't exist. Check with `ls`.
- **"Permission denied"** — Claude Desktop is downloading the npm package for the first time; it may need permission for `~/.npm`. Run `npm config get cache` and make sure the folder is readable.
- **The MCP server list in Claude Desktop doesn't show metawhisp-vault** — the config didn't load. Is the JSON valid? Is the file in the right place?
