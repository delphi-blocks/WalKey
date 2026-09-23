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
///   The generic entity adapter, exercised with a codec that is deliberately
///   not JSON - a point as "X;Y" - to show that the typed surface, the misses,
///   the TTL and the bulk calls do not depend on the text at all.
/// </summary>
unit WalKey.Tests.Adapters.Entity;

interface

uses
  System.SysUtils,
  DUnitX.TestFramework,
  WalKey.Core, WalKey.Stores.Memory, WalKey.Adapters.Entity;

type
  /// <summary>
  ///   Something to store as two integers.
  /// </summary>
  TPoint = record
    X, Y: Integer;
  end;

  /// <summary>
  ///   A codec that is not JSON: a point is "X;Y".
  /// </summary>
  TKVPointAdapter = class(TKVEntityAdapter<TPoint>)
  protected
    function Serialize(const AValue: TPoint): string; override;
    function Deserialize(const AText: string): TPoint; override;
  end;

  /// <summary>
  ///   A class to store, so the generic layer's ownership rule - a read builds
  ///   an instance and the caller frees it - is exercised without Neon.
  /// </summary>
  TNote = class
  public
    Text: string;
  end;

  /// <summary>
  ///   A codec for a class with a null token of its own choosing. Nothing here
  ///   assumes the token is JSON's "null".
  /// </summary>
  TKVNoteAdapter = class(TKVEntityAdapter<TNote>)
  public
    const NULL_TOKEN = '<none>';
  protected
    function Serialize(const AValue: TNote): string; override;
    function Deserialize(const AText: string): TNote; override;
  end;

  [TestFixture]
  TKVEntityAdapterTests = class
  private
    FNow: TDateTime;
    FStore: IKeyValue;
    procedure Advance(const ASeconds: Double);
  public
    [Setup] procedure Setup;

    [Test] procedure GenericCodec_RoundTripsWithoutJson;
    [Test] procedure GenericCodec_ReportsAMiss;
    [Test] procedure GenericCodec_RaisesOnMissingWhenAsked;
    [Test] procedure GenericCodec_CarriesTheEntryAndItsTtl;
    [Test] procedure GenericCodec_HandlesTheBulkCalls;
    [Test] procedure GenericCodec_AValueThatIsNotT_RaisesNamingTheKey;
    [Test] procedure ClassCodec_ChoosesItsOwnNullToken;
    [Test] procedure NilStore_Refused;
  end;

implementation

{ TKVPointAdapter }

function TKVPointAdapter.Serialize(const AValue: TPoint): string;
begin
  Result := Format('%d;%d', [AValue.X, AValue.Y]);
end;

function TKVPointAdapter.Deserialize(const AText: string): TPoint;
var
  LSeparator: Integer;
begin
  LSeparator := AText.IndexOf(';');
  if LSeparator < 1 then
    raise EKVSerializationError.Create('not a point');

  try
    Result.X := StrToInt(AText.Substring(0, LSeparator));
    Result.Y := StrToInt(AText.Substring(LSeparator + 1));
  except
    on E: Exception do
      // The text itself never goes into the message: it can be large, and it
      // can be somebody's personal data.
      raise EKVSerializationError.Create('not a point');
  end;
end;

{ TKVNoteAdapter }

function TKVNoteAdapter.Serialize(const AValue: TNote): string;
begin
  if IsNilInstance(AValue) then
    Exit(NULL_TOKEN);

  Result := AValue.Text;
end;

function TKVNoteAdapter.Deserialize(const AText: string): TNote;
begin
  if AText = NULL_TOKEN then
    Exit(nil);

  Result := TNote.Create;
  try
    Result.Text := AText;
  except
    Result.Free;
    raise;
  end;
end;

{ TKVEntityAdapterTests }

procedure TKVEntityAdapterTests.Setup;
begin
  FNow := EncodeDate(2026, 1, 1) + EncodeTime(12, 0, 0, 0);
  FStore := TKVMemoryStore.Create(
    function: TDateTime
    begin
      Result := FNow;
    end);
end;

procedure TKVEntityAdapterTests.Advance(const ASeconds: Double);
begin
  FNow := FNow + (ASeconds / SecsPerDay);
end;

procedure TKVEntityAdapterTests.GenericCodec_RoundTripsWithoutJson;
var
  LPoints: IKVEntityAdapter<TPoint>;
  LWritten, LRead: TPoint;
begin
  LPoints := TKVPointAdapter.Create(FStore, 'points');

  LWritten.X := 3;
  LWritten.Y := 4;
  LPoints.Put('a', LWritten);

  Assert.AreEqual('3;4', FStore.Get('a', 'points'),
    'the codec wrote plain text, and nothing parsed it');

  Assert.IsTrue(LPoints.TryGet('a', LRead));
  Assert.AreEqual(3, LRead.X);
  Assert.AreEqual(4, LRead.Y);
