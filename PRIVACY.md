# Privacy

QuotaDot is designed as a local macOS utility. It does not operate a QuotaDot account system, analytics backend, advertising SDK, or telemetry service.

## Data accessed on your Mac

- Codex authentication data from `CODEX_HOME/auth.json`, or `~/.codex/auth.json` by default.
- Claude Code authentication data from its local credential storage.
- Local process activity used to determine whether Codex or Claude is currently active.
- Approximate device location, only after macOS grants location permission.

## Network requests

- Codex quota requests are sent directly to OpenAI's service using the local Codex session.
- Claude quota requests are sent directly to Anthropic's service using the local Claude Code session.
- Coordinates are sent to Open-Meteo for current weather. If the user explicitly provides an `AMAP_WEBSERVICE_KEY`, coordinates may instead be sent to AMap for reverse geocoding and weather.

QuotaDot does not send authentication credentials to weather providers and does not send location coordinates to quota providers beyond information already included by their own network stack.

## Storage and logging

QuotaDot does not copy authentication tokens into its preferences or logs. System logs contain operational status and may include the resolved place name and location accuracy, but not raw coordinates or tokens.

## Revoking access

Location access can be revoked in System Settings → Privacy & Security → Location Services. Login-at-startup can be disabled in QuotaDot Settings or System Settings → General → Login Items.

Security issues involving credentials should be reported privately according to [SECURITY.md](SECURITY.md).
