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
///   The typed adapter, over a memory store: records, classes, the round trip
///   through Neon, and what a miss looks like on either side of
///   RaiseOnMissing.
/// </summary>
unit WalKey.Tests.Adapters.Neon;

interface

uses
  System.SysUtils, System.Generics.Collections,
  DUnitX.TestFramework,
  Neon.Core.Types, Neon.Core.Attributes, Neon.Core.Persistence,
  WalKey.Core, WalKey.Stores.Memory,
  WalKey.Adapters.Entity, WalKey.Adapters.Neon;

type
  /// <summary>
  ///   A record to store. The usual shape of a cached thing: a few fields, no
  ///   lifetime to manage.
  /// </summary>
  TUser = record
    Name: string;
    Email: string;
    Age: Integer;
    Active: Boolean;
  end;

  /// <summary>
  ///   A class to store, so the ownership rule gets exercised: every read
  ///   builds one, and the caller frees it.
  /// </summary>
  TOrder = class
  private
    FReference: string;
    FTotal: Double;
  public
    property Reference: string read FReference write FReference;
    property Total: Double read FTotal write FTotal;
  end;

  /// <summary>
  ///   A class that counts its live instances, so a test can tell whether a
  ///   read that failed left one behind. Counted in AfterConstruction and
  ///   BeforeDestruction, which run whichever constructor RTTI picks.
  /// </summary>
  TTrackedOrder = class
  private
    FReference: string;
    FTotal: Double;
  public
    class var Live: Integer;
    procedure AfterConstruction; override;
    procedure BeforeDestruction; override;
    property Reference: string read FReference write FReference;
    property Total: Double read FTotal write FTotal;
  end;

  [TestFixture]
  TKVNeonAdapterTests = class
  private
    FNow: TDateTime;
    FStore: IKeyValue;
    FUsers: IKVEntityAdapter<TUser>;
    function AUser: TUser;
    procedure Advance(const ASeconds: Double);
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    { Records }
    [Test] procedure Put_ThenGet_RoundTripsARecord;
    [Test] procedure Put_WritesJsonTheStoreCanBeReadDirectly;
    [Test] procedure Get_Missing_GivesAnEmptyRecord;
    [Test] procedure TryGet_SaysWhetherItWasThere;
    [Test] procedure GetDef_AnswersWithTheGivenValue;
    [Test] procedure Exists_DoesNotDeserialize;
    [Test] procedure Delete_Removes;

    { Classes }
    [Test] procedure Put_ThenGet_RoundTripsAClass;
    [Test] procedure EachRead_BuildsANewInstance;
    [Test] procedure Nil_RoundTripsAsNil;

    { Collections, TTL and the store underneath }
    [Test] procedure TheAdapter_StaysInItsCollection;
    [Test] procedure Ttl_IsPassedThrough;
    [Test] procedure TryGetEntry_ReportsTheRemainingTtl;
    [Test] procedure TwoAdapters_ShareOneStore;
    [Test] procedure TheStore_StaysReachable;

    { Bulk }
    [Test] procedure PutMany_ThenGetMany_RoundTrip;
    [Test] procedure GetMany_MissesAreEmptyRecords;
    [Test] procedure GetMany_AStoredEmptyValueRaises;
    [Test] procedure PutMany_LengthMismatch_Raises;
    [Test] procedure DeleteMany_CountsWhatWent;

    { Misses and malformed values }
    [Test] procedure RaiseOnMissing_TurnsAMissIntoAnException;
    [Test] procedure RaiseOnMissing_LeavesTryGetAlone;
    [Test] procedure AValueThatIsNotAT_Raises;
    [Test] procedure AValueThatIsNotAT_NamesTheKeyNotTheValue;
    [Test] procedure AClassThatWillNotDecode_IsNotLeaked;
    [Test] procedure GetMany_ABadValue_FreesWhatWasAlreadyBuilt;
    [Test] procedure NilStore_Refused;
  end;

implementation

{ TTrackedOrder }

procedure TTrackedOrder.AfterConstruction;
begin
  inherited;
  AtomicIncrement(Live);
end;

procedure TTrackedOrder.BeforeDestruction;
begin
  AtomicDecrement(Live);
  inherited;
end;

{ TKVNeonAdapterTests }

procedure TKVNeonAdapterTests.Setup;
begin
  FNow := EncodeDate(2026, 1, 1) + EncodeTime(12, 0, 0, 0);
  FStore := TKVMemoryStore.Create(
    function: TDateTime
    begin
      Result := FNow;
    end);
  FUsers := TKVNeonAdapter<TUser>.Create(FStore, 'users');
end;

