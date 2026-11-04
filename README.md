# fingerly-ruby

Server-side event reads, webhook verification and a same-origin proxy for
Ruby. Version 0.1.0 is prepared for release; the repository is private and
nothing has been published to RubyGems.

```ruby
gem "fingerly", "~> 0.1"
```

```ruby
require "fingerly"

fingerly = Fingerly::Client.new(secret_key: ENV.fetch("FINGERLY_SECRET_KEY"))

event = fingerly.events.get(request_id)
page = fingerly.events.list(level: "high", limit: 50)
```

Event reads require `fly_sk_{production|staging|development}_` keys. Requests
go to `https://api.fingerly.io`; `endpoint:` overrides that for a local
API. Public, proxy, management, malformed and unsupported keys are rejected
before network access, by the constructor rather than by the first call.
Requests do not follow redirects. `get` and `list` each perform one request
and never retry.

Ruby 3.2 or newer. No runtime dependencies: everything it needs is in the
standard library. Rack is a contract rather than a dependency, so the proxy
speaks it without loading it and cannot pin a version against your own.

## There is no asynchronous client, and none is needed

The Python SDK ships two clients because ASGI and WSGI are two live server
standards, and a blocking call inside FastAPI stalls its event loop. Ruby has
one server interface, Rack, and every framework on it calls your application
synchronously.

The stack that is not thread-per-request is covered anyway. `Net::HTTP` has
honoured the fiber scheduler since Ruby 3.0, so under Falcon or the `async`
gem the blocking reads in this SDK yield to the scheduler rather than holding
the thread. Concurrent calls overlap without a second API to choose between,
and there are tests asserting exactly that under both a fiber scheduler and
plain threads.

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
begin
  event = fingerly.events.get(request_id)
rescue Fingerly::APIError => e
  return "refuse" if e.status == 404

  raise
end
```

`Fingerly::APIError` carries `status`, and optional `code`, `details` and
`request_id`. The secret key is stripped from all three, and the response body
is never echoed. `event_not_found?` names the one retryable read failure, so
it needs no status-and-code check of your own. A deadline raises
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

## Read an event you just identified

An event is readable as soon as identification answers, so this needs nothing
special:

```ruby
event = fingerly.events.get(request_id)
```

Earlier versions had a `wait_for` that polled through the gap between
identification and the event becoming queryable. There is no gap, so
`event_not_found?` now means a request id that was never issued.

The archived document arrives moments after the event itself, so check
`has_document?` rather than assuming it is there.

## Verify a backend action

Read the event with a server-only key. Check that its tag matches your action,
that it is recent, that its environment is correct, and that it was scored.
Apply your own policy to the server's verdict. Do not authorize an action
using scores or visitor identifiers supplied by the browser. Tags correlate
events; they do not replace your application's authentication or replay
protection.

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
    FingerlyEventJob.perform_later(event.id, payload)   # deduplicate on the ID
    head :no_content
  end
end
```

Verify the exact raw bytes before parsing them. `request.raw_post` is those
bytes; a body reconstructed from parsed parameters is not. Signatures cover
the timestamp and body. The default replay tolerance is five minutes; persist
processed `id` values to deduplicate deliveries. During signing-secret
rotation, any matching signature in the comma-separated header is accepted.
Malformed or missing input is a false result, never an exception, and a body
that is not valid UTF-8 verifies rather than raising on concatenation.

`WebhookEvent#data` stays a plain `Hash`, so a new event type needs no gem
upgrade.

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
# config/application.rb
config.middleware.use Fingerly::Proxy,
  proxy_key: ENV.fetch("FINGERLY_PROXY_KEY"),
  path: "/k7x2qm4a",
  client_ip: ->(request) { request.header("CF-Connecting-IP") }
```

```ruby
# config.ru, for Sinatra, Hanami or a bare Rack app
use Fingerly::Proxy,
    proxy_key: ENV.fetch("FINGERLY_PROXY_KEY"),
    path: "/k7x2qm4a",
    client_ip: ->(request) { request.header("CF-Connecting-IP") }
run MyApp
```

Put it early, ahead of authentication: the browser SDK sends no cookies and
carries no user, and a filter that redirected it to a sign-in page would break
identification for every signed-out visitor.

Then point the browser SDK at the same path. Both of its calls go there, with
nothing appended:

```ts
const fingerly = await load({ apiKey: 'fly_pk_…', endpoints: '/k7x2qm4a' })
```

`path` is optional where the framework already routes the path to the proxy,
as a Rails `mount` or a `Rack::URLMap` entry does. Omit it there: the mount has
already moved the path into `SCRIPT_NAME`, and the proxy answers whatever the
mount hands it.

```ruby
# config/routes.rb
mount Fingerly::Proxy.new(
  proxy_key: ENV.fetch("FINGERLY_PROXY_KEY"),
  client_ip: ->(request) { request.header("CF-Connecting-IP") }
) => "/k7x2qm4a"
```

As middleware it sees every request in the stack, so there `path` is required
and its absence is a `ConfigurationError` at start-up.

### What the proxy does

It answers only the configured path, matched exactly with trailing slashes
ignored, so `/k7x2qm4a/admin` is not its own. Anything else is passed along to
your application, or answered `404` when the proxy has no application behind
it. On its own path, anything but `POST` gets `405`. Every request it accepts
goes to one URL, `https://api.fingerly.io/api/v1/ingest`, which tells the
identification from the report that follows it by the body. Nothing else is
reachable through it, event reads included: they need a secret key and stay
unreachable from a browser by construction. `api_version:` changes only the
version in that URL.

The browser must present a public key from the same environment as the proxy
key, or the request gets `401`. Bodies over 1 MiB get `413`,
enforced while reading rather than after buffering. Only the content type, the
visitor metadata Fingerly needs, and an `Idempotency-Key` are forwarded;
customer cookies and authorization headers never are. The proxy reports itself
upstream as `ruby/0.1.0` in `x-fingerly-proxy-version`, which the dashboard
shows per proxy.

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
> header your own infrastructure sets, such as your load balancer's or CDN's.
> Never read the left-most `X-Forwarded-For` value: the visitor writes it.

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

The gemspec sets `allowed_push_host` to an unresolvable host. Nothing here is
published yet, and a private SDK reaching a public registry is not a mistake
anybody can take back.

## Source structure

`Client` holds the connection and the options; `Events` owns the reads and the
list filters, and `Event`, `EventPage` and `EventTrigger` are what they speak
in. `Webhooks` verifies signatures. `Proxy` holds every proxy decision, with
`ProxyRequest` as the shape `client_ip` is given. `Config` validates every
caller-supplied option before any network access, and `Transport` is the one
place that knows how to bound an exchange and reuse a socket.
