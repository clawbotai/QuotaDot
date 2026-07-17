# Privacy

QuotaDot is designed as a local macOS utility. It does not operate a QuotaDot account system, analytics backend, advertising SDK, or telemetry service.

## Data accessed on your Mac

- Codex authentication data from `CODEX_HOME/auth.json`, or `~/.codex/auth.json` by default.
- Claude Code authentication data from its local credential storage.
- Local process activity used to determine whether Codex or Claude is currently active.
- Codex and Claude Code JSONL session history still stored on this Mac, used only to calculate local token totals and activity dates.
- Approximate device location, only after macOS grants location permission.

## Network requests

- Codex quota requests are sent directly to OpenAI's service using the local Codex session.
- Claude quota requests are sent directly to Anthropic's service using the local Claude Code session.
- Coordinates are sent to Open-Meteo for current weather. If the user explicitly provides an `AMAP_WEBSERVICE_KEY`, coordinates may instead be sent to AMap for reverse geocoding and weather.

QuotaDot does not send authentication credentials to weather providers and does not send location coordinates to quota providers beyond information already included by their own network stack.

## Storage and logging

QuotaDot does not copy authentication tokens into its preferences or logs. Its token-history index is stored under the current user's Application Support directory and contains source file paths, file cursors, local session/message identifiers, timestamps, and numeric token counts. QuotaDot restricts the index directory and file to the current user (`0700` and `0600`); if those permissions cannot be applied, it discards the rebuildable cache. The index does not copy prompts, responses, tool arguments, or tool output. Deleting it causes QuotaDot to rebuild it from local history on the next detail-page load.

System logs contain operational status and may include the resolved place name and location accuracy, but not raw coordinates or authentication tokens.

## Revoking access

Location access can be revoked in System Settings → Privacy & Security → Location Services. Login-at-startup can be disabled in QuotaDot Settings or System Settings → General → Login Items.

Security issues involving credentials should be reported privately according to [SECURITY.md](SECURITY.md).