procedure TKVNeonAdapterTests.TearDown;
begin
  FUsers := nil;
  FStore := nil;
end;

procedure TKVNeonAdapterTests.Advance(const ASeconds: Double);
begin
  FNow := FNow + (ASeconds / SecsPerDay);
end;

function TKVNeonAdapterTests.AUser: TUser;
begin
  Result.Name := 'Alice';
  Result.Email := 'alice@example.com';
  Result.Age := 42;
  Result.Active := True;
end;

procedure TKVNeonAdapterTests.Put_ThenGet_RoundTripsARecord;
var
  LUser: TUser;
begin
  FUsers.Put('alice', AUser);

  LUser := FUsers.Get('alice');
  Assert.AreEqual('Alice', LUser.Name);
  Assert.AreEqual('alice@example.com', LUser.Email);
  Assert.AreEqual(42, LUser.Age);
  Assert.IsTrue(LUser.Active);
end;

procedure TKVNeonAdapterTests.Put_WritesJsonTheStoreCanBeReadDirectly;
var
  LRaw: string;
begin
  // The adapter is a convenience, not a container format: what it writes is
  // ordinary JSON that anything else can read out of the store.
  FUsers.Put('alice', AUser);

  LRaw := FStore.Get('alice', 'users');
  Assert.IsTrue(LRaw.Contains('"Name"'), LRaw);
  Assert.IsTrue(LRaw.Contains('Alice'), LRaw);
end;

procedure TKVNeonAdapterTests.Get_Missing_GivesAnEmptyRecord;
var
  LUser: TUser;
begin
  LUser := FUsers.Get('nobody');

  Assert.AreEqual('', LUser.Name);
  Assert.AreEqual(0, LUser.Age);
end;

procedure TKVNeonAdapterTests.TryGet_SaysWhetherItWasThere;
var
  LUser: TUser;
begin
  Assert.IsFalse(FUsers.TryGet('nobody', LUser));
  Assert.AreEqual('', LUser.Name);

  FUsers.Put('alice', AUser);
  Assert.IsTrue(FUsers.TryGet('alice', LUser));
  Assert.AreEqual('Alice', LUser.Name);
end;

procedure TKVNeonAdapterTests.GetDef_AnswersWithTheGivenValue;
var
  LFallback, LRead: TUser;
begin
  LFallback.Name := 'Nobody';

  LRead := FUsers.GetDef('nobody', LFallback);
  Assert.AreEqual('Nobody', LRead.Name);

  FUsers.Put('alice', AUser);
  Assert.AreEqual('Alice', FUsers.GetDef('alice', LFallback).Name);
end;

procedure TKVNeonAdapterTests.Exists_DoesNotDeserialize;
begin
  Assert.IsFalse(FUsers.Exists('alice'));

  // Something that is not a TUser at all: Exists must still answer, since it
  // never looks at the value.
  FStore.Put('alice', 'not a user', 'users');
  Assert.IsTrue(FUsers.Exists('alice'));
end;

procedure TKVNeonAdapterTests.Delete_Removes;
begin
  FUsers.Put('alice', AUser);

  Assert.IsTrue(FUsers.Delete('alice'));
  Assert.IsFalse(FUsers.Exists('alice'));
  Assert.IsFalse(FUsers.Delete('alice'));
end;

procedure TKVNeonAdapterTests.Put_ThenGet_RoundTripsAClass;
var
  LOrders: IKVEntityAdapter<TOrder>;
  LOrder: TOrder;
begin
  LOrders := TKVNeonAdapter<TOrder>.Create(FStore, 'orders');

  LOrder := TOrder.Create;
  try
    LOrder.Reference := 'ORD-1';
    LOrder.Total := 19.95;
    LOrders.Put('1', LOrder);
  finally
    LOrder.Free;
  end;

  LOrder := LOrders.Get('1');
  try
    Assert.AreEqual('ORD-1', LOrder.Reference);
    Assert.AreEqual(Double(19.95), LOrder.Total, 0.001);
  finally
    LOrder.Free;
  end;
end;

procedure TKVNeonAdapterTests.EachRead_BuildsANewInstance;
var
  LOrders: IKVEntityAdapter<TOrder>;
  LWritten, LFirst, LSecond: TOrder;
begin
  // The ownership rule: a read hands over an instance the caller must free,
  // and never a reference to something the store still holds.
  LOrders := TKVNeonAdapter<TOrder>.Create(FStore, 'orders');

  LWritten := TOrder.Create;
  try
    LWritten.Reference := 'ORD-1';
    LOrders.Put('1', LWritten);
  finally
    LWritten.Free;
  end;

  LFirst := LOrders.Get('1');
  LSecond := LOrders.Get('1');
  try
    Assert.IsNotNull(LFirst);
    Assert.IsNotNull(LSecond);
    Assert.AreNotSame(LFirst, LSecond);
    Assert.AreEqual(LFirst.Reference, LSecond.Reference);
  finally
    LFirst.Free;
    LSecond.Free;
  end;
