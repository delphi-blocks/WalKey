{******************************************************************************}
{                                                                              }
{  WalKey - Pluggable Key-Value Stores for Delphi                              }
{                                                                              }
{  Copyright (c) 2026 Paolo Rossi <dev@paolorossi.net>                         }
{                                                                              }
{  All rights reserved                                                         }
{  Licensed under the MIT license                                              }
{                                                                              }
{******************************************************************************}

/// <summary>
///   The contract every WalKey store, wrapper and adapter is written against.
///
///   A store holds JSON text under a key, inside a collection. Nothing in this
///   unit parses or inspects a value: as far as the library is concerned a
///   value is an opaque string, and the "it is JSON" part is a convention the
///   typed adapters rely on.
///
///   TTL is uniform across backends because it is not delegated to them: a
///   value is stored as a TKVEntry carrying its own creation and expiry
///   instants, and an entry found expired on read is dropped and reported as
///   missing. A backend with native expiry is free to use it as well - it just
///   cannot be relied upon.
/// </summary>
unit WalKey.Core;

interface

uses
  System.SysUtils, System.DateUtils, System.JSON;

const
  /// <summary>
  ///   Collection used when a call passes an empty collection name.
  /// </summary>
  KV_DEFAULT_COLLECTION = 'default';
  /// <summary>
  ///   Longest key a store accepts.
  /// </summary>
  KV_MAX_KEY_LENGTH = 512;
  /// <summary>
  ///   Longest collection name a store accepts.
  /// </summary>
  KV_MAX_COLLECTION_LENGTH = 128;
  /// <summary>
  ///   Passed as a TTL: the entry never expires.
  /// </summary>
  KV_NO_TTL = 0.0;
  /// <summary>
  ///   Reported as a remaining TTL: the entry has no expiry.
  /// </summary>
  KV_NO_EXPIRY = -1.0;

