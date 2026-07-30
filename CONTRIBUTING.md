# Contributing

Thanks for taking the time! Bug reports, feature requests and PRs are all welcome.

## Setup

```bash
git clone https://github.com/lucasscurtoo/AgenticNotch.git
cd AgenticNotch
open boringNotch.xcodeproj      # Xcode 16+, macOS 14+
```

Set your team under **Signing & Capabilities** before building a Release config, or use
`./scripts/build-release-dmg.sh`, which signs everything with your Apple Development
certificate. Without that, hardened runtime rejects the bundled
`MediaRemoteAdapter.framework` and the app dies at launch.

## Pull requests

- Branch off `main`, one topic per PR.
- Keep the diff focused: no drive-by reformatting of untouched code.
- Say what you changed and how you verified it. Screenshots or a short screen recording
  help a lot for anything visual — the notch is hard to review from a diff.
- Match the surrounding style; this codebase is mostly SwiftUI with `Defaults` for
  persistence.

## Reporting bugs

Include your macOS version, whether the notch is physical or simulated, and the steps to
reproduce. For crashes, attach the report from
`~/Library/Logs/DiagnosticReports/AgenticNotch-*.ips`.

## Upstream

Anything that isn't agent-related — music, calendar, shelf, HUD — most likely belongs in
[boring.notch](https://github.com/TheBoredTeam/boring.notch), the project this is forked
from. Fixes that apply to both are welcome here, but consider sending them upstream too so
everyone gets them.
