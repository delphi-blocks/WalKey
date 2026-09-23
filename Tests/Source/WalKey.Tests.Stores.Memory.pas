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
///   The memory store against the shared contract, plus the handful of things
///   that are its own: the entry count, the default clock and thread safety.
/// </summary>
unit WalKey.Tests.Stores.Memory;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Threading,
  DUnitX.TestFramework,
  WalKey.Core, WalKey.Stores.Memory,
  WalKey.Tests.Conformance;

type
  [TestFixture]
  TKVMemoryStoreTests = class(TKVConformanceTests)
  private
    FMemory: TKVMemoryStore;
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  public
    [Test] procedure Count_CountsEveryCollection;
    [Test] procedure Count_StillCountsAnExpiredEntryUntilItIsTouched;
    [Test] procedure DefaultClock_IsUtcNow;
    [Test] procedure DefaultCollection_CanBeChanged;
    [Test] procedure DefaultCollection_Invalid_Raises;
    [Test] procedure PutMany_UsesOneClockReadForTheBatch;
    [Test] procedure ConcurrentWritesAndReads_DoNotCorruptTheStore;
  end;

implementation

const
  VALUE_A = '{"name":"Alice"}';

{ TKVMemoryStoreTests }

function TKVMemoryStoreTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  FMemory := TKVMemoryStore.Create(AClock);
  Result := FMemory;
end;

procedure TKVMemoryStoreTests.Count_CountsEveryCollection;
begin
  Store.Put('a', VALUE_A, 'one');
  Store.Put('b', VALUE_A, 'one');
  Store.Put('a', VALUE_A, 'two');

  Assert.AreEqual(3, FMemory.Count);
end;

procedure TKVMemoryStoreTests.Count_StillCountsAnExpiredEntryUntilItIsTouched;
begin
  Store.Put('a', VALUE_A, '', 60);
  Advance(120);

  Assert.AreEqual(1, FMemory.Count, 'expiry is lazy: nothing swept it yet');
  Store.Get('a');
  Assert.AreEqual(0, FMemory.Count, 'the read that found it expired dropped it');
end;

procedure TKVMemoryStoreTests.DefaultClock_IsUtcNow;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  // No clock injected: the store must fall back to the wall clock, in UTC.
  LStore := TKVMemoryStore.Create;
  LStore.Put('a', VALUE_A);

  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntry));
  Assert.AreEqual(Double(0), Double(LEntry.CreatedAt - TKVUtils.UtcNow), 1 / SecsPerDay);
end;

procedure TKVMemoryStoreTests.DefaultCollection_CanBeChanged;
begin
  FMemory.DefaultCollection := 'users';
  Store.Put('a', VALUE_A);

  Assert.AreEqual(VALUE_A, Store.Get('a', 'users'));
  Assert.AreEqual('', Store.Get('a', KV_DEFAULT_COLLECTION));
end;

procedure TKVMemoryStoreTests.DefaultCollection_Invalid_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      FMemory.DefaultCollection := '';
    end, EKVInvalidCollectionError);
end;

procedure TKVMemoryStoreTests.PutMany_UsesOneClockReadForTheBatch;
var
  LStore: IKeyValue;
  LCalls: Integer;
  LEntryA, LEntryB: TKVEntry;
  LBase: TDateTime;
begin
  LBase := EncodeDate(2026, 1, 1) + EncodeTime(12, 0, 0, 0);
  LCalls := 0;
  LStore := TKVMemoryStore.Create(
    function: TDateTime
    begin
      Inc(LCalls);
      Result := LBase + (LCalls / SecsPerDay);
    end);

  LStore.PutMany(['a', 'b'], [VALUE_A, VALUE_A]);

  Assert.AreEqual(1, LCalls, 'the whole batch reads the clock once');
  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntryA));
  Assert.IsTrue(LStore.TryGetEntry('b', '', LEntryB));
  Assert.IsTrue(LEntryA.CreatedAt = LEntryB.CreatedAt, 'one instant for the batch');
end;

procedure TKVMemoryStoreTests.ConcurrentWritesAndReads_DoNotCorruptTheStore;
const
  WORKERS = 4;
  PER_WORKER = 500;
var
  LMismatches: Integer;
begin
  // Asserting inside a worker would raise on a pool thread, so failures are
  // counted and reported here.
  LMismatches := 0;

  TParallel.For(0, WORKERS - 1,
    procedure(AWorker: Integer)
    var
      LItem: Integer;
      LKey, LWritten, LRead: string;
    begin
      for LItem := 0 to PER_WORKER - 1 do
      begin
        LKey := Format('w%d-k%d', [AWorker, LItem]);
        LWritten := Format('{"w":%d,"i":%d}', [AWorker, LItem]);

        Store.Put(LKey, LWritten, 'shared');
        if not Store.TryGet(LKey, 'shared', LRead) or (LRead <> LWritten) then
          TInterlocked.Increment(LMismatches);
      end;
    end);

  Assert.AreEqual(0, LMismatches, 'every worker read back what it wrote');
  Assert.AreEqual(WORKERS * PER_WORKER, FMemory.Count);
end;

initialization
  TDUnitX.RegisterTestFixture(TKVMemoryStoreTests);

end.