type
  /// <summary>
  ///   Seconds. As a TTL, 0 (KV_NO_TTL) means "no expiry"; as a remaining
  ///   lifetime, -1 (KV_NO_EXPIRY) means "does not expire".
  /// </summary>
  TKVDuration = Double;

  /// <summary>
  ///   Source of "now", in UTC. Injectable so expiry can be tested without
  ///   sleeping, and so a whole stack can share one clock.
  /// </summary>
  TKVClock = reference to function: TDateTime;

  /// <summary>
  ///   Base of every error the library raises.
  /// </summary>
  EKVError = class(Exception);

  /// <summary>
  ///   The key is empty, too long, or holds control characters.
  /// </summary>
  EKVInvalidKeyError = class(EKVError);

  /// <summary>
  ///   The collection name is empty, too long, or holds control characters.
  /// </summary>
  EKVInvalidCollectionError = class(EKVError);

  /// <summary>
  ///   An argument other than the key or the collection is not usable - a
  ///   negative TTL, or bulk arrays of different lengths.
  /// </summary>
  EKVArgumentError = class(EKVError);

  /// <summary>
  ///   The backend itself failed: unreachable, unwritable, out of space.
  /// </summary>
  EKVStoreError = class(EKVError);
  /// <summary>
  ///   A write was attempted through a store that refuses them.
  /// </summary>
  EKVReadOnlyError = class(EKVError);

  /// <summary>
  ///   A persisted entry could not be read back.
  /// </summary>
  EKVSerializationError = class(EKVError);

  /// <summary>
  ///   A value plus the metadata that makes TTL work the same way everywhere.
  /// </summary>
  TKVEntry = record

    /// <summary>
    ///   The stored value, as opaque text.
    /// </summary>
    Value: string;

    /// <summary>
    ///   UTC. When the entry was written.
    /// </summary>
    CreatedAt: TDateTime;

    /// <summary>
    ///   UTC. 0 means the entry never expires.
    /// </summary>
    ExpiresAt: TDateTime;

    /// <summary>
    ///   Builds an entry, turning a TTL in seconds into an expiry instant.
    /// </summary>
    /// <param name="AValue">The value to store, untouched by the library</param>
    /// <param name="ACreatedAt">UTC instant the entry is written at</param>
    /// <param name="ATTL">
    ///   Lifetime in seconds; 0 or less stores the entry without an expiry.
    ///   Note that the record does not police a negative TTL - TKVStoreBase.Put
    ///   raises on one before it ever gets here.
    /// </param>
    class function Create(const AValue: string; const ACreatedAt: TDateTime; const ATTL: TKVDuration): TKVEntry; static;

    /// <summary>
    ///   Whether the entry expires at all.
    /// </summary>
    function HasExpiry: Boolean;

    /// <summary>
    ///   Whether the entry is expired as of ANow. Expiry is inclusive: an entry
    ///   is gone at the instant it expires, not after it.
    /// </summary>
    /// <param name="ANow">The UTC instant to judge the entry against</param>
    function IsExpiredAt(const ANow: TDateTime): Boolean;

    /// <summary>
    ///   Lifetime left as of ANow.
    /// </summary>
    /// <param name="ANow">The UTC instant to measure from</param>
    /// <returns>
    ///   Seconds left, 0 once expired, KV_NO_EXPIRY when there is no expiry.
    /// </returns>
    function TTLRemainingAt(const ANow: TDateTime): TKVDuration;
  end;

  /// <summary>
  ///   The whole contract. Everything else in WalKey either implements this or
  ///   is written against it.
  /// </summary>
  IKeyValue = interface
    ['{1C6E4A70-8B2D-4E36-9C1F-5A0D7F3B2E41}']

    /// <summary>
    ///   Reads a value, treating a miss as an empty string. No valid JSON
    ///   document is the empty string, so the conflation is safe; use TryGet
    ///   when you need the distinction.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <returns>The value, or '' when the key is missing or expired</returns>
    function Get(const AKey: string; const ACollection: string = ''): string;

    /// <summary>
    ///   Reads a value from the default collection, reporting whether it was
    ///   there at all.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="AValue">Receives the value, or '' on a miss</param>
    /// <returns>True when a live entry was found</returns>
    function TryGet(const AKey: string; out AValue: string): Boolean; overload;

    /// <summary>
    ///   Reads a value, reporting whether it was there at all.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <param name="AValue">Receives the value, or '' on a miss</param>
    /// <returns>True when a live entry was found</returns>
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload;

    /// <summary>
    ///   Reads the value and its remaining lifetime in one round trip.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <param name="AEntry">Receives the entry, value and expiry both</param>
    /// <returns>True when a live entry was found</returns>
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean;

    /// <summary>
    ///   Whether a live entry is stored under the key.
    /// </summary>
    /// <param name="AKey">The key to look for</param>
    /// <param name="ACollection">Collection to look in; '' is the default one</param>
    function Exists(const AKey: string; const ACollection: string = ''): Boolean;

    /// <summary>
    ///   Stores a value, replacing whatever was under the key.
    /// </summary>
    /// <param name="AKey">The key to write</param>
    /// <param name="AValue">The value, stored as given and never parsed</param>
    /// <param name="ACollection">Collection to write to; '' is the default one</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores the value without an expiry</param>
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes an entry. An entry that has already expired counts as gone, so
    ///   removing one reports False even though something was freed.
    /// </summary>
    /// <param name="AKey">The key to remove</param>
    /// <param name="ACollection">Collection to remove from; '' is the default one</param>
    /// <returns>True when a live entry was removed</returns>
    function Delete(const AKey: string; const ACollection: string = ''): Boolean;

    /// <summary>
    ///   Reads several keys at once.
    /// </summary>
    /// <param name="AKeys">The keys to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <returns>
    ///   One result per requested key, in the order asked for, empty for the
    ///   misses.
    /// </returns>
    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   Stores several values at once, all with the same TTL.
    /// </summary>
    /// <param name="AKeys">The keys to write</param>
    /// <param name="AValues">The values, one per key and in the same order</param>
    /// <param name="ACollection">Collection to write to; '' is the default one</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores the values without an expiry</param>
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes several entries at once.
    /// </summary>
    /// <param name="AKeys">The keys to remove</param>
    /// <param name="ACollection">Collection to remove from; '' is the default one</param>
    /// <returns>How many of the requested keys held a live entry</returns>
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer;

    /// <summary>
    ///   A view of this store bound to one collection: every call made on the
    ///   view lands in AName whatever collection argument is passed to it.
    /// </summary>
    /// <param name="AName">The collection to bind to</param>
    function Collection(const AName: string): IKeyValue;
  end;

  /// <summary>
  ///   Optional: a store that can list what it holds. Ask for it with
  ///   Supports(), since not every backend can enumerate cheaply.
  /// </summary>
  IKeyValueEnumerable = interface
    ['{2D7F5B81-9C3E-4F47-8A2B-6B1E8A4C3F52}']

    /// <summary>
    ///   The live keys of a collection. Expired entries are not reported, even
    ///   when they are still stored.
    /// </summary>
    /// <param name="ACollection">Collection to list; '' is the default one</param>
    function Keys(const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   Every collection the store knows about, empty ones included.
    /// </summary>
    function Collections: TArray<string>;
  end;

  /// <summary>
  ///   Optional: a store that can be swept of expired entries. Expiry is lazy
  ///   by default, so a store nobody reads from never reclaims anything on its
  ///   own.
  /// </summary>
  IKeyValueCullable = interface
    ['{3E805C92-0A4F-4058-9B3C-7C2F9B5D4A63}']

    /// <summary>
    ///   Drops every expired entry.
    /// </summary>
    /// <returns>How many entries were removed</returns>
    function Cull: Integer;
  end;

  /// <summary>
  ///   Optional: a store whose contents can be dropped wholesale.
  /// </summary>
  IKeyValueDestroyable = interface
    ['{4F916DA3-1B50-4169-AC4D-8D30AC6E5B74}']

    /// <summary>
    ///   Drops a whole collection and everything in it.
    /// </summary>
    /// <param name="AName">The collection to drop; '' is the default one</param>
    /// <returns>True when the collection existed</returns>
    function DestroyCollection(const AName: string): Boolean;

    /// <summary>
    ///   Empties the store.
    /// </summary>
    procedure DestroyAll;
  end;

  /// <summary>
  ///   The on-the-wire form of a TKVEntry, for stores that persist text.
  ///
  ///   The value is carried as an escaped JSON string rather than nested JSON:
  ///   the library then never has to parse a value, which costs nothing on
  ///   write, accepts a payload that is not a JSON object, and gives
  ///   compression and encryption wrappers a single thing to transform. The
  ///   price is that a persisted entry reads as double-encoded JSON.
  /// </summary>
  TKVEnvelope = record

    /// <summary>
    ///   Renders an entry as the JSON document a store persists.
    /// </summary>
    /// <param name="AEntry">The entry to render</param>
    class function Encode(const AEntry: TKVEntry): string; overload; static;

    /// <summary>
    ///   Renders an entry together with the key it is stored under. A store
    ///   whose medium cannot hold a key verbatim - a file name, say - writes
    ///   the key here, so it can enumerate what it holds and tell a mangled
    ///   name apart from the one that was asked for.
    /// </summary>
    /// <param name="AEntry">The entry to render</param>
    /// <param name="AKey">The key; an empty one writes no key member at all</param>
    class function Encode(const AEntry: TKVEntry; const AKey: string): string; overload; static;

    /// <summary>
    ///   Reads an entry back, raising when the document is not one.
    /// </summary>
    /// <param name="AJson">The persisted document</param>
    /// <returns>The entry the document held</returns>
    class function Decode(const AJson: string): TKVEntry; static;

    /// <summary>
    ///   Reads an entry back, reporting failure instead of raising. This is the
    ///   overload a store reading its own files should use: a stray or
    ///   half-written file is a miss, not a crash.
    /// </summary>
    /// <param name="AJson">The persisted document</param>
    /// <param name="AEntry">Receives the entry, or an empty one on failure</param>
    /// <returns>True when the document was a WalKey envelope</returns>
    class function TryDecode(const AJson: string; out AEntry: TKVEntry): Boolean; overload; static;

    /// <summary>
    ///   Reads an entry and the key it was stored under.
    /// </summary>
    /// <param name="AJson">The persisted document</param>
    /// <param name="AEntry">Receives the entry, or an empty one on failure</param>
    /// <param name="AKey">
    ///   Receives the stored key, or '' when the document carries none. A key
    ///   that is present but unreadable makes the document malformed rather
    ///   than keyless, so the two can be told apart
    /// </param>
    /// <returns>True when the document was a WalKey envelope</returns>
    class function TryDecode(const AJson: string; out AEntry: TKVEntry; out AKey: string): Boolean; overload; static;
  end;

  /// <summary>
  ///   The rules a store applies to what it is handed, and the clock it reads
  ///   when none was injected.
  /// </summary>
  TKVUtils = record

    /// <summary>
    ///   The wall clock, in UTC.
    /// </summary>
    class function UtcNow: TDateTime; static;

    /// <summary>
    ///   Whether a key is usable: not empty, no longer than
    ///   KV_MAX_KEY_LENGTH, and free of control characters. Everything else -
    ///   spaces, dots, slashes, any Unicode - is allowed, and it is up to a
    ///   backend to sanitize what its medium cannot take verbatim.
    /// </summary>
    /// <param name="AKey">The key to judge</param>
    class function IsValidKey(const AKey: string): Boolean; static;

    /// <summary>
    ///   Whether a collection name is usable, by the same rule as a key but
    ///   with KV_MAX_COLLECTION_LENGTH as the limit.
    /// </summary>
    /// <param name="AName">The collection name to judge</param>
    class function IsValidCollection(const AName: string): Boolean; static;

    /// <summary>
    ///   Raises EKVInvalidKeyError unless the key is usable.
    /// </summary>
    /// <param name="AKey">The key to check</param>
    class procedure CheckKey(const AKey: string); static;

    /// <summary>
    ///   Raises EKVInvalidCollectionError unless the collection name is usable.
    /// </summary>
    /// <param name="AName">The collection name to check</param>
    class procedure CheckCollection(const AName: string); static;

    /// <summary>
    ///   Raises EKVArgumentError unless the two counts match. The array form
    ///   below is what a PutMany with string values calls; this one is for a
    ///   caller whose values are not strings, like the typed adapter.
    /// </summary>
    /// <param name="AKeyCount">How many keys were passed</param>
    /// <param name="AValueCount">How many values were passed</param>
    class procedure CheckBulkLengths(const AKeyCount, AValueCount: Integer); overload; static;

    /// <summary>
    ///   Raises EKVArgumentError unless the two arrays are the same length.
    ///   Every PutMany in the library is written in terms of this, so whether
    ///   the complaint comes from a store, a wrapper or an adapter it is the
    ///   same complaint.
    /// </summary>
    /// <param name="AKeys">The keys being written</param>
    /// <param name="AValues">The values, one per key</param>
    class procedure CheckBulkLengths(const AKeys, AValues: TArray<string>); overload; static;

    /// <summary>
    ///   Raises EKVArgumentError when a lifetime is negative. A negative TTL is
    ///   a mistake, not a very short one.
    /// </summary>
    /// <param name="ATTL">The lifetime to check, in seconds</param>
    class procedure CheckTTL(const ATTL: TKVDuration); static;
  end;

  /// <summary>
  ///   Base for every store: argument checking, collection resolution, expiry
  ///   policy and the bulk methods, all in one place. A backend fills in three
  ///   primitives and gets the contract for free.
  ///
  ///   Thread safety is the backend's, not the base's: TKVMemoryStore and
  ///   TKVNullStore are safe, the file store's writes are, and a backend that
  ///   is not says so. Clock and DefaultCollection are read on every call, so
  ///   set them before the store is shared rather than while it is in use.
  /// </summary>
  TKVStoreBase = class abstract(TInterfacedObject, IKeyValue)
  private
    FClock: TKVClock;
    FDefaultCollection: string;
    procedure SetDefaultCollection(const AValue: string);
  protected

    /// <summary>
    ///   Now, in UTC, from the injected clock or the wall clock.
    /// </summary>
    function UtcNow: TDateTime;

    /// <summary>
    ///   Validates a collection name, substituting the default collection for
    ///   an empty one.
    /// </summary>
    /// <param name="ACollection">The name a caller passed</param>
    /// <returns>The name the backend should use</returns>
    function ResolveCollection(const ACollection: string): string;

    /// <summary>
    ///   Backend primitive: fetch the entry stored under a key, expired or not.
    ///   Always called with a validated key and a resolved collection name.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="AEntry">Receives the entry as stored</param>
    /// <returns>True when something was stored under the key</returns>
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; virtual; abstract;

    /// <summary>
    ///   Backend primitive: store an entry, replacing whatever was there.
    ///   Always called with a validated key and a resolved collection name.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="AEntry">The entry to store, expiry already computed</param>
    procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); virtual; abstract;

    /// <summary>
    ///   Backend primitive: remove whatever is stored under a key, expired or
    ///   not. Always called with a validated key and a resolved collection name.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <returns>True when something was removed</returns>
    function DoDelete(const ACollection, AKey: string): Boolean; virtual; abstract;

    /// <summary>
    ///   Backend primitive: remove whatever is stored under a key and report
    ///   whether it was live at ANow. The default is a read and then a delete;
    ///   a backend that can do both under one lock overrides it, so the answer
    ///   and the removal cannot disagree.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="ANow">The UTC instant to judge the entry's expiry against</param>
    /// <returns>True when a live entry was removed</returns>
    function DoDeleteLive(const ACollection, AKey: string; const ANow: TDateTime): Boolean; virtual;

    /// <summary>
    ///   Drops an entry that a read found expired. The default deletes it
    ///   unconditionally; a store that can re-check under its own lock should
    ///   override, so a value written by another thread in between survives.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="ANow">The UTC instant the entry was judged expired at</param>
    procedure DoDropExpired(const ACollection, AKey: string; const ANow: TDateTime); virtual;
  public
    /// <summary>
    ///   Builds the store.
    /// </summary>
    /// <param name="AClock">
    ///   Where the store reads "now" from. Leave it nil for the wall clock;
    ///   pass one to test expiry without sleeping.
    /// </param>
    constructor Create(const AClock: TKVClock = nil); virtual;

    /// <summary>
    ///   Reads a value, treating a miss as an empty string.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <returns>The value, or '' when the key is missing or expired</returns>
    function Get(const AKey: string; const ACollection: string = ''): string;

    /// <summary>
    ///   Reads a value from the default collection, reporting whether it was
    ///   there at all.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="AValue">Receives the value, or '' on a miss</param>
    /// <returns>True when a live entry was found</returns>
    function TryGet(const AKey: string; out AValue: string): Boolean; overload;

    /// <summary>
    ///   Reads a value, reporting whether it was there at all.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <param name="AValue">Receives the value, or '' on a miss</param>
    /// <returns>True when a live entry was found</returns>
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload;

    /// <summary>
    ///   Reads the value and its remaining lifetime in one round trip. This is
    ///   where the expiry policy lives: an entry found expired is dropped and
    ///   reported as a miss.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <param name="AEntry">Receives the entry, value and expiry both</param>
    /// <returns>True when a live entry was found</returns>
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean;

    /// <summary>
    ///   Whether a live entry is stored under the key.
    /// </summary>
    /// <param name="AKey">The key to look for</param>
    /// <param name="ACollection">Collection to look in; '' is the default one</param>
    function Exists(const AKey: string; const ACollection: string = ''): Boolean;

    /// <summary>
    ///   Stores a value, replacing whatever was under the key.
    /// </summary>
    /// <param name="AKey">The key to write</param>
    /// <param name="AValue">The value, stored as given and never parsed</param>
    /// <param name="ACollection">Collection to write to; '' is the default one</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores the value without an expiry</param>
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes an entry.
    /// </summary>
    /// <param name="AKey">The key to remove</param>
    /// <param name="ACollection">Collection to remove from; '' is the default one</param>
    /// <returns>True when a live entry was removed</returns>
    function Delete(const AKey: string; const ACollection: string = ''): Boolean;

    /// <summary>
    ///   Reads several keys at once. The default walks them one by one; a
    ///   backend with native bulk reads should override.
    /// </summary>
    /// <param name="AKeys">The keys to read</param>
    /// <param name="ACollection">Collection to read from; '' is the default one</param>
    /// <returns>One result per requested key, in order, empty for the misses</returns>
    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   Stores several values at once. The default walks them one by one; a
    ///   backend with native bulk writes should override.
    /// </summary>
    /// <param name="AKeys">The keys to write</param>
    /// <param name="AValues">The values, one per key and in the same order</param>
    /// <param name="ACollection">Collection to write to; '' is the default one</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores the values without an expiry</param>
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes several entries at once. The default walks them one by one; a
    ///   backend with native bulk deletes should override.
    /// </summary>
    /// <param name="AKeys">The keys to remove</param>
    /// <param name="ACollection">Collection to remove from; '' is the default one</param>
    /// <returns>How many of the requested keys held a live entry</returns>
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer;

    /// <summary>
    ///   A view of this store bound to one collection.
    /// </summary>
    /// <param name="AName">The collection to bind to</param>
    function Collection(const AName: string): IKeyValue;

    /// <summary>
    ///   Where the store reads "now" from. Nil means the wall clock. Set it
    ///   before the store is shared: every call reads it anew.
    /// </summary>
    property Clock: TKVClock read FClock write FClock;

    /// <summary>
    ///   The collection a call that names none lands in. Defaults to
    ///   KV_DEFAULT_COLLECTION. Like Clock, set it before the store is shared,
    ///   not while another thread is using it.
    /// </summary>
    property DefaultCollection: string read FDefaultCollection write SetDefaultCollection;
  end;

  /// <summary>
  ///   What IKeyValue.Collection returns: a store seen through one collection.
  ///   The binding wins over any collection argument passed to the view, which
  ///   is what makes it safe to hand out as a namespaced store of its own.
  /// </summary>
  TKVCollectionView = class(TInterfacedObject, IKeyValue)
  private
    FInner: IKeyValue;
    FCollection: string;
  public
    /// <summary>
    ///   Binds a store to a collection.
    /// </summary>
    /// <param name="AInner">The store every call is forwarded to</param>
    /// <param name="ACollection">The collection every call lands in</param>
    constructor Create(const AInner: IKeyValue; const ACollection: string);

    /// <summary>
    ///   Reads a value from the bound collection.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <returns>The value, or '' when the key is missing or expired</returns>
    function Get(const AKey: string; const ACollection: string = ''): string;

    /// <summary>
    ///   Reads a value from the bound collection, reporting whether it was
    ///   there at all.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="AValue">Receives the value, or '' on a miss</param>
    /// <returns>True when a live entry was found</returns>
    function TryGet(const AKey: string; out AValue: string): Boolean; overload;

    /// <summary>
    ///   Reads a value from the bound collection, reporting whether it was
    ///   there at all.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <param name="AValue">Receives the value, or '' on a miss</param>
    /// <returns>True when a live entry was found</returns>
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload;

    /// <summary>
    ///   Reads the value and its remaining lifetime from the bound collection.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <param name="AEntry">Receives the entry, value and expiry both</param>
    /// <returns>True when a live entry was found</returns>
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean;

    /// <summary>
    ///   Whether a live entry is stored under the key in the bound collection.
    /// </summary>
    /// <param name="AKey">The key to look for</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    function Exists(const AKey: string; const ACollection: string = ''): Boolean;

    /// <summary>
    ///   Stores a value in the bound collection.
    /// </summary>
    /// <param name="AKey">The key to write</param>
    /// <param name="AValue">The value, stored as given and never parsed</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores the value without an expiry</param>
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes an entry from the bound collection.
    /// </summary>
    /// <param name="AKey">The key to remove</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <returns>True when a live entry was removed</returns>
    function Delete(const AKey: string; const ACollection: string = ''): Boolean;

    /// <summary>
    ///   Reads several keys at once from the bound collection.
    /// </summary>
    /// <param name="AKeys">The keys to read</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <returns>One result per requested key, in order, empty for the misses</returns>
    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   Stores several values at once in the bound collection.
    /// </summary>
    /// <param name="AKeys">The keys to write</param>
    /// <param name="AValues">The values, one per key and in the same order</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores the values without an expiry</param>
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes several entries at once from the bound collection.
    /// </summary>
    /// <param name="AKeys">The keys to remove</param>
    /// <param name="ACollection">Ignored: the bound collection wins</param>
    /// <returns>How many of the requested keys held a live entry</returns>
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer;

    /// <summary>
    ///   Another view of the same store. A view of a view is a view of the
    ///   store underneath, not a nesting.
    /// </summary>
    /// <param name="AName">The collection to bind to</param>
    function Collection(const AName: string): IKeyValue;
  end;

