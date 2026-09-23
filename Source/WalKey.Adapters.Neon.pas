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
///   Typed access to a store, through Neon.
///
///   The typed surface and every bit of store plumbing live in
///   WalKey.Adapters.Entity: TKVEntityAdapter&lt;T&gt; holds the store, the
///   collection, the misses and RaiseOnMissing, the entry and its TTL, and the
///   bulk calls. All it leaves to a descendant is the codec - how a T becomes
///   text and back - and this is the Neon one: a record or object through
///   Neon's JSON.
///
///   <code>
///   LUsers := TKVNeonAdapter&lt;TUser&gt;.Create(LStore, 'users');
///   LUsers.Put('john', LUser, 3600);
///   if LUsers.TryGet('john', LUser) then
///     ...
///   </code>
///
///   It is an adapter rather than a wrapper: it does not implement IKeyValue,
///   because its methods take and return T instead of a string. Several
///   adapters over different types can share one store, and the store stays
///   reachable through the Store property.
///
///   This is the only part of WalKey that depends on anything outside the RTL,
///   which is why it is a unit and a package of its own.
/// </summary>
unit WalKey.Adapters.Neon;

interface

uses
  System.SysUtils, System.Rtti, System.TypInfo, System.JSON,
  Neon.Core.Persistence, Neon.Core.Persistence.JSON, Neon.Core.Utils,
  Neon.Core.Types,
  WalKey.Core, WalKey.Adapters.Entity;

const
  /// <summary>
  ///   What a nil class instance is stored as, and what reads back as nil.
  /// </summary>
  KV_NULL_JSON = 'null';

type
  /// <summary>
  ///   The Neon-backed codec: a record or object rendered as Neon's JSON, with
  ///   the typed surface and all the store plumbing inherited from
  ///   TKVEntityAdapter.
  ///
  ///   <para>
  ///     For a class T, every read builds a new instance and hands it over:
  ///     the caller owns it and must free it.
  ///   </para>
  ///   <para>
  ///     A class T needs a parameterless constructor, since that is what a
  ///     read calls before filling the instance in.
  ///   </para>
  /// </summary>
  TKVNeonAdapter<T> = class(TKVEntityAdapter<T>)
  private
    FConfig: INeonConfiguration;

    /// <summary>
    ///   The exception a value that will not decode is reported as, naming the
    ///   type it should have been. The text itself is left out: it can be
    ///   large, and it can be somebody's personal data.
    /// </summary>
    function CannotRead(const AError: Exception): EKVSerializationError;
  protected
    /// <summary>
    ///   Turns a value into the JSON text the store keeps. A nil instance
    ///   becomes the null token rather than being refused, so an optional value
    ///   reads back as the nil it was.
    /// </summary>
    /// <param name="AValue">The value to render</param>
    function Serialize(const AValue: T): string; override;

    /// <summary>
    ///   Turns stored JSON back into a value, the null token included.
    /// </summary>
    /// <param name="AText">What the store gave back</param>
    /// <exception cref="EKVSerializationError">
    ///   The text is not a T. A store holding something the code can no longer
    ///   read is worth an exception: answering with an empty record would pass
    ///   the corruption on as though it were data.
    /// </exception>
    function Deserialize(const AText: string): T; override;
  public
    /// <summary>
    ///   Puts a typed face on a store, reading and writing it with Neon.
    /// </summary>
    /// <param name="AStore">The store to read and write; nil is refused</param>
    /// <param name="ACollection">
    ///   The collection every call lands in; '' is the store's default one
    /// </param>
    /// <param name="AConfig">
    ///   How Neon should serialize. Leave it nil for Neon's own defaults; pass
    ///   one to choose member casing, visibility or custom serializers - and
    ///   pass the same one everywhere, since it decides what the stored JSON
    ///   looks like.
    /// </param>
    constructor Create(const AStore: IKeyValue; const ACollection: string = '';
      const AConfig: INeonConfiguration = nil);
  end;

implementation

{ TKVNeonAdapter<T> }

constructor TKVNeonAdapter<T>.Create(const AStore: IKeyValue;
  const ACollection: string; const AConfig: INeonConfiguration);
begin
  inherited Create(AStore, ACollection);

  if Assigned(AConfig) then
    FConfig := AConfig
  else
    FConfig := TNeonConfiguration.Default;
end;

function TKVNeonAdapter<T>.Serialize(const AValue: T): string;
begin
  if IsNilInstance(AValue) then
    Exit(KV_NULL_JSON);

  if IsClassType then
    Result := TNeon.ObjectToJSONString(TValue.From<T>(AValue).AsObject, FConfig)
  else
    Result := TNeon.ValueToJSONString(TValue.From<T>(AValue), FConfig);
end;

function TKVNeonAdapter<T>.Deserialize(const AText: string): T;
var
  LObject: TObject;
  LValue: TValue;
begin
  if AText = KV_NULL_JSON then
    Exit(Default(T));

  try
    if IsClassType then
    begin
      // The instance is built here and filled by Neon, rather than left to the
      // Neon overload that does both: that one does not free what it built
      // when the filling fails, and a value that will not decode must not
      // cost a leaked object. Building one is why T needs a parameterless
      // constructor.
      LObject := TRttiUtils.CreateInstance(TRttiContext.Create.GetType(TypeInfo(T)));
      try
        TNeon.JSONToObject(LObject, AText, FConfig);
      except
        LObject.Free;
        raise;
      end;
      TValue.Make(@LObject, TypeInfo(T), LValue);
      Result := LValue.AsType<T>;
    end
    else
      Result := TNeon.JSONToValue<T>(AText, FConfig);
  except
    // Only what means "this text is not a T" becomes a serialization error:
    // Neon's own, the JSON parser's, a conversion or a cast between them.
    // Anything else - a reflection failure, a bug - is passed on, because
    // turning it into EKVSerializationError would hide it.
    on E: ENeonException do
      raise CannotRead(E);
    on E: EJSONParseException do
      raise CannotRead(E);
    on E: EConvertError do
      raise CannotRead(E);
    on E: EInvalidCast do
      raise CannotRead(E);
    on E: EIntfCastError do
      raise CannotRead(E);
  end;
end;

function TKVNeonAdapter<T>.CannotRead(const AError: Exception): EKVSerializationError;
begin
  Result := EKVSerializationError.CreateFmt(SKVCannotRead,
    [string(PTypeInfo(TypeInfo(T)).Name), AError.Message]);
end;

end.
