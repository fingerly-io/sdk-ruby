<p align="center">
  <a href="https://fingerly.io">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/fingerly-io/.github/main/assets/logo-dark.svg">
      <img src="https://raw.githubusercontent.com/fingerly-io/.github/main/assets/logo-light.svg" alt="Fingerly" height="44">
    </picture>
  </a>
</p>

<p align="center"><b>Fingerly for Ruby</b><br>Read device intelligence events, verify webhooks and serve the browser SDK from your own domain.</p>

<p align="center">
  <a href="https://rubygems.org/gems/fingerly"><img src="https://img.shields.io/gem/v/fingerly?style=flat-square" alt="Gem version"></a>
  <a href="https://github.com/fingerly-io/sdk-ruby/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/fingerly-io/sdk-ruby/ci.yml?style=flat-square&label=ci" alt="CI status"></a>
  <a href="https://github.com/fingerly-io/sdk-ruby/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-Apache--2.0-blue?style=flat-square" alt="License: Apache-2.0"></a>
  <img src="https://img.shields.io/badge/ruby-%E2%89%A5%203.2-CC342D?style=flat-square" alt="Ruby 3.2 or newer">
  <a href="https://docs.fingerly.io/docs/sdks/ruby"><img src="https://img.shields.io/badge/docs-docs.fingerly.io-111827?style=flat-square" alt="Documentation"></a>
</p>

<p align="center"><img src="https://raw.githubusercontent.com/fingerly-io/.github/main/assets/banner.webp" alt="Fingerly" width="100%"></p>

## What is this

