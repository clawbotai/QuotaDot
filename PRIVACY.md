# Privacy

QuotaDot is designed as a local macOS utility. It does not operate a QuotaDot account system, analytics backend, advertising SDK, or telemetry service.

## Data accessed on your Mac

- Codex authentication data from `CODEX_HOME/auth.json`, or `~/.codex/auth.json` by default.
- Claude Code authentication data from its local credential storage.
- Kimi Code authentication data from `KIMI_CODE_HOME/credentials/kimi-code.json`, or `~/.kimi-code/credentials/kimi-code.json` by default.
- An optional DeepSeek API key pasted by the user. QuotaDot validates it with DeepSeek before storing it in macOS Keychain; it is never written to UserDefaults or logs.
- Local process activity used to determine whether Codex, Claude, or Kimi is currently active.
- Codex, Claude Code, and Kimi Code JSONL session history still stored on this Mac, used only to calculate local token totals and activity dates.
- Approximate device location, only after macOS grants location permission.

## Network requests

- Codex quota requests are sent directly to OpenAI's service using the local Codex session.
- Claude quota requests are sent directly to Anthropic's service using the local Claude Code session.
- Kimi quota requests are sent directly to Moonshot AI's service using the local Kimi Code session.
- Optional DeepSeek balance requests are sent only to `https://api.deepseek.com/user/balance`, using either the transient key being validated or the previously validated Keychain credential. HTTP redirects are rejected so the Authorization header is not forwarded elsewhere.
- Coordinates are sent to Open-Meteo for current weather. If the user explicitly provides an `AMAP_WEBSERVICE_KEY`, coordinates may instead be sent to AMap for reverse geocoding and weather.

QuotaDot does not send authentication credentials to weather providers and does not send location coordinates to quota providers beyond information already included by their own network stack.

## Storage and logging

QuotaDot does not copy authentication tokens into its preferences or logs. Its token-history index is stored under the current user's Application Support directory and contains source file paths, file cursors, local session/message identifiers, timestamps, and numeric token counts. QuotaDot restricts the index directory and file to the current user (`0700` and `0600`); if those permissions cannot be applied, it discards the rebuildable cache. The index does not copy prompts, responses, tool arguments, or tool output. Deleting it causes QuotaDot to rebuild it from local history on the next detail-page load.

For DeepSeek, a successfully validated API key is stored as a generic password in macOS Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility. It is deleted when the user disconnects or when DeepSeek returns 401/403. Balance and provider status remain in memory and are cleared on exit. System logs contain operational status and may include the resolved place name and location accuracy, but not raw coordinates, API keys, authorization headers, response bodies, authentication tokens, or token fragments.

## Revoking access

Location access can be revoked in System Settings → Privacy & Security → Location Services. Login-at-startup can be disabled in QuotaDot Settings or System Settings → General → Login Items. DeepSeek access can be revoked with **Disconnect** in QuotaDot Settings or by deleting the corresponding API key on DeepSeek's API-key page.

Security issues involving credentials should be reported privately according to [SECURITY.md](SECURITY.md).
