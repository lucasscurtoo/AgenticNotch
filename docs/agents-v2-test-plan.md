# Agents v2 — combined manual test plan

One walk-through for both halves of the `agent-event` contract: the amber **"needs you"**
card and the **live session list** (closed-notch dot + count, **Live** section of the
Agents tab). Every step is one `open -g` — the same single URL the hook script sends per
hook. Deeper per-feature checks: `docs/needs-you-test-plan.md`,
`docs/live-sessions-test-plan.md`.

```
agenticnotch://agent-event?tool=<claude|codex>&event=<session_start|prompt|waiting|stop|session_end>&session=<id>&project=<name>&detail=<text>
```

## 0. Setup

- Quit the installed `/Applications/AgenticNotch.app` and run this branch's Debug build
  from Xcode (only one notch app at a time; the installed build has neither feature).
- Settings ▸ Agents: **Notify when an AI agent finishes** and **Alert when an agent needs
  me** on (defaults).
- No app needed for the logic: `scripts/test-agent-event` must print both
  `AgentEvent self-checks passed …` and `AgentSession self-checks passed …`.

Session **A** = Claude in `gcu-api`, session **B** = Claude in `web-app`. Keep the notch
closed unless a step says to open it (hover ▸ Agents tab, sparkles icon).

## 1. Two sessions working

```sh
open -g "agenticnotch://agent-event?tool=claude&event=session_start&session=test-a&project=gcu-api"
open -g "agenticnotch://agent-event?tool=claude&event=prompt&session=test-b&project=web-app"
```

Closed notch: pulsing **green** dot + **2**. Agents tab ▸ **Live**: two rows,
`Claude · web-app  working` and `Claude · gcu-api  working`, seconds ticking.

## 2. One of them needs you

```sh
open -g "agenticnotch://agent-event?tool=claude&event=waiting&session=test-a&project=gcu-api&kind=permission&detail=Claude%20needs%20your%20permission%20to%20use%20Bash"
```

`kind=permission` is what the hook script sends for a permission prompt or a question
(no `kind` at all means the same).

- Closed notch: amber card **Claude needs you** · **● waiting** · `gcu-api · permission to
  use Bash`, with its own chime. It stays (no 4 s collapse) and hovering doesn't open the notch.
- Live list: gcu-api jumps to the top as `needs you` (amber), timer back at 0s; web-app
  still `working`.
- Click the card: it goes away and the indicator shows an **amber** dot + **2**.

## 3. The other session finishing doesn't clear it

Re-run step 2 so the card is up, then:

```sh
open -g "agenticnotch://agent-event?tool=claude&event=stop&session=test-b&project=web-app&detail=Fixed%20the%20login%20test"
```

- The amber card stays (different session). After the 4 s debounce the green finish card
  `Fixed the login test` takes precedence over it for 4 s, then the amber card is back.
- History gains a green ✓ `Claude · web-app` entry.
- Live: web-app → `done` (gray); the count drops to **1**, still amber.

## 4. The idle reminder after a finish is ignored

About 60 s after a finished turn Claude fires `Notification` again ("Claude is waiting for
your input", `notification_type: idle_prompt`); the script sends it with `kind=idle`.
web-app finished in step 3:

```sh
open -g "agenticnotch://agent-event?tool=claude&event=waiting&session=test-b&project=web-app&kind=idle&detail=Claude%20is%20waiting%20for%20your%20input"
```

Nothing happens: no new amber card or chime (gcu-api's card from step 3 stays exactly as
it was), no amber History entry, and the web-app row stays `done` with its timer still
counting from step 3 (indicator count unchanged).

## 5. Answering clears it

```sh
open -g "agenticnotch://agent-event?tool=claude&event=prompt&session=test-a&project=gcu-api"
```

Amber card gone; indicator back to **green** + **1**; gcu-api `working` again.

## 6. Finish and end

```sh
open -g "agenticnotch://agent-event?tool=claude&event=stop&session=test-a&project=gcu-api&detail=Merged%20the%20branches"
open -g "agenticnotch://agent-event?tool=claude&event=session_end&session=test-a&project=gcu-api"
```

Finish card for gcu-api; once it collapses nothing is working, so the indicator is gone.
After `session_end` gcu-api leaves Live; web-app stays as `done` until 10 minutes after
step 3, then drops on its own (the Live header goes with it).

## 7. Codex

```sh
open -g "agenticnotch://agent-event?tool=codex&event=stop&session=thread-1&project=web-app"
```

Finish card, plus a `Codex · web-app  done` row (Codex only reports finished turns).

## 8. Old `done` URL still works

```sh
open -g "agenticnotch://done?tool=claude&status=ok&project=gcu-api&title=Fixed%20the%20build"
open -g "agenticnotch://done?tool=codex&status=error&project=web"
```

Same green / red cards as before, History entries, Live list untouched (no session).

## 9. Malformed URLs are ignored

```sh
open -g "agenticnotch://agent-event?event=waiting&session=s1"                 # no tool
open -g "agenticnotch://agent-event?tool=claude&event=waiting"                # no session
open -g "agenticnotch://agent-event?tool=claude&event=sleeping&session=s1"    # unknown event
```

No card, no Live row, no crash; Console.app shows `AgenticNotch: ignored URL …`.

## 10. Through the hook script (no app needed)

```sh
S=scripts/agenticnotch-notify; export AGENTICNOTCH_DEBUG=1
echo '{"hook_event_name":"SessionStart","session_id":"abc","cwd":"/tmp/gcu-api"}'     | $S --tool claude
echo '{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/tmp/gcu-api"}' | $S --tool claude
echo '{"hook_event_name":"Notification","session_id":"abc","cwd":"/tmp/gcu-api","message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}' | $S --tool claude
echo '{"hook_event_name":"Notification","session_id":"abc","cwd":"/tmp/gcu-api","message":"Claude is waiting for your input","notification_type":"idle_prompt"}' | $S --tool claude
echo '{"hook_event_name":"Notification","session_id":"abc","notification_type":"auth_success"}' | $S --tool claude
echo '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp/gcu-api"}'             | $S --tool claude
echo '{"hook_event_name":"SessionEnd","session_id":"abc","cwd":"/tmp/gcu-api"}'       | $S --tool claude
$S --tool codex --status ok '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/tmp/web-app"}' </dev/null
$S --tool claude --status error --title "Build broke" </dev/null
```

Exactly one URL per line: an `agent-event` for each hook and for Codex (the two
Notifications carry `kind=permission` and `kind=idle`), nothing for `auth_success` or any
other non-blocking type, and the legacy `done` URL only for the last (manual, no session)
run. A Notification without `notification_type` (older Claude Code) falls back to the
message text: "waiting for your input" → `kind=idle`, anything else → `kind=permission`.
Drop `AGENTICNOTCH_DEBUG` to send them to the app for real.

## Known differences, on purpose

- `kind=idle` is ignored even for a session still `working` (a missed Stop): only a real
  block raises the card or the `needs you` row, and an idle reminder never creates a row.
- Claude Code sends no hook when you approve a permission prompt, so both the card and the
  `needs you` row hold until that session's next `prompt` / `stop` / `session_end`, or a
  click on the card.
