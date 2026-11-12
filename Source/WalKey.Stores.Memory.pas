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
///   The in-process store: a dictionary of collections, each a dictionary of
///   entries, behind one lock. It is the reference implementation the
///   conformance suite is written against, the store wrappers are tested over,
///   and the one to reach for in tests and development.
///
///   Entries are held as TKVEntry records, so nothing is serialized on the way
///   in or out - but a value is still a string, never a live object, which
///   keeps the memory store honest about the contract the persistent ones have
///   to meet.
/// </summary>
unit WalKey.Stores.Memory;

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  WalKey.Core;

type
  TKVMemoryWatch = class;

  /// <summary>
  ///   Keeps everything in memory, for as long as the instance lives. Keys and
  ///   collection names are case-sensitive, and instances are thread-safe.
  ///
  ///   A watch is told synchronously, on the writer's thread and under the
  ///   store's lock, so by the time a Put returns every watcher already
  ///   knows.
  /// </summary>
  TKVMemoryStore = class(TKVStoreBase,
    IKeyValueEnumerable,
    IKeyValueCullable,
    IKeyValueDestroyable,
    IKeyValueWatchable)
  private type
    TEntries = TDictionary<string, TKVEntry>;
  private
    FLock: TCriticalSection;
    FCollections: TObjectDictionary<string, TEntries>;
    { Not owned: a watch removes itself when it is released. }
    FWatches: TList<TKVMemoryWatch>;

    /// <summary>
    ///   Tells every watch on ACollection - every watch at all, when
    ///   ACollection is '' - that AKey changed. The caller must hold the lock.
    /// </summary>
    procedure Notify(const ACollection, AKey: string);

    /// <summary>
    ///   Forgets a watch that is being released.
    /// </summary>
    procedure RemoveWatch(const AWatch: TKVMemoryWatch);

    /// <summary>
    ///   The entries of a collection. The caller must hold the lock.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="ACreate">Whether to start the collection when it is new</param>
    /// <returns>The collection's entries, or nil when it does not exist</returns>
    function EntriesOf(const ACollection: string; const ACreate: Boolean): TEntries;
  protected

    /// <summary>
    ///   Fetches the entry stored under a key, expired or not.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="AEntry">Receives the entry as stored</param>
    /// <returns>True when something was stored under the key</returns>
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;

    /// <summary>
    ///   Stores an entry, starting the collection if this is its first key.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="AEntry">The entry to store, expiry already computed</param>
    procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;
    /// <summary>
    ///   Removes whatever is stored under a key, expired or not.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <returns>True when something was removed</returns>
    function DoDelete(const ACollection, AKey: string): Boolean; override;

    /// <summary>
    ///   Removes a key and reports whether what was there was live. The lookup
    ///   and the removal happen under one lock, so the answer and the removal
    ///   cannot disagree with each other.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="ANow">The UTC instant to judge the entry's expiry against</param>
    /// <returns>True when a live entry was removed</returns>
    function DoDeleteLive(const ACollection, AKey: string; const ANow: TDateTime): Boolean; override;

    /// <summary>
    ///   Drops an entry a read found expired, re-checking the expiry under the
    ///   lock so a value written by another thread in between survives.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    /// <param name="ANow">The UTC instant the entry was judged expired at</param>
    procedure DoDropExpired(const ACollection, AKey: string; const ANow: TDateTime); override;
  public
    /// <summary>
    ///   Builds an empty store.
    /// </summary>
    /// <param name="AClock">
    ///   Where the store reads "now" from. Leave it nil for the wall clock.
    /// </param>
    constructor Create(const AClock: TKVClock = nil); override;
    destructor Destroy; override;

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

    /// <summary>
    ///   Drops every expired entry, across every collection.
    /// </summary>
    /// <returns>How many entries were removed</returns>
    function Cull: Integer;

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

    /// <summary>
    ///   Reports every write and removal in a collection, synchronously.
    /// </summary>
    /// <param name="ACollection">The collection to watch; '' is the default one</param>
    /// <param name="AOnChange">Called once per change; nil is refused</param>
    function Watch(const ACollection: string; const AOnChange: TKVChangeProc): IKVWatch;

    /// <summary>
    ///   Entries held, expired ones included until they are read or culled.
    /// </summary>
    function Count: Integer;
  end;

  /// <summary>
  ///   What TKVMemoryStore.Watch returns. It holds the store, so the store
  ///   outlives every watch on it, and it is always live.
  /// </summary>
  TKVMemoryWatch = class(TInterfacedObject, IKVWatch)
  private
    FStore: TKVMemoryStore;
    FStoreRef: IKeyValue;
    FCollection: string;
    FOnChange: TKVChangeProc;
  public
    constructor Create(const AStore: TKVMemoryStore; const ACollection: string;
      const AOnChange: TKVChangeProc);
    destructor Destroy; override;
    function IsLive: Boolean;
  end;

