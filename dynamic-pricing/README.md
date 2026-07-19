# Dynamic Pricing Proxy

The whole design rests on one idea: there's exactly one snapshot of pricing data in the
system, it covers all 36 `(period, hotel, room)` combinations at once, and it's swapped
atomically under a single cache key. Concretely that means every refresh is one bulk
call to the upstream model instead of 36 separate ones, freshness (five minutes) is
checked at read time rather than assumed from a schedule, and the worst case is 288
refresh cycles a day — 576 upstream calls once you count the one retry each gets —
against a 1,000/day limit with room to spare.

Caching wasn't the hard part. The hard part was that the upstream lies: probing it
directly (see `docs/recon-notes.md`) showed something like 5-10% of calls come back
`200 OK` with an error-shaped body, a missing `rate` key, or a rate in a different type
than the docs claim, so "the call succeeded" had to be a statement about the parsed
content, not the status code. The other hard part was coordination — making sure that
under real concurrent load, exactly one request per stale window actually goes to
PricingClient while everyone else either gets the fast path or waits for the winner.

## the math

Start with the keyspace, because it's the whole game: 4 periods times 3 hotels times 3
rooms is 36 combinations, full stop, no more and no fewer. That number being small and
fixed is the only reason "fetch everything, cache it, serve from cache" is even an
option here — the moment the keyspace is open-ended (arbitrary hotel IDs, say), this
falls apart, and I get back to that in "where this design breaks."

A day has 288 five-minute windows. If I refresh once per window, that's 288 upstream
calls a day against a budget of 1,000. If instead I fetched per key on a normal
cache-aside pattern — one upstream call per `(period, hotel, room)` the first time
someone asks for it after expiry — the worst case is 36 keys times 288 windows, which
is 10,368 calls a day. Ten times the budget. That arithmetic alone kills per-key
caching before I even have to think about concurrency.

| quantity | value |
| --- | --- |
| combinations (4 periods x 3 hotels x 3 rooms) | 36 |
| refresh windows/day (24h / 5min) | 288 |
| daily upstream budget | 1,000 |
| per-key worst case (36 x 288) | 10,368 |
| snapshot worst case, zero retries (288 x 1) | 288 |
| snapshot worst case, one retry each (288 x 2) | 576 |

The retry policy adds one more multiplier. `PricingClient::MAX_ATTEMPTS` is 2 — one
retry on any transient failure (timeout, connection error, 5xx, or a fake-success 200
that fails content validation), never on 429 or other 4xx — so the absolute worst case
is 288 windows times 2 attempts, 576 calls, still comfortably under 1,000. Retrying the
content-validation failures too is what actually makes the next number hold: given the
roughly 5-10% per-attempt failure rate I measured against the real simulator — and that
rate now covers all of those transient conditions, not just timeout/5xx — a window only
fails when two attempts in a row both go bad, which is that rate squared: 0.25% to 1%.
That's the number I'm actually optimizing: not "does upstream ever fail" but "how often
does a user see a 503 because of it."

I went back and forth on whether one retry is enough. A second retry would cut the
window-failure chance by another factor of that same per-attempt rate — down to roughly
0.01% to 0.1% — and there's plenty of quota headroom to afford it: 576 of 1,000 leaves
424 to spare. I landed on one anyway, mostly because every extra attempt adds up to 5
more seconds to a request that's already waiting on a lock, and that felt like a worse
trade than a failure mode that already lands under 1%. I'm not fully sold on that call.

## what I tried and threw away

The first thing I sketched was a scheduled job — something on a 5-minute cron hitting
PricingClient and filling the snapshot proactively, so requests never pay for a fetch.
I dropped it once I noticed the read-time freshness check has to exist regardless of
whether a scheduler exists: if the job dies silently or the container restarts and
misses a tick, a request still needs to know "is what I have actually fresh" before
serving it. Once that check exists on the read path anyway, a scheduler only buys
faster cold starts, at the cost of a whole second failure mode — a hung or dead job —
and another moving part to run and monitor. Not worth it under a "no new infra" rule.

Per-key lazy fetching was more tempting, because it's the default cache pattern
everyone reaches for first, and it's literally what the scaffold already did —
`PricingService` called `RateApiClient.get_rate` once per incoming request, no cache at
all, one key at a time. Obvious move. The math from the previous section rules it out
directly, though: 10,368 calls a day against a 1,000 budget isn't a close call, it's
over by 10x.

