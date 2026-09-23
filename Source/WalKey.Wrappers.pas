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
///   Stores that wrap other stores. Each one implements IKeyValue and holds
///   another IKeyValue, so they stack in any order and the thing at the bottom
///   never knows it is being wrapped:
///
///   <code>
///   LStore := TKVLoggingWrapper.Create(
///     TKVStatisticsWrapper.Create(
///       TKVTTLClampWrapper.Create(
///         TKVPrefixKeysWrapper.Create(LMemory, 'tenant-7'),
///         0, 3600)),
///     procedure (const AMessage: string) begin Writeln(AMessage) end);
///   </code>
///
///   One rule worth knowing: a wrapper does not pass on the optional
///   capabilities (IKeyValueEnumerable, IKeyValueCullable,
///   IKeyValueDestroyable) of the store it holds. Whether passing one on is
///   even safe depends on the wrapper - a read-only wrapper must not hand out
///   a DestroyAll, and a prefixing one must not hand out an enumeration that
///   reports keys under names its callers never used. So a wrapper offers a
///   capability only where it can honour it properly, and everything else is
///   reached through the Inner property. The thread-safe wrapper is the one
///   that always implements all three, so a capability call is guarded like
///   any other; a store that has none makes the call raise.
/// </summary>
unit WalKey.Wrappers;

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  WalKey.Core;

