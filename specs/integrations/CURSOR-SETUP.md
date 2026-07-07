# Connect Cursor to your MetaWhisp vault

Cursor (a VSCode-based IDE with Claude integration) supports MCP servers via its UI or a config file. It does the same thing as Claude Desktop — it gives Claude access to your MetaWhisp vault as a set of markdown files.

## What you get

While you work on code, Cursor's built-in Claude can reference your voices / meetings / tasks:
- *"I noted something about this bug before — find it"* → searches `Memories/` and `2026-*/voices/`.
- *"What did we discuss at Wednesday's standup about the cache layer?"* → reads the meetings/ files.
- *"What TODOs do I have about Stripe?"* → searches `tasks/`.

It does not: write back into MetaWhisp (read-only filesystem-MCP).

## Requirements

- Cursor installed → https://cursor.sh
- In MetaWhisp Settings → Obsidian Sync enabled, vault path set, bulk export done

## Steps

### 1. Run `npx` to confirm Node 22+ is installed

```bash
node --version  # v18+ minimum, ideally v22+
npx --version
```

If not — `brew install node`.

### 2. Find the absolute path to your MetaWhisp vault

In MetaWhisp Settings → Obsidian Sync. Take the path, append `/MetaWhisp`.

Example:
```
/Users/you/Documents/Obsidian Vault/MetaWhisp
```

### 3. Open Cursor settings → MCP

Cmd-, (Settings) → find the **MCP** section in the sidebar. If you don't see it — press Cmd-Shift-P → type "MCP" → pick "MCP: Open Settings".

### 4. Add a new MCP server

Either via the UI with the "+ Add new MCP server" button, or open `~/.cursor/mcp.json` directly and add:

```jsonc
{
  "mcpServers": {
    "metawhisp-vault": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/ABSOLUTE/PATH/TO/Obsidian Vault/MetaWhisp"
      ]
    }
  }
}
```

### 5. Restart Cursor

Cmd-Q → launch again.

### 6. Check

In Cursor chat:

> *Read MetaWhisp/README.md from my vault*

It should reply with the contents.

## Notes

- Cursor may ask for permission "Cursor wants to access filesystem" the first time — that's **our** filesystem-MCP, allow it.
- Path completion works: if you type `@MetaWhisp/2026-05-12/` in Cursor chat, it shows the list of files for that day.
- Cursor + filesystem-MCP behaves the same as Claude Desktop, but has a smaller context window — it may be slower on huge files. If your vault has huge transcripts (>20K chars in one file), Cursor may truncate them.

## If it doesn't work — see the troubleshooting in `CLAUDE-DESKTOP-SETUP.md` (shared by both clients).
