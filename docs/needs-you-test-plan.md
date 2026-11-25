# "Needs you" alert — manual test plan

Paste these into Terminal with **this branch's build** running (Xcode ▸ Run, or a
Debug build copied over the installed app). Only one notch app at a time: quit the
installed AgenticNotch first.

`open -g` hands the URL to the app without stealing focus, the same way the hook
script does.

## 0. Setup

- Settings ▸ Agents: **Alert when an agent needs me** is on (default), **Play a sound** on.
- Parser + live-session self-checks, no app needed: `scripts/test-agent-event` → `AgentEvent self-checks passed …`
  and `AgentSession self-checks passed …`.
- Every `agent-event` below also lands in the Agents tab's **Live** list
  (`docs/live-sessions-test-plan.md`); the combined walk-through is `docs/agents-v2-test-plan.md`.

## 1. The card shows, and stays

```sh
open -g "agenticnotch://agent-event?tool=claude&event=waiting&session=s1&project=gcu-api&detail=Claude%20needs%20your%20permission%20to%20use%20Bash"
```

Expect, with the notch closed:
- Amber card: left of the notch **Claude needs you** (amber), right **● waiting** (pulsing,
  still if Reduce Motion is on), below **gcu-api · permission to use Bash**.
- The "Ping" chime ("Tink" if the finish sound is set to Ping), not the finish chime.
- Still there after 10+ seconds. The green "finished" card would be gone after 4 s.
- Hovering the notch does **not** open it while the card is up.

## 2. The same session clears it

Each of these clears the card from step 1 (re-run step 1 between them):

```sh
open -g "agenticnotch://agent-event?tool=claude&event=prompt&session=s1&project=gcu-api"
open -g "agenticnotch://agent-event?tool=claude&event=session_end&session=s1&project=gcu-api"
open -g "agenticnotch://agent-event?tool=claude&event=stop&session=s1&project=gcu-api&detail=Fixed%20the%20build"
```

`stop` also shows the regular green "finished" card ("Fixed the build") once the
debounce passes (4 s by default).

## 3. Another session does not clear it

```sh
open -g "agenticnotch://agent-event?tool=claude&event=waiting&session=s1&project=gcu-api&detail=Claude%20needs%20your%20permission%20to%20use%20Bash"
open -g "agenticnotch://agent-event?tool=claude&event=prompt&session=OTHER&project=web"
```

The amber card stays.

## 4. Two sessions waiting

```sh
open -g "agenticnotch://agent-event?tool=claude&event=waiting&session=s1&project=gcu-api&detail=Claude%20needs%20your%20permission%20to%20use%20Bash"
open -g "agenticnotch://agent-event?tool=claude&event=waiting&session=s2&project=web&detail=Claude%20is%20waiting%20for%20your%20input"
```

Shows **web · waiting for your input** (the newest). Then:

```sh
open -g "agenticnotch://agent-event?tool=claude&event=prompt&session=s2&project=web"
```

The card falls back to **gcu-api · permission to use Bash**.

## 5. Click dismisses

With a card up, click it. It goes away and the notch does not open. If another
session was still waiting, its card shows next. Click again to clear it.

## 6. History

Open the notch ▸ Agents tab, and Settings ▸ Agents ▸ Recent. Each `waiting` event is
an entry with an amber ✋ icon, "Claude · gcu-api", and the full message
("Claude needs your permission to use Bash"). Finished runs keep their green ✓ and
errors their red ✕.

## 7. Toggle off

Settings ▸ Agents ▸ turn off **Alert when an agent needs me**, then re-run step 1.
No card and no chime, but the amber entry is still added to the history. Turn it back on.

## 8. Old finished URL unchanged

```sh
open -g "agenticnotch://done?tool=claude&status=ok&project=gcu-api&title=Fixed%20the%20build"
open -g "agenticnotch://done?tool=codex&status=error&project=web"
```

These are the same green and red cards as before. Neither clears an amber card,
because they carry no session.

## 9. Malformed URLs are ignored

```sh
open -g "agenticnotch://agent-event?event=waiting&session=s1"                 # no tool
open -g "agenticnotch://agent-event?tool=claude&event=sleeping&session=s1"    # unknown event
open -g "agenticnotch://agent-event?tool=claude&session=s1"                   # no event
open -g "agenticnotch://agent-event?tool=claude&event=waiting"                # no session
```

No card, no crash. Console.app shows `AgenticNotch: ignored URL …`.

## 10. Through the hook script (what Claude Code runs)

```sh
echo '{"session_id":"s9","cwd":"/tmp/gcu-api","hook_event_name":"Notification","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}' \
  | scripts/agenticnotch-notify --tool claude
echo '{"session_id":"s9","cwd":"/tmp/gcu-api","hook_event_name":"UserPromptSubmit"}' \
  | scripts/agenticnotch-notify --tool claude
```

The first command shows the card and the second clears it. Prefix either with
`AGENTICNOTCH_DEBUG=1` to print the URL instead of opening it. A Notification with
`"notification_type":"auth_success"` sends nothing.

## 11. Real Claude Code

Add the five hooks from the README to `~/.claude/settings.json`, start `claude` in
a project, and ask for something that needs a permission prompt (e.g. a Bash
command you haven't allowed). The amber card shows while Claude waits.

Known limit: Claude Code fires no hook when you approve the prompt, so the card
stays until that turn's `Stop` (or your next prompt), or until you click it.
