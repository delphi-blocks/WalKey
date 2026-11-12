# Stores

A store is anything that implements `IKeyValue`. WalKey ships three, plus a
NATS-backed one that is deliberately outside the packages, and the point of
the design is that swapping one for another changes a single line.

## The contract in one place

`TKVStoreBase` implements all of `IKeyValue` and leaves three primitives to the
backend:

```pascal
function  DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;
function  DoDelete(const ACollection, AKey: string): Boolean; override;
```

The base handles everything else, which is why every store behaves the same:

- **Argument checking.** Keys and collection names are validated before a
  primitive is ever called, so a backend never sees an empty key.
- **Collection resolution.** `''` becomes the default collection, once, in one
  place — `Collection('')` included, which returns a view of it.
- **Expiry.** `TryGetEntry` drops an entry it finds expired and reports a miss.
  Backends store the expiry and otherwise ignore it.
- **The bulk methods.** `GetMany`/`PutMany`/`DeleteMany` loop over the single
  calls. A backend with native bulk overrides them; none of the three shipped
  stores needs to. An override should still call `TKVUtils.CheckBulkLengths`,
  so a mismatched call is refused with the same message a wrapper or an
  adapter would give it. `PutMany` reads the clock and resolves the collection
  once for the whole batch, so a single call cannot straddle a clock tick.

There is a fourth, optional primitive: `DoDropExpired`, called when a read
finds an entry expired. The default deletes it outright. A store that can
re-check under its own lock should override it, so a value written by another
thread between the read and the delete is not thrown away — `TKVMemoryStore`
does exactly that.

A fifth, `DoDeleteLive`, is what `Delete` calls to remove a key and report
whether what was there was live. The default is a read and then a delete; a
store that can do both under one lock overrides it so the answer and the
removal cannot disagree — `TKVMemoryStore` does that too.

## TKVMemoryStore

A dictionary of collections, each a dictionary of entries, behind one
`TCriticalSection`. Thread-safe. Offers all four optional capabilities; a
watch is told synchronously, on the writer's thread.

```pascal
LStore := TKVMemoryStore.Create;
```

`Count` is its own addition: how many entries are held, expired ones included
until something reads or culls them.

## TKVFileTreeStore

One folder per collection, one file per entry, each file a JSON envelope.

```pascal
LStore := TKVFileTreeStore.Create('C:\ProgramData\MyApp\cache');
```

Nothing is created until something is written, so a store only read from leaves
no trace on disk. An empty root path is refused, since it would otherwise
silently mean the process's working directory.

### How a name becomes a file name

`SafeName` keeps a name verbatim when it is all lowercase letters, digits, `-`,
`_` or `.`, is 64 characters or fewer, does not start with `.`, and is not a
reserved device name (`con`, `lpt1`, …). Everything else becomes
`h_<sha256 of the name>`.

Uppercase falls in the second group deliberately. Windows would fold `Key` and
`key` onto one file, and two entries the contract keeps apart would silently
become one.

Because a file name can be a hash, **every file also records the key it was
written under**, and each collection folder carries a `.walkey-collection`
marker with its real name. That is what makes `Keys` and `Collections` able to
report what a caller would recognise — and what makes a read check that the
file it opened is really the key asked for, so a name collision reads as a miss
rather than as somebody else's value.

### Durability

A write goes to a uniquely named temporary file (`<name>.json.<guid>.tmp`),
which then replaces the target in a single rename, so a process that dies
mid-write leaves the old entry or no entry, never half of one. Reads are
forgiving to match: a file that cannot be read or parsed is a miss, not an
exception, and a leftover `.tmp` is not listed as an entry.

Instances hold no state and coordinate through the filesystem alone. Two
writers racing on one key resolve as last-write-wins, and the three steps a
lost race can reach — creating a collection folder, replacing an entry file
and deleting one — are retried, so losing a race is not reported as a failure.
A delete of a file another writer already removed counts as deleted rather
than as an error.

### What it costs

`Keys` opens every file in the collection, because a key is not always
recoverable from its file name and an expired entry must not be listed.
`Cull` walks everything. Neither is something to do in a loop.

## TKVNullStore

Accepts every write, keeps nothing, misses every read.

```pascal
if Config.CachingEnabled then
  LCache := TKVMemoryStore.Create
else
  LCache := TKVNullStore.Create;
```

For turning a cache off without unpicking the wiring around it, giving an
unconfigured dependency a default that cannot fail, keeping a test from
persisting anything, or measuring a benchmark with the storage taken out.

It is a *null* store, not a lax one: keys, collection names and TTLs are
validated exactly as a real store validates them, and the same calls raise the
same exceptions. A store that quietly swallowed bad arguments would let a bug
live until the day a real store was swapped back in.

## TKVNatsStore