implementation

resourcestring
  SKVInvalidKey = 'Invalid key: a key must be 1 to %d characters and hold no control characters';
  SKVInvalidCollection = 'Invalid collection name "%s": a name must be 1 to %d characters and hold no control characters';
  SKVNegativeTTL = 'Invalid TTL %g: a TTL cannot be negative (pass 0 for no expiry)';
  SKVLengthMismatch = 'PutMany was given %d keys and %d values';
  SKVBadEnvelope = 'Malformed WalKey envelope';

function DateTimeToUnixMs(const AValue: TDateTime): Int64;
begin
  Result := Round((AValue - UnixDateDelta) * MSecsPerDay);
end;

function UnixMsToDateTime(const AValue: Int64): TDateTime;
begin
  Result := UnixDateDelta + (AValue / MSecsPerDay);
end;

{ TKVEntry }

class function TKVEntry.Create(const AValue: string; const ACreatedAt: TDateTime;
  const ATTL: TKVDuration): TKVEntry;
begin
  Result.Value := AValue;
  Result.CreatedAt := ACreatedAt;
  if ATTL > 0 then
    Result.ExpiresAt := ACreatedAt + (ATTL / SecsPerDay)
  else
    Result.ExpiresAt := 0;
end;

function TKVEntry.HasExpiry: Boolean;
begin
  Result := ExpiresAt > 0;
