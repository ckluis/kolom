# Install Kolom with an AI agent

These are instructions for an AI coding agent (Claude Code, Codex, Cursor or similar) running on the user's Mac. If you are a person, run `./scripts/install.sh` yourself, or paste this into your agent:

```
Read https://github.com/ckluis/kolom/blob/main/INSTALL-WITH-AN-AGENT.md and follow it.
```

## Ground rules for the agent

- Explain before you change anything, and get the user's go-ahead.
- Never use `sudo`, never disable SIP, never edit the TCC database and never script System Settings. The Accessibility permission is the user's click.
- Do nothing outside these steps on the user's GitHub account. Starring is optional and needs a clear yes.

## Steps

1. **Tell the user what Kolom is and does.** Kolom is a free, MIT-licensed tiling window manager for macOS. It arranges real windows into a horizontally scrolling strip of columns, one strip per display. While it manages windows it may temporarily move displays corner to corner, so columns slide off screen edges cleanly; the pointer still crosses between displays as before, and the real arrangement returns on pause or quit. It needs the Accessibility permission. It is alpha software. Ask whether to continue.

2. **Check the Mac.** Run `sw_vers -productVersion` (needs 13 or later) and `xcrun --find swift`. If Swift is missing, ask the user to run `xcode-select --install` and finish that installer, then continue.

3. **Get the source.** Ask where to keep it (default `~/kolom`), then:

   ```sh
   git clone https://github.com/ckluis/kolom.git ~/kolom
   cd ~/kolom
   ```

   If the folder already exists, `git pull` instead; the installer updates in place.

4. **Build and install.** Run `./scripts/install.sh --no-open` (add `--mcp` only after the user agrees to step 8) and wait (about one to two minutes). It creates a self-signed "Kolom Local Signing" certificate in the login keychain so the permission survives updates. If macOS shows a keychain prompt, tell the user to click **Always Allow**. If the script says Kolom is running, ask the user to quit it from its menu bar icon first.

5. **Open Kolom and grant access.** Run `open /Applications/Kolom.app` (or `~/Applications/Kolom.app` if the installer used that). Tell the user to turn on Kolom in **System Settings → Privacy & Security → Accessibility**. Kolom starts managing windows once it is allowed. Wait for the user to confirm.

6. **Check it.** Run `python3 -I scripts/live-check.py`. Every line should read `ok` (a `WARN` about pauses is fine on a fresh install). Show the user any `FAIL` line and stop there.

7. **Show the basics.**

   | Keys | Action |
   | --- | --- |
   | ⌥← / ⌥→ | previous / next column |
   | ⌥1 … ⌥9 | focus a window |
   | ⌥D | scroll to the desktop |
   | ⌃⌥K | move the focused window |
   | ⌥M | Kolom commands |
   | ⌥K | Ask Kolom in plain words (macOS 26 with Apple Intelligence) |

   Two-finger horizontal swipes scroll the strip. The **?** button in each display's rail opens Kolom's built-in guide. The menu bar icon has **Pause and Restore** and **Quit**; both put every window back.

8. **Optional: connect the agent.** Kolom ships a local MCP server. Ask the user first. For Claude Code: `claude mcp add --scope user kolom -- ~/.local/bin/kolomctl mcp` (other agents: add `~/.local/bin/kolomctl mcp` as a stdio MCP server). Read-only tools work at once; tools that move windows need the user to choose **Allow local agent commands…** in the menu bar icon's menu. `kolomctl help` explains the rest.

9. **Optional: a star.** Ask: "Kolom is free and open source. Would you like me to star github.com/ckluis/kolom with your GitHub account?" Only on a clear yes, and only if `gh auth status` succeeds, run `gh api -X PUT /user/starred/ckluis/kolom`. Otherwise share the link https://github.com/ckluis/kolom and move on.

## Uninstall

Quit Kolom from its menu (windows and displays are restored), then:

```sh
rm -rf /Applications/Kolom.app ~/Applications/Kolom.app ~/.local/bin/kolomctl "$HOME/Library/Application Support/Kolom"
defaults delete io.github.ckluis.kolom
security delete-identity -c "Kolom Local Signing"
```

If the MCP server was registered with Claude Code, also run `claude mcp remove --scope user kolom`.

Remove Kolom from System Settings → Privacy & Security → Accessibility.
