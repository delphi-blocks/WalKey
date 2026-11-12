# Wrappers

A wrapper implements `IKeyValue` and holds another `IKeyValue`. Since it is a
store itself, wrappers stack in any order and the store at the bottom never
knows it is being wrapped.

```pascal
LStore :=
  TKVLoggingWrapper.Create(
    TKVStatisticsWrapper.Create(
      TKVTTLClampWrapper.Create(
        TKVPrefixKeysWrapper.Create(LRedis, 'tenant-7'),
        0, 3600, 300)),
    procedure (const AMessage: string)
    begin
      Writeln(AMessage);
    end);
```

Read a stack from the inside out. Above: a store, namespaced per tenant, with a
TTL policy over it, counted, and logged. (`LRedis` stands for any store; a Redis
backend is on the roadmap, and a memory or file store fits in the same place.)

This guide first explains how wrappers work and why the order of a stack
matters, then walks through real situations they are built for, then describes
each wrapper in turn, and ends with how to write your own.

## How a wrapper works

A wrapper is the *decorator* pattern: an object that has the same interface as
the thing it holds, adds one behaviour, and hands everything else on. Three
properties follow from that, and the rest of this guide leans on them.

**A wrapper is substitutable.** Anything that takes an `IKeyValue` takes a
wrapped one: a service, a typed adapter, another wrapper. Code written against
a bare memory store in a test runs unchanged against a logged, namespaced,
fail-over stack in production, and no line of it knows the difference.

**A wrapper does one thing.** Each of the nine adds a single concern —
naming, permission, lifetime policy, observation, resilience, caching — and none knows
the others exist. Combining concerns is the stack's job, not the class's.
That is why there is no `TKVLoggedReadOnlyTenantCache`: it is three wrappers.

**A stack is function composition.** A call goes down through each layer to the
store, and the answer comes back up through the same layers in reverse. Every
layer can act at one of four points:

| What it does | When | Wrappers |
|---|---|---|
| Rewrite the request | on the way down | prefix keys, prefix collections, TTL clamp |
| Stop the request | on the way down | read-only |
| Observe the answer | on the way up | logging, statistics |
| Redirect on failure | when the layer below raises | fallback |

### Invisible and visible wrappers

Some wrappers are meant to change nothing a caller can see. Statistics and
logging only watch; a TTL clamp with no limits set passes TTLs untouched;
prefixing the collections renames them but keeps them isolated; a fallback
with a healthy primary *is* the primary; a thread-safe wrapper only serializes.
Each of those runs through the whole
store contract in `WalKey.Tests.Wrappers.Conformance`, over a memory store,
exactly as a real backend does. The claim "this wrapper is invisible" is
therefore tested, not hoped.

Two wrappers change the contract on purpose and cannot pass that suite. The
read-only wrapper refuses writes, so nothing round-trips. The key prefix spends
part of the key-length budget, so a key of exactly `KV_MAX_KEY_LENGTH` fits a
bare store and not a prefixed one. Neither is a defect; both are what you asked
for when you added the wrapper, and both are tested for exactly that in
`WalKey.Tests.Wrappers`.

## The one rule

**A wrapper does not pass on the optional capabilities of the store it holds.**
`Supports(LWrapper, IKeyValueCullable)` is False unless that particular wrapper
implements it.

This is deliberate. Forwarding through `QueryInterface` would be easy and
wrong: a read-only wrapper would hand out a `DestroyAll` that empties the store
it is supposed to protect, and a prefixing wrapper would hand out an
enumeration reporting keys under names its callers never used. So a wrapper
offers a capability only where it can honour it properly, and everything else
is reached through `Inner`:

```pascal
if Supports(LStore.Inner, IKeyValueCullable, LCullable) then
  LCullable.Cull;
```

Where a wrapper *can* honour one, it implements it: the read-only wrapper
passes `IKeyValueEnumerable` through, because listing what is there is a read.
The thread-safe wrapper implements all four, because a capability call it did
not guard would slip past the lock; it raises `EKVStoreError` when the store
underneath has none. [capabilities.md](capabilities.md) has the full table of
which wrapper offers what.

Reaching through `Inner` is a deliberate act, and it steps *around* the wrapper:
`Inner` of a prefixing wrapper is the whole shared store, not the namespace.
Do it in maintenance code that knows what the stack is, not in code that was
handed an `IKeyValue` and should not care.

