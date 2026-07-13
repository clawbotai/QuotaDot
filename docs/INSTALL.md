# Install QuotaDot

## System Requirements

- macOS 14 Sonoma or later.
- At least one signed-in provider: Codex or Claude Code.

## Recommended Installation

Only install a release DMG that is signed with Developer ID and notarized by Apple.

1. Download the latest `QuotaDot-x.y.z.dmg` from [GitHub Releases](https://github.com/MeowkingCP/QuotaDot/releases).
2. Double-click the DMG to open it.
3. Drag QuotaDot into the Applications folder.
4. Launch QuotaDot from Applications.

QuotaDot is a menu bar application and does not appear in the Dock. After launch, the menu bar shows a dual-ring icon and the lowest remaining quota percentage. A floating window appears on the desktop and collapses automatically when it is not being inspected.

If no signed and notarized DMG is listed on the Releases page, a public end-user build is not available yet. Developers can build from source by following the instructions in the repository README.

## First Launch

- **Weather background:** Allow location access when macOS asks for permission. Quota features continue to work if permission is denied.
- **Launch at login:** Open the QuotaDot menu bar menu, choose Settings, and enable Launch at Login. If macOS requests approval, follow the prompt to System Settings → General → Login Items.
- **Language:** Click `EN` or `ZH` in the expanded status row, or select a display language in Settings. No restart is required.
- **No quota data:** Confirm that Codex or Claude Code is signed in for the current macOS user, then choose Refresh Now.

## Uninstall

1. Disable Launch at Login in QuotaDot Settings.
2. Choose Quit QuotaDot from the menu bar menu.
3. Move QuotaDot from Applications to the Trash.

## Unsigned Development Builds

DMG files containing `UNSIGNED` in their name are intended only for local developer validation and have not been notarized by Apple. End users should install only signed and notarized builds published on the GitHub Releases page.