A collection is a [NATS](https://nats.io) JetStream Key/Value bucket, and a key
is a KV key.

```pascal
uses
  Nats.Connection, Nats.JetStream.Client, Nats.Socket.Indy,
  WalKey.Core, WalKey.Stores.NATS;

LConn := TNatsConnection.Create;
LConn.SetName('MyApp').SetChannel('127.0.0.1', 4222, 5000).Open(nil);
try
  if not LConn.WaitForReady(5000) then
    raise Exception.Create('no nats-server on 127.0.0.1:4222');

  LJs := TJetStreamContext.Create(LConn);
  try
    LStore := TKVNatsStore.Create(LJs, 'myapp');
    try
      LStore.Put('session-42', '{"user":"alice"}', 'sessions', 3600);
    finally
      LStore.Free;
    end;
  finally
    LJs.Free;
  end;
finally
  LConn.Free;
end;
```

The store owns neither the connection nor the context: both must outlive it.
It is in neither package — `WalKey.dpk` stays free of the NATS client — so a
project that does not use this store never builds it.

### Names

NATS allows only letters, digits, `_` and `-` in a bucket name, and only a
slightly wider set in a key, while WalKey allows any printable text. A name
that fits is stored as itself behind a `v` mark; one that does not is
base64url-encoded behind an `x` mark. Every stored name carries one of the two,
which is what makes decoding it a function rather than a guess — and what lets
`Keys` and `Collections` report back the names a caller actually used.

### Buckets

Buckets are named `<prefix>_<collection>`, so one account can hold several
stores without them seeing each other; `Collections`, `Cull` and `DestroyAll`
look only under this store's prefix, `walkey` by default. `BucketName` and
`StreamName` expose that mapping to anything that wants to look at a bucket
with the NATS client directly.

### What a value is

| Value mode | Stored | TTL |
|---|---|---|
| `Envelope` (default) | the WalKey envelope: the value, its creation instant and its expiry, as JSON | yes |
| `Bare` | the value verbatim | no — a `Put` that asks for one raises `EKVArgumentError` |

`Envelope` is what makes expiry work at all: a KV bucket has no per-key TTL, so
the entry carries its own, exactly as it does in the memory and file stores.
`Bare` is for a bucket another NATS client reads and writes, one that knows
nothing of WalKey; the price is that an entry then has no TTL of its own, and
asking for one is refused rather than quietly dropped. The mode is fixed when
the store is built, because every bucket it touches has to agree.

### What it costs

Every call is a round trip to the server; no value is cached locally by the store itself. `Keys`
reads every value in the collection, because an expired entry must not be
listed, and `Cull` walks them all. All four optional capabilities are offered;
a watch is a JetStream KV watch on the bucket, and the limits that come with
it are in [capabilities.md](capabilities.md#ikeyvaluewatchable). Put a
`TKVNearCacheWrapper` over the store to cache reads locally.

### Failures

A failure from the client library arrives as `EKVStoreError` carrying the
server's message, so a caller does not have to know NATS to handle it. A
collection whose bucket does not exist reads as an empty collection rather than
as an error, because a missing stream is an error code to the NATS API and not
an empty answer — but nothing else is swallowed, and no other failure is ever
mistaken for a miss.

The suite runs this store through the whole contract against a live server.
Those tests are compiled only when the suite is built with `WALKEY_NATS` —
the default test build has no NATS reference at all — and are in the `Nats`
category, so they are out of the default run:

```
BuildTests.bat 37.0 nats        REM or: WalKey.Tests.Framework.exe --include:Nats
```

## Optional capabilities

Not every backend can offer these cheaply, so they are separate interfaces
found with `Supports`:

| Interface | Methods |
|---|---|
| `IKeyValueEnumerable` | `Keys(collection)`, `Collections` |
| `IKeyValueCullable` | `Cull` |
| `IKeyValueDestroyable` | `DestroyCollection(name)`, `DestroyAll` |
| `IKeyValueWatchable` | `Watch(collection, handler)` |

```pascal
var LCullable: IKeyValueCullable;
if Supports(LStore, IKeyValueCullable, LCullable) then
  LCullable.Cull;
```

Every shipped store offers the first three. The memory and NATS stores also
watch; the file and null stores do not. A future
Redis store might offer only
some — `Keys` over a large keyspace is not something to do casually.

What each method promises, what it costs on each store, what the wrappers do
with them and how to reach one beneath a stack are in
[capabilities.md](capabilities.md).

## Writing a store

1. Descend from `TKVStoreBase` and implement the three primitives.
2. Override `DoDropExpired` if the backend can re-check expiry atomically,
   and `DoDeleteLive` if it can remove and report liveness in one step.
3. Implement the optional interfaces only where the backend can do so without
   scanning everything.
4. Add a fixture descending from `TKVConformanceTests`:

```pascal
[TestFixture]
TKVMyStoreTests = class(TKVConformanceTests)
protected
  function CreateStore(const AClock: TKVClock): IKeyValue; override;
  procedure SetupStore; override;     // optional: scratch folder, connection
  procedure TearDownStore; override;  // optional: undo it
end;
```

The whole contract then runs against the new store. `SetupStore` runs before
the store is built and `TearDownStore` after it is released, which is how
`TKVFileTreeStoreTests` gets a fresh temp folder per test.

The clock is injected rather than read from the wall, so expiry is tested by
moving time. Nothing in the suite sleeps.