## Order matters

Because a stack is composition, swapping two layers can change what each of
them sees. Four pairs show it.

**Logging above or below a prefix.** Above it, the log speaks the caller's
language; below it, the store's:

```
[walkey] GET default/abc -> miss             logging over the prefix
[walkey] GET default/tenant-7:abc -> miss    logging under the prefix
```

The first is what a developer reading the application code wants. The second
is what someone looking at the raw store wants. Pick the one that answers the
question you are debugging — or use two logging wrappers with different tags.

**Logging above or below a TTL clamp.** Above it, the log shows the TTL the
caller *asked* for; below it, the one the store was *given*. A caller that
passes no TTL through a clamp with a default of 300 logs as `PUT default/abc (5
chars)` above and `PUT default/abc (5 chars, ttl 300 s)` below.

**Anything above or below a fallback.** A wrapper *above* the fallback applies
to whichever store answers. A wrapper wrapped around *one* of its two stores
applies to that store only. That decides, for instance:

- A key prefix goes above the fallback, or on both stores. On the primary alone,
  every tenant would share one unprefixed namespace in the standby for the
  length of an outage.
- Statistics above the fallback count the traffic the application sees;
  statistics around the primary count what the primary actually answered, which
  is the primary's health.

**Read-only above or below a fallback.** Above it, a write is refused before the
fallback is involved. Below it, as the primary, the refusal is an
`EKVReadOnlyError`, which the fallback deliberately does not treat as a
failure — so the write is still refused, and not quietly sent to the standby.
Either way round the store stays read-only; the rule that only `EKVStoreError`
falls through is what makes the second one safe.

One more thing is true regardless of order: **logging and statistics record
operations that returned.** Both act after the layer below answers, so a call
that raises — a refused write, a failed store — is neither logged nor counted.
Failures are reported by the exception itself and by the fallback's
`OnFallback`, not by these two.

### A default order

When nothing more specific applies, this order, outermost first, is a sound
starting point:

1. **Logging** — outermost, so it logs the caller's names and requested TTLs.
2. **Statistics** — the traffic as the application sees it.
3. **Read-only** — refuse early, before any work is done for a write that will
   not happen.
4. **TTL clamp** — the lifetime policy, applied to everything that gets past
   the read-only check.
5. **Near cache** — over the prefix, so it caches in the caller's names, and
   under logging and statistics, so those see every read, cached or not. It
   needs everything beneath it to report changes, which the prefixes,
   read-only and thread-safe do and the rest do not.
6. **Prefix** (keys or collections) — last before the stores, so everything
   above it speaks in unprefixed names.
7. **Fallback** — directly over the stores, so that everything above it
   applies to both of them. A near cache and a fallback do not mix: the
   fallback reports no changes, so the cache cannot go above it.

A collection view taken from the top of a stack goes through all of it:
`LStack.Collection('users')` returns a view bound to the outermost wrapper, not
to the store underneath, so every layer still applies to it.

### Keeping hold of a layer

Most layers need nothing after they are built, but some expose something worth
reading — statistics, a read-only wrapper's `Mode`, a fallback's `OnFallback`.
Keep a class reference to that layer and let the stack own it:

```pascal
var
  LStats: TKVStatisticsWrapper;
  LCache: IKeyValue;
begin
  LStats := TKVStatisticsWrapper.Create(TKVMemoryStore.Create);
  LCache := TKVLoggingWrapper.Create(LStats, LSink);
  ...
  Writeln(LStats.Statistics.ToString);   // valid for as long as LCache is
end;
```

Every wrapper is reference counted through `IKeyValue`. The outer layer holds
the inner one, so `LStats` lives as long as `LCache` does. Do not `Free` it,
and do not read it after the last `IKeyValue` reference to the stack has gone.

## In practice

### A cache shared by tenants

A server hosts many customers in one process and wants one in-memory cache for
all of them, without one customer ever reading another's entries.

```pascal
var
  GCache: IKeyValue;  // one for the whole process

procedure InitCache;
begin
  // House policy for everybody: nothing lives less than 30 s or more than an
  // hour, and a write that names no lifetime gets five minutes.
  GCache := TKVTTLClampWrapper.Create(TKVMemoryStore.Create, 30, 3600, 300);
end;

function TenantCache(const ATenantId: string): IKeyValue;
begin
  Result := TKVPrefixKeysWrapper.Create(GCache, 'tenant-' + ATenantId);
end;
```