implementation

resourcestring
  SKVNoChangeHandler = 'A watch needs a handler to report changes to';

{ TKVMemoryStore }

constructor TKVMemoryStore.Create(const AClock: TKVClock);
begin
  inherited Create(AClock);
  FLock := TCriticalSection.Create;
  FCollections := TObjectDictionary<string, TEntries>.Create([doOwnsValues]);
  FWatches := TList<TKVMemoryWatch>.Create;
end;

destructor TKVMemoryStore.Destroy;
begin
  // Every watch holds the store, so by now there are none left.
  FWatches.Free;
  FCollections.Free;
  FLock.Free;
  inherited;
end;

function TKVMemoryStore.EntriesOf(const ACollection: string; const ACreate: Boolean): TEntries;
begin
  if FCollections.TryGetValue(ACollection, Result) then
    Exit;

  if not ACreate then
    Exit(nil);

  Result := TEntries.Create;
  FCollections.Add(ACollection, Result);
end;

function TKVMemoryStore.DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean;
var
  LEntries: TEntries;
begin
  AEntry := Default(TKVEntry);
  FLock.Enter;
  try
    LEntries := EntriesOf(ACollection, False);
    Result := Assigned(LEntries) and LEntries.TryGetValue(AKey, AEntry);
  finally
    FLock.Leave;
  end;
end;

procedure TKVMemoryStore.DoPut(const ACollection, AKey: string; const AEntry: TKVEntry);
begin
  FLock.Enter;
  try
    EntriesOf(ACollection, True).AddOrSetValue(AKey, AEntry);
    Notify(ACollection, AKey);
  finally
    FLock.Leave;
  end;
end;

function TKVMemoryStore.DoDelete(const ACollection, AKey: string): Boolean;
var
  LEntries: TEntries;
begin
  FLock.Enter;
  try
    LEntries := EntriesOf(ACollection, False);
    Result := Assigned(LEntries) and LEntries.ContainsKey(AKey);
    if Result then
    begin
      LEntries.Remove(AKey);
      Notify(ACollection, AKey);
    end;
  finally
    FLock.Leave;
  end;
end;

function TKVMemoryStore.DoDeleteLive(const ACollection, AKey: string; const ANow: TDateTime): Boolean;
var
  LEntries: TEntries;
  LEntry: TKVEntry;
begin
  FLock.Enter;
  try
    LEntries := EntriesOf(ACollection, False);
    Result := Assigned(LEntries) and LEntries.TryGetValue(AKey, LEntry)
      and not LEntry.IsExpiredAt(ANow);
    if Assigned(LEntries) and LEntries.ContainsKey(AKey) then
    begin
      LEntries.Remove(AKey);
      Notify(ACollection, AKey);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TKVMemoryStore.DoDropExpired(const ACollection, AKey: string; const ANow: TDateTime);
var
  LEntries: TEntries;
  LEntry: TKVEntry;
begin
  // Re-check under the lock: between the read that found the entry expired and
  // this call, another thread may have written a fresh value under the key.
  FLock.Enter;
  try
    LEntries := EntriesOf(ACollection, False);
    if Assigned(LEntries) and LEntries.TryGetValue(AKey, LEntry)
       and LEntry.IsExpiredAt(ANow) then
      LEntries.Remove(AKey);
  finally
    FLock.Leave;
  end;
end;

function TKVMemoryStore.Keys(const ACollection: string): TArray<string>;
var
  LEntries: TEntries;
  LPair: TPair<string, TKVEntry>;
  LNow: TDateTime;
  LCount: Integer;
