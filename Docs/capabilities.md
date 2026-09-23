# Optional capabilities

`IKeyValue` is what every store can do: read, write and delete one key, or many.
Three more things are useful but cannot be promised by every backend, so each
has an interface of its own, and a store implements only the ones it can
honour.

| Interface | Methods | Answers the question |
|---|---|---|
| `IKeyValueEnumerable` | `Keys(collection)`, `Collections` | What is in here? |
| `IKeyValueCullable` | `Cull` | Can expired entries be cleared out now, rather than when read? |
| `IKeyValueDestroyable` | `DestroyCollection(name)`, `DestroyAll` | Can a whole collection, or everything, be dropped in one call? |

All of them are declared in `WalKey.Core`.

## Why they are not part of IKeyValue

**Not every backend can do them well.** Listing every key is a loop over a
dictionary in memory and a directory scan on disk. On a large remote key space
it is a command that blocks the server while it runs. Sweeping expired entries
is real work for a store that expires lazily and meaningless for one that
expires entries itself, as a Redis backend would. A store that had to
implement all of them would either do some badly or raise from half of its own
interface. A separate interface lets it say plainly: *not this one*.

**Every wrapper would have to implement them.** A method on `IKeyValue` is a
method on each of the seven wrappers, and several could not honour it: a
read-only wrapper must not hand out `DestroyAll`, and a prefixing one must not
list keys under names its callers never used. See
[Wrappers: the one rule](wrappers.md#the-one-rule).

**Code that needs one says so.** A function that takes `IKeyValue` promises to
need only the core. A function that asks for `IKeyValueEnumerable` shows in its
code that it lists keys, and that it must deal with a store that cannot.

This is the *interface segregation* principle applied to a store: many small
interfaces that a caller asks for, rather than one large one that every
implementer must fill in.

## Asking for one

A capability is discovered at run time with `Supports`, which answers False
rather than raising when the store does not offer it:

```pascal
var
  LCullable: IKeyValueCullable;
begin
  if Supports(LStore, IKeyValueCullable, LCullable) then
    Writeln(LCullable.Cull, ' expired entries removed');
end;
```

Decide what a missing capability means for your code. Sometimes it is nothing:
a store that cannot cull probably expires entries by itself. Sometimes it is
an error:

```pascal
if not Supports(LStore, IKeyValueEnumerable, LEnumerable) then
  raise EKVStoreError.Create('The export needs a store that can list its keys');
```

Three things never offer a capability, whatever is underneath:

- **A collection view.** `Store.Collection('users')` returns a `TKVCollectionView`,
  which implements `IKeyValue` and nothing else. Ask the store, and pass the
  collection name.
- **Most wrappers.** Logging, statistics, the TTL clamp and the fallback
  implement none. See [what each wrapper offers](#through-a-wrapper).
- **A plain `IKeyValue` you did not build.** It may be a view or a wrapper, and
  `Supports` is the only honest way to find out.

## IKeyValueEnumerable

```pascal
function Keys(const ACollection: string = ''): TArray<string>;
function Collections: TArray<string>;
```

**`Keys`** answers the live keys of one collection, `''` meaning the default
one. An expired entry is not listed even while it is still stored, so every key
returned was live when it was listed. A collection that does not exist answers
an empty array, not an error.

**`Collections`** answers every collection the store holds, **empty ones
included**. A collection exists from its first write until it is destroyed.
Deleting or culling every key in it leaves it in place, empty. Names are
reported as callers wrote them: the file store keeps a marker with the real
name in each folder, so a collection stored under a hashed folder name is
still listed as `Users`, not `h_3f2a...`.

Neither method promises an order. Sort the result if order matters.

### What a listing is and is not

A listing is a **snapshot**, and it is out of date as soon as it returns.
Another thread or process can add or delete keys, and a listed entry can
expire before you read it. So read the listed keys back as keys that may have
gone:

```pascal
for LKey in LEnumerable.Keys('sessions') do
  if LStore.TryGet(LKey, 'sessions', LValue) then
    Export(LKey, LValue);
  // else: expired or deleted since the listing - skip it
```

Use `TryGet` here rather than `GetMany`. `GetMany` answers `''` for a miss, so
it cannot tell a key that has just gone from one that holds an empty value.

### Uses

- **An admin or diagnostics page**: which collections exist, how many live
  entries each holds.
- **Export, backup, copying one store into another**: list, then read.
- **Migrating a format**: list the old collection, rewrite each entry in the new
  one.
- **Tests**: asserting exactly what a piece of code left behind.

### What it costs

In the memory store both methods run under the store's lock, so other threads
wait while a large collection is listed. In the file store `Keys` opens and
parses **every file** in the collection, because a hashed file name does not
give back its key and an expired entry must be left out. `Collections` reads
one small marker per folder. Neither belongs in a hot path, or in a loop.

## IKeyValueCullable

```pascal
function Cull: Integer;
```

Removes every expired entry in every collection, and answers how many it
removed.

### Why it exists: lazy expiry

WalKey expires entries **lazily**. An entry carries its own expiry instant, and
a read that finds it expired drops it and reports a miss. Nothing watches the
clock in the background. That makes expiry identical on every backend, costs
nothing until a read happens, and needs no timer thread.

The price is that **an entry nobody reads again is never removed**. A cache of
per-request results, written once and seldom read, grows until something sweeps
it: memory in the memory store, files on disk in the file store. The memory
store's `Count` shows it plainly, since it includes expired entries until
something reads or culls them.

`Cull` is that sweep. Call it on a schedule:

```pascal
// Every ten minutes, from a background thread or a timer.
if Supports(FStore, IKeyValueCullable, LCullable) then
  Log('cache: culled %d expired entries', [LCullable.Cull]);
```

How often depends on how fast dead entries pile up and how much they cost to
keep. Culling does not change what callers see, since an expired entry already
reads as a miss. It only reclaims space, so a missed sweep is never a
correctness problem.

### How the stores do it

- **Memory**: one pass over every collection, **under the store's lock**. Other
  threads wait for the whole sweep, so on a very large store run it off-peak or
  often enough that each sweep is short.
- **File tree**: opens every entry file in every collection and deletes the
  expired ones. It is best-effort: a file that is locked, or already deleted by
  another process, is skipped and left for the next sweep rather than failing
  this one. A file it cannot read or parse is not culled, since it cannot tell
  whether it has expired.
- **Null**: answers 0.
- **NATS**: lists every bucket of its own, every key in each, and then reads
  every value to see whether it expired — expiry lives in the value, not in
  the bucket — deleting the ones that did with a tombstone. Every step is a
  round trip to the server, so this is a slow sweep whatever the store's size.

Culling removes entries, never collections. A collection it empties is still
listed by `Collections`.

## IKeyValueDestroyable

```pascal
function DestroyCollection(const AName: string): Boolean;
procedure DestroyAll;
```

**`DestroyCollection`** drops one collection and every entry in it, live or
expired, and answers True when the collection existed. `''` is the default
collection. Afterwards the collection is gone from `Collections` too, not just
emptied.

**`DestroyAll`** drops every collection. The store is then as good as new, and
still usable.

Both are much faster than deleting key by key: the memory store drops a
dictionary, and the file store deletes a folder.

### Uses

- **Invalidating a group at once**: when everything cached for one purpose goes
  stale together, such as all of a report's cached pages, keep it in a
  collection of its own and destroy that collection.
- **Retiring an old format**: after moving to `v2_users`, destroy `users`.
- **A "clear cache" command** for an operator.
- **Tests**: a clean store between cases.

### Take care

These are the only calls in WalKey that remove data the caller did not name key
by key, so:

- **The file store's `DestroyAll` deletes every folder under its root**, whether
  the store created it or not. Give the store a root folder of its own. Never
  point it at a folder that holds anything else.
- **A file store failure stops the call part-way.** If a folder cannot be
  deleted (locked, or no permission), `EKVStoreError` is raised, and whatever
  was already deleted stays deleted. Neither method is transactional.
- **Hand this capability out sparingly.** Code that only reads should get the
  store through a `TKVReadOnlyWrapper`, which refuses both calls, instead of
  relying on it not to call them.

## Who offers what

### The stores

| | Enumerable | Cullable | Destroyable |
|---|---|---|---|
| `TKVMemoryStore` | yes | yes | yes |
| `TKVFileTreeStore` | yes (reads every file) | yes (reads every file) | yes |
| `TKVNullStore` | yes, always empty | yes, always 0 | yes, does nothing |
| `TKVNatsStore` | yes (reads every value) | yes (reads every value) | yes (drops the bucket) |

The null store offers all three so that swapping it in never changes which
code paths run. What it answers is what an empty store would answer:
`DestroyCollection` answers False, since nothing existed. It still refuses an
invalid collection name, as a real store would.

### Through a wrapper

| Wrapper | Enumerable | Cullable | Destroyable |
|---|---|---|---|
| `TKVPrefixKeysWrapper` | `Keys`: the namespace's keys, prefix removed. `Collections`: passed through unchanged | — | — |
| `TKVPrefixCollectionsWrapper` | its own collections, prefix removed | — | — |
| `TKVReadOnlyWrapper` | passed through | **refused** | **refused** |
| `TKVThreadSafeWrapper` | the store's, guarded | the store's, guarded | the store's, guarded |
| logging, statistics, TTL clamp, fallback | — | — | — |

Details that matter:

- A wrapper that enumerates needs the store beneath it to be enumerable, and
  raises `EKVStoreError` if it is not. `Supports` on the wrapper answers True
  either way: the wrapper implements the interface, and only calling it finds
  out.
- The key prefix namespaces keys, not collections, so its `Collections` lists
  every collection in the shared store, including ones where this namespace
  has no keys.
- The key prefix's `Keys` lists the **whole** collection underneath and then
  filters it. Listing one tenant's keys costs as much as listing everyone's.
- The read-only wrapper implements `IKeyValueCullable` and
  `IKeyValueDestroyable` only to refuse them. `Supports` answers True, and the
  call raises `EKVReadOnlyError`, or does nothing in `Ignore` mode. It does
  this on purpose: forwarding would let read-only code empty the store.
- The thread-safe wrapper implements all three so that a capability call is
  serialized like any other. When the store underneath does not have one, the
  call raises `EKVStoreError`, so `Supports` on this wrapper is optimistic
  too.

### Reaching the store under a stack

When a stack hides the capability you need, reach the store directly. The
simplest way is to **keep a reference to the store when you build the stack**:

```pascal
FStore := TKVFileTreeStore.Create(LRoot);    // an IKeyValue, kept for maintenance
FCache := TKVLoggingWrapper.Create(
  TKVStatisticsWrapper.Create(FStore), LSink); // handed to the application

// A maintenance timer, which knows what FStore is:
(FStore as IKeyValueCullable).Cull;
```

`Inner` does the same from inside a stack one layer at a time, but it is a
property of `TKVWrapper`, not of `IKeyValue`. Code that holds only the
interface would have to cast to reach it, and that is a sign it should have
been given the store instead.

Remember what reaching past a wrapper means. Culling underneath a key prefix
culls every tenant, which is harmless because expired entries are dead for all
of them. Destroying a collection underneath a key prefix destroys it for every
tenant, which usually is not what you want.

## Implementing them in a store

A store descending from `TKVStoreBase` adds the interfaces it can honour to its
class declaration:

```pascal
TKVMyStore = class(TKVStoreBase, IKeyValueEnumerable, IKeyValueCullable)
```

- **Offer a capability only if you can honour it.** A method that raises "not
  supported" is worse than a missing interface: `Supports` promised the call
  would work. If the backend expires entries itself, leave out
  `IKeyValueCullable`.
- **Keep the contract**, which `TKVConformanceTests` checks for every
  capability the store offers and skips for those it does not. `Keys` leaves
  out expired entries. `Collections` includes empty collections. `Cull` counts
  what it removed. `DestroyCollection` answers whether the collection existed.
  `''` means the default collection throughout: resolve it with
  `ResolveCollection`, which also validates the name.
- **Say what it costs.** If `Keys` scans everything, as the file store's does,
  write that in the store's documentation so nobody calls it per request.
