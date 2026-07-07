# Connect ChatGPT to your MetaWhisp vault

**Caveat:** as of 2026-05-12, ChatGPT Desktop **doesn't support MCP** the way Claude Desktop / Cursor do. OpenAI has its own (web-based) Connectors API, which works differently.

If something has changed by the time you're reading this — check for updates at https://platform.openai.com/docs.

## Option 1 — ChatGPT Custom GPT with File Search (available now)

This option works today. But it **uploads files to OpenAI** — your data goes to their servers (on one hand, that's how you already use ChatGPT; on the other, voices/meetings contain personal material).

1. Do a **bulk export** in MetaWhisp Settings.
2. In your Obsidian vault, find the `MetaWhisp/` folder and zip it:
   ```bash
   cd ~/Documents/Obsidian\ Vault
   zip -r metawhisp-export-$(date +%Y-%m-%d).zip MetaWhisp/
   ```
3. Go to https://chatgpt.com/gpts/editor → Create new GPT.
4. Configure → Knowledge → Upload files → upload the zip (or the unpacked folder).
5. Give the GPT a name like "My MetaWhisp Memory".
6. In Instructions, put: *"Use the uploaded MetaWhisp vault to answer questions about my dictations, meetings, tasks, and memories. Reference the filename when citing."*
7. Save it, then talk to this GPT whenever you want to pull in context from MetaWhisp.

**Downsides:** you have to re-upload periodically when the vault changes. The files are static inside OpenAI.

## Option 2 — Wait for MCP support in ChatGPT Desktop

Anthropic announced MCP in late 2024; OpenAI hasn't picked it up yet (or has — I wrote this in May 2026, check what's current). If ChatGPT Desktop adds MCP, the config will look like Claude Desktop / Cursor (the same `filesystem-MCP` package).

You'll likely connect it via `/Library/Application Support/ChatGPT/` or a similar path.

## Option 3 — Use Claude / Cursor instead of ChatGPT for these cases

If you have Claude or Cursor, they **already** support MCP. For queries like "find what I said about X in my voice notes" — those are better through them. Keep ChatGPT for other tasks.

## Why this file exists if there's no working option

So you don't spend an hour searching for "how do I connect ChatGPT to MetaWhisp" and come up empty — now you know right away: for now you can't, come back in 3-6 months, or use a Custom GPT with file upload as a workaround.
