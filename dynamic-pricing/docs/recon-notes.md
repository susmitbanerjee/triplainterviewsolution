# recon notes: probing tripladev/rate-api

Before writing any application code I pulled `tripladev/rate-api` and ran it locally
(`docker run -p 8080:8080 tripladev/rate-api`) and hit it directly with curl, outside
the Rails app entirely. This is the raw output from that session. Everything in the
README's failure table traces back to one of these observations.

Docker Hub's own docs for the image give the endpoint (`POST /pricing`), the header
shape (`Content-Type: application/json`, `token: <token>`), the published token
(`04aa6f42aa03f220c2ae9a276cd68c62`), a 1,000 requests/day limit that resets when the
container restarts, and a response shape of `{"rates": [...]}` where each rate is
described as a string. Some of that held up. Some of it didn't.

## happy path

```
curl -X POST http://localhost:8080/pricing \
  -H 'token: 04aa6f42aa03f220c2ae9a276cd68c62' \
  -H 'Content-Type: application/json' \
  -d '{"attributes":[{"period":"Summer","hotel":"FloatingPointResort","room":"SingletonRoom"}]}'
```

Batching works — one request with N attributes returns N rates in one `rates` array.
That's the whole basis for fetching all 36 in a single call instead of 36 separate ones.

## the response shape is not stable

I sent the exact same single-attribute request fifteen times in a row and diffed the
bodies. Results, roughly:

```
{"rates":[{"hotel":"FloatingPointResort","period":"Summer","room":"SingletonRoom"}]}
{"rates":[{"hotel":"FloatingPointResort","period":"Summer","rate":53800,"room":"SingletonRoom"}]}
{"rates":[{"hotel":"FloatingPointResort","period":"Summer","rate":"64300","room":"SingletonRoom"}]}
{"message":"Failed to process rates due to an intermittent issue.","status":"error"}   [HTTP 200]
{"error":"An unexpected internal error occurred"}                                       [HTTP 500]
```

Four distinct problems in fifteen calls, all against identical input:

- `rate` is sometimes a JSON integer (`45800`), sometimes a JSON string (`"64300"`). The
  docs say string. Empirically it's a coin flip.
- The `rate` key is sometimes missing from a rate object entirely, while the response is
  still `200` and otherwise correctly shaped.
- Roughly 1 in 15-20 calls (ballpark 5-10%) comes back `200 OK` with an error-shaped
  body instead of rates: `{"message":"Failed to process rates due to an intermittent
  issue.","status":"error"}`. Status code alone cannot tell you this call failed.
- Some calls come back `500` with `{"error":"An unexpected internal error occurred"}`.

And separately from all of that: some calls just never come back. I ran the same
request in a loop with a 10-15s curl timeout and got a handful of flat-out hangs
(`HTTP:000`, connection still open at the timeout). Nothing in the docs mentions this.
There's no server-side timeout I could find — the client has to bring its own.

## auth and validation

Wrong token or missing token header, consistently:

```
HTTP 401
{"error": "Unauthorized"}
```

Unknown hotel or period value, consistently (retried 5x to confirm it wasn't the
intermittent-failure noise above coinciding):

```
HTTP 400
{"error": "Invalid attribute: {'period': 'Summer', 'hotel': 'NotAHotel', 'room': 'SingletonRoom'}"}
```

Malformed JSON in the request body:

```
HTTP 400
<!doctype html>
<html lang=en>
<title>400 Bad Request</title>
<h1>Bad Request</h1>
<p>Failed to decode JSON object: Expecting property name enclosed in double quotes: line 1 column 35 (char 34)</p>
```

That's a Flask default error page, not JSON. Worth knowing: not every error response
from this API is JSON-shaped, even though every success response is.

Empty `attributes` array: `200 {"rates": []}`.

## quota

I wrote a script that fired ~1,050 sequential requests at a single running container
instance (10s curl timeout per request, so the occasional hang didn't stall the whole
run for too long). Some quota had already been burned by the manual probing above
against that same container, so the limit tripped around request #437 of that run, not
#1000 — consistent with the docs' claim that the budget is per container instance and
resets on restart. From the moment it tripped, every subsequent request against that
container got:

```
HTTP 429
{"error": "Rate limit exceeded (1000/day)"}
```

Consistent, no partial/degraded responses, no retry-after header.

## what this drove in the code

- Content has to be validated before a response counts as success — status code alone
  is not enough. This is `PricingClient#parse_rates` (`app/services/pricing_client.rb`):
  parses JSON, requires a `rates` array of exactly 36 entries covering all 36
  `(period, hotel, room)` combinations, requires every rate to be numeric.
- Rate values can be int or string on the wire; `PricingClient#numeric_rate?` accepts
  either and normalizes to string on the way into the snapshot, rather than rejecting
  half of otherwise-good responses over a type the docs got wrong.
- No response ever showed up after 5 seconds in my testing, but nothing guarantees
  that's a hard ceiling, and the hangs above prove the server won't enforce one for
  you. `PricingClient` sets `open_timeout: 2` / `read_timeout: 3` and treats a timeout
  as a retryable condition, same bucket as 5xx.
- 429 and other 4xx never retry (`PricingClient#request_with_retries`) — a bad token or
  a blown quota does not heal by trying again, and retrying against a 429 only makes
  the quota problem worse.