end;

function TKVEntry.IsExpiredAt(const ANow: TDateTime): Boolean;
begin
  Result := HasExpiry and (ANow >= ExpiresAt);
end;

function TKVEntry.TTLRemainingAt(const ANow: TDateTime): TKVDuration;
begin
  if not HasExpiry then
    Exit(KV_NO_EXPIRY);

  Result := (ExpiresAt - ANow) * SecsPerDay;
  if Result < 0 then
    Result := 0;
end;

{ TKVEnvelope }

class function TKVEnvelope.Encode(const AEntry: TKVEntry): string;
begin
  Result := Encode(AEntry, '');
end;

class function TKVEnvelope.Encode(const AEntry: TKVEntry; const AKey: string): string;
var
  LObject: TJSONObject;
begin
  LObject := TJSONObject.Create;
  try
    LObject.AddPair('v', AEntry.Value);
    LObject.AddPair('c', TJSONNumber.Create(DateTimeToUnixMs(AEntry.CreatedAt)));
    if AEntry.HasExpiry then
      LObject.AddPair('e', TJSONNumber.Create(DateTimeToUnixMs(AEntry.ExpiresAt)));
    if AKey <> '' then
      LObject.AddPair('k', AKey);
    Result := LObject.ToJSON;
  finally
    LObject.Free;
  end;
