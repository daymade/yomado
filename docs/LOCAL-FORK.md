# Local fork operation

Use this procedure to build and run the source in `daymade/yomado`. Upstream release downloads do not contain this fork's changes.

## Build and install

1. Save application work and coordinate with anyone using the virtual screens. Record the running Yomado bundle path, version, signature, display arrangement and the windows that must be restored. Keep this record and a recoverable copy of the installed app outside the repository.
2. Build in a source checkout with macOS and Xcode or Command Line Tools:

   ```sh
   bash ./build.sh
   ```

   Build inputs, output paths and signing selection are maintained in [build.sh](../build.sh); dependency pins and cache selection are in [fetch-sparkle.sh](../scripts/fetch-sparkle.sh). The app bundles Sparkle as well as using system frameworks. Build output must be separate from an installed or running app. Building does not install, launch or notarize the app.
3. Inspect the generated app's `Contents/Info.plist` and signature before replacement:

   ```sh
   # Set this to the generated bundle reported by build.sh.
   ym_candidate='/absolute/path/to/generated/Yomado.app'
   plutil -p "$ym_candidate/Contents/Info.plist"
   codesign --verify --deep --strict "$ym_candidate"
   codesign -dv --verbose=4 "$ym_candidate"
   ```

   Compare the bundle metadata with [Info.plist](../Info.plist). Signing success does not prove notarization, permission continuity or working window movement.
4. Return occupied virtual-screen windows through Yomado and verify recovery before quitting the old instance. If recovery is refused or another task still owns a screen, leave it running and resolve that condition; do not force quit. Replace only the intended installed app with the verified candidate, then open that exact app. Confirm the running process's bundle path and metadata, rather than relying on its display name or an old Dock shortcut.
5. Check window-control permission for the installed app. If a replacement build's switch is enabled but access is ineffective, follow [signed-app replacement diagnosis](https://github.com/daymade/claude-code-skills/blob/main/daymade-macos/macos-permissions/references/tcc-mechanics.md#signed-app-replacement-with-an-enabled-but-ineffective-grant). System authentication follows the [permission-dialog workflow](https://github.com/daymade/claude-code-skills/blob/main/daymade-macos/macos-permissions/SKILL.md#observe-and-classify-the-reported-problem-first) and the available host's permissions. If the host refuses protected input, stop that input and hand authentication to the user. Do not put authentication values in commands, logs or source.

## Upgrade and recover

The fork's updater policy is controlled by `YMLocalForkBuild` in [Info.plist](../Info.plist) and the corresponding gates in [app/Yomado.m](../app/Yomado.m). With that flag enabled, official automatic checks, manual installation and updater toggles are disabled; the panel identifies the local fork. Developer ID signing alone does not remove this gate. Upgrade by building reviewed fork source and following the installation procedure above.

If the new build cannot complete the original window operation, retain the recovery record and restore the saved app only after occupied screens and windows are safely accounted for. Recheck the actual installed identity and permissions after either replacement. Do not redirect this fork to the upstream feed as a recovery shortcut. Upstream release signing and feed publication belong to [AUTOMATIC-UPDATES.md](AUTOMATIC-UPDATES.md) and [distribution.md](distribution.md).

## Preview and window acceptance

Create or reuse only the task's screen using the [Yomado workflow](../.agents/skills/yomado/SKILL.md). Query fresh display IDs and bounds after topology changes; a saved name or ID is insufficient to identify the current target.

The menu action **在屏幕边缘预览虚拟屏** opens a view-only preview. It needs Screen Recording permission for Yomado, separately from window-control permission. The implementation is [WorkspacePreview.m](../app/WorkspacePreview.m). The preview does not provide keyboard focus isolation, mouse confinement or an input takeover mode. Use the Skill's [command boundary](../.agents/skills/yomado/SKILL.md#current-command-line-boundary) for preview annotations and display commands.

For JianYing/CapCut, follow [editor placement acceptance](https://github.com/cemakanshan/skills/blob/main/capcut-use/references/verified_ui_workflows.md#place-an-editor-on-a-virtual-display). That workflow owns editor identification, draft preservation, full-window containment and the move-out/return checks needed to validate a repair. A home-window icon in Yomado does not prove the editor moved. Inspect the actual editor and timeline after moving it.

When the app reports an unverified move, stop further movement and inspect its reported recovery result. Do not close the virtual screen to force recovery. A readable target screenshot and a verified reversible editor operation establish visual operation; preview visibility alone does not establish input delivery.

## Validate changes

Run [test.sh](../test.sh) for implementation changes and select relevant checks from its actual dispatch. Display-changing developer tests require an authorized idle desktop; building or editing documentation does not require them. Keep private window evidence outside the repository. Passing unit tests does not replace the affected app's real move-and-return acceptance.
