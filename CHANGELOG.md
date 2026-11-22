# Changelog

## 0.5.1

- Names the Android `bootloader_unlocked` signal and its group.

## 0.5.0

- Events read the AI agent behind them: `Fingerly::Event#ai` is a
  `Fingerly::AiAgent` with `name`, `provider`, `purpose`, `runtime`,
  `declared?` and `verification` (`method`, `result`) when `visitor_kind` is
  `ai_bot`, and `nil` otherwise. New constants `Fingerly::AiPurpose`,
  `Fingerly::AiRuntime`, `Fingerly::AiVerificationMethod` and
  `Fingerly::AiVerificationResult`, and the `ai_spoofed` and
  `identity_obfuscated` signals. `Fingerly::Signal::VPN_TIMEZONE` is gone:
  the API no longer sends it.
- `events.list` filters on `kind:`, `ai_provider:` and `ai_purpose:`.
- Added `Fingerly::AgentSightings` and its Rack middleware: they report the
  requests your server served, so AI crawlers that never run JavaScript are
  counted, and `lookup` answers from memory what sent a request. Reports go
  out from one background thread, never from a request, and every failure
  leaves requests served as usual. `fingerly.agents.report_sightings` is the
  call underneath.
- The proxy forwards the Web Bot Auth `Signature`, `Signature-Input` and
  `Signature-Agent` headers, each up to 4096 bytes.
- `APIError#rate_limit_scope` names the limit behind a `429`.
- Every field of `Fingerly::AiAgent` and `Fingerly::AiVerification` is now
  always set, as the API sends it, so `event.ai.verification.result` needs no
  nil check. An event whose `ai` lacks one raises `Fingerly::Error` when it
  is read, rather than a `NoMethodError` later in your code. In an agent
  sightings answer, such an item reads as `Fingerly::AgentSightings::UNKNOWN`
  and the other items of the answer are still remembered.
- A response field of another JSON type than documented now reads as absent
  (`nil`, `0` or empty) instead of being passed through, and an event list
  whose rows are not events raises `Fingerly::Error`.
- `AgentSightings#close` and `#flush` work inside a signal handler such as
  `trap("TERM")`, which they hold up 12 seconds at most and never hang, even
  when the signal interrupts a report in progress. A forked worker that
  closes no longer sends the reports its parent still holds, and its
  `dropped_count` counts only its own drops.
- `AgentSightings#flush` also waits for a send the background thread starts
  while it runs, so nothing is still pending when it returns.
- A `client_ip` callback or logger that raises `NotImplementedError`, another
  `ScriptError` or `SystemStackError` is contained like any other failure:
  the agent sightings middleware leaves the response alone, and the proxy
  answers its own `500`.
- The middleware's `content_types:` are matched as media types, so a
  configured `"text/html; charset=utf-8"` matches `text/html` responses.
- Agent sightings measure every limit on the value as sent, UTF-8 with an
  invalid byte sequence as U+FFFD, so no report can carry a field the API
  refuses: a user agent or method over 4096 bytes is not reported, and a
  Web Bot Auth header or `Host` over 4096 bytes is left out.
- `Fingerly::VisitorKind::UNKNOWN` names the answer for a reported request
  the server could not use. It comes with a `ttl` of 0, so it is never
  remembered and that request stays `UNKNOWN`; the rest of the batch is
  answered as usual. A `422` now means no item in the batch was usable.
- After a `429`, agent sightings stop reporting for at least 1 second and at
  most 24 hours, whatever `Retry-After` said, so a huge value cannot end
  reporting for the life of the process.
- The README and `Fingerly::DeviceCheck` describe one read and one write
  token per identification: a check-then-mark flow reads and writes on the
  same request ID.

## 0.4.1

- Each `Fingerly::AttestSkippedReason` constant documents when the iOS and
  Android SDKs send it.
- The vendored OpenAPI contract (`contract/openapi.json`) declares the enums
  for the closed string sets the API sends.

## 0.4.0

- Added named constants for the closed string sets the API sends, each a
  module of frozen wire strings with a frozen `ALL` array:
  `Fingerly::Signal` (every signal group and detector),
  `Fingerly::SuspectLevel`, `Fingerly::Confidence`, `Fingerly::EventState`,
  `Fingerly::Environment`, `Fingerly::Platform`, `Fingerly::AnonymityNetwork`,
  `Fingerly::DeviceKind`, `Fingerly::VisitorKind`,
  `Fingerly::AttestationState`, `Fingerly::AttestationStatus`,
  `Fingerly::AttestSkippedReason`,
  `Fingerly::VerifyReason`, `Fingerly::WebhookEventType` and
  `Fingerly::WebhookEnvironment`. Fields stay strings, so
  `event.suspect_level == Fingerly::SuspectLevel::HIGH` is a plain comparison
  and a value added later still arrives. The `Fingerly::EventTrigger::SIGNAL_*`
  and `Fingerly::EventVerification` reason constants now refer to the same
  strings.