The third thing I considered, and I went back and forth on this one, was
stale-while-revalidate: on a stale snapshot, serve the old rate and kick off a
background refresh instead of making the caller wait or fail. I read "a rate is valid
for at most 5 minutes" as a correctness statement from the pricing model's owners, not
a latency budget I get to negotiate — past that window the number is understood to be
wrong, not just old. Serving it anyway is serving a wrong price with a straight face.
So `RateRefresher#ensure_fresh!` fails loud instead: a descriptive 503, not a
confident-looking stale number. If that's ever the wrong call — if availability turns
out to matter more than a few minutes of price drift — it's a one-line change at that
same freshness gate: return whatever's in `RateSnapshot` instead of raising when
nothing fresh is available.

I kept HTTParty for the HTTP layer rather than swapping to something else. The scaffold
already used it in `RateApiClient`, and it does exactly what I needed here — separate
`open_timeout` and `read_timeout` per request — without pulling in anything new.

## one fetch, not many

Coordination is `RateRefresher`, and the lock underneath it is
`Rails.cache.write(key, token, unless_exist: true, expires_in: LOCK_TTL)` — the same
"set if absent, with a TTL" primitive as Redis's `SET NX EX`, expressed through whatever
`Rails.cache` happens to be. Here that's `:memory_store`, in-process only, which makes
this a Mutex with one property a Mutex doesn't have: an expiry. A holder that dies
mid-fetch doesn't wedge every future refresh behind it, because the lock ages out and
the next caller gets to try. Whoever wins the lock re-checks freshness before calling
`PricingClient`, because between "I saw it was stale" and "I acquired the lock," someone
else might have already refreshed it — and that re-check is, structurally, the entire
reason upstream is never called more than once per window no matter how many requests
pile up on the read side at once. `test/services/rate_refresher_test.rb` proves it
directly: 10 threads fired at an expired snapshot, exactly one upstream request.
Everyone who loses the lock race polls for the winner to publish, checking every 100ms
up to `RateRefresher::POLL_TIMEOUT`.

That poll timeout is the piece of this I'm least settled on. It's 3 seconds.
`PricingClient`'s own worst case, by contrast, is roughly 10 to 10.5 seconds — two
attempts, each up to a 2-second connect plus 3-second read timeout, with a short
jittered sleep between them (that gap is why `RateRefresher::LOCK_TTL` is set to 15
seconds, not 3). So under a slow-but-eventually-successful refresh, a waiting request
can time out and get a 503 several seconds before the request that's actually doing the
fetching goes on to succeed. I picked 3 seconds to keep the common case snappy —
upstream answers in well under a second almost all the time — instead of making every
waiting request eat the full worst case on the rare occasion it's needed. That's a bet
on the common path, not a proof, and it's the part of this design I'd want real
production latency data on before I'd call it settled.

One more thing worth being explicit about: the whole 288-cycles-a-day proof holds per
process, not per deployment. The lock and the snapshot both live in `Rails.cache`'s
`:memory_store`, which doesn't exist outside the process that created it — two Puma
workers would each think they're the only one talking to upstream, and the real call
count would multiply by however many workers are running. `config/puma.rb` pins this to
single-process mode on purpose, with a comment explaining why, rather than leaving it as
an accident of whatever `WEB_CONCURRENCY` happens to be set to in a given environment.
Scaling out from here doesn't mean rewriting the coordination logic — it means swapping
`Rails.cache` for a real shared store (Redis, say), at which point the exact same
`unless_exist` lock becomes a genuine distributed `SET NX EX` and nothing else in
`RateRefresher` has to change.

## proving it in production

Two structured log lines carry the observability load here, both single-line JSON via
`StructuredLogger`, both already written rather than bolted on for this README.
`pricing.request` fires once per request that reaches the snapshot lookup: `event`,
`request_id`, `cache` (`hit`, `refreshed`, or `unavailable`), `status`, `duration_ms`.
`rates.refresh` fires once per actual attempt to talk to `PricingClient`: `event`,
`outcome` (`success`, `rate_limited`, `invalid_response`, `timeout`, or
`upstream_error`), `duration_ms`, `upstream_calls_today`.