end;

class function TKVEnvelope.TryDecode(const AJson: string; out AEntry: TKVEntry): Boolean;
var
  LKey: string;
begin
  Result := TryDecode(AJson, AEntry, LKey);
end;

class function TKVEnvelope.TryDecode(const AJson: string; out AEntry: TKVEntry; out AKey: string): Boolean;
var
  LValue: TJSONValue;
  LObject: TJSONObject;
  LValueText, LKey: string;
  LCreated, LExpires: Int64;
  LExpiresAt: TDateTime;
begin
  Result := False;
  AEntry := Default(TKVEntry);
  AKey := '';

  try
    LValue := TJSONObject.ParseJSONValue(AJson);
  except
    // The parser answers nil for text that is not JSON rather than raising, so
    // this is belt and braces: if it ever does raise, the document is corrupt,
    // not the store, and the caller sees a miss.
    on E: EJSONParseException do
      Exit(False);
  end;

  if LValue = nil then
    Exit;
  try
    if not (LValue is TJSONObject) then
      Exit;

    LObject := TJSONObject(LValue);
    if not LObject.TryGetValue<string>('v', LValueText) then
      Exit;
    if not LObject.TryGetValue<Int64>('c', LCreated) then
      Exit;

    // A key that is there but unreadable is a corrupt envelope, not one
    // without a key. Only a document with no 'k' member at all leaves the key
    // empty, so a store that insists on a key can tell the two apart.
    if LObject.GetValue('k') <> nil then
      if not LObject.TryGetValue<string>('k', LKey) then
        Exit;

    // The same for the expiry: one that is there but unreadable is corruption,
    // not "no expiry". Reading it as the latter would make a broken entry
    // permanent.
    LExpiresAt := 0;
    if LObject.GetValue('e') <> nil then
    begin
      if not LObject.TryGetValue<Int64>('e', LExpires) then
        Exit;
      LExpiresAt := UnixMsToDateTime(LExpires);
    end;

    // Nothing is written out until every member has been read, so a document
    // that fails to decode leaves an empty entry rather than half of one.
    AEntry.Value := LValueText;
    AEntry.CreatedAt := UnixMsToDateTime(LCreated);
    AEntry.ExpiresAt := LExpiresAt;
    AKey := LKey;

    Result := True;
  finally
    LValue.Free;
  end;
