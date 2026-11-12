# Changelog

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
