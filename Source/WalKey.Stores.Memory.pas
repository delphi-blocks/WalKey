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
  /// <summary>
  ///   Keeps everything in memory, for as long as the instance lives. Keys and
  ///   collection names are case-sensitive, and instances are thread-safe.
  /// </summary>
  TKVMemoryStore = class(TKVStoreBase,
    IKeyValueEnumerable,
    IKeyValueCullable,
    IKeyValueDestroyable)
  private type
    TEntries = TDictionary<string, TKVEntry>;
  private
    FLock: TCriticalSection;
    FCollections: TObjectDictionary<string, TEntries>;

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
    ///   Entries held, expired ones included until they are read or culled.
    /// </summary>
    function Count: Integer;
  end;

implementation

{ TKVMemoryStore }

constructor TKVMemoryStore.Create(const AClock: TKVClock);
begin
  inherited Create(AClock);
  FLock := TCriticalSection.Create;
  FCollections := TObjectDictionary<string, TEntries>.Create([doOwnsValues]);
end;

destructor TKVMemoryStore.Destroy;
begin
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
      LEntries.Remove(AKey);
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
      LEntries.Remove(AKey);
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
      FCollections.Remove(LCollection);
  finally
    FLock.Leave;
  end;
end;

procedure TKVMemoryStore.DestroyAll;
begin
  FLock.Enter;
  try
    FCollections.Clear;
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

end.
