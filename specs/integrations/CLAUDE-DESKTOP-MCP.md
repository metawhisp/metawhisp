# Connect MetaWhisp to Claude Desktop via MCP

Once set up, Claude Desktop gets direct access to your MetaWhisp memory — it can search your meeting notes, tasks, and facts about people and projects, and use them in any conversation.

## What Claude can do with MetaWhisp connected

- **`search_memories(query)`** — search saved memories (facts, opinions, goals)
  - "find what I said about the ChatApp CTO"
  - "what memories do I have about Project Alpha"
- **`list_tasks(status)`** — current tasks (pending / completed / all)
- **`recent_conversations(limit, since_days)`** — recent calls with title + overview
- **`search_conversations(query)`** — search across meetings and voice notes
  - "find the call where we discussed the budget"
  - "what was Monday's meeting about"

## Setup

### 1. Make sure MetaWhisp is running

MetaWhisp writes a snapshot of its data to `~/Library/Application Support/MetaWhisp/mcp-snapshot.json` every 5 minutes. The MCP server reads it and answers Claude.

If the snapshot doesn't exist yet — start/restart MetaWhisp and wait up to 5 minutes (or open Settings → AI, which triggers an early snapshot).

### 2. Find the path to the binary

After building MetaWhisp, the binary is here:
```
/Applications/MetaWhisp.app/Contents/Resources/metawhisp-mcp
```

If you installed from source via `swift build`:
```
<PATH TO REPO>/.build/debug/metawhisp-mcp
```

### 3. Open the Claude Desktop config

```bash
open ~/Library/Application\ Support/Claude/
```

If `claude_desktop_config.json` doesn't exist — create it. If it does — add a `metawhisp` block to `mcpServers`.

### 4. Add the server

Minimal config:

```jsonc
{
  "mcpServers": {
    "metawhisp": {
      "command": "/Applications/MetaWhisp.app/Contents/Resources/metawhisp-mcp"
    }
  }
}
```

If you already have other MCP servers in the config, add only the `"metawhisp": { ... }` entry inside the existing `mcpServers`.

### 5. Restart Claude Desktop

Fully quit Claude Desktop (Cmd+Q) and open it again. After launch, a tools icon should appear in the bottom-right of the chat window — clicking it shows the list of MCP servers. `metawhisp` should be there, green.

### 6. Check

In a new chat with Claude, ask:
> What pending tasks do I have in MetaWhisp?

or

> Find memories about <any topic of yours>.

Claude will automatically call `list_tasks` or `search_memories` and return the result.

## Troubleshooting

**The MCP server didn't show up in Claude Desktop**
- Check the path to the binary — it must be executable: `ls -la /Applications/MetaWhisp.app/Contents/Resources/metawhisp-mcp`
- If the binary isn't executable: `chmod +x <path>`
- Check the Claude Desktop logs: `~/Library/Logs/Claude/mcp.log`

**"MetaWhisp snapshot not available"**
- Open MetaWhisp, wait 5 minutes (or restart the app)
- Check the file exists: `ls -la ~/Library/Application\ Support/MetaWhisp/mcp-snapshot.json`
- If it's missing — check the MetaWhisp logs: `tail ~/Library/Logs/MetaWhisp.log | grep MCPSnapshot`

**Tools aren't being called**
- Claude sometimes doesn't realize the tools are available until asked explicitly — try: "you have access to MetaWhisp via MCP, try list_tasks"
- The tool names themselves: `search_memories`, `list_tasks`, `recent_conversations`, `search_conversations`

## What the MCP server does NOT do (yet)

- **Doesn't write** anything to MetaWhisp — read-only
- **Doesn't have** semantic search via embeddings (substring match only)
- **Doesn't react** to live events — the snapshot refreshes every 5 minutes

These are coming in later iterations.

## Security

- The MCP server runs **locally**. No network connections.
- Claude Desktop launches the binary as a child process over stdio.
- The snapshot file sits on your disk. It's never sent anywhere.
- To disable — remove the `metawhisp` block from `claude_desktop_config.json` and restart Claude.
