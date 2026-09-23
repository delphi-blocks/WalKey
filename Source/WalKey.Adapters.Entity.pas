{******************************************************************************}
{                                                                              }
{  WalKey - Pluggable Key-Value Stores for Delphi                              }
{                                                                              }
{  Copyright (c) 2026 Paolo Rossi <dev@paolorossi.net>                         }
{                                                                              }
{  All rights reserved                                                         }
{  Licensed under the MIT license                                              }
{******************************************************************************}

/// <summary>
///   A store seen as a store of T: the typed surface, and the codec boundary
///   underneath it.
///
///   A store trades in text; this is the layer that turns a Delphi record or
///   object into that text and back, so calling code deals in its own types and
///   never writes a serialization call:
///
///   <code>
///   LUsers := TKVNeonAdapter&lt;TUser&gt;.Create(LStore, 'users');
///   LUsers.Put('john', LUser, 3600);
///   if LUsers.TryGet('john', LUser) then
///     ...
///   </code>
///
///   It does not care what the text is, and nothing here parses it. A
///   descendant supplies the two halves - Serialize and Deserialize - and gets
///   the whole typed surface for free: misses and RaiseOnMissing, the entry
///   and its TTL, the bulk calls, and the untyped store underneath.
///   TKVNeonAdapter&lt;T&gt; in WalKey.Adapters.Neon is that descendant for Neon and
///   JSON; a codec for XML, a packed record or a base64 blob is written the
///   same way, and this unit never learns about it.
///
///   It is an adapter rather than a wrapper: it does not implement IKeyValue,
///   because its methods take and return T instead of a string. Several
///   adapters over different types can share one store, and the store stays
///   reachable through the Store property.
///
///   This unit uses the RTL alone. Only a concrete codec, like the Neon one,
///   can take on a dependency, which is why the codec lives in its own unit and
///   its own package.
/// </summary>
unit WalKey.Adapters.Entity;

interface

uses
  System.SysUtils, System.Rtti, System.TypInfo,
  WalKey.Core;

{ These live in the interface section because TKVEntityAdapter is generic, and
  a parameterized type declared there cannot reach a symbol from the
  implementation section. }
resourcestring
  SKVNoStore = 'A typed adapter needs a store';
  SKVNotFound = 'No entry under key "%s" in collection "%s"';
  SKVCannotRead = 'The stored value is not a %s: %s';
  SKVCannotReadKey = 'Cannot read key "%s" in collection "%s": %s';

