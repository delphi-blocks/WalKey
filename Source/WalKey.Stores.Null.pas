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
///   The store that keeps nothing: every write is accepted and discarded,
///   every read is a miss. WalKey's /dev/null.
///
///   It is what you configure when a store is required but storage is not -
///   turning a cache off without unpicking the wiring that uses it, giving an
///   unconfigured dependency a default that cannot fail, keeping a test from
///   persisting anything, or measuring what a benchmark costs with the storage
///   taken out of it.
///
///   It is a null store, not a lax one: keys, collection names and TTLs are
///   validated exactly as a real store validates them, and the same calls
///   raise the same exceptions. Code that runs against this store runs against
///   any other - which is the only reason it is safe to swap in.
/// </summary>
unit WalKey.Stores.Null;

interface

uses
  System.SysUtils,
  WalKey.Core;

type
  /// <summary>
  ///   Accepts everything, stores nothing, reports every key as missing.
  ///   Stateless, and therefore trivially thread-safe.
  /// </summary>
  TKVNullStore = class(TKVStoreBase,
    IKeyValueEnumerable,
    IKeyValueCullable,
    IKeyValueDestroyable)
  protected

    /// <summary>
    ///   Always a miss: nothing was ever kept.
    /// </summary>
    /// <param name="ACollection">The resolved collection name, unused</param>
    /// <param name="AKey">The validated key, unused</param>
    /// <param name="AEntry">Receives an empty entry</param>
    /// <returns>Always False</returns>
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;

    /// <summary>
    ///   Discards the entry. The write is accepted, which is the point: a
    ///   caller cannot tell it apart from a store that ran out of room a
    ///   moment later.
    /// </summary>
    /// <param name="ACollection">The resolved collection name, unused</param>
    /// <param name="AKey">The validated key, unused</param>
    /// <param name="AEntry">The entry, dropped</param>
    procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;

    /// <summary>
    ///   Nothing to remove.
    /// </summary>
    /// <param name="ACollection">The resolved collection name, unused</param>
    /// <param name="AKey">The validated key, unused</param>
    /// <returns>Always False</returns>
    function DoDelete(const ACollection, AKey: string): Boolean; override;
  public

    /// <summary>
    ///   No keys, ever.
    /// </summary>
    /// <param name="ACollection">Collection to list; validated, then ignored</param>
    /// <returns>Always empty</returns>
    function Keys(const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   No collections, ever: a write never brings one into being.
    /// </summary>
    /// <returns>Always empty</returns>
    function Collections: TArray<string>;

    /// <summary>
    ///   Nothing is held, so nothing can expire.
    /// </summary>
    /// <returns>Always 0</returns>
    function Cull: Integer;

    /// <summary>
    ///   Nothing to drop.
    /// </summary>
    /// <param name="AName">The collection to drop; validated, then ignored</param>
    /// <returns>Always False</returns>
    function DestroyCollection(const AName: string): Boolean;

    /// <summary>
    ///   Nothing to empty.
    /// </summary>
    procedure DestroyAll;
  end;

implementation

{ TKVNullStore }

function TKVNullStore.DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean;
begin
  AEntry := Default(TKVEntry);
  Result := False;
end;

procedure TKVNullStore.DoPut(const ACollection, AKey: string; const AEntry: TKVEntry);
begin
  // Deliberately nothing.
end;

function TKVNullStore.DoDelete(const ACollection, AKey: string): Boolean;
begin
  Result := False;
end;

function TKVNullStore.Keys(const ACollection: string): TArray<string>;
begin
  // Validated for the sake of the swap: a name a real store would refuse is
  // refused here too.
  ResolveCollection(ACollection);
  Result := nil;
end;

function TKVNullStore.Collections: TArray<string>;
begin
  Result := nil;
end;

function TKVNullStore.Cull: Integer;
begin
  Result := 0;
end;

function TKVNullStore.DestroyCollection(const AName: string): Boolean;
begin
  ResolveCollection(AName);
  Result := False;
end;

procedure TKVNullStore.DestroyAll;
begin
  // Deliberately nothing.
end;

end.