end;

procedure TKVEntityAdapterTests.GenericCodec_ReportsAMiss;
var
  LPoints: IKVEntityAdapter<TPoint>;
  LRead: TPoint;
begin
  LPoints := TKVPointAdapter.Create(FStore, 'points');

  Assert.IsFalse(LPoints.TryGet('nope', LRead));
  Assert.AreEqual(0, LRead.X, 'a miss is a zeroed record');
  Assert.AreEqual(0, LPoints.Get('nope').X);
  Assert.IsFalse(LPoints.Exists('nope'));
end;

procedure TKVEntityAdapterTests.GenericCodec_RaisesOnMissingWhenAsked;
var
  LPoints: IKVEntityAdapter<TPoint>;
begin
  LPoints := TKVPointAdapter.Create(FStore, 'points');
  LPoints.RaiseOnMissing := True;

  Assert.WillRaise(
    procedure
    begin
      LPoints.Get('nope');
    end, EKVNotFoundError);
end;

procedure TKVEntityAdapterTests.GenericCodec_CarriesTheEntryAndItsTtl;
var
  LPoints: IKVEntityAdapter<TPoint>;
  LWritten, LRead: TPoint;
  LEntry: TKVEntry;
begin
  LPoints := TKVPointAdapter.Create(FStore, 'points');
  LWritten.X := 1;
  LWritten.Y := 2;
  LPoints.Put('a', LWritten, 60);
  Advance(20);

  Assert.IsTrue(LPoints.TryGetEntry('a', LRead, LEntry));
  Assert.AreEqual(1, LRead.X);
  Assert.AreEqual(Double(40), Double(LEntry.TTLRemainingAt(FNow)), 0.001);

  Advance(60);
  Assert.IsFalse(LPoints.Exists('a'), 'the TTL still expires the entry');
end;

procedure TKVEntityAdapterTests.GenericCodec_HandlesTheBulkCalls;
var
  LPoints: IKVEntityAdapter<TPoint>;
  LValues: TArray<TPoint>;
  LOne, LTwo: TPoint;
begin
  LPoints := TKVPointAdapter.Create(FStore, 'points');
  LOne.X := 1;
  LOne.Y := 2;
  LTwo.X := 5;
  LTwo.Y := 6;

  LPoints.PutMany(['one', 'two'], [LOne, LTwo]);

  LValues := LPoints.GetMany(['one', 'nope', 'two']);
  Assert.AreEqual(3, Length(LValues));
  Assert.AreEqual(1, LValues[0].X);
  Assert.AreEqual(0, LValues[1].X, 'a miss is Default(T)');
  Assert.AreEqual(5, LValues[2].X);

  Assert.AreEqual(2, LPoints.DeleteMany(['one', 'two', 'nope']));
end;

procedure TKVEntityAdapterTests.GenericCodec_AValueThatIsNotT_RaisesNamingTheKey;
var
  LPoints: IKVEntityAdapter<TPoint>;
begin
  FStore.Put('a', 'this is not a point', 'points');
  LPoints := TKVPointAdapter.Create(FStore, 'points');

  try
    LPoints.Get('a');
    Assert.Fail('expected EKVSerializationError');
  except
    on E: EKVSerializationError do
      Assert.IsTrue(E.Message.Contains('"a"') and E.Message.Contains('"points"'),
        'the message names the key and collection: ' + E.Message);
  end;
end;

procedure TKVEntityAdapterTests.ClassCodec_ChoosesItsOwnNullToken;
var
  LNotes: IKVEntityAdapter<TNote>;
  LNote: TNote;
begin
  LNotes := TKVNoteAdapter.Create(FStore, 'notes');

  LNote := TNote.Create;
  LNote.Text := 'hello';
  LNotes.Put('a', LNote);
  LNote.Free;

  LNotes.Put('nil', TNote(nil));

  Assert.AreEqual('hello', FStore.Get('a', 'notes'), 'plain text, not JSON');
  Assert.AreEqual(TKVNoteAdapter.NULL_TOKEN, FStore.Get('nil', 'notes'),
    'the codec picked its own null token');

  LNote := LNotes.Get('a');
  try
    Assert.AreEqual('hello', LNote.Text);
  finally
    LNote.Free;
  end;

  Assert.IsTrue(LNotes.Get('nil') = nil, 'the null token reads back as nil');
end;

procedure TKVEntityAdapterTests.NilStore_Refused;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVPointAdapter.Create(nil);
    end, EKVArgumentError);
end;

initialization
  TDUnitX.RegisterTestFixture(TKVEntityAdapterTests);

end.