begin
  Result := nil;
  LNow := UtcNow;

  FLock.Enter;
  try
    LEntries := EntriesOf(ResolveCollection(ACollection), False);
    if not Assigned(LEntries) then
      Exit;

    SetLength(Result, LEntries.Count);
    LCount := 0;
    for LPair in LEntries do
      if not LPair.Value.IsExpiredAt(LNow) then
      begin
        Result[LCount] := LPair.Key;
        Inc(LCount);
      end;
    SetLength(Result, LCount);
  finally
    FLock.Leave;
  end;
end;

function TKVMemoryStore.Collections: TArray<string>;
begin
  FLock.Enter;
  try
    Result := FCollections.Keys.ToArray;
  finally
    FLock.Leave;
  end;
end;

function TKVMemoryStore.Cull: Integer;
var
  LEntries: TEntries;
  LPair: TPair<string, TKVEntry>;
  LExpired: TArray<string>;
  LKey: string;
  LNow: TDateTime;
  LCount: Integer;
begin
  Result := 0;
  LNow := UtcNow;

  FLock.Enter;
  try
    for LEntries in FCollections.Values do
    begin
      SetLength(LExpired, LEntries.Count);
      LCount := 0;
      for LPair in LEntries do
        if LPair.Value.IsExpiredAt(LNow) then
        begin
          LExpired[LCount] := LPair.Key;
          Inc(LCount);
        end;

      for LKey in Copy(LExpired, 0, LCount) do
        LEntries.Remove(LKey);

      Inc(Result, LCount);
    end;
  finally
    FLock.Leave;
  end;
end;

function TKVMemoryStore.DestroyCollection(const AName: string): Boolean;
var
  LCollection: string;
begin
  // Resolved once, before the lock: resolving twice could name two different
  // collections if the default changed in between.
  LCollection := ResolveCollection(AName);

  FLock.Enter;
  try
    Result := FCollections.ContainsKey(LCollection);
    if Result then
    begin
      FCollections.Remove(LCollection);
      Notify(LCollection, '');
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TKVMemoryStore.DestroyAll;
begin
  FLock.Enter;
  try
    FCollections.Clear;
    Notify('', '');
  finally
    FLock.Leave;
  end;
end;

procedure TKVMemoryStore.Notify(const ACollection, AKey: string);
var
  LWatch: TKVMemoryWatch;
begin
  for LWatch in FWatches do
    if (ACollection = '') or (LWatch.FCollection = ACollection) then
      try
        LWatch.FOnChange(AKey);
      except
        // A handler must not raise. If one does anyway, the write it is being
        // told about has already happened, and failing the write would report
        // it as not having happened.
      end;
end;

function TKVMemoryStore.Watch(const ACollection: string; const AOnChange: TKVChangeProc): IKVWatch;
var
  LWatch: TKVMemoryWatch;
begin
  if not Assigned(AOnChange) then
    raise EKVArgumentError.Create(SKVNoChangeHandler);

  LWatch := TKVMemoryWatch.Create(Self, ResolveCollection(ACollection), AOnChange);
  Result := LWatch;

  FLock.Enter;
  try
    FWatches.Add(LWatch);
  finally
    FLock.Leave;
  end;
end;

procedure TKVMemoryStore.RemoveWatch(const AWatch: TKVMemoryWatch);
begin
  // Under the lock, so a notification in progress finishes before the watch
  // it is calling goes away.
  FLock.Enter;
  try
    FWatches.Remove(AWatch);
  finally
    FLock.Leave;
  end;
end;

function TKVMemoryStore.Count: Integer;
var
  LEntries: TEntries;
begin
  Result := 0;
  FLock.Enter;
  try
    for LEntries in FCollections.Values do
      Inc(Result, LEntries.Count);
  finally
    FLock.Leave;
  end;
end;

{ TKVMemoryWatch }

constructor TKVMemoryWatch.Create(const AStore: TKVMemoryStore;
  const ACollection: string; const AOnChange: TKVChangeProc);
begin
  inherited Create;
  FStore := AStore;
  FStoreRef := AStore;
  FCollection := ACollection;
  FOnChange := AOnChange;
end;

destructor TKVMemoryWatch.Destroy;
begin
  FStore.RemoveWatch(Self);
  FStoreRef := nil;
  inherited;
end;

function TKVMemoryWatch.IsLive: Boolean;
begin
  // Nothing between the store and its watchers can drop a notification.
  Result := True;
end;

end.