That last field is on every single `rates.refresh` line on purpose. "the math" above is
a claim about a number — at most 576 upstream calls a day — and a claim you can't
observe in production isn't proven, it's asserted. Logging the running count on every
refresh line means anyone watching logs can see the actual number track against the
ceiling in real time, not just trust that the tests pass. `PricingClient` also logs a
WARN once that counter crosses 500; what that means and why it's an alarm rather than a
breaker is covered in "where this design breaks."

## when the upstream misbehaves

Two guarantees hold no matter which of the conditions below happens: a bad or missing
fetch never overwrites a snapshot that was already good (this is asserted byte-for-byte
in `test/controllers/pricing_controller_upstream_failures_test.rb`, not just
eyeballed), and the caller is always told the truth — either a real rate or an explicit
503, never a silently stale or silently wrong one. None of the rows below are
hypothetical. Every one was reproduced against the real `tripladev/rate-api` simulator
before I wrote the handling for it; the raw sessions are in `docs/recon-notes.md`.

Every 503 body in this table is `{"error": "Pricing data is temporarily unavailable: Failed to refresh pricing snapshot: <detail>"}` — the "detail" column below is that trailing part, which is where the condition-specific information actually lives.

| condition | what upstream returned (observed) | our status | detail (trailing part of the error message) | snapshot | retried |
| --- | --- | --- | --- | --- | --- |
| timeout / hang | no response at all, connection stayed open past 15s in my testing | 503 | `PricingClient::Timeout: Pricing upstream timed out after 2 attempt(s): execution expired` | untouched | yes, once |
| connection refused | n/a (upstream process down) | 503 | `PricingClient::ConnectionError: Pricing upstream connection failed after 2 attempt(s): Errno::ECONNREFUSED: Connection refused` | untouched | yes, once |
| 500 | `{"error":"An unexpected internal error occurred"}` | 503 | `PricingClient::UpstreamError: Upstream returned unexpected status 500: {"error":"An unexpected internal error occurred"}` | untouched | yes, once |
| 429, quota exhausted | `{"error": "Rate limit exceeded (1000/day)"}` | 503 | `PricingClient::RateLimited: Upstream rate limit exceeded (429): {"error": "Rate limit exceeded (1000/day)"}` | untouched | no |
| 401, bad token | `{"error": "Unauthorized"}` | 503 | `PricingClient::AuthenticationError: Upstream rejected the API token (401) — check RATE_API_TOKEN` | untouched | no |
| response isn't valid JSON | (our test) `200` with a truncated body; separately, sending upstream a malformed *request* got back an HTML 400 page, not JSON, in recon | 503 | `PricingClient::InvalidResponse: Upstream response was not valid JSON: unexpected token at ...` | untouched | yes, once |
| 200 with an error-shaped body | `{"message":"Failed to process rates due to an intermittent issue.","status":"error"}`, HTTP 200 | 503 | `PricingClient::InvalidResponse: Response missing a "rates" array` | untouched | yes, once |
| 200, a rate object missing its `rate` key | observed on an otherwise normally-shaped 200 | 503 | `PricingClient::InvalidResponse: Non-numeric rate for ["Summer", "FloatingPointResort", "SingletonRoom"]: nil` | untouched | yes, once |
| 200, `rate` sent as a JSON integer instead of a string | e.g. `"rate": 73000` instead of `"rate": "73000"` | **200**, not an error | n/a — accepted, normalized to `"73000"` | updated | n/a |

That last row is deliberate, not an oversight — more on it in the next section.

The scaffold had its own landmine, and I want to name it because it's the kind of bug
that hides well: the original `pricing_service.rb` checked failures with
`rate.body['error']`, where `body` is a raw JSON string. `String#[]` with a string
argument does a substring search, not a hash lookup, so that line "succeeded" (returned
a truthy match) any time the word "error" showed up anywhere in the response body —
including inside a perfectly fine success payload that happened to mention it. I
replaced it with real parsing plus the content validation described above.

## the boundary

Freshness is `Time.current - fetched_at <= 5.minutes` — inclusive. A snapshot fetched
at 12:00:00 is still considered fresh, and still served with zero upstream calls, at
exactly 12:05:00; one second later it's stale. That `<=` was a coin flip when I wrote
it, but it's pinned by a test that checks the boundary at exactly 5:00
(`test/models/rate_snapshot_test.rb`, and again end-to-end through the actual endpoint
in `test/controllers/pricing_controller_freshness_test.rb`), which is what turns an
arbitrary choice into a contract someone can rely on instead of a guess someone has to
re-verify by reading the source.

