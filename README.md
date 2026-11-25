<h1 align="center">
  <br>
  <img src="Configuration/icon/agenticnotch-icon.png" alt="AgenticNotch" width="150">
  <br>
  AgenticNotch
  <br>
</h1>

<p align="center">
  <em>Turn your MacBook's notch into a live monitor for your AI coding agents.</em>
</p>

<p align="center">
  <a href="https://github.com/lucasscurtoo/AgenticNotch/releases/latest/download/AgenticNotch.dmg">
    <img src="https://img.shields.io/badge/Download%20app%20for-macOS-black?style=for-the-badge&logo=apple&logoColor=white&labelColor=black" height="42" alt="Download app for macOS" />
  </a>
</p>

<p align="center">
  <a href="https://github.com/lucasscurtoo/AgenticNotch/releases/latest"><img src="https://img.shields.io/github/v/release/lucasscurtoo/AgenticNotch?label=latest&color=blue" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/license-GPL--3.0-blue.svg" alt="License: GPL-3.0" />
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black.svg" alt="macOS 14+" />
</p>

<p align="center">
  <img src="docs/demo.gif" alt="AgenticNotch demo" width="720" />
</p>

**AgenticNotch** pops a card out of the notch — tool · summary · project · status — and
plays a chime whenever **Claude Code** or **Codex** finishes a turn, so you can stop
babysitting the terminal. It keeps a history of the last runs, and still does everything
the notch did before: music controls, calendar, file shelf and HUD replacement.

### Features

- 🔔 **Agent-finished notifications** — when Claude Code or Codex ends a turn, the notch
  pops a card with a short summary of *what it did*, the project, and an ok/error status.
- ✋ **"Needs you" alerts** — when Claude Code is blocked on you (a permission request
  or a question), the notch pops an amber card — *Claude needs you* ·
  project · reason — with its own chime. It stays until that session moves on (you
  answer, it stops, or it ends) or you click it. Toggle under **Settings → Agents**.
- 🟢 **Live sessions** — every running Claude Code / Codex session in the Agents tab
  (tool · project · working / needs you / done · time in that state), plus a pulsing dot
  and a count beside the closed notch while any of them is working (amber if one needs you).
- 🕑 **History** — the last 10 runs, in a dedicated notch tab and in Settings.
- 📊 **AI limits tab** — how much of your Claude and Codex quota is gone and when each
  window resets. Claude comes from the usage cache Claude Code writes to `~/.claude.json`
  (no token, no network); Codex from its own usage endpoint using `~/.codex/auth.json`.
- 🎧 **Everything else the notch already did** — music live activity, calendar, shelf with
  AirDrop, HUD replacement for volume/brightness/backlight.

## Install

**Requirements:** macOS 14 Sonoma or later · Apple Silicon or Intel.

### Option 1 — download the DMG