Each request builds its tenant's view with `TenantCache` and passes it on as a
plain `IKeyValue`. Building a prefix wrapper costs one small object, so doing
it once per request is fine. The memory store is thread-safe and the wrappers
hold nothing that changes, so every request thread shares the one `GCache`.

Code handed a tenant's view cannot name another tenant's keys: every key it
passes gets the prefix, and `Keys` lists only its own. What *can* break that is
the prefix itself. `tenant-a` with key `b:x` and `tenant-a:b` with key `x` are
both stored as `tenant-a:b:x`. The constructor refuses a prefix that *ends*
with the separator, but it cannot know where your ids come from. If a tenant id
can contain `:`, validate it or choose a separator that it cannot contain.

Note that the TTL clamp sits *under* the prefixes, on the shared store: it is
the house's policy, and no tenant's view can go around it.

### Is the cache earning its keep?

A service caches expensive lookups with the usual *cache-aside* pattern: try
the cache, and on a miss compute the value and store it.

```pascal
type
  TQuoteService = class
  private
    FStats: TKVStatisticsWrapper;
    FCache: IKeyValue;
  public
    constructor Create;
    function Quote(const ASku: string): string;
    procedure ReportAndReset;
  end;

constructor TQuoteService.Create;
begin
  FStats := TKVStatisticsWrapper.Create(TKVMemoryStore.Create);
  FCache := FStats;
end;

function TQuoteService.Quote(const ASku: string): string;
begin
  // TryGet, not Get: a quote stored as '' is still a quote.
  if FCache.TryGet(ASku, 'quotes', Result) then
    Exit;
  Result := FetchQuoteFromBackend(ASku);  // the slow call being cached
  FCache.Put(ASku, Result, 'quotes', 120);
end;

procedure TQuoteService.ReportAndReset;  // from a timer, every few minutes
begin
  Log(FStats.Statistics.ToString);
  FStats.Reset;
end;
```

Reading the numbers:

- **Hit rate** is the headline. A low one means the entries die before they are
  asked for again (the TTL is short compared with how often a key comes back)
  or the key space is too large for anything to repeat. Either way the cache is
  costing memory and buying little.
- **Puts roughly equal to misses** is the shape of cache-aside working as
  written: every miss is filled once. Puts well above misses means something is
  writing without reading first.
- **Deletes well above removals** means invalidation is aimed at entries that
  were not in the cache. That is harmless, but it is work nobody needed.

Reporting per window with `Reset` shows trends that a counter since start-up
hides. Increments that land between reading `Statistics` and calling `Reset`
belong to neither window; for a health report that loss is noise.

### Surviving an outage of a shared store

A cluster of servers shares a network cache. When the cache goes down, the
servers should keep working — slower, with a cold local cache — rather than
fail every request.

```pascal
LFallback := TKVFallbackWrapper.Create(LNetworkStore, TKVMemoryStore.Create);
LFallback.OnFallback :=
  procedure (const AOperation, AError: string)
  begin
    Alert('cache degraded: %s (%s)', [AOperation, AError]);
  end;
LCache := TKVTTLClampWrapper.Create(LFallback, 0, 600, 60);
```

Understand what this buys and what it does not before relying on it:

- **It is for caches, not for data you cannot lose.** Writes during an outage go
  only to the standby. When the primary returns, reads go back to it, and
  whatever was written in the meantime is invisible. Worse, a `Delete` issued
  during the outage reached only the standby, so the primary still holds the
  value that was deleted, and serves it again once it is back. A cache
  tolerates that. A system of record does not.
- **Keep lifetimes short.** That is why the clamp in the example sits *above*
  the fallback, capping every entry, in either store, at ten minutes. A stale
  value resurrected after an outage then lives no longer than a stale value
  ever could.
- **Each call tries the primary first.** There is no circuit breaker: while the
  primary is down, every call pays for the primary's failure before the standby
  answers. A primary that fails fast costs little. One that fails by timing out
  slows every call by its timeout.