The type-normalization row from the table above gets the same treatment. Upstream's
own docs describe `rate` as a string; empirically it's sometimes a JSON integer for the
identical field on the identical endpoint. `PricingClient#numeric_rate?` accepts either
representation and normalizes to a string on the way into the snapshot — rejecting a
solid chunk of otherwise-good responses over a type the documentation got wrong felt
like the wrong trade. That's pinned too, in
`test/services/pricing_client_test.rb` ("accepts integer rate values and normalizes
them to strings").

One small departure from the scaffold, while I'm on the subject of deliberate choices:
validation failures return 422 now, not the scaffold's original 400. 422 is the more
accurate signal that the request was well-formed but semantically invalid, and it's the
kind of failure a client should never blindly retry.

## running it

```bash
cp .env.example .env
docker compose up -d --build
```

`.env.example` ships with the simulator's own published token
(`04aa6f42aa03f220c2ae9a276cd68c62`, from the `tripladev/rate-api` Docker Hub page) —
not something I'd commit in a real system, but this one is the simulator's own public
test credential, and including it is what lets a reviewer run this from a clean clone
without hunting for a secret first.

`RATE_API_URL` defaults to `http://rate-api:8080`, not `localhost:8080`. `interview-dev`
and `rate-api` are two separate containers on the same compose network, and from inside
`interview-dev`, `localhost` means `interview-dev` itself, not its sibling.

If `docker compose up` refuses to start and complains that `RATE_API_TOKEN` is required,
`.env` is missing or empty — go back and run the `cp .env.example .env` step above.

```bash
docker compose exec interview-dev ./bin/rails test
```

That's 66 tests, 220 assertions, all green, roughly 29 seconds — most of that spent in
one deliberately slow test that replays a full simulated day of traffic (288 windows,
several requests each) through the actual endpoint and checks the upstream-call counter
never crosses 288.

```bash
curl 'http://localhost:3000/api/v1/pricing?period=Summer&hotel=FloatingPointResort&room=SingletonRoom'
# {"rate":"14200","fetched_at":"2026-07-19T12:07:23Z"}
```

## where this design breaks

This whole approach only works because the keyspace is 36 known, enumerated values.
Fetching "everything" is only a cheap, well-defined operation because "everything" is
small enough to enumerate. At a scale of thousands of hotels this exact design is the
wrong one — you can't prefetch the universe anymore. What I'd move to is either per-key
caching with proper request coalescing (single-flight per key instead of single-flight
globally, each key on its own TTL), or, if the pricing model can support it, a push or
webhook contract where the model tells us when a price changed instead of us guessing a
five-minute poll interval. One more honest note: the daily upstream-call counter
(`PricingClient.upstream_calls_today`, with a WARN logged past 500) is a safety net
that tells you the single-flight coordination broke, after the fact. It doesn't stop
anything from happening — it's an alarm, not a circuit breaker.

## notes from poking the real API

Three things from probing the simulator directly shaped the design more than anything
else: the fake-success rate (200 OK with an error-shaped body, no rate data, roughly
5-10% of calls) is why content validation had to replace status-code checking as the
definition of success; the indefinite hangs with no server-side timeout are why
`PricingClient` sets its own `open_timeout`/`read_timeout` rather than trusting
upstream to ever give up; and the int-vs-string instability in the `rate` field,
contradicting the documented contract, is why normalization happens at the client
boundary instead of trusting the docs. The full session — including the 429 hammer
test that found the exact quota-exceeded response — is in `docs/recon-notes.md`.

## AI usage
I used Claude (chat) to pressure-test my initial analysis of the assignment and 
Claude Code to implement it, working from step-scoped prompts  one step per commit, 
in the order the git history shows. The recon against the live simulator (docs/recon-notes.md) 
was done by hand with curl and a small hammer script, and its findings drove several 
design decisions the assistant then implemented: content validation as the definition
of success, client-side timeouts, and rate-type normalization. Before every commit 
I reviewed the full diff and ran the test suite. The core design calls the 
single-snapshot invariant, bulk-fetch-per-window, strict 5-minute freshness over 
stale-while-revalidate, and the retry budget arithmetic came out of my own analysis 
of the constraints. Where I disagreed with generated code or found gaps 
(for example, the retry policy initially not covering fake-success 200s), 
I caught it in review and had it fixed.