type
  /// <summary>
  ///   A key that was asked for and is not there, raised in place of a default
  ///   value when the adapter is in RaiseOnMissing mode.
  /// </summary>
  EKVNotFoundError = class(EKVError);

  /// <summary>
  ///   A store seen as a store of T, whatever text the codec underneath
  ///   produces.
  /// </summary>
  IKVEntityAdapter<T> = interface
    /// <summary>
    ///   Reads a value. A miss gives Default(T) - nil for a class, a
    ///   zeroed record - unless RaiseOnMissing is on, in which case a miss
    ///   raises EKVNotFoundError.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    function Get(const AKey: string): T;

    /// <summary>
    ///   Reads a value, reporting whether it was there. Unaffected by
    ///   RaiseOnMissing: asking whether something is there is never a
    ///   mistake.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="AValue">Receives the value, or Default(T) on a miss</param>
    /// <returns>True when a live entry was found</returns>
    function TryGet(const AKey: string; out AValue: T): Boolean;

    /// <summary>
    ///   Reads a value, answering with something of your choosing on a miss.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="ADefault">What a miss answers with</param>
    function GetDef(const AKey: string; const ADefault: T): T;

    /// <summary>
    ///   Reads a value and the entry that carried it, for when the remaining
    ///   lifetime matters as much as the value.
    /// </summary>
    /// <param name="AKey">The key to read</param>
    /// <param name="AValue">Receives the value, or Default(T) on a miss</param>
    /// <param name="AEntry">Receives the entry, expiry included</param>
    /// <returns>True when a live entry was found</returns>
    function TryGetEntry(const AKey: string; out AValue: T; out AEntry: TKVEntry): Boolean;

    /// <summary>
    ///   Whether a live entry is stored under the key. Nothing is decoded.
    /// </summary>
    /// <param name="AKey">The key to look for</param>
    function Exists(const AKey: string): Boolean;

    /// <summary>
    ///   Encodes a value and stores it.
    /// </summary>
    /// <param name="AKey">The key to write</param>
    /// <param name="AValue">The value; how a nil, for a class, is stored is the codec's business</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores it without an expiry</param>
    procedure Put(const AKey: string; const AValue: T; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes an entry.
    /// </summary>
    /// <param name="AKey">The key to remove</param>
    /// <returns>True when a live entry was removed</returns>
    function Delete(const AKey: string): Boolean;

    /// <summary>
    ///   Reads several keys at once.
    /// </summary>
    /// <param name="AKeys">The keys to read</param>
    /// <returns>
    ///   One result per requested key, in order, Default(T) for the misses.
    ///   RaiseOnMissing does not apply: a bulk read is a query, and the
    ///   answers say for themselves which keys were there.
    /// </returns>
    function GetMany(const AKeys: TArray<string>): TArray<T>;

    /// <summary>
    ///   Stores several values at once, all with the same TTL.
    /// </summary>
    /// <param name="AKeys">The keys to write</param>
    /// <param name="AValues">The values, one per key and in the same order</param>
    /// <param name="ATTL">Lifetime in seconds; 0 stores them without an expiry</param>
    procedure PutMany(const AKeys: TArray<string>; const AValues: TArray<T>; const ATTL: TKVDuration = KV_NO_TTL);

    /// <summary>
    ///   Removes several entries at once.
    /// </summary>
    /// <param name="AKeys">The keys to remove</param>
    /// <returns>How many of them held a live entry</returns>
    function DeleteMany(const AKeys: TArray<string>): Integer;

    function GetStore: IKeyValue;
    function GetCollection: string;
    function GetRaiseOnMissing: Boolean;
    procedure SetRaiseOnMissing(const AValue: Boolean);

    /// <summary>
    ///   The store underneath, for anything the adapter does not cover.
    /// </summary>
    property Store: IKeyValue read GetStore;

    /// <summary>
    ///   The collection every call lands in.
    /// </summary>
    property Collection: string read GetCollection;

    /// <summary>
    ///   Whether Get raises on a miss rather than answering Default(T). Off by
    ///   default. Worth turning on where a missing key means a broken
    ///   invariant rather than a cold cache - an empty record read as though
    ///   it were real data is a bug that surfaces a long way from its cause.
    /// </summary>
    property RaiseOnMissing: Boolean read GetRaiseOnMissing write SetRaiseOnMissing;
  end;

  /// <summary>
  ///   The part of a typed adapter that does not depend on the codec: the store,
  ///   the collection, the misses, the TTL and the bulk calls. A descendant
  ///   adds the codec by implementing Serialize and Deserialize, and nothing
  ///   else.
  ///
  ///   <para>
  ///     For a class T, every read builds a new instance and hands it over:
  ///     the caller owns it and must free it. Nothing is cached, and nothing
  ///     the adapter returns is ever referenced again - the same rule the
  ///     stores follow, one type up.
  ///   </para>
  /// </summary>
  TKVEntityAdapter<T> = class abstract(TInterfacedObject, IKVEntityAdapter<T>)
  private
    FStore: IKeyValue;
    FCollection: string;
    FRaiseOnMissing: Boolean;
    function GetStore: IKeyValue;
    function GetCollection: string;
    function GetRaiseOnMissing: Boolean;
    procedure SetRaiseOnMissing(const AValue: Boolean);

    /// <summary>
    ///   Deserialize, with the key and collection added to the message of a
    ///   value that will not decode. Deserialize sees only the text, and the
    ///   text is the one thing that must not go into the message: it can be
    ///   large, and it can be somebody's personal data.
    /// </summary>
    function ReadValue(const AKey, AText: string): T;
  protected
    /// <summary>
    ///   Whether T is a class type. A class and a record need different
    ///   treatment from a codec, and only a class needs freeing.
    /// </summary>
    class function IsClassType: Boolean; static;

    /// <summary>
    ///   Whether T is a class type and this particular value is nil.
    /// </summary>
    class function IsNilInstance(const AValue: T): Boolean; static;

    /// <summary>
    ///   Frees the first ACount values when T is a class type, and does
    ///   nothing otherwise. For a bulk read that fails part-way, whose
    ///   instances would otherwise belong to nobody.
    /// </summary>
    class procedure FreeValues(const AValues: TArray<T>; const ACount: Integer); static;

    /// <summary>
    ///   Turns a value into the text the store keeps. This is the codec, and
    ///   it is the one thing a descendant must supply. It is called for every
    ///   value a Put or a PutMany writes.
    /// </summary>
    /// <param name="AValue">The value to render</param>
    function Serialize(const AValue: T): string; virtual; abstract;

    /// <summary>
    ///   Turns stored text back into a value. The other half of the codec.
    /// </summary>
    /// <param name="AText">What the store gave back</param>
    /// <exception cref="EKVSerializationError">
    ///   The text is not a T. A store holding something the code can no longer
    ///   read is worth an exception: answering with an empty record would pass
    ///   the corruption on as though it were data.
    /// </exception>
    function Deserialize(const AText: string): T; virtual; abstract;
  public
    /// <summary>
    ///   Puts a typed face on a store.
    /// </summary>
    /// <param name="AStore">The store to read and write; nil is refused</param>
    /// <param name="ACollection">
    ///   The collection every call lands in; '' is the store's default one
    /// </param>
    constructor Create(const AStore: IKeyValue; const ACollection: string = '');

    function Get(const AKey: string): T;
    function TryGet(const AKey: string; out AValue: T): Boolean;
    function GetDef(const AKey: string; const ADefault: T): T;
    function TryGetEntry(const AKey: string; out AValue: T; out AEntry: TKVEntry): Boolean;
    function Exists(const AKey: string): Boolean;
    procedure Put(const AKey: string; const AValue: T; const ATTL: TKVDuration = KV_NO_TTL);
    function Delete(const AKey: string): Boolean;

    function GetMany(const AKeys: TArray<string>): TArray<T>;
    procedure PutMany(const AKeys: TArray<string>; const AValues: TArray<T>;
      const ATTL: TKVDuration = KV_NO_TTL);
    function DeleteMany(const AKeys: TArray<string>): Integer;

    property Store: IKeyValue read GetStore;
    property Collection: string read GetCollection;
    property RaiseOnMissing: Boolean read GetRaiseOnMissing write SetRaiseOnMissing;
  end;

implementation

{ TKVEntityAdapter<T> }

constructor TKVEntityAdapter<T>.Create(const AStore: IKeyValue; const ACollection: string);
begin
  inherited Create;
  if not Assigned(AStore) then
    raise EKVArgumentError.Create(SKVNoStore);

  FStore := AStore;
  FCollection := ACollection;
end;

function TKVEntityAdapter<T>.GetStore: IKeyValue;
begin
  Result := FStore;
end;

function TKVEntityAdapter<T>.GetCollection: string;
begin
  Result := FCollection;
end;

function TKVEntityAdapter<T>.GetRaiseOnMissing: Boolean;
begin
  Result := FRaiseOnMissing;
end;

procedure TKVEntityAdapter<T>.SetRaiseOnMissing(const AValue: Boolean);
begin
  FRaiseOnMissing := AValue;
end;

class function TKVEntityAdapter<T>.IsClassType: Boolean;
begin
  Result := (TypeInfo(T) <> nil) and (PTypeInfo(TypeInfo(T)).Kind = tkClass);
end;

class function TKVEntityAdapter<T>.IsNilInstance(const AValue: T): Boolean;
begin
  Result := IsClassType and (TValue.From<T>(AValue).AsObject = nil);
end;

class procedure TKVEntityAdapter<T>.FreeValues(const AValues: TArray<T>; const ACount: Integer);
var
  LIndex: Integer;
begin
  if not IsClassType then
    Exit;

  for LIndex := 0 to ACount - 1 do
    TValue.From<T>(AValues[LIndex]).AsObject.Free;
end;

function TKVEntityAdapter<T>.ReadValue(const AKey, AText: string): T;
begin
  try
    Result := Deserialize(AText);
  except
    on E: EKVSerializationError do
      raise EKVSerializationError.CreateFmt(SKVCannotReadKey, [AKey, FCollection, E.Message]);
  end;
end;

function TKVEntityAdapter<T>.TryGet(const AKey: string; out AValue: T): Boolean;
var
  LText: string;
begin
  AValue := Default(T);
  Result := FStore.TryGet(AKey, FCollection, LText);
  if Result then
    AValue := ReadValue(AKey, LText);
end;

function TKVEntityAdapter<T>.Get(const AKey: string): T;
begin
  if TryGet(AKey, Result) then
    Exit;

  if FRaiseOnMissing then
    raise EKVNotFoundError.CreateFmt(SKVNotFound, [AKey, FCollection]);

  Result := Default(T);
end;

function TKVEntityAdapter<T>.GetDef(const AKey: string; const ADefault: T): T;
begin
  if not TryGet(AKey, Result) then
    Result := ADefault;
end;

function TKVEntityAdapter<T>.TryGetEntry(const AKey: string; out AValue: T;
  out AEntry: TKVEntry): Boolean;
begin
  AValue := Default(T);
  Result := FStore.TryGetEntry(AKey, FCollection, AEntry);
  if Result then
    AValue := ReadValue(AKey, AEntry.Value);
end;

function TKVEntityAdapter<T>.Exists(const AKey: string): Boolean;
begin
  Result := FStore.Exists(AKey, FCollection);
end;

procedure TKVEntityAdapter<T>.Put(const AKey: string; const AValue: T; const ATTL: TKVDuration);
begin
  FStore.Put(AKey, Serialize(AValue), FCollection, ATTL);
end;

function TKVEntityAdapter<T>.Delete(const AKey: string): Boolean;
begin
  Result := FStore.Delete(AKey, FCollection);
end;

function TKVEntityAdapter<T>.GetMany(const AKeys: TArray<string>): TArray<T>;
var
  LValues: TArray<string>;
  LIndex, LBuilt: Integer;
begin
  LValues := FStore.GetMany(AKeys, FCollection);

  SetLength(Result, Length(LValues));
  LBuilt := 0;
  try
    for LIndex := 0 to High(LValues) do
    begin
      // An empty answer is a stored '' or a miss, and only the store can say
      // which. A stored '' is not a T, so it takes the same route as any other
      // value that will not decode, exactly as Get and TryGet do.
      if (LValues[LIndex] <> '') or FStore.Exists(AKeys[LIndex], FCollection) then
        Result[LIndex] := ReadValue(AKeys[LIndex], LValues[LIndex])
      else
        Result[LIndex] := Default(T);
      LBuilt := LIndex + 1;
    end;
  except
    // The caller never receives the array, so the instances already built for
    // the keys before the bad one would belong to nobody.
    FreeValues(Result, LBuilt);
    raise;
  end;
end;

procedure TKVEntityAdapter<T>.PutMany(const AKeys: TArray<string>;
  const AValues: TArray<T>; const ATTL: TKVDuration);
var
  LText: TArray<string>;
  LIndex: Integer;
begin
  // Checked before anything is encoded, and in the same terms, and with the
  // same message, a store would use - it never sees the original arrays, so it
  // cannot do the check for the adapter.
  TKVUtils.CheckBulkLengths(Length(AKeys), Length(AValues));

  SetLength(LText, Length(AValues));
  for LIndex := 0 to High(AValues) do
    LText[LIndex] := Serialize(AValues[LIndex]);

  FStore.PutMany(AKeys, LText, FCollection, ATTL);
end;

function TKVEntityAdapter<T>.DeleteMany(const AKeys: TArray<string>): Integer;
begin
  Result := FStore.DeleteMany(AKeys, FCollection);
end;

end.
