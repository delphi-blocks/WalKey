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
///   The null store has a fixture of its own rather than the conformance one:
///   the shared suite asserts that a store hands back what was put into it,
///   which is the single promise this store is built to break.
///
///   What it must still honour is everything else - the shape of a miss, the
///   counts the bulk calls report, and the argument checking that makes it
///   safe to swap in for a real store. That is what is tested here.
/// </summary>
unit WalKey.Tests.Stores.Null;

interface

uses
  System.SysUtils,
  DUnitX.TestFramework,
  WalKey.Core, WalKey.Stores.Null;

type
  [TestFixture]
  TKVNullStoreTests = class
  private
    FStore: IKeyValue;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    { Nothing is kept }
    [Test] procedure Put_ThenGet_IsAMiss;
    [Test] procedure Put_ThenTryGet_ReportsAMiss;
    [Test] procedure Put_ThenTryGetEntry_ReportsAMiss;
    [Test] procedure Put_ThenExists_IsFalse;
    [Test] procedure Put_WithTtl_IsStillAMiss;
    [Test] procedure Delete_ReportsNothingRemoved;
    [Test] procedure CollectionView_DiscardsToo;

    { Bulk }
    [Test] procedure PutMany_ThenGetMany_IsAllMisses;
    [Test] procedure GetMany_KeepsTheShapeOfTheRequest;
    [Test] procedure DeleteMany_ReportsNothingRemoved;

    { Optional capabilities }
    [Test] procedure OffersEveryOptionalCapability;
    [Test] procedure Enumerable_ListsNothing;
    [Test] procedure Cullable_FindsNothingToCull;
    [Test] procedure Destroyable_FindsNothingToDrop;

    { Still a store: the arguments are policed the same way }
    [Test] procedure Key_Empty_Raises;
    [Test] procedure Key_TooLong_Raises;
    [Test] procedure Key_WithControlCharacter_Raises;
    [Test] procedure Collection_WithControlCharacter_Raises;
    [Test] procedure Ttl_Negative_Raises;
    [Test] procedure PutMany_LengthMismatch_Raises;
    [Test] procedure Keys_InvalidCollection_Raises;
  end;

implementation

const
  VALUE_A = '{"name":"Alice"}';
  VALUE_B = '{"name":"Bob"}';

{ TKVNullStoreTests }

procedure TKVNullStoreTests.Setup;
begin
  FStore := TKVNullStore.Create;
end;

procedure TKVNullStoreTests.TearDown;
begin
  FStore := nil;
end;

procedure TKVNullStoreTests.Put_ThenGet_IsAMiss;
begin
  FStore.Put('a', VALUE_A);
  Assert.AreEqual('', FStore.Get('a'));
end;

procedure TKVNullStoreTests.Put_ThenTryGet_ReportsAMiss;
var
  LValue: string;
begin
  FStore.Put('a', VALUE_A);

  Assert.IsFalse(FStore.TryGet('a', LValue));
  Assert.AreEqual('', LValue);
end;

procedure TKVNullStoreTests.Put_ThenTryGetEntry_ReportsAMiss;
var
  LEntry: TKVEntry;
begin
  FStore.Put('a', VALUE_A);
  Assert.IsFalse(FStore.TryGetEntry('a', '', LEntry));
end;

procedure TKVNullStoreTests.Put_ThenExists_IsFalse;
begin
  FStore.Put('a', VALUE_A);
  Assert.IsFalse(FStore.Exists('a'));
end;

procedure TKVNullStoreTests.Put_WithTtl_IsStillAMiss;
begin
  // A TTL is accepted and, like the value, goes nowhere.
  FStore.Put('a', VALUE_A, 'users', 3600);
  Assert.AreEqual('', FStore.Get('a', 'users'));
end;

procedure TKVNullStoreTests.Delete_ReportsNothingRemoved;
begin
  FStore.Put('a', VALUE_A);
  Assert.IsFalse(FStore.Delete('a'));
end;

procedure TKVNullStoreTests.CollectionView_DiscardsToo;
var
  LUsers: IKeyValue;
begin
  LUsers := FStore.Collection('users');
  LUsers.Put('a', VALUE_A);

  Assert.AreEqual('', LUsers.Get('a'));
  Assert.AreEqual('', FStore.Get('a', 'users'));
end;