## 0.3.0

- Synced the v3 single-call ingest contract snapshot (`openapi.json` and
  `fixtures.json`), removing the retired supplement endpoint and
  `deferred_token`.
- Added `Fingerly::Event#reason`, v3 `Fingerly::EventTrigger` anti-spoofing
  signal constants (`attestation_failed`, `attestation_downgrade`,
  `device_inconsistent`, `report_incomplete`, `probe_errors`,
  `fetch_metadata_missing`, `web_ticket_missing`, `web_ticket_invalid`,
  `tampering`, `custom_root_ca`, `secondary_user_profile`), optional `EventTrigger#group`, and empty
  `visitor_id` (`""`) support for unidentifiable events.
- Enforced the v3 first-party proxy relay contract: sanitize-and-restore of
  validated `x-fingerly-sdk-platform`, `400 missing_origin` when both `Origin`
  and a validated native platform header are absent (never synthesizing
  `x-fingerly-origin`), forwarding `x-fingerly-host`, `sec-fetch-*` and
  `sec-ch-ua-*`, and optional `allowed_origins:` CORS preflight handling.
- `Fingerly::Proxy` requires `proxy_key:` and checks the caller's public key
  on every request; a secret key is never sent upstream.
- Added `fingerly.device_check.query(request_id)` and
  `fingerly.device_check.write(request_id, bit0:, bit1:)`, which spend an iOS
  event's held DeviceCheck token once, raise `Fingerly::DeviceCheckError`
  with a predicate per code and `apple_status`, and retry a `503` or a
  transport failure with the same request only.
- Added `fingerly.events.verify(request_id, max_age_seconds:, tag:,
  consume:)`, which reads an event and checks it exists, is recent
  (`max_age_seconds`, 300 by default), carries the expected `tag`, is
  identifiable and scored, then consumes it once, answering a
  `Fingerly::EventVerification` with `ok?` and a `reason`, and
  `fingerly.events.consume(request_id)` with a typed
  `Fingerly::EventAlreadyConsumedError` for `event_already_consumed`.

## 0.2.0

- `Fingerly::Event#project_id` is the Fingerly project an event belongs to,
  on single reads and list rows; nil when the server does not send it.
  Webhook `data` for `identification.completed` and `visitor.suspect` (and
  `identification.refused` when the key was known) carries `project_id`.
- `Fingerly::Event#ip_address` is removed; `#ip_network` (an IPv4 /24 or an
  IPv6 /40, such as `203.0.113.0/24`, or nil when absent) replaces it. The
  API no longer returns the address.
- `Fingerly::Event#deferred_signals` is removed; the API no longer returns
  the deferred report.
- `Fingerly::Event#document` is now an allow-listed view of the archived
  request, with no raw signals, user agent or address.
- The vendored contract snapshot is refreshed.

## 0.1.1

- Security: `Fingerly::Client#events.get` now refuses the request ids `.`
  and `..` as well as the empty id, raising `Fingerly::ConfigurationError`
  before any request is sent. Escaping left them as dot segments, so `..`
  addressed a route above `/events` with the secret key attached and `.`
  read the event list, which a caller could take for an event. The id
  usually comes from the browser, so upgrade if you pass it through.

## 0.1.0

First release.

- Event reads (`Fingerly::Client#events`) with one deadline over the whole
  exchange: connecting, sending, the response headers and the body.
- Every non-2xx answer, a redirect included, raises `Fingerly::APIError` with
  `status`, `code`, `details`, `request_id` and `retry_after`. Network failures
  raise `Fingerly::ConnectionError` or `Fingerly::TimeoutError`. Reads never
  retry by themselves. Response bodies over 4 MiB are refused.
- `Fingerly::APIError#pending?` for `404 event_pending`: the event was
  accepted and is still being recorded, so read again after `retry_after`
  seconds. `event_not_found?` still matches only `event_not_found` (never
  issued, or past retention).
- One idle connection pool per process, shared by every thread and fiber,
  recycled after 60 seconds and dropped after 15 seconds idle.
- Webhook verification with rotation support, reading at most 32 signatures.
- The same-origin proxy as Rack middleware or a mount, answering only its
  exact path, forwarding only one valid client IP address, and answering
  upstream trouble with `504 Gateway timeout` or `502 Bad gateway`, logged in
  one line. It reports itself upstream as `ruby/0.1.0`.
- No object shows a credential through `inspect`, `to_s`, `pp`, JSON or YAML,
  and `Marshal.dump` refuses them.
- Requires Ruby 3.2+. No runtime dependencies.