end;

procedure TKVNeonAdapterTests.Nil_RoundTripsAsNil;
var
  LOrders: IKVEntityAdapter<TOrder>;
begin
  LOrders := TKVNeonAdapter<TOrder>.Create(FStore, 'orders');
  LOrders.Put('1', nil);

  Assert.AreEqual('null', FStore.Get('1', 'orders'), 'stored as null');
  Assert.IsTrue(LOrders.Exists('1'), 'and it is still an entry');
  Assert.IsNull(LOrders.Get('1'));
end;

procedure TKVNeonAdapterTests.TheAdapter_StaysInItsCollection;
begin
  FUsers.Put('alice', AUser);

  Assert.AreNotEqual('', FStore.Get('alice', 'users'));
  Assert.AreEqual('', FStore.Get('alice'), 'not in the default collection');
end;

procedure TKVNeonAdapterTests.Ttl_IsPassedThrough;
begin
  FUsers.Put('alice', AUser, 60);

  Advance(30);
  Assert.IsTrue(FUsers.Exists('alice'));

  Advance(60);
  Assert.IsFalse(FUsers.Exists('alice'));
  Assert.AreEqual('', FUsers.Get('alice').Name);
end;

procedure TKVNeonAdapterTests.TryGetEntry_ReportsTheRemainingTtl;
var
  LUser: TUser;
  LEntry: TKVEntry;
begin
  FUsers.Put('alice', AUser, 60);
  Advance(20);

  Assert.IsTrue(FUsers.TryGetEntry('alice', LUser, LEntry));
  Assert.AreEqual('Alice', LUser.Name);
  Assert.AreEqual(Double(40), Double(LEntry.TTLRemainingAt(FNow)), 0.001);
end;

procedure TKVNeonAdapterTests.TwoAdapters_ShareOneStore;
var
  LOrders: IKVEntityAdapter<TOrder>;
  LOrder: TOrder;
begin
  // Different types, different collections, one store underneath.
  LOrders := TKVNeonAdapter<TOrder>.Create(FStore, 'orders');

  FUsers.Put('alice', AUser);
  LOrder := TOrder.Create;
  try
    LOrder.Reference := 'ORD-1';
    LOrders.Put('1', LOrder);
  finally
    LOrder.Free;
  end;

  Assert.AreEqual('Alice', FUsers.Get('alice').Name);
  LOrder := LOrders.Get('1');
  try
    Assert.AreEqual('ORD-1', LOrder.Reference);
  finally
    LOrder.Free;
  end;
end;

procedure TKVNeonAdapterTests.TheStore_StaysReachable;
var
  LCullable: IKeyValueCullable;
begin
  // The adapter covers the typed calls; everything else is still the store's.
  Assert.AreSame(TObject(FStore), TObject(FUsers.Store));
  Assert.AreEqual('users', FUsers.Collection);
  Assert.IsTrue(Supports(FUsers.Store, IKeyValueCullable, LCullable));
end;

procedure TKVNeonAdapterTests.PutMany_ThenGetMany_RoundTrip;
var
  LBob: TUser;
  LRead: TArray<TUser>;
begin
  LBob.Name := 'Bob';

  FUsers.PutMany(['alice', 'bob'], [AUser, LBob]);

  LRead := FUsers.GetMany(['alice', 'bob']);
  Assert.AreEqual(2, Length(LRead));
  Assert.AreEqual('Alice', LRead[0].Name);
  Assert.AreEqual('Bob', LRead[1].Name);
end;

procedure TKVNeonAdapterTests.GetMany_MissesAreEmptyRecords;
var
  LRead: TArray<TUser>;
begin
  FUsers.Put('alice', AUser);

  LRead := FUsers.GetMany(['alice', 'nobody']);
  Assert.AreEqual(2, Length(LRead));
  Assert.AreEqual('Alice', LRead[0].Name);
  Assert.AreEqual('', LRead[1].Name);
end;

procedure TKVNeonAdapterTests.GetMany_AStoredEmptyValueRaises;
begin
  // An empty string is not a T, and the single-key calls already say so; the
  // bulk read must not quietly turn it into an empty record.
  FStore.Put('alice', '', 'users');

  Assert.WillRaise(
    procedure
    begin
      FUsers.GetMany(['alice']);
    end, EKVSerializationError);
end;