The `fingerly` gem is the server-side SDK for Ruby. It reads Fingerly events
with a secret key, verifies webhook signatures and relays the browser SDK's
traffic through your own domain with a same-origin Rack proxy. It has no
runtime dependencies and is for backends that protect signups, logins and
payments from fraud and abuse. [Fingerly](https://fingerly.io) identifies the
device behind each session and scores how suspicious it is.

## Getting started

1. **Prerequisites.** A Fingerly account and a secret key (`fly_sk_...`). See
   [API keys and environments](https://docs.fingerly.io/docs/api-keys). Ruby
   3.2+.
2. **Install.** Add it to your `Gemfile`:

   ```ruby
   gem "fingerly", "~> 0.4.1"
   ```

3. **Read an event.**

   ```ruby
   require "fingerly"

   fingerly = Fingerly::Client.new(secret_key: ENV.fetch("FINGERLY_SECRET_KEY"))

   request_id = ARGV.fetch(0) # the requestId the browser SDK's identify() returned
   event = fingerly.events.get(request_id)
   page = fingerly.events.list(level: Fingerly::SuspectLevel::HIGH, limit: 50)
   page.each { |row| puts "#{row.request_id} #{row.suspect_level}" }
   ```

4. **Verify a webhook.**

   ```ruby
   class FingerlyWebhooksController < ActionController::API
     def create
       payload = request.raw_post

       valid = Fingerly::Webhooks.verify(
         secret: ENV.fetch("FINGERLY_WEBHOOK_SECRET"),
         payload: payload,
         timestamp: request.headers["x-fingerly-timestamp"],
         signature: request.headers["x-fingerly-signature"]
       )
       return head :bad_request unless valid

       event = Fingerly::Webhooks.parse(payload)
       # Hand the work to your own job queue here, deduplicating on event.id.
       Rails.logger.info("Fingerly webhook #{event.id} (#{event.type})")
       head :no_content
     end
   end
   ```

   ```ruby
   # config/routes.rb
   post "/webhooks/fingerly", to: "fingerly_webhooks#create"
   ```

Full guide: [docs.fingerly.io/docs/sdks/ruby](https://docs.fingerly.io/docs/sdks/ruby).

## Choose what you need

| I want to | Use | Read |
| --- | --- | --- |
| Read an event after the browser identified a visitor | `Fingerly::Client` and `events.get` / `events.list` | [Read events](#read-events) |
| Let one event back one backend action | `events.verify` and `events.consume` | [Verify a backend action](#verify-a-backend-action) |
| Read or write an iOS device's DeviceCheck bits | `device_check.query` / `device_check.write` | [DeviceCheck bits](#devicecheck-bits) |
| Check a webhook delivery is genuine | `Fingerly::Webhooks.verify` and `.parse` | [Verify webhooks](#verify-webhooks) |
| Keep the browser SDK first-party, away from content blockers | `Fingerly::Proxy`, a Rack middleware | [First-party proxy](#first-party-proxy-same-origin) |

On this page: [Read events](#read-events) · [DeviceCheck bits](#devicecheck-bits) · [Verify webhooks](#verify-webhooks) · [First-party proxy](#first-party-proxy-same-origin) · [Threads, fibers and deadlines](#threads-fibers-and-deadlines) · [Requirements](#requirements) · [Development](#development-and-release-preparation) · [Documentation](#documentation) · [Help](#help) · [Licence](#licence)

## Read events

Event reads require `fly_sk_{production|staging|development}_` keys. Requests
go to `https://api.fingerly.io`; `endpoint:` overrides that with a bare
`https` origin, scheme, host and an optional port. A path, query, fragment,
credentials, whitespace, a control character or plain `http` is a
`ConfigurationError`, and the message never repeats the value. For a local
test API, `allow_insecure_loopback: true` accepts `http://127.0.0.1`,
`http://localhost` and `http://[::1]` (with any port); leave it off in
production. Public, proxy, management, malformed and unsupported keys are rejected
before network access, by the constructor rather than by the first call.
Requests do not follow redirects. `get` and `list` each perform one request
and never retry.

### Unscored events

`event.suspect_score` is `nil` when the request was not scored. Never read nil
as zero: a visitor about whom nothing fired scores 0, while a submission that
was never enriched has no score at all. `scored?` states the distinction at
the call site.

```ruby
unless event.scored?
  # Decide on something else; do not treat it as clean.
end
```

`event.raw` keeps the response body exactly as it arrived, so a field the API
adds later is reachable without a gem upgrade.

`event.project_id` is the UUID string of the Fingerly project the event
belongs to, on both `events.get` and `events.list` rows; it is `nil` when an
older server does not send it.

`event.ai` is set only when `event.visitor_kind` is
`Fingerly::VisitorKind::AI_BOT`, and `nil` otherwise: a `Fingerly::AiAgent`
with the agent's `name`, `provider`, `purpose`, `runtime`, `declared?` and
`verification` (`method`, `result`). The identity comes from the user agent,
which anyone can copy, and is not verified yet
(`Fingerly::AiVerificationMethod::NONE`,
`Fingerly::AiVerificationResult::NOT_ATTEMPTED`), so treat it as a label, not
proof. Only clients that run the Fingerly SDK produce events, so crawlers that
do not run JavaScript never appear. `events.list` filters on `kind:`,
`ai_provider:` (exact and case-sensitive, such as `"OpenAI"`) and `ai_purpose:`.

```ruby
fetches = fingerly.events.list(
  kind: Fingerly::VisitorKind::AI_BOT,
  ai_purpose: Fingerly::AiPurpose::USER_FETCH
)
```

### Read an event you just identified

An event is usually readable as soon as identification answers. If it is
still being recorded, the read raises a `Fingerly::APIError` whose `pending?`
is true and whose `retry_after` says when to read again:

```ruby
# Returns the event, or nil while it is still being recorded.
def read_event(fingerly, request_id)
  fingerly.events.get(request_id)
rescue Fingerly::APIError => e
  raise unless e.pending?

  # Not recorded yet, so nothing is decided: read again after e.retry_after
  # seconds (2 when nil), or verify asynchronously.
  nil
end
```

Retry a pending read a bounded number of times, for example from a background
job. `event_not_found?` means a request id that was never issued, or one past
retention, and is never pending.

The archived document arrives moments after the event itself, so check
`has_document?` rather than assuming it is there, and read `event.document`
(`Hash` or `nil`, holding allow-listed `risk`, `attestation`, `ip_network` and
`velocity` fields without raw signals, user agent or address). When a submission
is unidentifiable (`identifiable == false`, such as insufficient entropy, a
genuine embedded WebView, or an unmatched high-risk Web payload),
`event.visitor_id` is `""`; there are no `deferred_token`, `deferred_signals` or
`supplements` fields in `v: 3`.

Compare fields against the named constants rather than raw strings. Each is
the frozen wire string itself, so `event.suspect_level ==
Fingerly::SuspectLevel::HIGH` is an ordinary string comparison, and every field
stays a `String`: a value the server adds later arrives unchanged, and is only
missing from the module's frozen `ALL` array.

| Module | Field | Values |
| --- | --- | --- |
| `Fingerly::Signal` | `EventTrigger#signal`, `#group` | every signal group and detector, such as `VPN`, `VPN_PUBLIC` and `FINGERPRINT_SUPPRESSED` |
| `Fingerly::SuspectLevel` | `Event#suspect_level`, webhook `data["level"]` | `LOW`, `MEDIUM`, `HIGH` |
| `Fingerly::Confidence` | `EventTrigger#confidence` | `LOW`, `MEDIUM`, `HIGH` |
| `Fingerly::EventState` | `Event#state` | `ENRICHED`, `UNAVAILABLE`, and `PENDING`, which a read raises as `pending?` |
| `Fingerly::Environment` | `Event#environment` | `PRODUCTION`, `STAGING`, `DEVELOPMENT` |
| `Fingerly::Platform` | `Event#platform` | `WEB`, `ANDROID`, `IOS` |
| `Fingerly::AnonymityNetwork` | `Event#anonymity_network` | `TOR`, `RELAY`, `VPN`, `PROXY`, `HOSTING` |
| `Fingerly::DeviceKind` | `Event#device_kind` | `DESKTOP`, `MOBILE`, `TABLET`, `SERVER` |
| `Fingerly::VisitorKind` | `Event#visitor_kind`, `events.list(kind:)` | `HUMAN`, `AI_BOT`, `AUTOMATION`, `SEARCH_CRAWLER` |
| `Fingerly::AiPurpose` | `AiAgent#purpose`, `events.list(ai_purpose:)` | `TRAINING`, `SEARCH`, `USER_FETCH`, `AGENT` |
| `Fingerly::AiRuntime` | `AiAgent#runtime` | `PROVIDER_CLOUD`, `HOSTED_BROWSER`, `USER_DEVICE` |
| `Fingerly::AiVerificationMethod` | `AiVerification#method` | `SIGNATURE`, `IP_LIST`, `REVERSE_DNS`, `NONE` |
| `Fingerly::AiVerificationResult` | `AiVerification#result` | `PASS`, `FAIL`, `NOT_ATTEMPTED` |
| `Fingerly::AttestationState` | `event.document["attestation"]["state"]` | `ATTESTED`, `NOT_ATTESTED`, `FAILED` |
| `Fingerly::AttestationStatus` | `event.document["attestation"]["status"]` | `VERIFIED`, `INDETERMINATE`, `INVALID`, `ABSENT`, `UNCONFIGURED` |
| `Fingerly::AttestSkippedReason` | `event.document["attestation"]["attest_skipped"]` | `NOT_OFFERED`, `UNSUPPORTED`, `CHALLENGE_UNAVAILABLE`, `KEY_ERROR`, `TIMEOUT`, `BACKOFF`, `INSTALL_UNAVAILABLE` |
| `Fingerly::VerifyReason` | `EventVerification#reason` | `OK` (`""`) and the failures in [Verify a backend action](#verify-a-backend-action) |
| `Fingerly::WebhookEventType` | `WebhookEvent#type` | see [Verify webhooks](#verify-webhooks) |
| `Fingerly::WebhookEnvironment` | `WebhookEvent#environment` | `LIVE`, `TEST` |

A constant's name is its value upper-cased, with `.` as `_` (`VerifyReason::OK` is `""`). Event reads report
each trigger under its signal group (`Fingerly::Signal::VPN`), while
`visitor.suspect` webhooks and the archived document's `risk.triggers` carry
the detector (`Fingerly::Signal::VPN_PUBLIC`) with its group beside it. Inside
`module Fingerly`, `Signal` names `Fingerly::Signal`; write `::Signal` for
Ruby's own. The `SIGNAL_*` constants on `Fingerly::EventTrigger` and its
`V3_SIGNALS` list are the same strings.

### Verify a backend action

`fingerly.events.verify` reads the event with the server-only key, checks
that it can back the action, and consumes it, so one event backs one
decision:

```ruby
def authorize_checkout(fingerly, request_id)
  result = fingerly.events.verify(request_id, tag: "checkout") # max_age_seconds: 300, consume: true
  return "refuse" unless result.ok? # result.reason names the failed check

  # The score policy is yours: verify never judges the score.
  result.event.suspect_level == Fingerly::SuspectLevel::LOW ? "allow" : "review"
rescue Fingerly::APIError => e
  return "retry later" if e.pending? # not decided yet: read again after e.retry_after

  raise
end
```

The checks run in this order and stop at the first failure, whose wire string
is `result.reason` (`""` when `result.ok?`), with a constant on
`Fingerly::VerifyReason` (also on `Fingerly::EventVerification`):

1. `not_found` (`NOT_FOUND`): the request id was never issued, or the event is
   past retention. `result.event` is `nil` for this reason only.
2. `too_old` (`TOO_OLD`): the event occurred more than `max_age_seconds`
   ago (300 by default), or carries no readable `occurred_at`.
3. `tag_mismatch` (`TAG_MISMATCH`): `tag:` was given and the event's tag is not
   exactly it. Without `tag:` nothing is compared; an empty tag raises
   `Fingerly::ConfigurationError`.
4. `unidentifiable` (`UNIDENTIFIABLE`): `event.visitor_id` is empty.
5. `unscored` (`UNSCORED`): the event has no suspect score.
6. `already_consumed` (`ALREADY_CONSUMED`): another call consumed the event
   first.

The consume runs last, only when every other check passed, so a failed check
leaves the event unused. Pass `consume: false` to check without consuming. An
invalid option raises `Fingerly::ConfigurationError` before anything is sent.
Any other failure raises as it does for `events.get`. A pending event
(`pending?`) is not a verdict: retry after `retry_after` seconds or verify
asynchronously, rather than refusing the action.

`fingerly.events.consume(request_id)` is the consume on its own. It returns a
`Fingerly::EventConsumption` (`request_id`, `consumed_at`, `first?`) the first
time, is never retried, and raises `Fingerly::EventAlreadyConsumedError`, a
`Fingerly::APIError` with `event_already_consumed?` true and the first
`consumed_at`, every time after.

Do not authorize an action using scores or visitor identifiers supplied by the
browser. Tags correlate events; they do not replace your application's
authentication. A tag must never hold a personal identifier, such as a user
ID, email, install ID or advertising ID, because the server keeps tags in
long-lived rollups.

### Errors

Every runtime failure derives from `Fingerly::Error`. A bad option raises
`Fingerly::ConfigurationError`, which is an `ArgumentError`: a key that was
never valid is a programming mistake rather than something a rescue around the
call site can help with.

```ruby
def decide(fingerly, request_id)
  event = fingerly.events.get(request_id)
  return "review" if event.visitor_id.empty? || !event.scored?
  return "refuse" if event.triggers.any? { |t| t.signal == Fingerly::Signal::ATTESTATION_FAILED }

  event.suspect_level == Fingerly::SuspectLevel::LOW ? "allow" : "review"
rescue Fingerly::APIError => e
  return "retry later" if e.pending? # not decided yet: read again after e.retry_after
  return "refuse" if e.event_not_found?
  return "retry later" if e.status == 429

  raise
end
```

| Error | Raised when |
| --- | --- |
| `Fingerly::ConfigurationError` (an `ArgumentError`) | A bad option, such as a key that was never valid. |
| `Fingerly::APIError` | Every response outside 2xx, a redirect included. Carries `status`, and optional `code`, `details`, `request_id` and `retry_after`. |
| `Fingerly::TimeoutError` | The deadline (`timeout:`) passed. |
| `Fingerly::ConnectionError` | The API is unreachable. |

On `APIError`, the secret key is stripped from the first three of those
fields, and the response body is never echoed. `request_id` falls back to the
`x-request-id` header when the body is not an error envelope. `retry_after` is
the `Retry-After` header in whole seconds, from either of its forms, or `nil`
when there was none: on a `429` or a pending event, wait that long before
reading again.

A read answers `404` with one of two codes, each with its own predicate:

| Predicate | Code | Meaning |
| --- | --- | --- |
| `pending?` | `event_pending` | The request id was accepted and the event is still being recorded. Nothing is decided yet: read again after `retry_after` seconds (the API sends `Retry-After: 2`), or verify asynchronously. Do not treat it as fraud. |
| `event_not_found?` | `event_not_found` | The request id was never issued, or the event is past retention. |

The client never retries an event read by itself; only a
[DeviceCheck](#devicecheck-bits) call retries, and only the same request.

No object in the SDK shows a credential. A client or proxy printed with
`inspect`, `to_s`, `pp`, `to_json` or YAML shows `[redacted]` in place of its
key, and `Marshal.dump` refuses it. The request handed to `client_ip` hides the
visitor's cookies and authorization header the same way.

## DeviceCheck bits

On iOS, Apple keeps two DeviceCheck bits per device for your developer team,
and they survive a reinstall. When DeviceCheck is on for the project's Apple
key, Fingerly holds the DeviceCheck token that came with an identification for
one hour, and your backend spends it once:

```ruby
bits = fingerly.device_check.query(request_id)    # Fingerly::DeviceCheckBits
bits.found      # false when Apple holds no bits for the device yet
bits.bit0       # true or false
bits.last_update # "YYYY-MM", or nil when Apple holds no bits

written = fingerly.device_check.write(request_id, bit0: true) # Fingerly::DeviceCheckWrite
written.bit0    # true; a bit left out is nil, and keeps its value at Apple
```

Apple treats each DeviceCheck token as single-use, so one event pays for one
call: a read or a write, never both. A flow that checks and then marks a
device, such as a once-per-device free trial, takes two identifications:

1. Query on the identification that asks for the trial. If the bits say the
   device already had one, refuse it.
2. Otherwise grant the trial and record the grant in your own data.
3. Write the bit on the next identification from that install, such as one
   the app makes right after the grant. Until the write lands, your own record
   of the grant is what stops a second trial.

```ruby
# bit0 means "this device has had a free trial". The meaning is yours.
def start_trial(fingerly, account, request_id)
  bits = begin
    fingerly.device_check.query(request_id)
  rescue Fingerly::DeviceCheckError => e
    raise unless e.not_held? || e.spent? || e.apple_rejected?

    nil # no answer, not a verdict: decide without the bits
  end
  return "offer-paid-plan" if bits&.bit0

  Trial.grant(account, device_marked: false)
  "granted"
end

def mark_trial(fingerly, account, request_id)
  fingerly.device_check.write(request_id, bit0: true)
  Trial.update(account, device_marked: true)
rescue Fingerly::DeviceCheckError => e
  raise unless e.not_held? || e.spent?
  # Keep device_marked false and write at the install's next identification.
end
```

A failure raises `Fingerly::DeviceCheckError`, a `Fingerly::APIError` with a
predicate per code:

| Status | Code | Predicate |
|---|---|---|
| 404 | `device_check_not_held` | `not_held?` |
| 409 | `device_check_spent` | `spent?` |
| 409 | `device_check_busy` | `busy?` |
| 409 | `credential_unavailable` | `credential_unavailable?` |
| 422 | `bits_required` | `bits_required?` |
| 422 | `apple_rejected` | `apple_rejected?`, with Apple's HTTP status in `apple_status` |
| 503 | `device_check_unavailable` | `unavailable?` |

A write that names neither bit raises `Fingerly::ConfigurationError` before
anything is sent.

The token may be retried only with the same request. After a `503` or a
transport failure the token is kept, so the client sends the identical request
again, up to three attempts in all; it retries nothing else. If you retry
later yourself, repeat the same call with the same bits: a read after a failed
write, or a write with other bits, answers `409 device_check_spent`. Apple asks
that DeviceCheck is never the only fraud check, and that users have a way to
have the bits reset.

## Verify webhooks

The controller and route are in [Getting started](#getting-started). Verify the
exact raw bytes before parsing them. `request.raw_post` is those bytes; a body
reconstructed from parsed parameters is not.

| Behaviour | Detail |
| --- | --- |
| What a signature covers | the timestamp and the body |
| Replay tolerance | five minutes by default |
| Secret rotation | any matching signature in the comma-separated header is accepted; only the first 32 are read |
| Malformed or missing input | a false result, never an exception; a body that is not valid UTF-8 verifies rather than raising on concatenation |
| Deduplication | persist processed `id` values to deduplicate deliveries |

`WebhookEvent#data` stays a plain `Hash`, so a new event type needs no gem
upgrade. Dispatch on `event.type` with `Fingerly::WebhookEventType`:

```ruby
case event.type
when Fingerly::WebhookEventType::VISITOR_SUSPECT # sent for SuspectLevel::HIGH only
  review(event.data["request_id"])
when Fingerly::WebhookEventType::IDENTIFICATION_COMPLETED,
     Fingerly::WebhookEventType::IDENTIFICATION_REFUSED
  record(event.data)
when Fingerly::WebhookEventType::WEBHOOK_TEST
  nil # sent to one endpoint on request; nobody subscribes to it
end
```

The other types are `BILLING_STATUS_CHANGED` (`billing.status_changed`) and
`USAGE_DAILY_SETTLED` (`usage.daily_settled`). `identification.completed` and `visitor.suspect` deliveries carry the
event's project as `data["project_id"]`; `identification.refused` carries it
only when the refused request named a known key.

## First-party proxy (same-origin)

Content blockers refuse browser requests to third-party APIs, and a refused
identification is a visitor never identified. Mount the proxy on a path of
your own site and those requests become first-party. The proxy key is what
lets that hop declare the visitor's real address, origin and user agent; a
public key alone never can, so nobody can spoof them.

Create a proxy in the dashboard (**Integration > Proxy keys**). It issues a
path such as `/k7x2qm4a`, and the proxy answers that one path. Rack is the one
interface every Ruby server and framework shares, so there is one middleware
and no per-framework variants.

```ruby
# config/application.rb, inside `class Application < Rails::Application`
config.middleware.insert_before 0, Fingerly::Proxy,
  proxy_key: ENV.fetch("FINGERLY_PROXY_KEY"),
  path: "/k7x2qm4a",
  client_ip: ->(request) { request.header("CF-Connecting-IP") || request.peer_host }
```

Use `insert_before 0`, not `use`. `use` appends the proxy after Rails' own
middleware, which then rewrites its answers on the way out:
`ActionDispatch::RequestId` replaces Fingerly's `x-request-id` with a Rails
one, and `Rack::ETag` and `Rack::Runtime` add `etag` and `x-runtime`. At the
front of the stack the proxy answers before any of them, and before anything
that could redirect a signed-out visitor.

```ruby
# config.ru, for Sinatra, Hanami or a bare Rack app
require "fingerly"
require_relative "app" # defines MyApp, your Sinatra or Rack application

use Fingerly::Proxy,
    proxy_key: ENV.fetch("FINGERLY_PROXY_KEY"),
    path: "/k7x2qm4a",
    client_ip: ->(request) { request.header("CF-Connecting-IP") || request.peer_host }
run MyApp
```

Put it first, ahead of authentication: the browser SDK sends no cookies and
carries no user, and a filter that redirected it to a sign-in page would break
identification for every signed-out visitor.

> **`client_ip` is the one thing you must get right.** Resolve it from a
> header your own infrastructure sets, such as your load balancer's or CDN's,
> and fall back to `request.peer_host`, the TCP peer, when it is absent, as in
> local development. Trust that header only when traffic can reach your
> application through that CDN alone; otherwise a visitor can set it. Never read
> the left-most `X-Forwarded-For` value: the visitor writes it.

`client_ip` must return exactly one IPv4 or IPv6 address. Anything else, `nil`
or an empty string, a list, a port, a prefix length, or an exception, is a
configuration mistake: the proxy sends nothing upstream, answers `500` with
"The client IP callback returned no valid address", and logs it once per
process rather than once per visitor.

Then point the client SDK at the same path. Browser and proxied native SDKs post
a single `v: 3` identification envelope there, with nothing appended:

```ts
import { load } from '@fingerly/web-js'

const fingerly = await load({ apiKey: 'fly_pk_…', endpoints: '/k7x2qm4a' })
```

`proxy_key` and `path` are required. A proxy key that is not
`fly_px_<environment>_...` for `production`, `staging` or `development`, or a
missing `path`, is a `ConfigurationError` at start-up. The proxy matches it
exactly against `PATH_INFO`, so use it as middleware, as above, or run it as
the whole application. Do not put it behind a Rails `mount` or a
`Rack::URLMap` entry: those move the path into `SCRIPT_NAME`, and the proxy
then sees a path that is not its own and answers `404`.

### What the proxy does

| Rule | Behaviour |
| --- | --- |
| Path match | Only the configured path, matched exactly and case-sensitively: `/k7x2qm4a/`, `//k7x2qm4a`, `/k7x2qm4a/.`, `/k7x2qm4a%2F`, `/k7x2qm4a/admin` and retired `/supplement` paths are not its own. Anything else is passed along to your application, or answered `404` when the proxy has no application behind it. |
| Other methods | On its own path, anything but `POST` (plus `OPTIONS` when `allowed_origins:` is configured) gets `405`. Methods are compared exactly, so `post` gets `405` too. |
| Own answers | Every answer the proxy writes itself carries `cache-control: no-store`. |
| Upstream | Every request it accepts goes verbatim as raw bytes to one URL, `https://api.fingerly.io/api/v1/ingest`. `api_version:` changes only the version in that URL. |
| Event reads | Nothing else is reachable through it, event reads included: they need a secret key and stay unreachable from a browser by construction. |
| Public key | The caller must present a public key (`fly_pk_...`) from the same environment as the proxy key, or the request gets `401` and nothing is forwarded; a secret key is refused the same way. |
| Credentials upstream | Every request carries the proxy key as `X-Fingerly-Proxy-Key` and the caller's public key as `X-API-Key`, never a secret key. |
| Origin or platform | Requests without either `Origin` or a validated native `X-Fingerly-SDK-Platform` header (`ios`, `android`, `react-native`, `react-native-ios`, `react-native-android`, `flutter`, `flutter-ios`, `flutter-android`, `lynx-ios`, `lynx-android`, `capacitor`, `kotlin-multiplatform`) are rejected locally with `400` (`missing_origin`), and `x-fingerly-origin` is never synthesized from `Host`, `Referer` or the request URL. A request is forwarded on one channel only: with an `Origin` the proxy sends `x-fingerly-origin` and drops the platform header, and without one it sends the validated platform. |
| Body size | Bodies over 1 MiB get `413`, enforced while reading rather than after buffering. |
| Forwarded headers | All incoming `x-fingerly-*`, `cookie` and `authorization` headers are stripped, restoring only a validated `x-fingerly-sdk-platform` (when there is no `Origin`) alongside `x-fingerly-host`, `idempotency-key`, `sec-fetch-*`, `sec-ch-ua-*` and the Web Bot Auth `signature`, `signature-input` and `signature-agent` (each dropped when over 4096 bytes). |
| Proxy identity | The proxy reports itself upstream as `ruby/0.4.1` in `x-fingerly-proxy-version`, which the dashboard shows per proxy. |
| Fingerly unreachable | The visitor gets a gateway error rather than your application's `500`. |
| Deadline passes | `504 Gateway timeout` when `timeout:` (5 seconds by default) passes. |
| Any other upstream failure | `502 Bad gateway`, whether the connection was refused or reset, the name did not resolve, or the answer was malformed, cut short or over 4 MiB. Redirects are never followed, and an upstream redirect or a status outside `200` to `599` is answered `502` as well. |
| Truncated answers | The whole answer is read before anything is written back, so a truncated response is never relayed as a success. |
| Failure logging | Each failure logs one line, without a stack trace, to `logger:` when you pass one, to `rack.logger` when your server provides it, and to standard error otherwise. The line names the kind of failure only, never the upstream address or a key. |
| Relayed back | Only `content-type`, `x-request-id`, `ratelimit-limit`, `ratelimit-remaining` and `retry-after`, plus `cache-control: no-store` set by the proxy. A content blocker can match a response header by name, and an allowlist keeps anything that names Fingerly off the response, whatever the API adds later. |
| Header shape | Relayed headers are lowercase and repeats joined with `", "`, which is the one shape Rack 2 and Rack 3 both accept: Rack 3 refuses an uppercase name outright, and Rack 2 refuses the array Rack 3 would rather have. |

The 1 MiB limit bounds what the proxy holds. A server that buffers the whole
request before calling the application, as Puma does, has already read it by
then, so bound request bodies there with the server's or the load balancer's own
limit as well. Falcon streams the body, so there the proxy stops reading at the
limit.

`upstream:` takes a bare origin, scheme, host and an optional port, such as
`https://api.fingerly.io`. A path, query, fragment, credentials, whitespace or
a control character is a `ConfigurationError`, and so is plain `http`. For a
local test API, `allow_insecure_loopback: true` accepts `http://127.0.0.1`,
`http://localhost` and `http://[::1]` (with any port), and nothing else; leave
it off in production.

<details>
<summary>Why the middleware decides from the path alone, and what <code>path</code> means</summary>

The middleware decides from the path alone before it reads anything. It sees
every request in the stack, and reading the body to find out whether one
belongs to Fingerly would have consumed it: under Rack 3 `rack.input` is not
required to rewind, so your application would receive an empty request rather
than an error.

`path` is the path within your application. It excludes anything a sub-URI
deployment puts in `SCRIPT_NAME`, because the proxy matches `PATH_INFO`, which
means the same thing wherever the application is deployed. Use the one the
dashboard issued rather than inventing one: blockers look for words such as
`fingerprint`, `tracking` and `analytics` in a path.

</details>

## Threads, fibers and deadlines

There is no asynchronous client, and none is needed.

The Python SDK ships two clients because ASGI and WSGI are two live server
standards, and a blocking call inside FastAPI stalls its event loop. Ruby has
one server interface, Rack, and every framework on it calls your application
synchronously.

The stack that is not thread-per-request is covered anyway. On Ruby 3.2+,
the floor this gem requires, `Net::HTTP` yields to a fiber scheduler, so under
Falcon or the `async` gem the blocking reads in this SDK hand the thread back
to the scheduler rather than holding it. Concurrent calls overlap without a
second API to choose between, and there are tests asserting exactly that under
both a fiber scheduler and plain threads.

Where there is no fiber scheduler, a call holds its thread until it answers,
for at most `timeout:`. That is what Puma and Unicorn expect. Do not call the
client from an event loop that is not a fiber scheduler, such as an
EventMachine reactor: there it would stall every connection the loop serves.

Size the thread pool for the slow case, not the average one: while Fingerly is
slow, every proxied request holds its thread for the whole `timeout:`. At 100
proxied requests a second with 1% of them running into a 5 second timeout, that
is 5 threads busy on average, before any fast request is served. Run more
threads than that across your Puma or Unicorn workers, lower `timeout:` for the
proxy, or serve with Falcon, where a waiting call holds no thread.

### Deadlines

`timeout:` bounds the whole exchange: connecting, sending, the response
headers and the body.

That takes care on this platform. `Net::HTTP` has `open_timeout`,
`read_timeout` and `write_timeout`, but each bounds a single operation: a
server that answers and then sends one byte a second would satisfy all three
forever, and so would one that sends a header line a second, because each
header line gets the full read timeout. The client shrinks the socket's own
timeouts to whatever is left of the deadline before each step, and one
`Timeout` around the whole exchange covers the header lines, so the bound is
tight rather than a multiple of the timeout. Under a fiber scheduler that
`Timeout` is the scheduler's own.

### Connection pool

Idle connections are kept in one pool per process and destination, shared by
every client and proxy in it. `Net::HTTP` cannot be used by two threads or
fibers at once, so each exchange checks a connection out and hands it back
when it is done: a burst of a few hundred concurrent requests reuses its
sockets rather than opening one each, and a fiber that ends (Falcon runs one
per client connection) returns its socket instead of stranding it.

| Pool rule | Value |
| --- | --- |
| Idle connections kept | at most 256 per destination |
| Reopened after | 60 seconds, so DNS is asked again |
| Dropped after | 15 seconds idle |
| Closed while idle by the other end | reopened and the request sent again, but only for `GET`, because a `POST` that may already have arrived must never be sent twice |
| Forked worker | starts with an empty pool |

## Requirements

Ruby 3.2+, which is what the gemspec declares (`required_ruby_version >= 3.2.0`),
and fiber-scheduler support needs nothing newer. CI runs Ruby 3.2, 3.3 and 3.4.
No runtime dependencies: everything it needs is in the standard library. Rack is
a contract rather than a dependency, so the proxy speaks it without loading it
and cannot pin a version against your own.

## Development and release preparation

<details>
<summary>Tests, signatures, contract snapshot, release, source structure</summary>

```sh
bundle install
bundle exec rake                 # tests, RuboCop and the RBS signatures

FINGERLY_CONTRACT_DIR=../../contract bundle exec ruby tools/sync_contract.rb
```

Tests run with Ruby's own warnings on, and every proxy response goes through
`Rack::Lint`, which holds it to the Rack 3 spec more strictly than any
assertion written by hand. The fake API is a real WEBrick server on a loopback
port rather than a stubbed `Net::HTTP`: a stub shares this SDK's assumptions
about framing, keep-alive and compression, so it cannot disprove any of them.

`sig/fingerly.rbs` describes the public surface. `rbs validate` proves the
signatures are consistent; `test/signatures_test.rb` proves they describe the
library that exists, which matters because several readers are defined by
metaprogramming.

The vendored synthetic contract snapshot makes tests independent of sibling
repositories. Its hashes are checked by `ContractTest`, so there is no
separate check step. Never put production secrets in fixtures.

The gemspec sets `allowed_push_host` to RubyGems, so a push to any other host
is refused.

### Source structure

`Client` holds the connection and the options; `Events` owns the reads and the
list filters, and `Event`, `EventPage` and `EventTrigger` are what they speak
in. `Webhooks` verifies signatures. `Proxy` holds every proxy decision, with
`ProxyRequest` as the shape `client_ip` is given. `Config` validates every
caller-supplied option before any network access, and `Transport` is the one
place that knows how to bound an exchange and reuse a socket.

</details>

## Documentation

- [Ruby SDK guide](https://docs.fingerly.io/docs/sdks/ruby)
- [Webhooks](https://docs.fingerly.io/docs/webhooks)
- [Proxy integrations](https://docs.fingerly.io/docs/proxy-integrations)
- [API reference](https://docs.fingerly.io/reference/overview)

## Help

Open an issue on [this repository](https://github.com/fingerly-io/sdk-ruby/issues), or write to
[support@fingerly.io](mailto:support@fingerly.io). Report security issues to
[security@fingerly.io](mailto:security@fingerly.io).

## Licence

Apache-2.0. See [LICENSE](https://github.com/fingerly-io/sdk-ruby/blob/main/LICENSE).
