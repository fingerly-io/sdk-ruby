# fingerly-ruby

Server-side event reads, webhook verification and a same-origin proxy for
Ruby.

```ruby
gem "fingerly", "~> 0.1"
```

```ruby
require "fingerly"

fingerly = Fingerly::Client.new(secret_key: ENV.fetch("FINGERLY_SECRET_KEY"))

request_id = ARGV.fetch(0) # the requestId the browser SDK's identify() returned
event = fingerly.events.get(request_id)
page = fingerly.events.list(level: "high", limit: 50)
page.each { |row| puts "#{row.request_id} #{row.suspect_level}" }
```

Event reads require `fly_sk_{production|staging|development}_` keys. Requests
go to `https://api.fingerly.io`; `endpoint:` overrides that for a local
API. Public, proxy, management, malformed and unsupported keys are rejected
before network access, by the constructor rather than by the first call.
Requests do not follow redirects. `get` and `list` each perform one request
and never retry.

Requires Ruby 3.2+, which is what the gemspec declares, and fiber-scheduler
support below needs nothing newer. No runtime dependencies: everything it
needs is in the standard library. Rack is a contract rather than a
dependency, so the proxy speaks it without loading it and cannot pin a version
against your own.

## There is no asynchronous client, and none is needed

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

## Deadlines

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

Idle connections are kept in one pool per process and destination, shared by
every client and proxy in it. `Net::HTTP` cannot be used by two threads or
fibers at once, so each exchange checks a connection out and hands it back
when it is done: a burst of a few hundred concurrent requests reuses its
sockets rather than opening one each, and a fiber that ends (Falcon runs one
per client connection) returns its socket instead of stranding it. At most
256 idle connections are kept per destination. A connection is reopened after
60 seconds, so DNS is asked again, and dropped after 15 seconds idle. One the
other end closed while it was idle is reopened and the request sent again,
but only for `GET`, because a `POST` that may already have arrived must never
be sent twice. A forked worker starts with an empty pool.

## Errors

Every runtime failure derives from `Fingerly::Error`. A bad option raises
`Fingerly::ConfigurationError`, which is an `ArgumentError`: a key that was
never valid is a programming mistake rather than something a rescue around the
call site can help with.

```ruby
def decide(fingerly, request_id)
  event = fingerly.events.get(request_id)
  event.scored? && event.suspect_level == "low" ? "allow" : "review"
rescue Fingerly::APIError => e
  return "retry later" if e.pending? # not decided yet: read again after e.retry_after
  return "refuse" if e.event_not_found?
  return "retry later" if e.status == 429

  raise
end
```

Every response outside 2xx, a redirect included, raises `Fingerly::APIError`.
It carries `status`, and optional `code`, `details`, `request_id` and
`retry_after`. The secret key is stripped from the first three, and the
response body is never echoed. `request_id` falls back to the `x-request-id`
header when the body is not an error envelope. `retry_after` is the
`Retry-After` header in whole seconds, from either of its forms, or `nil`
when there was none: on a `429` or a pending event, wait that long before
reading again.

A read answers `404` with one of two codes, each with its own predicate:

- `pending?`: `event_pending`, the request id was accepted and the event is
  still being recorded. Nothing is decided yet: read again after
  `retry_after` seconds (the API sends `Retry-After: 2`), or verify
  asynchronously. Do not treat it as fraud.
- `event_not_found?`: `event_not_found`, the request id was never issued, or
  the event is past retention.

The client never retries by itself. A deadline raises
`Fingerly::TimeoutError`; an unreachable API raises
`Fingerly::ConnectionError`.

No object in the SDK shows a credential. A client or proxy printed with
`inspect`, `to_s`, `pp`, `to_json` or YAML shows `[redacted]` in place of its
key, and `Marshal.dump` refuses it. The request handed to `client_ip` hides the
visitor's cookies and authorization header the same way.

## Unscored events

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

## Read an event you just identified

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
`has_document?` rather than assuming it is there.

## Verify a backend action

Read the event with a server-only key. Check that its tag matches your action,
that it is recent, that its environment is correct, and that it was scored.
Apply your own policy to the server's verdict. A pending event (`pending?`)
is not a verdict: retry after `retry_after` seconds or verify asynchronously,
rather than refusing the action. Do not authorize an action using scores or
visitor identifiers supplied by the browser. Tags correlate events; they do
not replace your application's authentication or replay protection. A tag must
never hold a personal identifier, such as a user ID, email, install ID or
advertising ID, because the server keeps tags in long-lived rollups.

## Webhooks

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