procedure TKVNullStoreTests.PutMany_ThenGetMany_IsAllMisses;
var
  LValues: TArray<string>;
begin
  FStore.PutMany(['a', 'b'], [VALUE_A, VALUE_B]);

  LValues := FStore.GetMany(['a', 'b']);
  Assert.AreEqual('', LValues[0]);
  Assert.AreEqual('', LValues[1]);
end;

procedure TKVNullStoreTests.GetMany_KeepsTheShapeOfTheRequest;
var
  LValues: TArray<string>;
begin
  // One result per key asked for, exactly as a real store answers.
  LValues := FStore.GetMany(['a', 'b', 'c']);

  Assert.AreEqual(3, Length(LValues));
  Assert.AreEqual(0, Length(FStore.GetMany([])));
end;

procedure TKVNullStoreTests.DeleteMany_ReportsNothingRemoved;
begin
  FStore.PutMany(['a', 'b'], [VALUE_A, VALUE_B]);
  Assert.AreEqual(0, FStore.DeleteMany(['a', 'b']));
end;

procedure TKVNullStoreTests.OffersEveryOptionalCapability;
begin
  // Cheap to honour when there is nothing to hold, so the null store declares
  // all three rather than making a caller branch on Supports.
  Assert.IsTrue(Supports(FStore, IKeyValueEnumerable), 'IKeyValueEnumerable');
  Assert.IsTrue(Supports(FStore, IKeyValueCullable), 'IKeyValueCullable');
  Assert.IsTrue(Supports(FStore, IKeyValueDestroyable), 'IKeyValueDestroyable');
end;

procedure TKVNullStoreTests.Enumerable_ListsNothing;
var
  LEnumerable: IKeyValueEnumerable;
begin
  FStore.Put('a', VALUE_A, 'users');

  Assert.IsTrue(Supports(FStore, IKeyValueEnumerable, LEnumerable));
  Assert.AreEqual(0, Length(LEnumerable.Keys('users')));
  Assert.AreEqual(0, Length(LEnumerable.Collections), 'a write brings no collection into being');
end;

procedure TKVNullStoreTests.Cullable_FindsNothingToCull;
var
  LCullable: IKeyValueCullable;
begin
  FStore.Put('a', VALUE_A, '', 60);

  Assert.IsTrue(Supports(FStore, IKeyValueCullable, LCullable));
  Assert.AreEqual(0, LCullable.Cull);
end;

procedure TKVNullStoreTests.Destroyable_FindsNothingToDrop;
var
  LDestroyable: IKeyValueDestroyable;
begin
  FStore.Put('a', VALUE_A, 'users');

  Assert.IsTrue(Supports(FStore, IKeyValueDestroyable, LDestroyable));
  Assert.IsFalse(LDestroyable.DestroyCollection('users'), 'it never existed');
  LDestroyable.DestroyAll;
end;

procedure TKVNullStoreTests.Key_Empty_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FStore.Put('', VALUE_A);
    end, EKVInvalidKeyError);
end;

procedure TKVNullStoreTests.Key_TooLong_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FStore.Get(StringOfChar('k', KV_MAX_KEY_LENGTH + 1));
    end, EKVInvalidKeyError);
end;

procedure TKVNullStoreTests.Key_WithControlCharacter_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FStore.Delete('a' + #10 + 'b');
    end, EKVInvalidKeyError);
end;

procedure TKVNullStoreTests.Collection_WithControlCharacter_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FStore.Put('a', VALUE_A, 'one' + #9);
    end, EKVInvalidCollectionError);
end;

procedure TKVNullStoreTests.Ttl_Negative_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FStore.Put('a', VALUE_A, '', -1);
    end, EKVArgumentError);
end;

procedure TKVNullStoreTests.PutMany_LengthMismatch_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FStore.PutMany(['a', 'b'], [VALUE_A]);
    end, EKVArgumentError);
end;

procedure TKVNullStoreTests.Keys_InvalidCollection_Raises;
var
  LEnumerable: IKeyValueEnumerable;
begin
  Assert.IsTrue(Supports(FStore, IKeyValueEnumerable, LEnumerable));
  Assert.WillRaise(
    procedure
    begin
      LEnumerable.Keys('one' + #9);
    end, EKVInvalidCollectionError);
end;

initialization
  TDUnitX.RegisterTestFixture(TKVNullStoreTests);

end.
