# Typed access

A store trades in text. `TKVEntityAdapter<T>` turns that text into a Delphi
record or object and back, so calling code deals in its own types and never
writes a serialization call. What the text *is* belongs to a codec:
`TKVNeonAdapter<T>`, in `WalKey.Adapters.Neon`, is the one that uses JSON, and
another is two methods.

```pascal
uses
  WalKey.Core, WalKey.Stores.Memory, WalKey.Adapters.Neon;

type
  TUser = record
    Name: string;
    Email: string;
    Age: Integer;
  end;

var
  LUsers: IKVEntityAdapter<TUser>;
  LUser: TUser;
begin
  LUsers := TKVNeonAdapter<TUser>.Create(TKVMemoryStore.Create, 'users');

  LUsers.Put('alice', LUser, 3600);
  if LUsers.TryGet('alice', LUser) then
    ShowMessage(LUser.Name);
end;
```

The generic half — `TKVEntityAdapter<T>` and `IKVEntityAdapter<T>` — uses the
RTL alone and ships in `WalKey.dpk`. Only the Neon codec depends on anything
outside the RTL, which is why it is a unit and a package of its own —
`WalKeyNeon.dpk`, requiring `WalKey` and `Neon`.

## What it is for

The core library never looks inside a value: it stores a string and gives the
same string back. That keeps every store and wrapper simple and free of
dependencies, but it leaves the application with the job of turning its data
into JSON and back at every call. Without the adapter, every read looks like
this:

```pascal
var
  LJson: string;
  LUser: TUser;
begin
  if LStore.TryGet('alice', 'users', LJson) then
  try
    LUser := TNeon.JSONToValue<TUser>(LJson, LConfig);
  except
    on E: Exception do
      raise EMyAppError.Create('users/alice is corrupt: ' + E.Message);
  end
  else
    LUser := Default(TUser);
  ...
```

Repeated at every call site, that code drifts. One place passes a different
Neon configuration and writes JSON the others cannot read. Another forgets the
`except` and lets a Neon exception escape where the caller expected a WalKey
one. A third mistakes a stored `null` for a miss. And it is easy to forget who
frees an object that was just read.

The adapter decides each of those questions once:

| Question | The adapter's answer |
|---|---|
| Which serializer, which settings? | Neon, with one configuration per adapter |
| Which collection? | The one given to the constructor, for every call |
| What does a miss give? | `Default(T)`, a default of your choosing, or an exception: your choice |
| What if the text is not a `T`? | `EKVSerializationError`, naming the key; see [Values that are not a T](#values-that-are-not-a-t) |
| What about `nil`? | Stored as `null`, read back as `nil` |
| Who owns an object that was read? | The caller, every time |

With the adapter the read above is one line, and so is every other call:

```pascal
LUser := LUsers.Get('alice');
```

The result is a store with a type: `IKVEntityAdapter<TUser>` holds users, and the
compiler will not let anything else be put in it.

### When to use it, and when not

Use it when the values are **structured data your code owns**: sessions,
settings, cached results from a service, snapshots of domain objects.

Use the store directly when:

- **The value is already text**: a rendered HTML fragment, a token, a JSON
  document received from elsewhere and passed on untouched. Deserializing and
  reserializing it would only cost time and risk changing it.
- **The value is a single scalar.** The adapter works for `Integer` or `string`,
  but `IntToStr` and `StrToInt` over the plain store are simpler.
- **Every microsecond counts on a hot path.** Every read parses JSON through
  RTTI, and for a class it also allocates an object. That is cheap next to a
  database round-trip, but it is not free next to a dictionary lookup.

The adapter and the plain store can be used side by side on the same store.
What the Neon codec writes is ordinary JSON (see [What it writes](#what-it-writes)).

## An adapter, not a wrapper

`TKVNeonAdapter<T>` does not implement `IKeyValue`: its methods take and return `T`
rather than a string, so it could not. That makes it an adapter. It sits on top
of the wrapper stack, not in it: the stack decides *where and how* strings are
stored, and the adapter decides *what* the strings mean.

```
TKVNeonAdapter<TSession>                     typed values in, typed values out
  -> TKVStatisticsWrapper              }
    -> TKVTTLClampWrapper              }  any stack of wrappers
      -> TKVPrefixKeysWrapper          }
        -> TKVFileTreeStore            the backend
```

```pascal
LSessions := TKVNeonAdapter<TSession>.Create(
  TKVStatisticsWrapper.Create(
    TKVTTLClampWrapper.Create(
      TKVPrefixKeysWrapper.Create(LStore, 'app1'),
      0, 86400, 1800)),
  'sessions');
```

Everything the stack does still applies: sessions get a default lifetime of
half an hour and at most a day, are namespaced, and are counted. The adapter
neither knows nor cares.

Several adapters over different types can share one store, each bound to its
own collection, and the store stays reachable through `Store`:

```pascal
LUsers  := TKVNeonAdapter<TUser>.Create(LStore, 'users');
LOrders := TKVNeonAdapter<TOrder>.Create(LStore, 'orders');

if Supports(LUsers.Store, IKeyValueCullable, LCullable) then
  LCullable.Cull;
```

**Give each type its own collection.** Two adapters of different types on one
collection can read each other's entries. At best the result is an
`EKVSerializationError`. At worst Neon, which ignores members it does not know,
reads a `TOrder` as a `TUser` with every field empty.

## The methods

`IKVEntityAdapter<T>` mirrors `IKeyValue` without the collection argument, which was
fixed when the adapter was built:

| Method | What it does |
|---|---|
| `Get(key)` | The value, or `Default(T)` on a miss, or raises if `RaiseOnMissing` is on |
| `TryGet(key, out value)` | True and the value, or False and `Default(T)` |
| `GetDef(key, default)` | The value, or the default you pass |
| `TryGetEntry(key, out value, out entry)` | As `TryGet`, plus the `TKVEntry` with its creation and expiry instants |
| `Exists(key)` | Whether a live entry is there. Nothing is deserialized |
| `Put(key, value, ttl)` | Serializes and stores |
| `Delete(key)` | True when a live entry was removed |
| `GetMany`, `PutMany`, `DeleteMany` | The bulk forms, one TTL for the whole batch |

`Exists` never deserializes, so it is the cheap check. It is also the one that
cannot tell you whether what is stored is still a valid `T`.

## Records and classes

Both work. The difference is ownership.

A **record** is copied in and out; there is nothing to manage.

A **class** is built fresh on every read, and **the caller owns what it gets**:

```pascal
LOrder := LOrders.Get('1');
try
  ...
finally
  LOrder.Free;
end;
```

Nothing is cached, and the adapter never keeps a reference to anything it
returned — the same rule the stores follow, one type up. Two reads of one key
give two independent objects, and changing one changes neither the other nor
the store. To change a stored object, read it, change it, and `Put` it back.

Writing works the same way round: **`Put` does not take ownership.** It
serializes the object and forgets it, so the caller still frees what it passed:

```pascal
LOrder := TOrder.Create;
try
  LOrder.Total := 42;
  LOrders.Put('1', LOrder);
finally
  LOrder.Free;
end;
```

`GetMany` for a class type answers an array of new objects, and the caller
frees each one that is not `nil`, since a miss gives `nil`.

A class `T` needs a parameterless constructor, since that is what a read calls
before filling the instance in.

**What gets serialized** follows Neon's defaults: a record's public fields, and
a class's public and published properties. A class that keeps its state in
private fields must expose it through properties, or be given a configuration
that selects fields.

## Misses, nil and empty values

By default a miss gives `Default(T)` — `nil` for a class, a zeroed record:

```pascal
LUser := LUsers.Get('nobody');     // LUser.Name = ''
```

`TryGet` is the explicit form, `GetDef` lets you choose what a miss answers
with, and `RaiseOnMissing` turns a miss into an `EKVNotFoundError`:

```pascal
LUsers.RaiseOnMissing := True;
LUser := LUsers.Get('nobody');     // raises
```

Turn it on where a missing key means a broken invariant rather than a cold
cache. An empty record read as though it were real data is a bug that surfaces
a long way from its cause.

`RaiseOnMissing` does not affect `TryGet` or `GetMany`: asking whether
something is there is never the mistake the flag is for.

Three situations look alike through `Get` and must be told apart with
`TryGet`:

| Stored | `Get` | `TryGet` |
|---|---|---|
| nothing, or expired | `Default(T)` (or raises) | False |
| `nil` object, stored as `null` | `nil` | **True**, value `nil` |
| a record stored as `null` by other code | a zeroed record | **True** |

`nil` is stored as JSON `null` and reads back as `nil`, so an optional value
round-trips as itself. It is a hit, not a miss: `RaiseOnMissing` does not
raise for it.

An **empty string** stored under a key, by code using the plain store, is not
a `T`, so reading it through the adapter raises `EKVSerializationError`. That
applies to `Get`, `TryGet` and `GetMany` alike.

## Values that are not a T

A stored value that will not deserialize into `T` raises
`EKVSerializationError`. Answering with an empty record would pass corruption
— or a type that has moved on — off as data. The message names the key, the
collection and the type, and carries Neon's own complaint. It never quotes the
stored value, which can be large and can be somebody's personal data.

"Will not deserialize" means the text as a whole: something that is not JSON,
or JSON of the wrong kind, such as a number where an object is expected. A
single *member* that will not convert is another matter. By default Neon logs
it and carries on, and the member reads as its default. To make that an error
as well, turn on Neon's `RaiseExceptions`:

```pascal
LUsers := TKVNeonAdapter<TUser>.Create(LStore, 'users',
  TNeonConfiguration.Default.SetRaiseExceptions(True));
```

For a class type, a read that fails frees the instance it had started to
build, and a `GetMany` that fails part-way frees the ones it had already
built. A failed read never leaves you anything to free.

`EKVSerializationError` is also one of the exceptions a `TKVFallbackWrapper`
deliberately does not fall through on: a corrupt value in the primary is
reported, not quietly replaced by the standby's copy.

## When the type changes

Stored JSON outlives the code that wrote it: a file store keeps it across
restarts, and a shared store may be read by the old and the new version of an
application at the same time. So a change to `T` is a change to a stored
format, and it deserves the same thought as a database schema change.

Neon is forgiving about a *shape* that has drifted: unknown members are ignored
and missing ones are left at their default. That decides what each kind of
change costs:

| Change to `T` | Reading old entries |
|---|---|
| Add a field | Works. The new field reads as its default until the entry is rewritten |
| Remove a field | Works. The stored value is ignored |
| Rename a field | **Silently loses data.** The old name is ignored, and the new one reads as its default |
| Change a field's type | **Usually silent too.** A stored value Neon cannot convert is skipped and the field reads as its default, unless `RaiseExceptions` is on |

A rename is the dangerous one, because nothing fails, and with Neon's default
configuration an incompatible type change is just as quiet. Keep the stored name with
a Neon attribute and rename freely in code:

```pascal
uses
  Neon.Core.Attributes;

type
  TUser = record
    Name: string;
    [NeonProperty('Email')]
    EmailAddress: string;  // renamed in code, still "Email" in the store
  end;
```

For a change that cannot be made compatible, give the new format its own
collections, so the old and new versions never read each other's entries.
Either bind the adapter to a new collection (`'users-v2'`), or put a
`TKVPrefixCollectionsWrapper` under the adapter, as in
[Changing the format of stored values](wrappers.md#changing-the-format-of-stored-values).
In a cache the old entries then expire by themselves. In anything longer-lived,
migrate them: read each one with an adapter for the old type and write it with
one for the new.

## In practice

### Sessions

```pascal
type
  TSession = record
    UserId: Integer;
    UserName: string;
    Roles: TArray<string>;
    CreatedAt: TDateTime;
  end;

LSessions := TKVNeonAdapter<TSession>.Create(LStore, 'sessions');

// Log in
LSession.UserId := 42;
LSession.UserName := 'alice';
LSession.Roles := ['admin'];
LSession.CreatedAt := Now;
LSessions.Put(LToken, LSession, 1800);

// Each request
if not LSessions.TryGet(LToken, LSession) then
  raise EUnauthorized.Create('Session expired');

// Log out
LSessions.Delete(LToken);
```

A record suits a session: it is copied, so there is nothing to free, and a
missing session is an ordinary event handled with `TryGet`, not an error. With
a file store underneath, sessions survive a restart of the server.

### User settings with defaults

```pascal
type
  TEditorSettings = record
    FontName: string;
    FontSize: Integer;
    WordWrap: Boolean;
  end;

const
  DEFAULT_SETTINGS: TEditorSettings =
    (FontName: 'Consolas'; FontSize: 11; WordWrap: False);

LSettings := TKVNeonAdapter<TEditorSettings>.Create(
  TKVFileTreeStore.Create(TPath.Combine(TPath.GetHomePath, 'MyApp')), 'settings');

LCurrent := LSettings.GetDef(LUserName, DEFAULT_SETTINGS);
...
LSettings.Put(LUserName, LCurrent);   // no TTL: settings do not expire
```

`GetDef` makes "a user who has never saved settings" a non-event. When a later
version adds a field to `TEditorSettings`, stored settings still load, with the
new field at its zero value. So choose new fields whose zero is a sensible
default, or fill them in after reading.

### Caching a slow service

```pascal
type
  TForecast = class
  private
    FCity: string;
    FTemperature: Double;
    FSummary: string;
  public
    property City: string read FCity write FCity;
    property Temperature: Double read FTemperature write FTemperature;
    property Summary: string read FSummary write FSummary;
  end;

function TWeatherService.Forecast(const ACity: string): TForecast;
begin
  // The caller owns the result, whichever branch produced it.
  if FCache.TryGet(ACity, Result) then
    Exit;

  Result := FClient.FetchForecast(ACity);   // slow, over the network
  try
    FCache.Put(ACity, Result, 600);         // Put copies; Result stays ours
  except
    Result.Free;
    raise;
  end;
end;
```

The same ownership rule holds on both branches, a cache hit or a fresh fetch:
the caller receives an object it must free. That is the point of the adapter
never keeping a reference. The cached copy and the returned object are
unrelated, so a caller that modifies its forecast cannot corrupt the cache.

### Refreshing before expiry

`TryGetEntry` returns the entry alongside the value, and with it the entry's
expiry. That makes it possible to refresh a value while it is still valid,
instead of making one unlucky caller wait for the fetch after it expires:

```pascal
var
  LEntry: TKVEntry;
begin
  if FRates.TryGetEntry('EUR', Result, LEntry) then
  begin
    if LEntry.HasExpiry and (LEntry.TTLRemainingAt(TKVUtils.UtcNow) < 60) then
      QueueRefresh('EUR');   // serve the current value; refresh in background
    Exit;
  end;
  ...
```

Check `HasExpiry` first. For an entry without one, `TTLRemainingAt` answers
`KV_NO_EXPIRY`, which is -1 and would pass any "less than" test.
`TKVUtils.UtcNow` is the wall clock. If the store was given a clock of its own,
as in tests, use that instead.

## Neon configuration

The third constructor argument is an `INeonConfiguration`. Leave it nil for
`TNeonConfiguration.Default`, which writes member names in PascalCase, or pass
one to choose member casing, visibility or custom serializers:

```pascal
LUsers := TKVNeonAdapter<TUser>.Create(LStore, 'users', TNeonConfiguration.Camel);
```

`TNeonConfiguration` also offers `Snake`, and `Pretty`, which indents the JSON.
`Pretty` makes entries in a file store easier to read by eye, at the cost of
space on every entry.

**Pass the same configuration everywhere.** It decides what the stored JSON
looks like, so changing it makes existing entries unreadable — the same care a
schema change deserves. The simplest way to guarantee that is one function that
builds all the adapters of an application:

```pascal
function StoreConfig: INeonConfiguration;
begin
  Result := TNeonConfiguration.Camel;
end;

LUsers  := TKVNeonAdapter<TUser>.Create(LStore, 'users', StoreConfig);
LOrders := TKVNeonAdapter<TOrder>.Create(LStore, 'orders', StoreConfig);
```

When the JSON is also read outside Delphi, for example by a JavaScript front
end or another service reading the same store, `Camel` matches what most other
languages expect.

## What it writes

Ordinary JSON, with nothing of WalKey's own in it:

```pascal
LUsers.Put('alice', LUser);
LStore.Get('alice', 'users');
// {"Name":"Alice","Email":"alice@example.com","Age":42}
```

The adapter is a convenience, not a container format. Anything else that can
read the store can read what it wrote — which is also what makes the file-tree
store's contents worth looking at. It works in the other direction too: JSON
put into the store by other code, or by hand, reads back through the adapter as
long as its shape matches `T`.

## Writing a codec

`TKVEntityAdapter<T>` is the whole typed adapter with one hole in it: how a `T`
becomes text and back. Two protected methods fill it, and everything else —
misses, `RaiseOnMissing`, the entry and its TTL, the bulk calls, the store
underneath — is already written:

```pascal
function Serialize(const AValue: T): string; virtual; abstract;
function Deserialize(const AText: string): T; virtual; abstract;
```

`TKVNeonAdapter<T>` is the codec for Neon and JSON. Another is one class:

```pascal
TKVPointAdapter = class(TKVEntityAdapter<TPoint>)
protected
  function Serialize(const AValue: TPoint): string; override;   // 'X;Y'
  function Deserialize(const AText: string): TPoint; override;
end;
```

Nothing in the base parses the text, so a codec can be CSV, a packed record or a
base64 blob; `WalKey.Tests.Adapters.Entity` is that example, over a codec that
is deliberately not JSON. Deriving from `TKVNeonAdapter<T>` is the smaller step
when only the JSON shape needs to change: override `Serialize`/`Deserialize`,
call `inherited` for the cases you do not want to handle, and keep Neon for the
rest.

Two things are the codec's responsibility:

- **`nil`.** The base hands every value to `Serialize`, nil included, and gives
  back whatever `Deserialize` returns. A codec for a class type decides how a
  nil is written and read the token back as `Default(T)` —
  `TKVNeonAdapter` uses `null`; a codec is free to choose anything, or refuse
  nil outright.
- **The exception.** Raise `EKVSerializationError` for text that is not a `T`.
  The base adds the key and collection to the message and keeps the text out of
  it, and the fallback wrapper sees the same exception whichever codec is in
  use.