- **It is only as good as the primary's errors.** Only an `EKVStoreError` falls
  through. A store that turns an I/O error into a miss can never be failed over
  on a read. `TKVFileTreeStore` is such a store: a file it cannot read is a
  miss by design, so on an unreachable share its reads miss while its writes
  raise. Put a fallback over a file store and it covers writes, not reads.
- **The standby's own failures are not caught.** If both stores fail, the
  standby's exception reaches the caller.

And wire up `OnFallback`. Nothing else in the stack reports an outage.

### Handing out a store that must not be changed

A reporting module, a plugin, or a support tool needs to look at what is in a
store and has no business changing it.

```pascal
procedure RunReport(const AData: IKeyValue);  // never sees the writable store
...
RunReport(TKVReadOnlyWrapper.Create(LStore));
```

The report can read, list keys and collections, and take collection views.
`Put`, `Delete`, `Cull`, `DestroyCollection` and `DestroyAll` all raise
`EKVReadOnlyError`. For legacy code that writes as a side effect and cannot be
changed, `TKVReadOnlyMode.Ignore` drops those writes instead of raising — use
it knowingly, since a silently dropped write is exactly the bug `Refuse`
exists to prevent.

Read-only means *callers* cannot change the store. It does not freeze the
store's own housekeeping: reading an entry that has expired makes the store
remove it, as it would without the wrapper. On a file store in a folder the
process may not write to, that removal fails, and the read raises
`EKVStoreError` instead of reporting a miss.

### Changing the format of stored values

Version 2 of an application stores users in a new JSON shape. Old entries must
not be read by new code, and servers running version 1 and version 2 side by
side must not overwrite each other's entries.

```pascal
LUsers := TKVPrefixCollectionsWrapper.Create(LStore, 'v2');
LUsers.Put('u-42', LNewJson, 'users');  // stored in collection 'v2_users'
```

Each version has its own collections in the same store and no code changes
beyond the line that builds the stack. The old entries stay where they are
until their TTLs expire. If they have none, remove them from maintenance code
through `Inner`, where the unprefixed names are visible:

```pascal
if Supports(LUsers.Inner, IKeyValueDestroyable, LDestroyable) then
  LDestroyable.DestroyCollection('users');  // version 1's collection
```

### Switching logging on in production

Logging every operation is too much by default and exactly right while
chasing a problem. A nil sink makes the wrapper transparent, so the stack can
always include it:

```pascal
if Settings.TraceCache then
  LSink :=
    procedure (const AMessage: string)
    begin
      TLogify.Debug(AMessage);
    end
else
  LSink := nil;

LCache := TKVLoggingWrapper.Create(LStack, LSink, 'sessions');
```

The tag tells stores apart when several share one log: `[sessions] GET ...`
and `[quotes] GET ...`. Values are never logged, so turning tracing on does
not put customer data in the log files — only keys, and keys can be personal
data too (an email address used as a key is still an email address). Choose
keys accordingly.

## The wrappers

### TKVPrefixKeysWrapper

Puts every key in a namespace. What a caller writes as `abc` is stored as
`tenant-7:abc`.

```pascal
LSeven := TKVPrefixKeysWrapper.Create(LStore, 'tenant-7');
LSeven.Put('a', '{"n":1}');   // lands under 'tenant-7:a'
```

The separator defaults to `:` and is a constructor argument. An empty
separator, or a prefix that already ends with the separator, is refused: either
would let two different prefixes name the same key space and see each other's
entries.

Implements `IKeyValueEnumerable`: `Keys` reports the namespace's own keys with
the prefix taken back off, and hides everyone else's. It needs the store
underneath to be enumerable, and raises `EKVStoreError` if it is not.

**The cost:** the prefix comes out of the same key-length budget, so a key of
exactly `KV_MAX_KEY_LENGTH` fits a bare store and not a prefixed one. The
caller's key is validated *before* the prefix is added, so an empty key is
still refused rather than turned into a valid `tenant-7:`.

### TKVPrefixCollectionsWrapper

The same idea one level up: `users` becomes `app1_users`, and keys are left
alone. The cheaper way to partition a whole store.

`''` is resolved to the default collection *before* the prefix is applied, so a
caller naming no collection and a caller naming `default` land in the same
place. Which collection that is, is the wrapper's own `DefaultCollection`
(`default` unless changed): set it to match a store whose own
`DefaultCollection` is something else. `Collections` strips the prefix and
hides the rest, and the separator rule is the same as for keys.

