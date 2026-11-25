# Live sessions — manual test plan

Checks the closed-notch indicator and the **Live** section of the Agents tab with two
fake sessions, without touching any real Claude Code / Codex config.

**Before you start:** these URLs go to whichever AgenticNotch is running. The installed
`/Applications/AgenticNotch.app` does not have this feature yet, so quit it and run the
Debug build of this branch from Xcode (only one notch app at a time). Keep the notch
**closed** for the indicator steps; hover it open and pick the **Agents** tab (sparkles
icon) for the list steps.

Session A = Claude in `gcu-api`, session B = Claude in `web-app`.

| # | Command | Expect |
|---|---------|--------|
| 1 | `open -g "agenticnotch://agent-event?tool=claude&event=session_start&session=test-a&project=gcu-api"` | Beside the closed notch: sparkles on the left, pulsing **green** dot + **1** on the right. |
| 2 | `open -g "agenticnotch://agent-event?tool=claude&event=prompt&session=test-b&project=web-app"` | Count goes to **2**. |
| 3 | Open the notch → Agents tab | **Live** header above History: `Claude · web-app  working  Ns` and `Claude · gcu-api  working  Ns`; the seconds tick. |
| 4 | `open -g "agenticnotch://agent-event?tool=claude&event=waiting&session=test-a&project=gcu-api&detail=Claude%20needs%20your%20permission%20to%20use%20Bash"` | Closed: dot turns **amber**, count stays **2**. Live list: gcu-api moves to the top, `needs you`, timer restarts at 0s. |
| 5 | `open -g "agenticnotch://agent-event?tool=claude&event=stop&session=test-b&project=web-app"` | web-app → `done` (gray), timer restarts; count drops to **1**, still amber. No finish card: that comes only from the `done` URL (step 10). |
| 6 | `open -g "agenticnotch://agent-event?tool=claude&event=prompt&session=test-a&project=gcu-api"` | gcu-api back to `working`; dot back to **green**, count **1**. |
| 7 | `open -g "agenticnotch://agent-event?tool=claude&event=stop&session=test-a&project=gcu-api"` | Nothing working → the indicator disappears (music / face come back). Both rows stay in Live as `done`. |
| 8 | `open -g "agenticnotch://agent-event?tool=claude&event=session_end&session=test-a&project=gcu-api"` | gcu-api leaves the Live list; web-app stays. |
| 9 | Wait 10 minutes after step 5 | web-app drops out of Live on its own (done TTL). The Live header disappears with it. |
| 10 | `open -g "agenticnotch://done?tool=claude&status=ok&project=gcu-api&title=Fixed%20the%20login%20test"` | Unchanged legacy path: finish card + chime, new History entry. Live list untouched. |
| 11 | `open -g "agenticnotch://agent-event?tool=codex&event=stop&session=thread-1&project=web-app"` | Codex row appears directly as `done` (Codex only reports finished turns). |

Clean up any leftovers with `session_end` for each id used above.

## The hook script, dry-run

`AGENTICNOTCH_DEBUG=1` prints the URLs instead of opening them, so this needs no app:

```bash
S=scripts/agenticnotch-notify; export AGENTICNOTCH_DEBUG=1
echo '{"hook_event_name":"SessionStart","session_id":"abc","cwd":"/tmp/gcu-api"}'     | $S --tool claude
echo '{"hook_event_name":"UserPromptSubmit","session_id":"abc","cwd":"/tmp/gcu-api"}' | $S --tool claude
echo '{"hook_event_name":"Notification","session_id":"abc","cwd":"/tmp/gcu-api","message":"Claude is waiting for your input"}' | $S --tool claude
echo '{"hook_event_name":"Stop","session_id":"abc","cwd":"/tmp/gcu-api"}'             | $S --tool claude --status ok
echo '{"hook_event_name":"SessionEnd","session_id":"abc","cwd":"/tmp/gcu-api"}'       | $S --tool claude
$S --tool codex --status ok '{"type":"agent-turn-complete","thread-id":"t1","cwd":"/tmp/web-app"}' </dev/null
```

Stop and Codex print two lines (`done` + `agent-event?event=stop`); the others print one
`agent-event` line each.

## Not covered by hand

The 2-hour stale drop, the 10-minute expiry boundary, the flood ceiling and the parser's
edge cases are in `AgentSession.runSelfCheck()` (`boringNotch/models/AgentSessionStore.swift`),
which runs on every Debug launch.