type
  /// <summary>
  ///   Base of every wrapper: holds another store and forwards the whole of
  ///   IKeyValue to it. Every method is virtual, so a descendant overrides
  ///   only what it changes.
  /// </summary>
  TKVWrapper = class abstract(TInterfacedObject, IKeyValue)
  private
    FInner: IKeyValue;
  public
    /// <summary>
    ///   Wraps a store.
    /// </summary>
    /// <param name="AInner">The store to forward to; nil is refused</param>
    constructor Create(const AInner: IKeyValue);

    function Get(const AKey: string; const ACollection: string = ''): string; virtual;
    function TryGet(const AKey: string; out AValue: string): Boolean; overload; virtual;
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload; virtual;
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean; virtual;
    function Exists(const AKey: string; const ACollection: string = ''): Boolean; virtual;
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); virtual;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; virtual;

    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>; virtual;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); virtual;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; virtual;

    function Collection(const AName: string): IKeyValue; virtual;

    /// <summary>
    ///   The store underneath. This is how a caller reaches a capability the
    ///   wrapper does not pass on.
    /// </summary>
    property Inner: IKeyValue read FInner;
  end;

  /// <summary>
  ///   Puts every key in a namespace: what a caller writes as 'abc' is stored
  ///   as 'tenant-7:abc'. Several tenants, features or versions then share one
  ///   store without seeing each other.
  ///
  ///   The caller's key is validated before the prefix is added, so the length
  ///   limit still applies to what the caller wrote - but the prefixed key
  ///   must fit too, which is what makes a very long key fail here and pass
  ///   against a bare store.
  /// </summary>
  TKVPrefixKeysWrapper = class(TKVWrapper, IKeyValueEnumerable)
  private
    FPrefix: string;
    FSeparator: string;
    function Prefixed(const AKey: string): string;
    function Prefix: string;
  public
    /// <summary>
    ///   Wraps a store in a key namespace.
    /// </summary>
    /// <param name="AInner">The store to forward to</param>
    /// <param name="APrefix">The namespace; an empty one is refused</param>
    /// <param name="ASeparator">What goes between prefix and key</param>
    constructor Create(const AInner: IKeyValue; const APrefix: string; const ASeparator: string = ':'); reintroduce;

    function Get(const AKey: string; const ACollection: string = ''): string; override;
    function TryGet(const AKey: string; out AValue: string): Boolean; overload; override;
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload; override;
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean; override;
    function Exists(const AKey: string; const ACollection: string = ''): Boolean; override;
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; override;

    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>; override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; override;

    /// <summary>
    ///   The namespace's own keys, with the prefix taken back off. Keys
    ///   belonging to other namespaces in the same store are not reported.
    /// </summary>
    /// <param name="ACollection">Collection to list; '' is the default one</param>
    function Keys(const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   The collections of the store underneath, unchanged: this wrapper
    ///   namespaces keys, not collections.
    /// </summary>
    function Collections: TArray<string>;
  end;

  /// <summary>
  ///   Puts every collection in a namespace: what a caller calls 'users' is
  ///   stored as 'app1_users'. The same idea as TKVPrefixKeysWrapper, one
  ///   level up, and the cheaper one when a whole store is to be partitioned,
  ///   since it leaves keys untouched.
  /// </summary>
  TKVPrefixCollectionsWrapper = class(TKVWrapper, IKeyValueEnumerable)
  private
    FPrefix: string;
    FSeparator: string;
    FDefaultCollection: string;
    function Prefixed(const ACollection: string): string;
    function Prefix: string;
    procedure SetDefaultCollection(const AValue: string);
  public
    /// <summary>
    ///   Wraps a store in a collection namespace.
    /// </summary>
    /// <param name="AInner">The store to forward to</param>
    /// <param name="APrefix">The namespace; an empty one is refused</param>
    /// <param name="ASeparator">What goes between prefix and collection name</param>
    constructor Create(const AInner: IKeyValue; const APrefix: string; const ASeparator: string = '_'); reintroduce;

    function Get(const AKey: string; const ACollection: string = ''): string; override;
    function TryGet(const AKey: string; out AValue: string): Boolean; overload; override;
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload; override;
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean; override;
    function Exists(const AKey: string; const ACollection: string = ''): Boolean; override;
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; override;

    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>; override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; override;

    /// <summary>
    ///   The keys of one of this namespace's collections.
    /// </summary>
    /// <param name="ACollection">Collection to list; '' is the default one</param>
    function Keys(const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   The namespace's own collections, with the prefix taken back off.
    /// </summary>
    function Collections: TArray<string>;

    /// <summary>
    ///   The collection a call naming none lands in, before the prefix.
    ///   Defaults to KV_DEFAULT_COLLECTION; set it to match a store whose own
    ///   DefaultCollection is something else, so '' means the same place
    ///   through the wrapper as through the store.
    /// </summary>
    property DefaultCollection: string read FDefaultCollection write SetDefaultCollection;
  end;

{$SCOPEDENUMS ON}
  /// <summary>
  ///   What a read-only store does when written to.
  /// </summary>
  TKVReadOnlyMode = (

    /// <summary>
    ///   Raise EKVReadOnlyError. The default: a write that silently did
    ///   nothing would be a bug that only shows up much later.
    /// </summary>
    Refuse,

    /// <summary>
    ///   Accept the call and do nothing. For a store deliberately put in
    ///   read-only mode under code that cannot be changed.
    /// </summary>
    Ignore
  );
{$SCOPEDENUMS OFF}

  /// <summary>
  ///   Lets reads through and stops writes. For handing a store to code that
  ///   has no business changing it, or for freezing one during a migration.
  ///
  ///   It also refuses to cull or destroy, which is why it implements those
  ///   two capabilities itself rather than leaving them to the store
  ///   underneath. Enumeration is not a write, so IKeyValueEnumerable passes
  ///   through unchanged.
  /// </summary>
  TKVReadOnlyWrapper = class(TKVWrapper, IKeyValueEnumerable, IKeyValueCullable, IKeyValueDestroyable)
  private
    FMode: TKVReadOnlyMode;
    procedure Refused(const AOperation: string);
  public
    /// <summary>
    ///   Wraps a store so that it cannot be written to.
    /// </summary>
    /// <param name="AInner">The store to forward reads to</param>
    /// <param name="AMode">Whether a write raises or is quietly dropped</param>
    constructor Create(const AInner: IKeyValue; const AMode: TKVReadOnlyMode = TKVReadOnlyMode.Refuse); reintroduce;

    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; override;

    /// <summary>
    ///   Refused, or 0 in Ignore mode: culling deletes.
    /// </summary>
    function Cull: Integer;

    /// <summary>
    ///   Refused, or False in Ignore mode.
    /// </summary>
    /// <param name="AName">Unused: the call never gets that far</param>
    function DestroyCollection(const AName: string): Boolean;

    /// <summary>
    ///   Refused, or nothing in Ignore mode.
    /// </summary>
    procedure DestroyAll;

    /// <summary>
    ///   Reading is what this wrapper allows, so enumeration passes through.
    /// </summary>
    /// <param name="ACollection">Collection to list; '' is the default one</param>
    function Keys(const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   The collections of the store underneath.
    /// </summary>
    function Collections: TArray<string>;

    /// <summary>
    ///   Whether a write raises or is quietly dropped.
    /// </summary>
    property Mode: TKVReadOnlyMode read FMode write FMode;
  end;

  /// <summary>
  ///   Applies a house policy to every TTL that passes through: a default for
  ///   callers that ask for none, and a floor and ceiling for those that do.
  ///   The way to stop one caller from pinning an entry in a shared cache for
  ///   a year, or from filling it with entries that expire before they are
  ///   ever read.
  ///
  ///   Each limit is off at 0, and a negative TTL is passed straight through
  ///   so the store underneath still refuses it.
  /// </summary>
  TKVTTLClampWrapper = class(TKVWrapper)
  private
    FMinTTL: TKVDuration;
    FMaxTTL: TKVDuration;
    FDefaultTTL: TKVDuration;
    procedure SetMinTTL(const AValue: TKVDuration);
    procedure SetMaxTTL(const AValue: TKVDuration);
    procedure SetDefaultTTL(const AValue: TKVDuration);
  protected
    /// <summary>
    ///   The TTL that will actually be used for a requested one.
    /// </summary>
    /// <param name="ATTL">What the caller asked for</param>
    function ClampTTL(const ATTL: TKVDuration): TKVDuration; virtual;
  public
    /// <summary>
    ///   Wraps a store in a TTL policy.
    /// </summary>
    /// <param name="AInner">The store to forward to</param>
    /// <param name="AMinTTL">Shortest lifetime allowed; 0 for no floor</param>
    /// <param name="AMaxTTL">Longest lifetime allowed; 0 for no ceiling</param>
    /// <param name="ADefaultTTL">
    ///   Lifetime given to a write that asks for none; 0 leaves those entries
    ///   without an expiry
    /// </param>
    constructor Create(const AInner: IKeyValue; const AMinTTL: TKVDuration = 0; const AMaxTTL: TKVDuration = 0; const ADefaultTTL: TKVDuration = 0); reintroduce;

    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;

    /// <summary>
    ///   Shortest lifetime allowed; 0 for no floor.
    /// </summary>
    property MinTTL: TKVDuration read FMinTTL write SetMinTTL;

    /// <summary>
    ///   Longest lifetime allowed; 0 for no ceiling.
    /// </summary>
    property MaxTTL: TKVDuration read FMaxTTL write SetMaxTTL;

    /// <summary>
    ///   Lifetime given to a write that asks for none; 0 for none.
    /// </summary>
    property DefaultTTL: TKVDuration read FDefaultTTL write SetDefaultTTL;
  end;

  /// <summary>
  ///   Where a logging wrapper sends its lines.
  /// </summary>
  TKVLogProc = reference to procedure(const AMessage: string);

  /// <summary>
  ///   Writes a line per operation to whatever you hand it - Logify, a file, a
  ///   memo, Writeln. WalKey stays dependency-free by not choosing for you.
  ///
  ///   Keys and collections are logged; values are not. A value can be large,
  ///   and it can be a customer's personal data - neither belongs in a log by
  ///   default.
  /// </summary>
  TKVLoggingWrapper = class(TKVWrapper)
  private
    FLog: TKVLogProc;
    FTag: string;
    procedure Write(const AMessage: string); overload;
    procedure Write(const AFormat: string; const AArgs: array of const); overload;
    function Where(const AKey, ACollection: string): string;
  public
    /// <summary>
    ///   Wraps a store in logging.
    /// </summary>
    /// <param name="AInner">The store to forward to</param>
    /// <param name="ALog">
    ///   Where lines go. Nil is allowed and logs nothing, which is how logging
    ///   is switched off without unpicking the stack.
    /// </param>
    /// <param name="ATag">
    ///   Put in front of every line, to tell two wrapped stores apart
    /// </param>
    constructor Create(const AInner: IKeyValue; const ALog: TKVLogProc; const ATag: string = 'walkey'); reintroduce;

    function Get(const AKey: string; const ACollection: string = ''): string; override;
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload; override;
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean; override;
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; override;

    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>; override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; override;
  end;

  /// <summary>
  ///   What a statistics wrapper has counted.
  /// </summary>
  TKVStatistics = record

    /// <summary>
    ///   Keys read, bulk reads counted one per key.
    /// </summary>
    Gets: Int64;

    /// <summary>
    ///   Reads that found a live entry.
    /// </summary>
    Hits: Int64;

    /// <summary>
    ///   Reads that found nothing, or something expired.
    /// </summary>
    Misses: Int64;

    /// <summary>
    ///   Keys written, bulk writes counted one per key.
    /// </summary>
    Puts: Int64;

    /// <summary>
    ///   Keys asked to be deleted, bulk deletes counted one per key.
    /// </summary>
    Deletes: Int64;

    /// <summary>
    ///   Deletes that actually removed a live entry.
    /// </summary>
    Removals: Int64;

    /// <summary>
    ///   Hits over reads, 0 when nothing has been read yet.
    /// </summary>
    function HitRate: Double;

    /// <summary>
    ///   A one-line rendering, for a log or a status page.
    /// </summary>
    function ToString: string;
  end;

  /// <summary>
  ///   Counts what goes through it, and changes nothing. Put one over a cache
  ///   to find out whether the cache is earning its keep.
  ///
  ///   Counters are updated atomically, so a wrapped store stays as
  ///   thread-safe as it was.
  /// </summary>
  TKVStatisticsWrapper = class(TKVWrapper)
  private
    FGets: Int64;
    FHits: Int64;
    FMisses: Int64;
    FPuts: Int64;
    FDeletes: Int64;
    FRemovals: Int64;
    procedure CountRead(const AHit: Boolean);
    function GetStatistics: TKVStatistics;
  public
    function Get(const AKey: string; const ACollection: string = ''): string; override;
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload; override;
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean; override;
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; override;

    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>; override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; override;

    /// <summary>
    ///   Puts every counter back to zero.
    /// </summary>
    procedure Reset;

    /// <summary>
    ///   What has been counted so far.
    /// </summary>
    property Statistics: TKVStatistics read GetStatistics;
  end;

  /// <summary>
  ///   Told that an operation fell through to the standby store.
  /// </summary>
  TKVFallbackProc = reference to procedure(const AOperation, AError: string);

  /// <summary>
  ///   Sends everything to one store and, when that store fails, to another.
  ///   A Redis cache with an in-memory standby behind it keeps working through
  ///   a Redis outage, at reduced quality rather than not at all.
  ///
  ///   Only a failure of the store falls through, and a failure is an
  ///   EKVStoreError and nothing else. A miss does not: "there is nothing
  ///   under that key" is an answer, not a failure, and treating it as one
  ///   would turn the standby into a second place to look on every read.
  ///   Neither does a bad argument - a key the primary refuses the standby
  ///   would refuse too - nor a read-only refusal, nor a stored value that
  ///   cannot be decoded, nor a bug in the caller. Those are raised rather
  ///   than answered from the standby, which would hide all four.
  /// </summary>
  TKVFallbackWrapper = class(TKVWrapper)
  private
    FFallback: IKeyValue;
    FOnFallback: TKVFallbackProc;
    procedure FellBack(const AOperation: string; const AError: Exception);
  public
    /// <summary>
    ///   Pairs a store with a standby.
    /// </summary>
    /// <param name="APrimary">Where everything goes first; nil is refused</param>
    /// <param name="AFallback">Where it goes instead on failure; nil is refused</param>
    constructor Create(const APrimary, AFallback: IKeyValue); reintroduce;

    function Get(const AKey: string; const ACollection: string = ''): string; override;
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload; override;
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean; override;
    function Exists(const AKey: string; const ACollection: string = ''): Boolean; override;
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; override;

    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>; override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; override;

    /// <summary>
    ///   The standby store.
    /// </summary>
    property Fallback: IKeyValue read FFallback;

    /// <summary>
    ///   Called whenever the primary failed and the standby answered instead.
    ///   The place to raise an alarm: a fallback that nobody notices is an
    ///   outage nobody notices.
    /// </summary>
    property OnFallback: TKVFallbackProc read FOnFallback write FOnFallback;
  end;

  /// <summary>
  ///   Makes the store underneath safe to share between threads: one call at a
  ///   time, reads included.
  ///
  ///   It is for a store that does not lock itself - a SQLite connection, a
  ///   socket, anything a backend leaves to its caller. The memory and null
  ///   stores are already thread-safe, so wrapping them costs a lock and buys
  ///   nothing; the file store is safe between processes through the
  ///   filesystem, and this adds in-process serialization on top.
  ///
  ///   What it promises is one call at a time, not one transaction: a sequence
  ///   of calls (Exists then Put, say) can still interleave with another
  ///   thread. It guards this instance, so two wrappers, or two processes, are
  ///   not coordinated with each other.
  ///
  ///   Put it immediately above the store, below logging and fallback, so the
  ///   lock is not held while a log sink or an alarm callback runs. Every
  ///   method calls Inner directly rather than a sibling, so a call never
  ///   nests its own lock.
  ///
  ///   It always implements the three optional capabilities, so a call through
  ///   one is guarded like any other rather than reaching the store around the
  ///   lock. If the store underneath does not have that capability, the call
  ///   raises EKVStoreError; Supports is therefore optimistic, exactly as it
  ///   is for the prefixing wrappers.
  /// </summary>
  TKVThreadSafeWrapper = class(TKVWrapper,
    IKeyValueEnumerable,
    IKeyValueCullable,
    IKeyValueDestroyable)
  private
    FLock: TCriticalSection;
  public
    /// <summary>
    ///   Wraps a store in a lock.
    /// </summary>
    /// <param name="AInner">The store every call is serialized against</param>
    constructor Create(const AInner: IKeyValue); reintroduce;
    destructor Destroy; override;

    function Get(const AKey: string; const ACollection: string = ''): string; override;
    function TryGet(const AKey: string; out AValue: string): Boolean; overload; override;
    function TryGet(const AKey, ACollection: string; out AValue: string): Boolean; overload; override;
    function TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean; override;
    function Exists(const AKey: string; const ACollection: string = ''): Boolean; override;
    procedure Put(const AKey, AValue: string; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function Delete(const AKey: string; const ACollection: string = ''): Boolean; override;

    function GetMany(const AKeys: TArray<string>; const ACollection: string = ''): TArray<string>; override;
    procedure PutMany(const AKeys, AValues: TArray<string>; const ACollection: string = ''; const ATTL: TKVDuration = KV_NO_TTL); override;
    function DeleteMany(const AKeys: TArray<string>; const ACollection: string = ''): Integer; override;

    function Keys(const ACollection: string = ''): TArray<string>;
    function Collections: TArray<string>;
    function Cull: Integer;
    function DestroyCollection(const AName: string): Boolean;
    procedure DestroyAll;
  end;

implementation

resourcestring
  SKVNoInnerStore = 'A wrapper needs a store to wrap';
  SKVNoFallbackStore = 'A fallback wrapper needs a store to fall back to';
  SKVEmptyPrefix = 'A prefix cannot be empty';
  SKVEmptySeparator = 'A prefix separator cannot be empty';
  SKVAmbiguousPrefix = 'A prefix cannot end with its own separator';
  SKVReadOnly = 'This store is read-only: %s is not allowed';

{ TKVWrapper }

constructor TKVWrapper.Create(const AInner: IKeyValue);
begin
  inherited Create;
  if not Assigned(AInner) then
    raise EKVArgumentError.Create(SKVNoInnerStore);
  FInner := AInner;
end;

function TKVWrapper.Get(const AKey, ACollection: string): string;
begin
  Result := FInner.Get(AKey, ACollection);
end;

function TKVWrapper.TryGet(const AKey: string; out AValue: string): Boolean;
begin
  Result := TryGet(AKey, '', AValue);
end;

function TKVWrapper.TryGet(const AKey, ACollection: string; out AValue: string): Boolean;
begin
  Result := FInner.TryGet(AKey, ACollection, AValue);
end;

function TKVWrapper.TryGetEntry(const AKey, ACollection: string; out AEntry: TKVEntry): Boolean;
begin
  Result := FInner.TryGetEntry(AKey, ACollection, AEntry);
end;

function TKVWrapper.Exists(const AKey, ACollection: string): Boolean;
begin
  Result := FInner.Exists(AKey, ACollection);
end;

procedure TKVWrapper.Put(const AKey, AValue, ACollection: string; const ATTL: TKVDuration);
begin
  FInner.Put(AKey, AValue, ACollection, ATTL);
end;

function TKVWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  Result := FInner.Delete(AKey, ACollection);
end;

function TKVWrapper.GetMany(const AKeys: TArray<string>; const ACollection: string): TArray<string>;
begin
  Result := FInner.GetMany(AKeys, ACollection);
end;

procedure TKVWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  // A wrapper that forwards the arrays untouched still checks its own
  // contract: the store underneath may be one that ignores writes.
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  FInner.PutMany(AKeys, AValues, ACollection, ATTL);
end;

function TKVWrapper.DeleteMany(const AKeys: TArray<string>; const ACollection: string): Integer;
begin
  Result := FInner.DeleteMany(AKeys, ACollection);
end;

function TKVWrapper.Collection(const AName: string): IKeyValue;
begin
  // Bound to this wrapper, not to the store underneath: a view must still go
  // through whatever the wrapper does.
  Result := TKVCollectionView.Create(Self, AName);
end;

{ TKVPrefixKeysWrapper }

constructor TKVPrefixKeysWrapper.Create(const AInner: IKeyValue;
  const APrefix, ASeparator: string);
begin
  inherited Create(AInner);
  if APrefix = '' then
    raise EKVArgumentError.Create(SKVEmptyPrefix);
  // An empty separator, or a prefix that already ends with it, would let two
  // different prefixes name the same key space and see each other's entries.
  if ASeparator = '' then
    raise EKVArgumentError.Create(SKVEmptySeparator);
  if APrefix.EndsWith(ASeparator) then
    raise EKVArgumentError.Create(SKVAmbiguousPrefix);
  FPrefix := APrefix;
  FSeparator := ASeparator;
end;

function TKVPrefixKeysWrapper.Prefix: string;
begin
  Result := FPrefix + FSeparator;
end;

function TKVPrefixKeysWrapper.Prefixed(const AKey: string): string;
begin
  // The caller's key is judged on its own merits first: prefixing an empty or
  // malformed key would otherwise turn it into a valid one.
  TKVUtils.CheckKey(AKey);
  Result := Prefix + AKey;
end;

function TKVPrefixKeysWrapper.Get(const AKey, ACollection: string): string;
begin
  Result := Inner.Get(Prefixed(AKey), ACollection);
end;

function TKVPrefixKeysWrapper.TryGet(const AKey: string; out AValue: string): Boolean;
begin
  Result := TryGet(AKey, '', AValue);
end;

function TKVPrefixKeysWrapper.TryGet(const AKey, ACollection: string; out AValue: string): Boolean;
begin
  Result := Inner.TryGet(Prefixed(AKey), ACollection, AValue);
end;

function TKVPrefixKeysWrapper.TryGetEntry(const AKey, ACollection: string;
  out AEntry: TKVEntry): Boolean;
begin
  Result := Inner.TryGetEntry(Prefixed(AKey), ACollection, AEntry);
end;

function TKVPrefixKeysWrapper.Exists(const AKey, ACollection: string): Boolean;
begin
  Result := Inner.Exists(Prefixed(AKey), ACollection);
end;

procedure TKVPrefixKeysWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  Inner.Put(Prefixed(AKey), AValue, ACollection, ATTL);
end;

function TKVPrefixKeysWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  Result := Inner.Delete(Prefixed(AKey), ACollection);
end;

function TKVPrefixKeysWrapper.GetMany(const AKeys: TArray<string>;
  const ACollection: string): TArray<string>;
var
  LKeys: TArray<string>;
  LIndex: Integer;
begin
  SetLength(LKeys, Length(AKeys));
  for LIndex := 0 to High(AKeys) do
    LKeys[LIndex] := Prefixed(AKeys[LIndex]);

  Result := Inner.GetMany(LKeys, ACollection);
end;

procedure TKVPrefixKeysWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
var
  LKeys: TArray<string>;
  LIndex: Integer;
begin
  // Prefixing a mismatched pair would report keys the caller never passed, so
  // the lengths are checked here rather than left to the store underneath.
  TKVUtils.CheckBulkLengths(AKeys, AValues);

  SetLength(LKeys, Length(AKeys));
  for LIndex := 0 to High(AKeys) do
    LKeys[LIndex] := Prefixed(AKeys[LIndex]);

  Inner.PutMany(LKeys, AValues, ACollection, ATTL);
end;

function TKVPrefixKeysWrapper.DeleteMany(const AKeys: TArray<string>;
  const ACollection: string): Integer;
var
  LKeys: TArray<string>;
  LIndex: Integer;
begin
  SetLength(LKeys, Length(AKeys));
  for LIndex := 0 to High(AKeys) do
    LKeys[LIndex] := Prefixed(AKeys[LIndex]);

  Result := Inner.DeleteMany(LKeys, ACollection);
end;

function TKVPrefixKeysWrapper.Keys(const ACollection: string): TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
  LKey, LPrefix: string;
  LCount: Integer;
  LKeys: TArray<string>;
begin
  Result := nil;
  if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
    raise EKVStoreError.Create('The store underneath cannot enumerate its keys');

  LPrefix := Prefix;
  LKeys := LEnumerable.Keys(ACollection);
  SetLength(Result, Length(LKeys));
  LCount := 0;
  for LKey in LKeys do
    if LKey.StartsWith(LPrefix) then
    begin
      Result[LCount] := LKey.Substring(Length(LPrefix));
      Inc(LCount);
    end;
  SetLength(Result, LCount);
end;

function TKVPrefixKeysWrapper.Collections: TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
begin
  if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
    raise EKVStoreError.Create('The store underneath cannot enumerate its collections');

  Result := LEnumerable.Collections;
end;

{ TKVPrefixCollectionsWrapper }

constructor TKVPrefixCollectionsWrapper.Create(const AInner: IKeyValue;
  const APrefix, ASeparator: string);
begin
  inherited Create(AInner);
  if APrefix = '' then
    raise EKVArgumentError.Create(SKVEmptyPrefix);
  // An empty separator, or a prefix that already ends with it, would let two
  // different prefixes name the same collection and see each other's entries.
  if ASeparator = '' then
    raise EKVArgumentError.Create(SKVEmptySeparator);
  if APrefix.EndsWith(ASeparator) then
    raise EKVArgumentError.Create(SKVAmbiguousPrefix);
  FPrefix := APrefix;
  FSeparator := ASeparator;
  FDefaultCollection := KV_DEFAULT_COLLECTION;
end;

procedure TKVPrefixCollectionsWrapper.SetDefaultCollection(const AValue: string);
begin
  TKVUtils.CheckCollection(AValue);
  FDefaultCollection := AValue;
end;

function TKVPrefixCollectionsWrapper.Prefix: string;
begin
  Result := FPrefix + FSeparator;
end;

function TKVPrefixCollectionsWrapper.Prefixed(const ACollection: string): string;
var
  LCollection: string;
begin
  // '' has to become the default collection here rather than inside the store,
  // or a caller naming the default collection outright would land somewhere
  // else than a caller naming none.
  if ACollection = '' then
    LCollection := FDefaultCollection
  else
    LCollection := ACollection;

  TKVUtils.CheckCollection(LCollection);
  Result := Prefix + LCollection;
end;

function TKVPrefixCollectionsWrapper.Get(const AKey, ACollection: string): string;
begin
  Result := Inner.Get(AKey, Prefixed(ACollection));
end;

function TKVPrefixCollectionsWrapper.TryGet(const AKey: string; out AValue: string): Boolean;
begin
  Result := TryGet(AKey, '', AValue);
end;

function TKVPrefixCollectionsWrapper.TryGet(const AKey, ACollection: string;
  out AValue: string): Boolean;
begin
  Result := Inner.TryGet(AKey, Prefixed(ACollection), AValue);
end;

function TKVPrefixCollectionsWrapper.TryGetEntry(const AKey, ACollection: string;
  out AEntry: TKVEntry): Boolean;
begin
  Result := Inner.TryGetEntry(AKey, Prefixed(ACollection), AEntry);
end;

function TKVPrefixCollectionsWrapper.Exists(const AKey, ACollection: string): Boolean;
begin
  Result := Inner.Exists(AKey, Prefixed(ACollection));
end;

procedure TKVPrefixCollectionsWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  Inner.Put(AKey, AValue, Prefixed(ACollection), ATTL);
end;

function TKVPrefixCollectionsWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  Result := Inner.Delete(AKey, Prefixed(ACollection));
end;

function TKVPrefixCollectionsWrapper.GetMany(const AKeys: TArray<string>;
  const ACollection: string): TArray<string>;
begin
  Result := Inner.GetMany(AKeys, Prefixed(ACollection));
end;

procedure TKVPrefixCollectionsWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  Inner.PutMany(AKeys, AValues, Prefixed(ACollection), ATTL);
end;

function TKVPrefixCollectionsWrapper.DeleteMany(const AKeys: TArray<string>;
  const ACollection: string): Integer;
begin
  Result := Inner.DeleteMany(AKeys, Prefixed(ACollection));
end;

function TKVPrefixCollectionsWrapper.Keys(const ACollection: string): TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
begin
  if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
    raise EKVStoreError.Create('The store underneath cannot enumerate its keys');

  Result := LEnumerable.Keys(Prefixed(ACollection));
end;

function TKVPrefixCollectionsWrapper.Collections: TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
  LCollection, LPrefix: string;
  LCount: Integer;
  LCollections: TArray<string>;
begin
  Result := nil;
  if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
    raise EKVStoreError.Create('The store underneath cannot enumerate its collections');

  LPrefix := Prefix;
  LCollections := LEnumerable.Collections;
  SetLength(Result, Length(LCollections));
  LCount := 0;
  for LCollection in LCollections do
    if LCollection.StartsWith(LPrefix) then
    begin
      Result[LCount] := LCollection.Substring(Length(LPrefix));
      Inc(LCount);
    end;
  SetLength(Result, LCount);
end;

{ TKVReadOnlyWrapper }

constructor TKVReadOnlyWrapper.Create(const AInner: IKeyValue; const AMode: TKVReadOnlyMode);
begin
  inherited Create(AInner);
  FMode := AMode;
end;

procedure TKVReadOnlyWrapper.Refused(const AOperation: string);
begin
  if FMode = TKVReadOnlyMode.Refuse then
    raise EKVReadOnlyError.CreateFmt(SKVReadOnly, [AOperation]);
end;

procedure TKVReadOnlyWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  Refused('Put');
end;

function TKVReadOnlyWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  Refused('Delete');
  Result := False;
end;

procedure TKVReadOnlyWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  // Refused or dropped, the arguments are still checked, as the null store
  // checks them: a lax mode must not turn a malformed call into a silent
  // success.
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  Refused('PutMany');
end;

function TKVReadOnlyWrapper.DeleteMany(const AKeys: TArray<string>;
  const ACollection: string): Integer;
begin
  Refused('DeleteMany');
  Result := 0;
end;

function TKVReadOnlyWrapper.Cull: Integer;
begin
  Refused('Cull');
  Result := 0;
end;

function TKVReadOnlyWrapper.DestroyCollection(const AName: string): Boolean;
begin
  Refused('DestroyCollection');
  Result := False;
end;

procedure TKVReadOnlyWrapper.DestroyAll;
begin
  Refused('DestroyAll');
end;

function TKVReadOnlyWrapper.Keys(const ACollection: string): TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
begin
  if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
    raise EKVStoreError.Create('The store underneath cannot enumerate its keys');

  Result := LEnumerable.Keys(ACollection);
end;

function TKVReadOnlyWrapper.Collections: TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
begin
  if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
    raise EKVStoreError.Create('The store underneath cannot enumerate its collections');

  Result := LEnumerable.Collections;
end;

{ TKVTTLClampWrapper }

constructor TKVTTLClampWrapper.Create(const AInner: IKeyValue;
  const AMinTTL, AMaxTTL, ADefaultTTL: TKVDuration);
begin
  inherited Create(AInner);
  SetMinTTL(AMinTTL);
  SetMaxTTL(AMaxTTL);
  SetDefaultTTL(ADefaultTTL);
end;

procedure TKVTTLClampWrapper.SetMinTTL(const AValue: TKVDuration);
begin
  TKVUtils.CheckTTL(AValue);
  FMinTTL := AValue;
end;

procedure TKVTTLClampWrapper.SetMaxTTL(const AValue: TKVDuration);
begin
  TKVUtils.CheckTTL(AValue);
  FMaxTTL := AValue;
end;

procedure TKVTTLClampWrapper.SetDefaultTTL(const AValue: TKVDuration);
begin
  TKVUtils.CheckTTL(AValue);
  FDefaultTTL := AValue;
end;

function TKVTTLClampWrapper.ClampTTL(const ATTL: TKVDuration): TKVDuration;
begin
  // A negative TTL is an error, not a lifetime: hand it on untouched so the
  // store underneath refuses it as it would for any other caller.
  if ATTL < 0 then
    Exit(ATTL);

  Result := ATTL;
  if (Result = 0) and (FDefaultTTL > 0) then
    Result := FDefaultTTL;

  if Result > 0 then
  begin
    if (FMinTTL > 0) and (Result < FMinTTL) then
      Result := FMinTTL;
    if (FMaxTTL > 0) and (Result > FMaxTTL) then
      Result := FMaxTTL;
  end;
end;

procedure TKVTTLClampWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  Inner.Put(AKey, AValue, ACollection, ClampTTL(ATTL));
end;

procedure TKVTTLClampWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  Inner.PutMany(AKeys, AValues, ACollection, ClampTTL(ATTL));
end;

{ TKVLoggingWrapper }

constructor TKVLoggingWrapper.Create(const AInner: IKeyValue; const ALog: TKVLogProc;
  const ATag: string);
begin
  inherited Create(AInner);
  FLog := ALog;
  FTag := ATag;
end;

procedure TKVLoggingWrapper.Write(const AMessage: string);
begin
  if Assigned(FLog) then
    FLog(Format('[%s] %s', [FTag, AMessage]));
end;

procedure TKVLoggingWrapper.Write(const AFormat: string; const AArgs: array of const);
begin
  if Assigned(FLog) then
    Write(Format(AFormat, AArgs));
end;

function TKVLoggingWrapper.Where(const AKey, ACollection: string): string;
begin
  if ACollection = '' then
    Result := KV_DEFAULT_COLLECTION + '/' + AKey
  else
    Result := ACollection + '/' + AKey;
end;

function TKVLoggingWrapper.Get(const AKey, ACollection: string): string;
begin
  // TryGet, not "is the answer empty": a value deliberately stored as '' is a
  // hit and must not be logged as a miss.
  if Inner.TryGet(AKey, ACollection, Result) then
    Write('GET %s -> hit (%d chars)', [Where(AKey, ACollection), Length(Result)])
  else
    Write('GET %s -> miss', [Where(AKey, ACollection)]);
end;

function TKVLoggingWrapper.TryGet(const AKey, ACollection: string; out AValue: string): Boolean;
begin
  Result := Inner.TryGet(AKey, ACollection, AValue);
  if Result then
    Write('GET %s -> hit (%d chars)', [Where(AKey, ACollection), Length(AValue)])
  else
    Write('GET %s -> miss', [Where(AKey, ACollection)]);
end;

function TKVLoggingWrapper.TryGetEntry(const AKey, ACollection: string;
  out AEntry: TKVEntry): Boolean;
begin
  Result := Inner.TryGetEntry(AKey, ACollection, AEntry);

  // The expiry is logged as the instant it is, not as a lifetime remaining: a
  // wrapper has no clock, and the store's may not be the wall clock.
  if Result and AEntry.HasExpiry then
    Write('GET %s -> hit (%d chars, expires %s)',
      [Where(AKey, ACollection), Length(AEntry.Value),
       FormatDateTime('yyyy-mm-dd hh:nn:ss"Z"', AEntry.ExpiresAt)])
  else if Result then
    Write('GET %s -> hit (%d chars)', [Where(AKey, ACollection), Length(AEntry.Value)])
  else
    Write('GET %s -> miss', [Where(AKey, ACollection)]);
end;

procedure TKVLoggingWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  Inner.Put(AKey, AValue, ACollection, ATTL);
  if ATTL > 0 then
    Write('PUT %s (%d chars, ttl %.0f s)', [Where(AKey, ACollection), Length(AValue), ATTL])
  else
    Write('PUT %s (%d chars)', [Where(AKey, ACollection), Length(AValue)]);
end;

function TKVLoggingWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  Result := Inner.Delete(AKey, ACollection);
  if Result then
    Write('DELETE %s -> removed', [Where(AKey, ACollection)])
  else
    Write('DELETE %s -> nothing there', [Where(AKey, ACollection)]);
end;

function TKVLoggingWrapper.GetMany(const AKeys: TArray<string>;
  const ACollection: string): TArray<string>;
begin
  Result := Inner.GetMany(AKeys, ACollection);
  Write('GETMANY %d keys', [Length(AKeys)]);
end;

procedure TKVLoggingWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  Inner.PutMany(AKeys, AValues, ACollection, ATTL);
  Write('PUTMANY %d keys', [Length(AKeys)]);
end;

function TKVLoggingWrapper.DeleteMany(const AKeys: TArray<string>;
  const ACollection: string): Integer;
begin
  Result := Inner.DeleteMany(AKeys, ACollection);
  Write('DELETEMANY %d keys -> %d removed', [Length(AKeys), Result]);
end;

{ TKVStatistics }

function TKVStatistics.HitRate: Double;
begin
  if Gets = 0 then
    Result := 0
  else
    Result := Hits / Gets;
end;

function TKVStatistics.ToString: string;
begin
  Result := Format('gets %d (hits %d, misses %d, %.1f%%), puts %d, deletes %d (removed %d)',
    [Gets, Hits, Misses, HitRate * 100, Puts, Deletes, Removals]);
end;

{ TKVStatisticsWrapper }

procedure TKVStatisticsWrapper.CountRead(const AHit: Boolean);
begin
  TInterlocked.Increment(FGets);
  if AHit then
    TInterlocked.Increment(FHits)
  else
    TInterlocked.Increment(FMisses);
end;

function TKVStatisticsWrapper.GetStatistics: TKVStatistics;
begin
  Result.Gets := TInterlocked.Read(FGets);
  Result.Hits := TInterlocked.Read(FHits);
  Result.Misses := TInterlocked.Read(FMisses);
  Result.Puts := TInterlocked.Read(FPuts);
  Result.Deletes := TInterlocked.Read(FDeletes);
  Result.Removals := TInterlocked.Read(FRemovals);
end;

procedure TKVStatisticsWrapper.Reset;
begin
  TInterlocked.Exchange(FGets, 0);
  TInterlocked.Exchange(FHits, 0);
  TInterlocked.Exchange(FMisses, 0);
  TInterlocked.Exchange(FPuts, 0);
  TInterlocked.Exchange(FDeletes, 0);
  TInterlocked.Exchange(FRemovals, 0);
end;

function TKVStatisticsWrapper.Get(const AKey, ACollection: string): string;
begin
  // TryGet, not "is the answer empty": a value deliberately stored as '' is a
  // hit and must not be counted as a miss.
  CountRead(Inner.TryGet(AKey, ACollection, Result));
end;

function TKVStatisticsWrapper.TryGet(const AKey, ACollection: string; out AValue: string): Boolean;
begin
  Result := Inner.TryGet(AKey, ACollection, AValue);
  CountRead(Result);
end;

function TKVStatisticsWrapper.TryGetEntry(const AKey, ACollection: string;
  out AEntry: TKVEntry): Boolean;
begin
  Result := Inner.TryGetEntry(AKey, ACollection, AEntry);
  CountRead(Result);
end;

procedure TKVStatisticsWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  Inner.Put(AKey, AValue, ACollection, ATTL);
  TInterlocked.Increment(FPuts);
end;

function TKVStatisticsWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  Result := Inner.Delete(AKey, ACollection);
  TInterlocked.Increment(FDeletes);
  if Result then
    TInterlocked.Increment(FRemovals);
end;

function TKVStatisticsWrapper.GetMany(const AKeys: TArray<string>;
  const ACollection: string): TArray<string>;
var
  LIndex: Integer;
begin
  Result := Inner.GetMany(AKeys, ACollection);
  // Counted from the answers, with one Exists for an empty one: it is the only
  // answer that cannot say for itself whether it was a stored '' or a miss.
  for LIndex := 0 to High(Result) do
    if Result[LIndex] <> '' then
      CountRead(True)
    else
      CountRead(Inner.Exists(AKeys[LIndex], ACollection));
end;

procedure TKVStatisticsWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  Inner.PutMany(AKeys, AValues, ACollection, ATTL);
  TInterlocked.Add(FPuts, Length(AKeys));
end;

function TKVStatisticsWrapper.DeleteMany(const AKeys: TArray<string>;
  const ACollection: string): Integer;
begin
  Result := Inner.DeleteMany(AKeys, ACollection);
  TInterlocked.Add(FDeletes, Length(AKeys));
  TInterlocked.Add(FRemovals, Result);
end;

{ TKVFallbackWrapper }

constructor TKVFallbackWrapper.Create(const APrimary, AFallback: IKeyValue);
begin
  inherited Create(APrimary);
  if not Assigned(AFallback) then
    raise EKVArgumentError.Create(SKVNoFallbackStore);
  FFallback := AFallback;
end;

procedure TKVFallbackWrapper.FellBack(const AOperation: string; const AError: Exception);
begin
  if Assigned(FOnFallback) then
    FOnFallback(AOperation, AError.Message);
end;

function TKVFallbackWrapper.Get(const AKey, ACollection: string): string;
begin
  try
    Result := Inner.Get(AKey, ACollection);
  except
    on E: EKVStoreError do
    begin
      FellBack('Get', E);
      Result := FFallback.Get(AKey, ACollection);
    end;
  end;
end;

function TKVFallbackWrapper.TryGet(const AKey, ACollection: string; out AValue: string): Boolean;
begin
  try
    Result := Inner.TryGet(AKey, ACollection, AValue);
  except
    on E: EKVStoreError do
    begin
      FellBack('TryGet', E);
      Result := FFallback.TryGet(AKey, ACollection, AValue);
    end;
  end;
end;

function TKVFallbackWrapper.TryGetEntry(const AKey, ACollection: string;
  out AEntry: TKVEntry): Boolean;
begin
  try
    Result := Inner.TryGetEntry(AKey, ACollection, AEntry);
  except
    on E: EKVStoreError do
    begin
      FellBack('TryGetEntry', E);
      Result := FFallback.TryGetEntry(AKey, ACollection, AEntry);
    end;
  end;
end;

function TKVFallbackWrapper.Exists(const AKey, ACollection: string): Boolean;
begin
  try
    Result := Inner.Exists(AKey, ACollection);
  except
    on E: EKVStoreError do
    begin
      FellBack('Exists', E);
      Result := FFallback.Exists(AKey, ACollection);
    end;
  end;
end;

procedure TKVFallbackWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  try
    Inner.Put(AKey, AValue, ACollection, ATTL);
  except
    on E: EKVStoreError do
    begin
      FellBack('Put', E);
      FFallback.Put(AKey, AValue, ACollection, ATTL);
    end;
  end;
end;

function TKVFallbackWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  try
    Result := Inner.Delete(AKey, ACollection);
  except
    on E: EKVStoreError do
    begin
      FellBack('Delete', E);
      Result := FFallback.Delete(AKey, ACollection);
    end;
  end;
end;

function TKVFallbackWrapper.GetMany(const AKeys: TArray<string>;
  const ACollection: string): TArray<string>;
begin
  try
    Result := Inner.GetMany(AKeys, ACollection);
  except
    on E: EKVStoreError do
    begin
      FellBack('GetMany', E);
      Result := FFallback.GetMany(AKeys, ACollection);
    end;
  end;
end;

procedure TKVFallbackWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  TKVUtils.CheckBulkLengths(AKeys, AValues);
  try
    Inner.PutMany(AKeys, AValues, ACollection, ATTL);
  except
    on E: EKVStoreError do
    begin
      FellBack('PutMany', E);
      FFallback.PutMany(AKeys, AValues, ACollection, ATTL);
    end;
  end;
end;

function TKVFallbackWrapper.DeleteMany(const AKeys: TArray<string>;
  const ACollection: string): Integer;
begin
  try
    Result := Inner.DeleteMany(AKeys, ACollection);
  except
    on E: EKVStoreError do
    begin
      FellBack('DeleteMany', E);
      Result := FFallback.DeleteMany(AKeys, ACollection);
    end;
  end;
end;

{ TKVThreadSafeWrapper }

constructor TKVThreadSafeWrapper.Create(const AInner: IKeyValue);
begin
  inherited Create(AInner);
  FLock := TCriticalSection.Create;
end;

destructor TKVThreadSafeWrapper.Destroy;
begin
  FLock.Free;
  inherited;
end;

function TKVThreadSafeWrapper.Get(const AKey, ACollection: string): string;
begin
  FLock.Enter;
  try
    Result := Inner.Get(AKey, ACollection);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.TryGet(const AKey: string; out AValue: string): Boolean;
begin
  FLock.Enter;
  try
    Result := Inner.TryGet(AKey, AValue);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.TryGet(const AKey, ACollection: string;
  out AValue: string): Boolean;
begin
  FLock.Enter;
  try
    Result := Inner.TryGet(AKey, ACollection, AValue);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.TryGetEntry(const AKey, ACollection: string;
  out AEntry: TKVEntry): Boolean;
begin
  FLock.Enter;
  try
    Result := Inner.TryGetEntry(AKey, ACollection, AEntry);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.Exists(const AKey, ACollection: string): Boolean;
begin
  FLock.Enter;
  try
    Result := Inner.Exists(AKey, ACollection);
  finally
    FLock.Leave;
  end;
end;

procedure TKVThreadSafeWrapper.Put(const AKey, AValue, ACollection: string;
  const ATTL: TKVDuration);
begin
  FLock.Enter;
  try
    Inner.Put(AKey, AValue, ACollection, ATTL);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.Delete(const AKey, ACollection: string): Boolean;
begin
  FLock.Enter;
  try
    Result := Inner.Delete(AKey, ACollection);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.GetMany(const AKeys: TArray<string>;
  const ACollection: string): TArray<string>;
begin
  FLock.Enter;
  try
    Result := Inner.GetMany(AKeys, ACollection);
  finally
    FLock.Leave;
  end;
end;

procedure TKVThreadSafeWrapper.PutMany(const AKeys, AValues: TArray<string>;
  const ACollection: string; const ATTL: TKVDuration);
begin
  FLock.Enter;
  try
    Inner.PutMany(AKeys, AValues, ACollection, ATTL);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.DeleteMany(const AKeys: TArray<string>;
  const ACollection: string): Integer;
begin
  FLock.Enter;
  try
    Result := Inner.DeleteMany(AKeys, ACollection);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.Keys(const ACollection: string): TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
begin
  FLock.Enter;
  try
    if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
      raise EKVStoreError.Create('The store underneath cannot enumerate its keys');

    Result := LEnumerable.Keys(ACollection);
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.Collections: TArray<string>;
var
  LEnumerable: IKeyValueEnumerable;
begin
  FLock.Enter;
  try
    if not Supports(Inner, IKeyValueEnumerable, LEnumerable) then
      raise EKVStoreError.Create('The store underneath cannot enumerate its collections');

    Result := LEnumerable.Collections;
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.Cull: Integer;
var
  LCullable: IKeyValueCullable;
begin
  FLock.Enter;
  try
    if not Supports(Inner, IKeyValueCullable, LCullable) then
      raise EKVStoreError.Create('The store underneath cannot cull');

    Result := LCullable.Cull;
  finally
    FLock.Leave;
  end;
end;

function TKVThreadSafeWrapper.DestroyCollection(const AName: string): Boolean;
var
  LDestroyable: IKeyValueDestroyable;
begin
  FLock.Enter;
  try
    if not Supports(Inner, IKeyValueDestroyable, LDestroyable) then
      raise EKVStoreError.Create('The store underneath cannot destroy collections');

    Result := LDestroyable.DestroyCollection(AName);
  finally
    FLock.Leave;
  end;
end;

procedure TKVThreadSafeWrapper.DestroyAll;
var
  LDestroyable: IKeyValueDestroyable;
begin
  FLock.Enter;
  try
    if not Supports(Inner, IKeyValueDestroyable, LDestroyable) then
      raise EKVStoreError.Create('The store underneath cannot be destroyed');

    LDestroyable.DestroyAll;
  finally
    FLock.Leave;
  end;
end;

end.