procedure TKVNeonAdapterTests.PutMany_LengthMismatch_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FUsers.PutMany(['alice', 'bob'], [AUser]);
    end, EKVArgumentError);
end;

procedure TKVNeonAdapterTests.DeleteMany_CountsWhatWent;
var
  LBob: TUser;
begin
  LBob.Name := 'Bob';
  FUsers.PutMany(['alice', 'bob'], [AUser, LBob]);

  Assert.AreEqual(2, FUsers.DeleteMany(['alice', 'bob', 'nobody']));
end;

procedure TKVNeonAdapterTests.RaiseOnMissing_TurnsAMissIntoAnException;
begin
  FUsers.RaiseOnMissing := True;

  Assert.WillRaise(
    procedure
    begin
      FUsers.Get('nobody');
    end, EKVNotFoundError);

  FUsers.Put('alice', AUser);
  Assert.AreEqual('Alice', FUsers.Get('alice').Name, 'a hit is unaffected');
end;

procedure TKVNeonAdapterTests.RaiseOnMissing_LeavesTryGetAlone;
var
  LUser: TUser;
begin
  // Asking whether something is there is never the mistake the flag is for.
  FUsers.RaiseOnMissing := True;

  Assert.IsFalse(FUsers.TryGet('nobody', LUser));
  Assert.AreEqual(2, Length(FUsers.GetMany(['nobody', 'nobody-else'])));
end;

procedure TKVNeonAdapterTests.AValueThatIsNotAT_Raises;
begin
  // Corruption, or a type that has moved on. Answering with an empty record
  // would pass it off as data.
  FStore.Put('alice', 'this is not JSON at all', 'users');

  Assert.WillRaise(
    procedure
    begin
      FUsers.Get('alice');
    end, EKVSerializationError);
end;

procedure TKVNeonAdapterTests.AValueThatIsNotAT_NamesTheKeyNotTheValue;
var
  LMessage: string;
begin
  // The key and collection say where to look. The value stays out: it can be
  // large, and it can be somebody's personal data.
  FStore.Put('alice', 'secret-payload, not JSON', 'users');

  LMessage := '';
  try
    FUsers.Get('alice');
  except
    on E: EKVSerializationError do
      LMessage := E.Message;
  end;

  Assert.IsTrue(LMessage.Contains('"alice"'), LMessage);
  Assert.IsTrue(LMessage.Contains('"users"'), LMessage);
  Assert.IsTrue(LMessage.Contains('TUser'), LMessage);
  Assert.IsFalse(LMessage.Contains('secret-payload'), LMessage);
end;

procedure TKVNeonAdapterTests.AClassThatWillNotDecode_IsNotLeaked;
var
  LOrders: IKVEntityAdapter<TTrackedOrder>;
  LLive: Integer;
begin
  // Well-formed JSON that is not an object: it parses, so the instance is
  // built, and only then does the filling fail. The instance must not outlive
  // the failure. (A member of the wrong type would not do: Neon logs that and
  // carries on.)
  LOrders := TKVNeonAdapter<TTrackedOrder>.Create(FStore, 'orders');
  FStore.Put('1', '42', 'orders');
  LLive := TTrackedOrder.Live;

  Assert.WillRaise(
    procedure
    begin
      LOrders.Get('1');
    end, EKVSerializationError);
  Assert.AreEqual(LLive, TTrackedOrder.Live, 'no instance left behind');
end;

procedure TKVNeonAdapterTests.GetMany_ABadValue_FreesWhatWasAlreadyBuilt;
var
  LOrders: IKVEntityAdapter<TTrackedOrder>;
  LOrder: TTrackedOrder;
  LLive: Integer;
begin
  // The caller never receives the array, so the instances built for the keys
  // before the bad one have to be freed by the adapter.
  LOrders := TKVNeonAdapter<TTrackedOrder>.Create(FStore, 'orders');

  LOrder := TTrackedOrder.Create;
  try
    LOrder.Reference := 'ORD-1';
    LOrders.PutMany(['1', '2'], [LOrder, LOrder]);
  finally
    LOrder.Free;
  end;
  FStore.Put('3', 'not an order', 'orders');
  LLive := TTrackedOrder.Live;

  Assert.WillRaise(
    procedure
    begin
      LOrders.GetMany(['1', '2', '3']);
    end, EKVSerializationError);
  Assert.AreEqual(LLive, TTrackedOrder.Live, 'the two good reads were freed');
end;

procedure TKVNeonAdapterTests.NilStore_Refused;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVNeonAdapter<TUser>.Create(nil);
    end, EKVArgumentError);
end;

initialization
  TDUnitX.RegisterTestFixture(TKVNeonAdapterTests);

end.