[**Download AgenticNotch.dmg**](https://github.com/lucasscurtoo/AgenticNotch/releases/latest/download/AgenticNotch.dmg)
(always the latest release), open it and drag **AgenticNotch** to `/Applications`.

> [!IMPORTANT]
> The app is signed with a free Apple Development certificate, not notarized (that needs a
> paid Apple Developer account), so macOS will refuse to open it on first launch. One
> command, once:
>
> ```bash
> xattr -dr com.apple.quarantine /Applications/AgenticNotch.app
> ```
>
> Then open it normally. Alternative without Terminal: **System Settings → Privacy &
> Security → Open Anyway**, right after the first failed launch.

### Option 2 — build from source

```bash
git clone https://github.com/lucasscurtoo/AgenticNotch.git
cd AgenticNotch
./scripts/build-release-dmg.sh     # builds, signs with your Apple Development cert, makes a DMG
```

Or open `boringNotch.xcodeproj` in Xcode and hit **Run**. If you build a *Release* config
from Xcode without setting your signing team, the app will crash at launch with
`Library not loaded: @rpath/MediaRemoteAdapter.framework` — the bundled framework and the
app end up with different Team IDs under hardened runtime. Set your team in **Signing &
Capabilities**, or just use the script above.

## Wiring your agents

The notch reacts when a CLI agent finishes a turn, and tracks every session while it runs.
Configure the sound and behaviour under **Settings → Agents**, and point your agent at the
bundled script (absolute path):

**Claude Code** — `~/.claude/settings.json`. Every hook runs the same command; the script
reads which event fired from the hook's JSON:
```json
{
  "hooks": {
    "SessionStart":     [ { "hooks": [ { "type": "command", "command": "/absolute/path/to/AgenticNotch/scripts/agenticnotch-notify --tool claude" } ] } ],
    "UserPromptSubmit": [ { "hooks": [ { "type": "command", "command": "/absolute/path/to/AgenticNotch/scripts/agenticnotch-notify --tool claude" } ] } ],
    "Notification":     [ { "hooks": [ { "type": "command", "command": "/absolute/path/to/AgenticNotch/scripts/agenticnotch-notify --tool claude" } ] } ],
    "Stop":             [ { "hooks": [ { "type": "command", "command": "/absolute/path/to/AgenticNotch/scripts/agenticnotch-notify --tool claude" } ] } ],
    "SessionEnd":       [ { "hooks": [ { "type": "command", "command": "/absolute/path/to/AgenticNotch/scripts/agenticnotch-notify --tool claude" } ] } ]
  }
}
```
- **Stop** pops the finish card + chime and records it in History. The summary is derived
  from the last assistant message; `project` is the basename of the session's cwd.
- **Notification** pops the amber "needs you" card for real blocks (permission requests,
  questions). The script passes Claude's `notification_type` on as `kind=permission|idle`;
  the idle "waiting for your input" reminder after a finished turn (`kind=idle`) is
  ignored. `UserPromptSubmit`, `Stop` and `SessionEnd` from the same session clear the card.
- All five feed the live session list: a session is *working* from start or prompt,
  *needs you* while a running turn is blocked on you, *done* after Stop (listed for 10
  minutes), and leaves on SessionEnd. Sessions silent for 2 hours are dropped as stale.
- Each hook opens exactly one URL,
  `agenticnotch://agent-event?tool=claude&event=<session_start|prompt|waiting|stop|session_end>&session=<id>&project=<name>&detail=<text>`.
  An older `Stop`-only setup keeps working, and the legacy
  `agenticnotch://done?tool=&status=&project=&title=` URL is still accepted.

**Codex** — `~/.codex/config.toml`:
```toml
notify = ["/absolute/path/to/AgenticNotch/scripts/agenticnotch-notify", "--tool", "codex", "--status", "ok"]
```
Codex only reports finished turns (`agent-turn-complete`, appended as a JSON argument): each
one pops the finish card and lists the session (its `thread-id`) as *done* in the Live list.

## Usage

- Hover over the notch to expand it: music, calendar, shelf, agent history.
- Click the icon in the menu bar to open Settings and customize everything.

## 📋 Roadmap

- [x] Agent-finished notifications for Claude Code and Codex 🔔
- [x] Run history 🕑
- [ ] Per-project filters and mute rules 🔕
- [ ] More agents (Gemini CLI, Cursor, Aider) 🤖
- [x] Live "agent is working" state, not just finished 🔄
- [ ] Own appcast so the app can auto-update ⬆️

## 🤝 Contributing

Contributions welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## 🎉 Credits

AgenticNotch is a fork of **[boring.notch](https://github.com/TheBoredTeam/boring.notch)**
by [TheBoringTeam](https://github.com/TheBoredTeam) (GPL-3.0) — the music, calendar, shelf
and HUD features are their work; this fork adds the AI-agent layer on top. Go star the
original: [Discord](https://discord.gg/GvYcYpAKTu) · [Ko-fi](https://www.ko-fi.com/alexander5015).

Also built on **[MediaRemoteAdapter](https://github.com/ungive/mediaremote-adapter)** (Now
Playing on macOS 15.4+) and **[NotchDrop](https://github.com/Lakr233/NotchDrop)** (basis for
the Shelf). Original icon by [@maxtron95](https://github.com/maxtron95).
Full attributions: [Third-Party Licenses](./THIRD_PARTY_LICENSES).
