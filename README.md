# WalKey: Delphi Key-Value Library

<div align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="walkey-for-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="walkey-for-light.png">
  <img alt="WalKey Logo" src="walkey-for-light.png" width="400">
</picture>
</div>

---

**Pluggable key-value stores for Delphi.** One interface, any backend.

WalKey is a thin abstraction over key-value storage. Write your code against
`IKeyValue` and swap an in-memory store for a persistent one — or wrap either in
compression, logging or a fallback chain — without touching a line of the code
that uses it.

```pascal
uses
  WalKey.Core, WalKey.Stores.Memory;

var
  LStore: IKeyValue;
begin
  LStore := TKVMemoryStore.Create;

  LStore.Put('123', '{"name":"Alice"}', 'users', 3600); // 1 hour
  WriteLn(LStore.Get('123', 'users'));
  LStore.Delete('123', 'users');
end;
```

## Why WalKey?

- **One interface, several backends.** Memory, a file tree on disk, NATS
  JetStream and a null store today; Code written against `IKeyValue` runs on 
  any of them unchanged.
- **TTL everywhere.** Expiry is part of the stored entry, not something the
  backend has to support, so it behaves the same on every store.
- **Collections.** Keys are grouped into named namespaces, on every backend.
- **Wrappers that stack.** Prefixing, read-only, TTL clamping, logging,
  statistics, fallback, thread safety and a near cache, each one an
  `IKeyValue` around another, combined in any order.
- **A cache that stays correct across instances.** Over a store that reports
  its changes, `TKVNearCacheWrapper` serves reads from local memory and drops
  a value the moment any instance writes it.
- **Typed access** with Neon: `TKVNeonAdapter<T>` stores Delphi records and 
  objects as plain JSON, readable by anything else that opens the store.
- **No dependencies in the core.** The stores and wrappers need nothing but
  the RTL.
- **A conformance suite.** Write a store, point the shared tests at it, and the
  whole contract is checked for you.

## At a glance

Three layers, each optional except the store at the bottom. Every arrow is a
call through `IKeyValue`, except the top one, which is typed:

```mermaid
flowchart TB
    App["Your code"]

    subgraph Adapters["Typed adapters (optional)"]
        Neon["TKVNeonAdapter#lt;T#gt;<br/><i>T #8596; JSON</i>"]
    end

    subgraph Wrappers["Wrappers (optional, stackable)"]
        direction LR
        W1["Logging"] --> W2["Statistics"] --> W3["Near cache"] --> W4["Prefix keys"]
    end

    subgraph Stores["Store (exactly one)"]
        direction LR
        Mem["Memory"]
        File["File tree"]
        Nats["NATS JetStream"]
        Null["Null"]
    end

    App -- "T" --> Neon
    App -. "string" .-> W1
    Neon -- "string" --> W1
    W4 -- "string" --> Stores
```

Your code may enter at any layer: straight into a store, through a stack of
wrappers, or through an adapter on top of both.

## For framework authors

A key-value store is useful in an application, but WalKey pays off most inside
a **framework or library** that has to keep state it does not own: caches,
tokens, sessions, rate-limit counters, discovery documents.

A framework that picks the storage itself forces that choice on every
application built on it. One that asks for an `IKeyValue` instead leaves the
choice to the application: memory while developing, a file tree on a single
server, NATS (and, in time, Redis) once there are several instances sharing
state, and the null store in tests. The framework code is the same in every
case.

### Real-world example: MCPConnect