end;

class function TKVEnvelope.Decode(const AJson: string): TKVEntry;
begin
  if not TryDecode(AJson, Result) then
    raise EKVSerializationError.Create(SKVBadEnvelope);
end;

{ TKVUtils }

class function TKVUtils.UtcNow: TDateTime;
begin
  Result := TTimeZone.Local.ToUniversalTime(System.SysUtils.Now);
end;

class function TKVUtils.IsValidKey(const AKey: string): Boolean;
var
  LChar: Char;
begin
  if (AKey = '') or (Length(AKey) > KV_MAX_KEY_LENGTH) then
    Exit(False);

  for LChar in AKey do
    if (LChar < #32) or (LChar = #127) then
      Exit(False);

  Result := True;
end;

class function TKVUtils.IsValidCollection(const AName: string): Boolean;
var
  LChar: Char;
begin
  if (AName = '') or (Length(AName) > KV_MAX_COLLECTION_LENGTH) then
    Exit(False);

  for LChar in AName do
    if (LChar < #32) or (LChar = #127) then
      Exit(False);

  Result := True;
end;

class procedure TKVUtils.CheckKey(const AKey: string);
begin
  if not IsValidKey(AKey) then
    raise EKVInvalidKeyError.CreateFmt(SKVInvalidKey, [KV_MAX_KEY_LENGTH]);
end;

class procedure TKVUtils.CheckCollection(const AName: string);
begin
  if not IsValidCollection(AName) then
    raise EKVInvalidCollectionError.CreateFmt(SKVInvalidCollection,
      [AName, KV_MAX_COLLECTION_LENGTH]);
end;

class procedure TKVUtils.CheckBulkLengths(const AKeyCount, AValueCount: Integer);
begin
  if AKeyCount <> AValueCount then
    raise EKVArgumentError.CreateFmt(SKVLengthMismatch, [AKeyCount, AValueCount]);
end;

class procedure TKVUtils.CheckBulkLengths(const AKeys, AValues: TArray<string>);
begin
  TKVUtils.CheckBulkLengths(Length(AKeys), Length(AValues));
end;

class procedure TKVUtils.CheckTTL(const ATTL: TKVDuration);
begin
  if ATTL < 0 then
    raise EKVArgumentError.CreateFmt(SKVNegativeTTL, [ATTL]);
end;

{ TKVStoreBase }

constructor TKVStoreBase.Create(const AClock: TKVClock);
begin
  inherited Create;
  FClock := AClock;
  FDefaultCollection := KV_DEFAULT_COLLECTION;
end;

function TKVStoreBase.UtcNow: TDateTime;
begin
  if Assigned(FClock) then
    Result := FClock()
  else
    Result := TKVUtils.UtcNow;
end;

procedure TKVStoreBase.SetDefaultCollection(const AValue: string);
begin
  TKVUtils.CheckCollection(AValue);
  FDefaultCollection := AValue;
end;

function TKVStoreBase.ResolveCollection(const ACollection: string): string;
begin
  if ACollection = '' then
    Result := FDefaultCollection
  else
    Result := ACollection;

  TKVUtils.CheckCollection(Result);
end;

procedure TKVStoreBase.DoDropExpired(const ACollection, AKey: string; const ANow: TDateTime);
begin
  DoDelete(ACollection, AKey);
end;

function TKVStoreBase.DoDeleteLive(const ACollection, AKey: string; const ANow: TDateTime): Boolean;
var
  LEntry: TKVEntry;
begin
  // An expired entry is already gone as far as a caller is concerned, so
  // deleting it reports False even though something was removed.
  Result := DoTryGet(ACollection, AKey, LEntry) and not LEntry.IsExpiredAt(ANow);
  DoDelete(ACollection, AKey);
end;

function TKVStoreBase.TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean;
var
  LCollection: string;
  LNow: TDateTime;
begin
  TKVUtils.CheckKey(AKey);
  LCollection := ResolveCollection(ACollection);

  Result := DoTryGet(LCollection, AKey, AEntry);
  if not Result then
    Exit;

  LNow := UtcNow;
  if AEntry.IsExpiredAt(LNow) then
  begin
    DoDropExpired(LCollection, AKey, LNow);
    AEntry := Default(TKVEntry);
    Result := False;
  end;
end;

function TKVStoreBase.TryGet(const AKey, ACollection: string; out AValue: string): Boolean;
var
  LEntry: TKVEntry;
begin
  Result := TryGetEntry(AKey, ACollection, LEntry);
  if Result then
    AValue := LEntry.Value
  else
    AValue := '';
end;

function TKVStoreBase.TryGet(const AKey: string; out AValue: string): Boolean;
begin
  Result := TryGet(AKey, '', AValue);
end;

function TKVStoreBase.Get(const AKey, ACollection: string): string;
begin
  TryGet(AKey, ACollection, Result);
end;

function TKVStoreBase.Exists(const AKey, ACollection: string): Boolean;
var
  LEntry: TKVEntry;
begin
  Result := TryGetEntry(AKey, ACollection, LEntry);
end;

procedure TKVStoreBase.Put(const AKey, AValue, ACollection: string; const ATTL: TKVDuration);
begin
  TKVUtils.CheckKey(AKey);
  TKVUtils.CheckTTL(ATTL);

  DoPut(ResolveCollection(ACollection), AKey, TKVEntry.Create(AValue, UtcNow, ATTL));
end;

function TKVStoreBase.Delete(const AKey, ACollection: string): Boolean;
var
  LCollection: string;
begin
  TKVUtils.CheckKey(AKey);
  LCollection := ResolveCollection(ACollection);

  Result := DoDeleteLive(LCollection, AKey, UtcNow);
end;

function TKVStoreBase.GetMany(const AKeys: TArray<string>; const ACollection: string): TArray<string>;
var
  LIndex: Integer;
begin
  SetLength(Result, Length(AKeys));
  for LIndex := 0 to High(AKeys) do
    TryGet(AKeys[LIndex], ACollection, Result[LIndex]);
end;

procedure TKVStoreBase.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
var
  LIndex: Integer;
  LCollection: string;
  LNow: TDateTime;
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  TKVUtils.CheckTTL(ATTL);

  // One instant and one collection for the whole batch, so a single call
  // cannot straddle a clock tick or a default collection changed midway.
  LCollection := ResolveCollection(ACollection);
  LNow := UtcNow;

  for LIndex := 0 to High(AKeys) do
  begin
    TKVUtils.CheckKey(AKeys[LIndex]);
    DoPut(LCollection, AKeys[LIndex], TKVEntry.Create(AValues[LIndex], LNow, ATTL));
  end;
end;

function TKVStoreBase.DeleteMany(const AKeys: TArray<string>; const ACollection: string): Integer;
var
  LKey: string;
begin
  Result := 0;
  for LKey in AKeys do
    if Delete(LKey, ACollection) then
      Inc(Result);
end;

function TKVStoreBase.Collection(const AName: string): IKeyValue;
begin
  Result := TKVCollectionView.Create(Self, AName);
end;

{ TKVCollectionView }

constructor TKVCollectionView.Create(const AInner: IKeyValue; const ACollection: string);
begin
  inherited Create;
  // '' is the default collection, so a view can bind it: every call is then
  // forwarded with '' and the store underneath resolves its own default,
  // which a wrapper could not do on its behalf.
  if ACollection <> '' then
    TKVUtils.CheckCollection(ACollection);
  FInner := AInner;
  FCollection := ACollection;
end;

function TKVCollectionView.Get(const AKey, ACollection: string): string;
begin
  Result := FInner.Get(AKey, FCollection);
end;

function TKVCollectionView.TryGet(const AKey: string; out AValue: string): Boolean;
begin
  Result := FInner.TryGet(AKey, FCollection, AValue);
end;

function TKVCollectionView.TryGet(const AKey, ACollection: string; out AValue: string): Boolean;
begin
  Result := FInner.TryGet(AKey, FCollection, AValue);
end;

function TKVCollectionView.TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean;
begin
  Result := FInner.TryGetEntry(AKey, FCollection, AEntry);
end;

function TKVCollectionView.Exists(const AKey, ACollection: string): Boolean;
begin
  Result := FInner.Exists(AKey, FCollection);
end;

procedure TKVCollectionView.Put(const AKey, AValue, ACollection: string; const ATTL: TKVDuration);
begin
  FInner.Put(AKey, AValue, FCollection, ATTL);
end;

function TKVCollectionView.Delete(const AKey, ACollection: string): Boolean;
begin
  Result := FInner.Delete(AKey, FCollection);
end;

function TKVCollectionView.GetMany(const AKeys: TArray<string>; const ACollection: string): TArray<string>;
begin
  Result := FInner.GetMany(AKeys, FCollection);
end;

procedure TKVCollectionView.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  FInner.PutMany(AKeys, AValues, FCollection, ATTL);
end;

function TKVCollectionView.DeleteMany(const AKeys: TArray<string>; const ACollection: string): Integer;
begin
  Result := FInner.DeleteMany(AKeys, FCollection);
end;

function TKVCollectionView.Collection(const AName: string): IKeyValue;
begin
  // A view of a view is a view of the same store, not a nesting.
  Result := TKVCollectionView.Create(FInner, AName);
end;

end.