**Keys or collections?** Prefixing collections leaves the full key length to
the caller and suits a store that keeps collections apart physically, such as
the file store's one folder per collection. Prefixing keys suits a store where
collections are few or fixed, and is the one to use when the partition has to
live *inside* a collection the caller chooses.

### TKVReadOnlyWrapper

Lets reads through, stops writes.

```pascal
LFrozen := TKVReadOnlyWrapper.Create(LStore);                        // raises
LQuiet  := TKVReadOnlyWrapper.Create(LStore, TKVReadOnlyMode.Ignore); // drops
```

`Refuse` (the default) raises `EKVReadOnlyError`; `Ignore` accepts the call and
does nothing, for a store put in read-only mode under code that cannot be
changed. A write that silently did nothing would otherwise be a bug that
surfaces much later.

`PutMany` still checks that its two arrays are the same length before refusing
or dropping: `Ignore` must not turn a malformed call into a silent success, any
more than `TKVNullStore` does.

It implements `IKeyValueCullable` and `IKeyValueDestroyable` itself, purely to
refuse them — culling and destroying are writes. `IKeyValueEnumerable` is the
other way round: it passes through, because listing what is there is a read.

### TKVTTLClampWrapper

A house policy for every TTL that passes through.

```pascal
TKVTTLClampWrapper.Create(LStore, 60, 3600, 300);
//                               min  max   default
```

- **Default**: given to a write that asks for no TTL. 0 leaves those entries
  without an expiry.
- **Min / max**: floor and ceiling on a TTL that was asked for. 0 turns either
  off.

The default is applied first and then clamped, so a default outside the limits
is pulled inside them. A negative TTL passes straight through, so the store
underneath still refuses it — a default must not swallow what is a mistake
rather than a lifetime. The limits themselves must not be negative: the
constructor and the properties refuse one.

Stops one caller pinning an entry in a shared cache for a year, or filling it
with entries that expire before they are read.

A clamp with a maximum but no default still lets a write that asks for no TTL
live forever. That is what 0 means, and the clamp only limits lifetimes that
were asked for. To guarantee that *everything* expires, set a default too.

### TKVLoggingWrapper

A line per operation, to whatever sink you hand it.

```pascal
TKVLoggingWrapper.Create(LStore,
  procedure (const AMessage: string)
  begin
    TLogify.Debug(AMessage);
  end, 'cache');
```

WalKey has no logging dependency and does not choose one for you; a one-line
lambda bridges to Logify, a file, a memo or `Writeln`. A nil sink logs nothing
and is otherwise transparent, which is how logging is switched off without
unpicking the stack.

**Keys and collections are logged; values are not.** A value can be large, and
it can be somebody's personal data. An expiry is logged as the instant it is
rather than as a lifetime remaining, because a wrapper has no clock and the
store's may not be the wall clock. A value deliberately stored as `''` is a
hit, because the wrapper asks whether the key was there rather than whether the
answer is empty.

The sink is called on the caller's thread. Over a store shared between
threads, the sink must be safe to call from several at once.

### TKVStatisticsWrapper

Counts what goes through, changes nothing.

```pascal
LStats := TKVStatisticsWrapper.Create(LStore);
...
Writeln(LStats.Statistics.ToString);
// gets 41 (hits 33, misses 8, 80.5%), puts 12, deletes 3 (removed 2)
```

`TKVStatistics` carries `Gets`, `Hits`, `Misses`, `Puts`, `Deletes`,
`Removals`, plus `HitRate` and `ToString`. Bulk calls count one per key.
Counters are atomic, so a thread-safe store stays thread-safe. `Reset` zeroes
them.

An empty answer is the one that cannot say for itself whether it was a stored
`''` or a miss; the wrapper asks `Exists` for those few, so a stored empty value
is counted as a hit. `Exists` itself is not counted as a read: asking whether a
key is there is not the cache serving a value.

### TKVFallbackWrapper

Everything goes to one store and, when that store fails, to a standby.

```pascal
LStore := TKVFallbackWrapper.Create(LRedis, TKVMemoryStore.Create);
LStore.OnFallback :=
  procedure (const AOperation, AError: string)
  begin
    Alert('cache degraded: %s (%s)', [AOperation, AError]);
  end;
```