Verify the exact raw bytes before parsing them. `request.raw_post` is those
bytes; a body reconstructed from parsed parameters is not. Signatures cover
the timestamp and body. The default replay tolerance is five minutes; persist
processed `id` values to deduplicate deliveries. During signing-secret
rotation, any matching signature in the comma-separated header is accepted;
only the first 32 are read.
Malformed or missing input is a false result, never an exception, and a body
that is not valid UTF-8 verifies rather than raising on concatenation.

`WebhookEvent#data` stays a plain `Hash`, so a new event type needs no gem
upgrade. `identification.completed` and `visitor.suspect` deliveries carry the
event's project as `data["project_id"]`; `identification.refused` carries it
only when the refused request named a known key.

## Same-origin proxy

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

Then point the browser SDK at the same path. Both of its calls go there, with
nothing appended:

```ts
import { load } from '@fingerly/web-js'

const fingerly = await load({ apiKey: 'fly_pk_…', endpoints: '/k7x2qm4a' })
```

`path` is optional where the framework already routes the path to the proxy,
as a Rails `mount` or a `Rack::URLMap` entry does. Omit it there: the mount has
already moved the path into `SCRIPT_NAME`. A mount matches a prefix, but the
proxy still answers only the mount's exact path: `/k7x2qm4a/admin` or
`/k7x2qm4a/` routed to it get `404`. Rails hands a mount the same `PATH_INFO`
with and without a trailing slash, so the proxy tells them apart by the raw
request line in `REQUEST_URI`, which Puma and Falcon provide.

```ruby
# config/routes.rb
mount Fingerly::Proxy.new(
  proxy_key: ENV.fetch("FINGERLY_PROXY_KEY"),
  client_ip: ->(request) { request.header("CF-Connecting-IP") || request.peer_host }
) => "/k7x2qm4a"
```

As middleware it sees every request in the stack, so there `path` is required
and its absence is a `ConfigurationError` at start-up.

### What the proxy does

It answers only the configured path, matched exactly and case-sensitively:
`/k7x2qm4a/`, `//k7x2qm4a`, `/k7x2qm4a/.`, `/k7x2qm4a%2F` and `/k7x2qm4a/admin`
are not its own. Anything else is passed along to
your application, or answered `404` when the proxy has no application behind
it. On its own path, anything but `POST` gets `405`. Every request it accepts
goes to one URL, `https://api.fingerly.io/api/v1/ingest`, which tells the
identification from the report that follows it by the body. Nothing else is
reachable through it, event reads included: they need a secret key and stay
unreachable from a browser by construction. `api_version:` changes only the
version in that URL.

The browser must present a public key from the same environment as the proxy
key, or the request gets `401`. Bodies over 1 MiB get `413`,
enforced while reading rather than after buffering. That bounds what the proxy
holds. A server that buffers the whole request before calling the application,
as Puma does, has already read it by then, so bound request bodies there with
the server's or the load balancer's own limit as well. Falcon streams the body,
so there the proxy stops reading at the limit. Only the content type, the
visitor metadata Fingerly needs, and an `Idempotency-Key` are forwarded;
customer cookies and authorization headers never are. The proxy reports itself
upstream as `ruby/0.2.0` in `x-fingerly-proxy-version`, which the dashboard
shows per proxy.

When Fingerly cannot be reached, the visitor gets a gateway error rather than
your application's `500`: `504 Gateway timeout` when `timeout:` (5 seconds by
default) passes, and `502 Bad gateway` for anything else, whether the
connection was refused or reset, the name did not resolve, or the answer was
malformed, cut short or over 4 MiB. The whole answer is read before anything
is written back, so a truncated response is never relayed as a success. Each
failure logs one line, without a stack trace, to `logger:` when you pass one,
to `rack.logger` when your server provides it, and to standard error
otherwise.

Only `content-type`, `x-request-id`, `ratelimit-limit`, `ratelimit-remaining`
and `retry-after` are relayed back, plus `cache-control: no-store` set by the
proxy. A content blocker can match a response header by name, and an
allowlist keeps anything that names Fingerly off the response, whatever the
API adds later.

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

Relayed headers are lowercase and repeats joined with `", "`, which is the
one shape Rack 2 and Rack 3 both accept: Rack 3 refuses an uppercase name
outright, and Rack 2 refuses the array Rack 3 would rather have.

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

## Development and release preparation

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

## Source structure

`Client` holds the connection and the options; `Events` owns the reads and the
list filters, and `Event`, `EventPage` and `EventTrigger` are what they speak
in. `Webhooks` verifies signatures. `Proxy` holds every proxy decision, with
`ProxyRequest` as the shape `client_ip` is given. `Config` validates every
caller-supplied option before any network access, and `Transport` is the one
place that knows how to bound an exchange and reuse a socket.