[MCPConnect](https://github.com/delphi-blocks/MCPConnect), the Delphi framework
for building MCP servers, has exactly this kind of state in its OAuth layer:

- **Authorization server metadata and signing keys (JWKS)**, fetched from the
  identity provider and cached with their own TTLs, so a token can be verified
  without a network round trip on every request.
- **Proxied metadata documents**, which the OAuth middleware keeps for every
  client of a server to share, instead of fetching them again for each one.

These are the caches that are no longer enough once the server runs as more
than one instance: each instance fetches everything again and holds its own
copy. Backed by an `IKeyValue`, the application decides where they live:

```mermaid
flowchart LR
    FW["Framework<br/><i>asks for an IKeyValue</i>"]
    App{"Application<br/>chooses"}

    App -- development --> Mem["TKVMemoryStore"]
    App -- one server --> File["TKVFileTreeStore"]
    App -- several instances --> Nats["TKVNatsStore"]
    App -- tests --> Null["TKVNullStore"]

    Mem & File & Nats & Null -. "IKeyValue" .-> FW
```

- Development: `TKVMemoryStore` — nothing to set up
- A single server: `TKVFileTreeStore` — the cache survives a restart
- Several instances: `TKVNatsStore` — one shared cache for all of them, with
  a `TKVNearCacheWrapper` in front so each instance reads from its own memory
  and still sees what the others write
- Tests: `TKVNullStore` — no state carried from one test to the next

### Using WalKey in your framework

1. **Ask for the interface**, not a store:

   ```pascal
   type
     TMyFramework = class
     private
       FCache: IKeyValue;
     public
       constructor Create(const ACache: IKeyValue);
     end;
   ```

2. **Use it through the plain operations**, with a collection of your own and
   a TTL where the data goes stale:

   ```pascal
   FCache.Put('session-123', '{"user":"456"}', 'sessions', 3600);

   if FCache.TryGet('session-123', 'sessions', LJson) then
     ...
   ```

3. **Let the application choose the backend**:

   ```pascal
   // Development
   LFramework := TMyFramework.Create(TKVMemoryStore.Create);

   // Production, on disk
   LFramework := TMyFramework.Create(
     TKVFileTreeStore.Create('C:\ProgramData\MyApp\cache'));

   // Production, shared between instances, one tenant's namespace
   LFramework := TMyFramework.Create(
     TKVPrefixKeysWrapper.Create(TKVNatsStore.Create(LJs, 'myapp'), 'tenant-7'));
   ```

By depending on `WalKey.Core` rather than on a particular store, a framework
stays backend-agnostic and leaves storage where it belongs: with the
application that deploys it.

## The model

- **Values are JSON text.** Nothing in the library parses a value: it is an
  opaque string on the way in and the way out. The typed adapter layer is what
  turns a Delphi record or object into one.
- **Keys live in collections.** A collection is a namespace; an empty collection
  argument means the default one, and `Store.Collection('')` binds that default
  to a view, if you would rather not pass the collection on every call.
- **TTL is uniform.** A value is stored as a `TKVEntry` carrying its own creation
  and expiry instants, so expiry behaves identically on a backend that has no
  notion of it. Expiry is lazy — an entry found expired on read is dropped and
  reported as missing — and `Cull` is the explicit sweep.
- **No live objects.** A store hands back a copy, never a reference to something
  it still holds, so the in-memory store cannot quietly behave differently from
  a persistent one.

How a read meets expiry. The check lives in `TKVStoreBase`, so a backend only
ever stores and returns entries; it never decides whether one is still alive:

```mermaid
sequenceDiagram
    participant C as Caller
    participant B as TKVStoreBase
    participant S as Backend (DoTryGet)

    C->>B: TryGet('123', 'users')
    B->>B: check key, resolve collection
    B->>S: DoTryGet('users', '123')
    S-->>B: TKVEntry (value, created, expires)
    alt entry expired at UtcNow
        B->>S: DoDropExpired('users', '123')
        B-->>C: False (a miss)
    else entry alive
        B-->>C: True + value
    end
```

## The interface

```pascal
IKeyValue = interface
  function  Get(const AKey: string; const ACollection: string = ''): string;
  function  TryGet(const AKey: string; out AValue: string): Boolean; overload;
  function  TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload;
  function  TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean;
  function  Exists(const AKey: string; const ACollection: string = ''): Boolean;
  procedure Put(const AKey, AValue: string; const ACollection: string = '';
                const ATTL: TKVDuration = KV_NO_TTL);
  function  Delete(const AKey: string; const ACollection: string = ''): Boolean;

  function  GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>;
  procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = '';
                const ATTL: TKVDuration = KV_NO_TTL);
  function  DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer;

  function  Collection(const AName: string): IKeyValue;
end;
```

`Get` answers an empty string for a key that is missing or expired — no valid
JSON document is the empty string, so the conflation is safe; `TryGet` is there
when the distinction matters.

Four capabilities are optional, because not every backend can offer them
cheaply. Ask for them with `Supports`:

| Interface | What it adds |
|---|---|
| `IKeyValueEnumerable` | `Keys(collection)`, `Collections` |
| `IKeyValueCullable` | `Cull` — sweep expired entries |
| `IKeyValueDestroyable` | `DestroyCollection(name)`, `DestroyAll` |
| `IKeyValueWatchable` | `Watch(collection, handler)` — be told when anyone changes a key |

## What ships today

Every store descends from `TKVStoreBase`, which turns the full `IKeyValue`
surface into three primitives. The optional capabilities are separate
interfaces that a store adds where its backend can honour them:

```mermaid
classDiagram
    direction TB
    class IKeyValue {
        <<interface>>
        Get / TryGet / TryGetEntry / Exists
        Put / Delete
        GetMany / PutMany / DeleteMany
        Collection(name)
    }
    class TKVStoreBase {
        <<abstract>>
        argument checks
        collection resolution
        expiry, bulk calls
        DoTryGet()*
        DoPut()*
        DoDelete()*
    }
    class Capabilities {
        <<optional interfaces>>
        IKeyValueEnumerable - Keys, Collections
        IKeyValueCullable - Cull
        IKeyValueDestroyable - DestroyCollection, DestroyAll
    }
    class IKeyValueWatchable {
        <<optional interface>>
        Watch(collection, handler)
    }

    IKeyValue <|.. TKVStoreBase
    TKVStoreBase <|-- TKVMemoryStore
    TKVStoreBase <|-- TKVFileTreeStore
    TKVStoreBase <|-- TKVNatsStore
    TKVStoreBase <|-- TKVNullStore

    TKVMemoryStore ..|> Capabilities
    TKVFileTreeStore ..|> Capabilities
    TKVNatsStore ..|> Capabilities
    TKVNullStore ..|> Capabilities
    TKVMemoryStore ..|> IKeyValueWatchable
    TKVNatsStore ..|> IKeyValueWatchable
```

All four shipped stores offer the first three capabilities, and the memory and
NATS stores can also be watched. A new store needs only
the three `Do*` primitives (in italics: abstract) and may offer none of them.

| Store | What it does |
|---|---|
| `TKVMemoryStore` | Keeps everything in memory for as long as the instance lives. Thread-safe, offers all four optional capabilities. |
| `TKVFileTreeStore` | Keeps everything on disk: one folder per collection, one file per entry. |
| `TKVNullStore` | Keeps nothing: every write is accepted and discarded, every read is a miss. |

Outside the packages, `Source\WalKey.Stores.NATS.pas` adds `TKVNatsStore`,
which keeps entries in [NATS](https://nats.io) JetStream Key/Value — one
bucket per collection. The NATS client is not a dependency of WalKey, so
neither `.dpk` holds it and a project that does not use the store never
builds it.

| Wrapper | What it adds |
|---|---|
| `TKVPrefixKeysWrapper` | Puts every key in a namespace, so tenants or features share one store without seeing each other |
| `TKVPrefixCollectionsWrapper` | The same, one level up: namespaces the collections and leaves keys alone |
| `TKVReadOnlyWrapper` | Lets reads through, refuses writes (or drops them quietly) |
| `TKVTTLClampWrapper` | A default TTL for callers that ask for none, a floor and a ceiling for those that do |
| `TKVLoggingWrapper` | A line per operation, to any sink you hand it |
| `TKVStatisticsWrapper` | Counts gets, hits, misses, puts and deletes |
| `TKVFallbackWrapper` | Sends everything to one store and, when that store fails, to a standby |
| `TKVThreadSafeWrapper` | Serializes every call, so a store that does not lock itself can be shared between threads |
| `TKVNearCacheWrapper` | Serves reads from local memory, and drops a value the moment the store reports anyone changed it |

| Adapter | What it adds |
|---|---|
| `TKVEntityAdapter<T>` | The typed surface over any text codec: a store that holds T instead of a string |
| `TKVNeonAdapter<T>` | That, with Neon as the codec: store and read Delphi records and objects as JSON |

On the way: SQLite and Redis stores, then compression, encryption and retry
wrappers.

### Typed access

```pascal
uses
  WalKey.Core, WalKey.Stores.Memory,
  WalKey.Adapters.Entity, WalKey.Adapters.Neon;

var
  LUsers: IKVEntityAdapter<TUser>;
begin
  LUsers := TKVNeonAdapter<TUser>.Create(TKVMemoryStore.Create, 'users');
  LUsers.Put('alice', LUser, 3600);
  if LUsers.TryGet('alice', LUser) then
    ...
```

An adapter is not a wrapper: it does not implement `IKeyValue`, it sits on top
of one. `TKVEntityAdapter<T>` holds the typed surface and leaves the codec
abstract; a descendant supplies `Serialize` and `Deserialize`, and
`TKVNeonAdapter<T>` is the one that does so with Neon:

```mermaid
flowchart LR
    App["Your code"]

    subgraph Adapter["TKVNeonAdapter#lt;TUser#gt;"]
        direction TB
        Typed["TKVEntityAdapter#lt;T#gt;<br/><i>Put / Get / TryGet / ...<br/>misses, ownership, bulk</i>"]
        Codec["Codec<br/><i>Serialize / Deserialize<br/>(Neon)</i>"]
        Typed <--> Codec
    end

    Store[("any IKeyValue<br/>store or wrapper stack")]

    App -- "TUser" --> Typed
    Typed -- "TUser" --> App
    Codec -- "JSON text" --> Store
    Store -- "JSON text" --> Codec
```

Records and classes both work — a class is built fresh on every read and the
caller owns it. A miss gives `Default(T)`, or raises with
`RaiseOnMissing := True`. What it writes is ordinary JSON that anything else
can read out of the store. See [Docs/typed-access.md](Docs/typed-access.md).

This is the only part of WalKey that depends on anything outside the RTL, which
is why it is a unit and a package of its own.

### The file-tree store

```pascal
LStore := TKVFileTreeStore.Create('C:\ProgramData\MyApp\cache');
LStore.Put('session-42', '{"user":"alice"}', 'sessions', 3600);
```

One folder per collection, one file per entry, each file a JSON envelope — so
what the store holds can be read, diffed, backed up and deleted with ordinary
tools. Names stay readable where the filesystem allows it: a key of nothing but
lowercase letters, digits, `-`, `_` and `.`, short enough and not a reserved
device name, becomes that file name, and anything else becomes a SHA-256 hash
of the key. Uppercase counts as "anything else" on purpose — Windows would
otherwise fold `Key` and `key` onto one file and merge two entries the contract
keeps apart.

Because a file name can be a hash, every file also records the key it was
written under. That is what lets the store enumerate what it holds, and what
makes a read verify that the file it opened really is the key that was asked
for. Writes go through a temporary file, so a process that dies mid-write
leaves the old entry or no entry, never half of one; a file that cannot be read
or parsed is a miss rather than an exception.

### The NATS store

```pascal
uses WalKey.Core, WalKey.Stores.NATS;

LStore := TKVNatsStore.Create(LJs, 'myapp');       // LJs: TJetStreamContext
LStore.Put('session-42', '{"user":"alice"}', 'sessions', 3600);
```

One bucket per collection, named `<prefix>_<collection>` so a single account can
hold several stores without them seeing each other. A value is stored as the
usual WalKey envelope, so the entry still carries its own creation instant and
expiry; `TKVNatsValueMode.Bare` stores the value verbatim instead, for a bucket
another NATS client shares, at the price of the TTL. A collection or key name
that NATS cannot hold is encoded reversibly, so any name WalKey allows still
round-trips.

The store owns neither the connection nor the JetStream context — both must
outlive it — and it needs a nats-server with JetStream. See
[Docs/stores.md](Docs/stores.md).

### Wrappers

A wrapper implements `IKeyValue` and holds another `IKeyValue`, so they stack in
any order and the store at the bottom never knows:

```pascal
LStore :=
  TKVLoggingWrapper.Create(
    TKVStatisticsWrapper.Create(
      TKVTTLClampWrapper.Create(
        TKVPrefixKeysWrapper.Create(LRedis, 'tenant-7'),
        0, 3600, 300)),               // no floor, an hour's ceiling, 5 min default
    procedure (const AMessage: string)
    begin
      Writeln(AMessage);
    end);
```

A call travels down the stack and each wrapper does its part on the way. For
the stack above, a `Put('session-42', ..., 'sessions')` with no TTL:

```mermaid
sequenceDiagram
    participant C as Caller
    participant L as Logging
    participant S as Statistics
    participant T as TTL clamp
    participant P as Prefix keys
    participant R as Store

    C->>L: Put('session-42', v, 'sessions')
    L->>L: write a log line
    L->>S: Put(...)
    S->>S: puts += 1
    S->>T: Put(...)
    T->>T: no TTL given, use 300 s
    T->>P: Put(..., ttl 300)
    P->>R: Put('tenant-7:session-42', v, 'sessions', 300)
```

One rule worth knowing: **a wrapper does not pass on the optional capabilities**
of the store it holds. Whether passing one on is even safe depends on the
wrapper — a read-only wrapper must not hand out a `DestroyAll`, and a prefixing
one must not hand out an enumeration reporting keys under names its callers
never used. So a wrapper offers a capability only where it can honour it
properly (`TKVPrefixKeysWrapper` enumerates its own namespace; `TKVReadOnlyWrapper`
passes enumeration through but refuses to cull or destroy), and everything else
is reached through `Inner`.

### The null store

`TKVNullStore` is WalKey's `/dev/null` — for turning a cache off without
unpicking the wiring around it, giving an unconfigured dependency a default
that cannot fail, keeping a test from persisting anything, or measuring a
benchmark with the storage taken out of it.

```pascal
uses
  WalKey.Core, WalKey.Stores.Memory, WalKey.Stores.Null;

if Config.CachingEnabled then
  LCache := TKVMemoryStore.Create
else
  LCache := TKVNullStore.Create;   // same code path, nothing retained
```

It is a *null* store, not a lax one: keys, collection names and TTLs are
validated exactly as a real store validates them, and the same calls raise the
same exceptions. Code that runs against it runs against any other store, which
is the only reason it is safe to swap in.

## Requirements

Delphi 11 Alexandria or newer.

The stores, the wrappers and the generic entity adapter depend on nothing but
the RTL. Three things are needed only for what uses them:

- [Neon](https://github.com/paolo-rossi/delphi-neon) — for
  `WalKey.Adapters.Neon` and `WalKeyNeon.dpk`. Set the `NEON` environment
  variable to your checkout, or clone it as `Libs\Neon`.
- [DUnitX](https://github.com/VSoftTechnologies/DUnitX) — for the test suite.
- [nats.delphi](https://github.com/paolo-rossi/nats.delphi) — for
  `WalKey.Stores.NATS`, and for its tests, which are compiled only when the
  suite is built with the `WALKEY_NATS` define (`BuildTests.bat 37.0 nats`).
  Clone it as `Libs\nats.delphi`. Nothing else in WalKey needs it.

## Building

Add `Source\` to your project's search path and use the units directly — for
the stores and wrappers there is nothing else to install, apart from the two
libraries above that the typed adapter and the NATS store need.

Or build the runtime packages, in `Packages\11AndLater\WalKeyGroup.groupproj`:

| Package | Contains | Requires |
|---|---|---|
| `WalKey.dpk` | core, stores, wrappers | `rtl` |
| `WalKeyNeon.dpk` | the typed adapter | `rtl`, `WalKey`, `Neon` |

```
BuildPackages.bat         REM both packages, Delphi 13 (default)
BuildTests.bat            REM build + run the test suite
BuildDemo.bat             REM build + run the demo
BuildTests.bat 23.0       REM ...or pick a Studio version
BuildTests.bat 37.0 nats  REM ...and the NATS tests (library + live server)
```

## Demo

`Demos\DemoBasic` is a console tour of the whole library: the three stores,
what TTL does (with the clock under its own control, so nothing waits), the
wrapper stack, a near cache per instance over one shared store, and typed
access. It writes into a temp folder and removes it
on the way out.

## Documentation

| | |
|---|---|
| [Docs/stores.md](Docs/stores.md) | The backends, what `TKVStoreBase` handles for them, the optional capabilities, and how to write one |
| [Docs/capabilities.md](Docs/capabilities.md) | The optional interfaces — enumerating, culling, destroying, watching: what they promise, what they cost, and how wrappers treat them |
| [Docs/wrappers.md](Docs/wrappers.md) | The stack, each wrapper, and why capabilities are not forwarded |
| [Docs/typed-access.md](Docs/typed-access.md) | `TKVNeonAdapter<T>`: what it is for, records and classes, ownership, misses, changing a stored type, and Neon configuration |

## Writing a store

Descend from `TKVStoreBase` and implement three primitives. Argument checking,
collection resolution, expiry and the bulk methods are already handled:

```pascal
function  DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;
function  DoDelete(const ACollection, AKey: string): Boolean; override;
```

Then point the conformance suite at it — descend from `TKVConformanceTests`,
implement `CreateStore`, and the whole contract is tested for you:

```pascal
[TestFixture]
TKVMyStoreTests = class(TKVConformanceTests)
protected
  function CreateStore(const AClock: TKVClock): IKeyValue; override;
end;
```

The clock is injected, so expiry is tested by moving time rather than sleeping.

## Credits

WalKey's design follows [py-key-value](https://github.com/strawgate/py-key-value)
by [strawgate](https://github.com/strawgate), adapted to Delphi idiom.

## License

MIT.