A failure is an `EKVStoreError` and nothing else, so what deliberately does
**not** fall through is everything a standby cannot answer honestly:

- **A miss.** "Nothing under that key" is an answer, not a failure. Treating it
  as one would turn the standby into a second place to look on every read, and
  start serving values the primary deliberately no longer has.
- **A bad argument.** `EKVInvalidKeyError`, `EKVInvalidCollectionError` and
  `EKVArgumentError` are re-raised: the standby would refuse them identically,
  so falling back would only hide the bug.
- **A policy refusal.** An `EKVReadOnlyError` is the read-only wrapper in front
  of the store working, not the store failing; answering the write from the
  standby would defeat it.
- **A value that will not decode.** An `EKVSerializationError` is corruption,
  and quietly serving the standby's copy instead would hide it.

Everything that is not an `EKVStoreError` is raised, a bug in the caller
included. A store that wants a fallback must say so by raising `EKVStoreError`.

The two stores are never synchronised: nothing is copied to the standby while
the primary is healthy, and nothing is copied back when it recovers. See
[Surviving an outage of a shared store](#surviving-an-outage-of-a-shared-store)
for what that means in practice.

Wire up `OnFallback`. A fallback nobody hears about is an outage nobody hears
about.

### TKVThreadSafeWrapper

Makes the store underneath safe to share between threads: one call at a time,
reads included.

```pascal
FStore  := TKVFileTreeStore.Create(LRoot);        // does not lock itself
LShared := TKVThreadSafeWrapper.Create(FStore);   // safe to hand around
```

It is for a store that does not lock itself — a SQLite connection, a socket,
something a backend leaves to its caller. `TKVMemoryStore` and
`TKVNullStore` are already thread-safe, so wrapping them costs a lock and
buys nothing; the file store is safe *between processes* through the
filesystem, and this adds in-process serialization on top.

**What it promises:** one call at a time. Not one transaction — a sequence of
calls (`Exists` then `Put`, say) can still interleave with another thread.
And it guards one wrapper instance: two wrappers over one store, or two
processes, are not coordinated with each other.

**Where to put it:** immediately above the store, below logging and fallback,
so the lock is not held while a log sink or an alarm callback runs. Every
method calls `Inner` directly, so a call never nests its own lock.

It implements all four optional capabilities, so a call through one is
guarded like any other rather than reaching the store around the lock. If the
store underneath lacks that capability, the call raises `EKVStoreError`;
`Supports` is optimistic, exactly as it is for the prefixing wrappers.

### TKVNearCacheWrapper

Keeps a local copy of what is read, and drops it the moment the store reports
that it changed. A read is served from memory, with no round trip, and still
sees a write made by any other process.

```pascal
LShared := TKVNatsStore.Create(LJs, 'myapp');            // every instance
LCache  := TKVNearCacheWrapper.Create(LShared, 60);      // this instance
```

It is the cache for a store that several instances share. Each instance keeps
the values it reads close at hand, and the store tells all of them when one
changes. That is the case the [MCPConnect example](../README.md#real-world-example-mcpconnect)
describes: signing keys and metadata documents read on every request, written
rarely, and shared by every instance.

**It needs a store that reports changes.** The store underneath must support
`IKeyValueWatchable` (see [capabilities.md](capabilities.md#ikeyvaluewatchable)),
or the constructor raises `EKVArgumentError`. `TKVMemoryStore` and
`TKVNatsStore` do, and so do the prefixing, read-only and thread-safe wrappers
over one of them. Logging, statistics, the TTL clamp and the fallback do not,
so they go above the cache, never below it.

**How fresh a value is.** A change made through the cache is visible to its
next read. A change made elsewhere is visible once the store reports it: at
once for the memory store, a few milliseconds later for NATS.

**`MaxAge` is the bound on what a store cannot report.** A NATS connection that
drops and comes back between two reads, or a bucket deleted from outside, goes
unnoticed. So nothing is served from the cache once it has been held for
`MaxAge` seconds (60 by default), and `MaxAge` cannot be switched off.
Everything else is noticed sooner: a watch found dead on a read discards
everything it vouched for, and reads go uncached until a new one is live.

**What it does not cache:** misses, and any value a change may have overtaken.
If a change is reported while a read is out at the store, the read returns
what it found but does not keep it. Under a steady stream of writes, that means
fewer values cached, never a stale one.

**Expiry** is judged here, against the cache's clock: a value expires in the
cache when it would have expired in the store, without asking the store. Give
the cache the store's clock if the store was given one.

**Size:** `MaxEntries` (10,000 by default). Past it, the least recently read
tenth goes at once.

`Clear` drops everything, for a caller that changed the store around the cache
in a way the store does not report. `Count` says how much is held. It offers
no optional capabilities: reach them through `Inner`.

## Writing a wrapper

Descend from `TKVWrapper`, which forwards all of `IKeyValue` to `Inner`, and
override only what changes. Every method is virtual.

A complete example: a policy that refuses values over a size limit, so that
one caller cannot fill a shared cache with a handful of huge entries.

```pascal
type
  TKVValueSizeWrapper = class(TKVWrapper)
  private
    FMaxLength: Integer;
    procedure CheckValue(const AKey, AValue: string);
  public
    constructor Create(const AInner: IKeyValue; const AMaxLength: Integer); reintroduce;
    procedure Put(const AKey, AValue: string; const ACollection: string = '';
      const ATTL: TKVDuration = KV_NO_TTL); override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = '';
      const ATTL: TKVDuration = KV_NO_TTL); override;
  end;

constructor TKVValueSizeWrapper.Create(const AInner: IKeyValue; const AMaxLength: Integer);
begin
  inherited Create(AInner);
  if AMaxLength <= 0 then
    raise EKVArgumentError.Create('The maximum value length must be positive');
  FMaxLength := AMaxLength;
end;

procedure TKVValueSizeWrapper.CheckValue(const AKey, AValue: string);
begin
  if Length(AValue) > FMaxLength then
    raise EKVArgumentError.CreateFmt('Value for "%s" is %d chars, the limit is %d',
      [AKey, Length(AValue), FMaxLength]);
end;

procedure TKVValueSizeWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  CheckValue(AKey, AValue);
  inherited;
end;

procedure TKVValueSizeWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
var
  LIndex: Integer;
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  // Every value is checked before any is written, so a refused batch leaves
  // nothing behind.
  for LIndex := 0 to High(AKeys) do
    CheckValue(AKeys[LIndex], AValues[LIndex]);
  inherited;
end;
```

What the example gets right, and what any wrapper has to think about:

- **Cover every path.** A read arrives through `Get`, `TryGet`, `TryGetEntry`,
  `Exists` or `GetMany`. A write arrives through `Put` or `PutMany`, a delete
  through `Delete` or `DeleteMany`. `TKVWrapper` forwards each one to `Inner`
  *separately*: `Get` does not go through `TryGet`. A wrapper meant to affect
  "every read" that overrides only `Get` leaves four other doors open. (The
  one-argument `TryGet` is the exception: it calls the two-argument one on
  `Self`, so overriding that covers both.)
- **Check bulk lengths yourself.** A wrapper that loops over `AKeys` and
  `AValues` must call `TKVUtils.CheckBulkLengths` before it touches them, as
  above. It cannot rely on the store underneath, which may be one that ignores
  writes.
- **Choose the exception class for what it tells the layers above you.** The
  example raises `EKVArgumentError`, which is a caller's mistake, so a fallback
  above it re-raises it. Had it raised `EKVStoreError`, a fallback would read
  it as "the store is down" and write the oversized value to the standby.
  Raise `EKVStoreError` only for a genuine failure of the store.
- **Do not forward capabilities by default.** Implement `IKeyValueEnumerable`,
  `IKeyValueCullable` or `IKeyValueDestroyable` only if your wrapper can honour
  them with its own behaviour applied. A caller who needs one you do not offer
  has `Inner`.
- **Leave `Collection` alone.** The inherited one binds the view to your
  wrapper, so the view goes through it too.
- **Keep state thread-safe or immutable.** Stores are shared between threads;
  a wrapper over one is shared with it. Configuration set in the constructor
  and never changed is safe. Counters need `TInterlocked`, as the statistics
  wrapper uses.

If the wrapper is meant to be invisible, add a fixture to
`WalKey.Tests.Wrappers.Conformance`: the whole contract then runs through it
over a memory store, and anything it quietly changes shows up as a failure. If
it changes the contract on purpose, as the size limit does, test what it
changes in `WalKey.Tests.Wrappers` instead.
