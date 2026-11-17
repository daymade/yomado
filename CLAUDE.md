# Yomado fork

This checkout is the `daymade/yomado` fork. For local build, installation, upgrade and repair acceptance, read [local fork operation](docs/LOCAL-FORK.md) before acting. Keep reusable permission and editor-placement procedures with the Skills linked there.

## Sources of truth

- Bundle identity, version and local-fork updater policy: [Info.plist](Info.plist).
- Build/signing inputs and outputs: [build.sh](build.sh); dependency pins: [fetch-sparkle.sh](scripts/fetch-sparkle.sh).
- CLI parsing, replies and updater gates: [app/Yomado.m](app/Yomado.m). The agent workflow belongs to [.agents/skills/yomado/SKILL.md](.agents/skills/yomado/SKILL.md).
- Window movement and restore transactions: [app/AppWorkspace.m](app/AppWorkspace.m); input deadlines: [app/InputLeasePolicy.h](app/InputLeasePolicy.h) and [app/InputLease.m](app/InputLease.m).
- Preview capture and presentation: [app/WorkspacePreview.m](app/WorkspacePreview.m).
- Test dispatch and safe test selection: [test.sh](test.sh).

## Change and delivery

Update directly affected docs and examples when these contracts change. Keep detailed fork operation in its SOP; README translations link to that source. Do not copy current versions, dependency pins, deadline constants or test counts into this file.

Build in a separate output directory. Coordinate an occupied app replacement, preserve drafts and verify window recovery before quitting. Do not use display-changing tests on an occupied desktop or treat a successful build as permission to install or restart.

Use fresh display/window observations for acceptance. Keep physical displays enabled and the physical main display unchanged; stop on unverified moves or restore failures. Never force a screen closed to bypass recovery.

Do not commit credentials, permission databases, private window titles, screenshots or machine diagnostics. Report source checks, installed identity and actual app acceptance separately.
