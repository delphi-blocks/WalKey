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
///   The contract, as tests. Every IKeyValue implementation - store or
///   wrapper - gets its correctness from here: descend from
///   TKVConformanceTests, mark the descendant [TestFixture], implement
///   CreateStore, and the whole suite runs against the new implementation.
///
///   Time is injected, so nothing here sleeps: the fixture owns "now" and the
///   store reads it through the clock it was built with.
/// </summary>
unit WalKey.Tests.Conformance;

interface

uses
  System.SysUtils, System.DateUtils, System.Classes, System.SyncObjs,
  System.Generics.Collections,
  DUnitX.TestFramework,
  WalKey.Core;

type
  /// <summary>
  ///   Collects what a watch reports, from whatever thread reports it, and
  ///   lets a test wait for a key to turn up. A store may report a moment
  ///   after the write - NATS does - so waiting is part of the contract, not
  ///   a sleep in disguise.
  /// </summary>
  TKVChangeLog = class
  private
    FLock: TCriticalSection;
    FKeys: TList<string>;
    FChanged: TEvent;
    procedure Add(const AKey: string);
  public
    constructor Create;
    destructor Destroy; override;
    /// <summary>
    ///   The handler to give a watch. Release the watch before the log.
    /// </summary>
    function Handler: TKVChangeProc;
    /// <summary>
    ///   Waits until AKey has been reported; False if it is not, in the time
    ///   allowed.
    /// </summary>
    function WaitFor(const AKey: string; const ATimeoutMs: Cardinal = 5000): Boolean;
    function Contains(const AKey: string): Boolean;
    function Count: Integer;
  end;

  TKVConformanceTests = class abstract
  private
    FNow: TDateTime;
    FStore: IKeyValue;
  protected
    /// <summary>
    ///   Builds the implementation under test, reading time from AClock.
    /// </summary>
    /// <param name="AClock">The fixture clock the store must read "now" from</param>
    function CreateStore(const AClock: TKVClock): IKeyValue; virtual; abstract;
    /// <summary>
    ///   Runs before the store is built, for whatever it needs to exist first
    ///   - a scratch folder, a connection. The base does nothing.
    /// </summary>
    procedure SetupStore; virtual;
    /// <summary>
    ///   Runs after the store has been released, to undo SetupStore. The base
    ///   does nothing.
    /// </summary>
    procedure TearDownStore; virtual;
    /// <summary>
    ///   Moves the fixture clock forward. Nothing sleeps.
    /// </summary>
    /// <param name="ASeconds">How far to move "now" ahead</param>
    procedure Advance(const ASeconds: Double);
    /// <summary>
    ///   The implementation under test, rebuilt before each test.
    /// </summary>
    property Store: IKeyValue read FStore;
    /// <summary>
    ///   What the store currently reads as "now", in UTC.
    /// </summary>
    property Now: TDateTime read FNow;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    { Reading and writing }
    [Test] procedure Get_Missing_ReturnsEmptyString;
    [Test] procedure TryGet_Missing_ReturnsFalse;
    [Test] procedure PutThenGet_RoundTrips;
    [Test] procedure Put_Twice_Overwrites;
    [Test] procedure Exists_ReflectsPresence;
    [Test] procedure Delete_Existing_ReturnsTrue;
    [Test] procedure Delete_Missing_ReturnsFalse;
    [Test] procedure Delete_Removes;

    { Collections }
    [Test] procedure Collections_AreIsolated;
    [Test] procedure EmptyCollection_MeansTheDefaultCollection;
    [Test] procedure CollectionView_BindsTheCollection;
    [Test] procedure CollectionView_IgnoresACollectionArgument;
    [Test] procedure CollectionView_EmptyName_BindsTheDefaultCollection;

    { Expiry }
    [Test] procedure Ttl_BeforeExpiry_ValueIsReadable;
    [Test] procedure Ttl_AtExpiry_ValueIsGone;
    [Test] procedure Ttl_AfterExpiry_StaysGone;
    [Test] procedure Ttl_Zero_MeansNoExpiry;
    [Test] procedure Ttl_Negative_Raises;
    [Test] procedure Ttl_Expired_DeleteReportsNothingRemoved;
    [Test] procedure TryGetEntry_ReportsRemainingTtl;
    [Test] procedure TryGetEntry_WithoutTtl_ReportsNoExpiry;
    [Test] procedure Put_RefreshesTheExpiry;

    { Bulk }
    [Test] procedure GetMany_ReturnsValuesInOrder;
    [Test] procedure GetMany_MissingKeys_AreEmptyStrings;
    [Test] procedure GetMany_NoKeys_ReturnsNothing;
    [Test] procedure PutMany_StoresAll;
    [Test] procedure PutMany_LengthMismatch_Raises;
    [Test] procedure DeleteMany_ReturnsTheDeletedCount;

    { Keys, collection names and values }
    [Test] procedure Key_Empty_Raises;
    [Test] procedure Key_TooLong_Raises;
    [Test] procedure Key_WithControlCharacter_Raises;
    [Test] procedure Key_AtTheLengthLimit_IsAccepted;
    [Test] procedure Collection_WithControlCharacter_Raises;
    [Test] procedure Value_Empty_IsNotAMiss;
    [Test] procedure Value_Unicode_RoundTrips;
    [Test] procedure Value_Large_RoundTrips;

    { Optional capabilities - skipped by a store that does not offer them }
    [Test] procedure Enumerable_ListsLiveKeys;
    [Test] procedure Enumerable_ListsCollections;
    [Test] procedure Cullable_RemovesExpiredEntries;
    [Test] procedure Destroyable_DropsOneCollection;
    [Test] procedure Destroyable_DropsEverything;
    [Test] procedure Watchable_ReportsAPut;
    [Test] procedure Watchable_ReportsADelete;
    [Test] procedure Watchable_ReportsTheKeyAsWritten;
    [Test] procedure Watchable_EmptyCollection_WatchesTheDefaultOne;
    [Test] procedure Watchable_IgnoresOtherCollections;
    [Test] procedure Watchable_StopsWhenReleased;
    [Test] procedure Watchable_NilHandler_Raises;
    [Test] procedure Watchable_InvalidCollection_Raises;
  end;

implementation

const
  VALUE_A = '{"name":"Alice"}';
  VALUE_B = '{"name":"Bob"}';

{ TKVChangeLog }

constructor TKVChangeLog.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FKeys := TList<string>.Create;
  FChanged := TEvent.Create(nil, False, False, '');
end;

destructor TKVChangeLog.Destroy;
begin
  FChanged.Free;
  FKeys.Free;
  FLock.Free;
  inherited;
end;

procedure TKVChangeLog.Add(const AKey: string);
begin
  FLock.Enter;
  try
    FKeys.Add(AKey);
  finally
    FLock.Leave;
  end;
  FChanged.SetEvent;
end;

function TKVChangeLog.Handler: TKVChangeProc;
begin
  Result :=
    procedure (const AKey: string)
    begin
      Add(AKey);
    end;
end;

function TKVChangeLog.Contains(const AKey: string): Boolean;
begin
  FLock.Enter;
  try
    Result := FKeys.Contains(AKey);
  finally
    FLock.Leave;
  end;
end;

function TKVChangeLog.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FKeys.Count;
  finally
    FLock.Leave;
  end;
end;

function TKVChangeLog.WaitFor(const AKey: string; const ATimeoutMs: Cardinal): Boolean;
var
  LDeadline: UInt64;
  LNow: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + ATimeoutMs;
  repeat
    if Contains(AKey) then
      Exit(True);
    LNow := TThread.GetTickCount64;
    if LNow >= LDeadline then
      Exit(False);
    FChanged.WaitFor(Cardinal(LDeadline - LNow));
  until False;
end;

{ TKVConformanceTests }

procedure TKVConformanceTests.SetupStore;
begin
  // Nothing by default.
end;

procedure TKVConformanceTests.TearDownStore;
begin
  // Nothing by default.
end;

procedure TKVConformanceTests.Setup;
begin
  FNow := EncodeDate(2026, 1, 1) + EncodeTime(12, 0, 0, 0);
  SetupStore;
  FStore := CreateStore(
    function: TDateTime
    begin
      Result := FNow;
    end);
end;

procedure TKVConformanceTests.TearDown;
begin
  FStore := nil;
  TearDownStore;
end;

procedure TKVConformanceTests.Advance(const ASeconds: Double);
begin
  FNow := FNow + (ASeconds / SecsPerDay);
end;

procedure TKVConformanceTests.Get_Missing_ReturnsEmptyString;
begin
  Assert.AreEqual('', Store.Get('nope'));
end;

procedure TKVConformanceTests.TryGet_Missing_ReturnsFalse;
var
  LValue: string;
begin
  Assert.IsFalse(Store.TryGet('nope', LValue));
  Assert.AreEqual('', LValue);
end;

procedure TKVConformanceTests.PutThenGet_RoundTrips;
begin
  Store.Put('a', VALUE_A);
  Assert.AreEqual(VALUE_A, Store.Get('a'));
end;

procedure TKVConformanceTests.Put_Twice_Overwrites;
begin
  Store.Put('a', VALUE_A);
  Store.Put('a', VALUE_B);
  Assert.AreEqual(VALUE_B, Store.Get('a'));
end;

procedure TKVConformanceTests.Exists_ReflectsPresence;
begin
  Assert.IsFalse(Store.Exists('a'));
  Store.Put('a', VALUE_A);
  Assert.IsTrue(Store.Exists('a'));
  Store.Delete('a');
  Assert.IsFalse(Store.Exists('a'));
end;

procedure TKVConformanceTests.Delete_Existing_ReturnsTrue;
begin
  Store.Put('a', VALUE_A);
  Assert.IsTrue(Store.Delete('a'));
end;

procedure TKVConformanceTests.Delete_Missing_ReturnsFalse;
begin
  Assert.IsFalse(Store.Delete('nope'));
end;

procedure TKVConformanceTests.Delete_Removes;
begin
  Store.Put('a', VALUE_A);
  Store.Delete('a');
  Assert.AreEqual('', Store.Get('a'));
end;

procedure TKVConformanceTests.Collections_AreIsolated;
begin
  Store.Put('a', VALUE_A, 'one');
  Store.Put('a', VALUE_B, 'two');

  Assert.AreEqual(VALUE_A, Store.Get('a', 'one'));
  Assert.AreEqual(VALUE_B, Store.Get('a', 'two'));
  Assert.AreEqual('', Store.Get('a'), 'the default collection is a collection too');
end;

procedure TKVConformanceTests.EmptyCollection_MeansTheDefaultCollection;
begin
  Store.Put('a', VALUE_A, '');
  Assert.AreEqual(VALUE_A, Store.Get('a', KV_DEFAULT_COLLECTION));
end;

procedure TKVConformanceTests.CollectionView_BindsTheCollection;
var
  LUsers: IKeyValue;
begin
  LUsers := Store.Collection('users');
  LUsers.Put('a', VALUE_A);

  Assert.AreEqual(VALUE_A, Store.Get('a', 'users'));
  Assert.AreEqual('', Store.Get('a'));
  Assert.AreEqual(VALUE_A, LUsers.Get('a'));
end;

procedure TKVConformanceTests.CollectionView_IgnoresACollectionArgument;
var
  LUsers: IKeyValue;
begin
  LUsers := Store.Collection('users');
  LUsers.Put('a', VALUE_A, 'somewhere-else');

  Assert.AreEqual(VALUE_A, Store.Get('a', 'users'));
  Assert.AreEqual('', Store.Get('a', 'somewhere-else'));
end;

procedure TKVConformanceTests.CollectionView_EmptyName_BindsTheDefaultCollection;
var
  LDefault: IKeyValue;
begin
  // '' is the default collection everywhere else, so it is a usable binding
  // too, and the binding wins like any other.
  LDefault := Store.Collection('');
  LDefault.Put('a', VALUE_A);

  Assert.AreEqual(VALUE_A, Store.Get('a'));
  Assert.AreEqual(VALUE_A, Store.Get('a', KV_DEFAULT_COLLECTION));

  LDefault.Put('a', VALUE_B, 'somewhere-else');
  Assert.AreEqual(VALUE_B, Store.Get('a'), 'the binding still wins');
  Assert.AreEqual('', Store.Get('a', 'somewhere-else'));
end;

procedure TKVConformanceTests.Ttl_BeforeExpiry_ValueIsReadable;
begin
  Store.Put('a', VALUE_A, '', 60);
  Advance(59);
  Assert.AreEqual(VALUE_A, Store.Get('a'));
end;

procedure TKVConformanceTests.Ttl_AtExpiry_ValueIsGone;
begin
  Store.Put('a', VALUE_A, '', 60);
  Advance(60);
  Assert.AreEqual('', Store.Get('a'));
end;

procedure TKVConformanceTests.Ttl_AfterExpiry_StaysGone;
begin
  Store.Put('a', VALUE_A, '', 60);
  Advance(120);

  Assert.AreEqual('', Store.Get('a'), 'first read');
  Assert.AreEqual('', Store.Get('a'), 'second read, after the entry was dropped');
  Assert.IsFalse(Store.Exists('a'));
end;

procedure TKVConformanceTests.Ttl_Zero_MeansNoExpiry;
begin
  Store.Put('a', VALUE_A, '', KV_NO_TTL);
  Advance(365 * 24 * 60 * 60);
  Assert.AreEqual(VALUE_A, Store.Get('a'));
end;

procedure TKVConformanceTests.Ttl_Negative_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      Store.Put('a', VALUE_A, '', -1);
    end, EKVArgumentError);
end;

procedure TKVConformanceTests.Ttl_Expired_DeleteReportsNothingRemoved;
begin
  Store.Put('a', VALUE_A, '', 60);
  Advance(120);
  Assert.IsFalse(Store.Delete('a'), 'an expired entry is already gone');
end;

procedure TKVConformanceTests.TryGetEntry_ReportsRemainingTtl;
var
  LEntry: TKVEntry;
begin
  Store.Put('a', VALUE_A, '', 60);
  Advance(20);

  Assert.IsTrue(Store.TryGetEntry('a', '', LEntry));
  Assert.AreEqual(VALUE_A, LEntry.Value);
  Assert.AreEqual(Double(40), Double(LEntry.TTLRemainingAt(Now)), 0.001);
end;

procedure TKVConformanceTests.TryGetEntry_WithoutTtl_ReportsNoExpiry;
var
  LEntry: TKVEntry;
begin
  Store.Put('a', VALUE_A);

  Assert.IsTrue(Store.TryGetEntry('a', '', LEntry));
  Assert.IsFalse(LEntry.HasExpiry);
  Assert.AreEqual(Double(KV_NO_EXPIRY), Double(LEntry.TTLRemainingAt(Now)), 0.001);
end;

procedure TKVConformanceTests.Put_RefreshesTheExpiry;
begin
  Store.Put('a', VALUE_A, '', 60);
  Advance(50);
  Store.Put('a', VALUE_B, '', 60);
  Advance(50);

  Assert.AreEqual(VALUE_B, Store.Get('a'), 'the second Put restarted the clock');
end;

procedure TKVConformanceTests.GetMany_ReturnsValuesInOrder;
var
  LValues: TArray<string>;
begin
  Store.Put('a', VALUE_A);
  Store.Put('b', VALUE_B);

  LValues := Store.GetMany(['b', 'a']);

  Assert.AreEqual(2, Length(LValues));
  Assert.AreEqual(VALUE_B, LValues[0]);
  Assert.AreEqual(VALUE_A, LValues[1]);
end;

procedure TKVConformanceTests.GetMany_MissingKeys_AreEmptyStrings;
var
  LValues: TArray<string>;
begin
  Store.Put('a', VALUE_A);

  LValues := Store.GetMany(['a', 'nope']);

  Assert.AreEqual(2, Length(LValues));
  Assert.AreEqual(VALUE_A, LValues[0]);
  Assert.AreEqual('', LValues[1]);
end;

procedure TKVConformanceTests.GetMany_NoKeys_ReturnsNothing;
begin
  Assert.AreEqual(0, Length(Store.GetMany([])));
end;

procedure TKVConformanceTests.PutMany_StoresAll;
begin
  Store.PutMany(['a', 'b'], [VALUE_A, VALUE_B], 'users');

  Assert.AreEqual(VALUE_A, Store.Get('a', 'users'));
  Assert.AreEqual(VALUE_B, Store.Get('b', 'users'));
end;

procedure TKVConformanceTests.PutMany_LengthMismatch_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      Store.PutMany(['a', 'b'], [VALUE_A]);
    end, EKVArgumentError);
end;

procedure TKVConformanceTests.DeleteMany_ReturnsTheDeletedCount;
begin
  Store.Put('a', VALUE_A);
  Store.Put('b', VALUE_B);

  Assert.AreEqual(2, Store.DeleteMany(['a', 'b', 'nope']));
  Assert.IsFalse(Store.Exists('a'));
  Assert.IsFalse(Store.Exists('b'));
end;

procedure TKVConformanceTests.Key_Empty_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      Store.Put('', VALUE_A);
    end, EKVInvalidKeyError);
end;

procedure TKVConformanceTests.Key_TooLong_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      Store.Put(StringOfChar('k', KV_MAX_KEY_LENGTH + 1), VALUE_A);
    end, EKVInvalidKeyError);
end;

procedure TKVConformanceTests.Key_WithControlCharacter_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      Store.Put('a' + #10 + 'b', VALUE_A);
    end, EKVInvalidKeyError);
end;

procedure TKVConformanceTests.Key_AtTheLengthLimit_IsAccepted;
var
  LKey: string;
begin
  LKey := StringOfChar('k', KV_MAX_KEY_LENGTH);
  Store.Put(LKey, VALUE_A);
  Assert.AreEqual(VALUE_A, Store.Get(LKey));
end;

procedure TKVConformanceTests.Collection_WithControlCharacter_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      Store.Put('a', VALUE_A, 'one' + #9);
    end, EKVInvalidCollectionError);
end;

procedure TKVConformanceTests.Value_Empty_IsNotAMiss;
var
  LValue: string;
begin
  Store.Put('a', '');

  Assert.IsTrue(Store.TryGet('a', LValue), 'an empty value is still a value');
  Assert.AreEqual('', LValue);
  Assert.IsTrue(Store.Exists('a'));
end;

procedure TKVConformanceTests.Value_Unicode_RoundTrips;
var
  LValue: string;
begin
  // Written as escapes so the source stays plain ASCII: e-acute, a CJK
  // ideograph, an emoji as a surrogate pair.
  LValue := '{"name":"' + #$00E9 + #$4E2D + #$D83D + #$DE00 + '"}';

  Store.Put('a', LValue);
  Assert.AreEqual(LValue, Store.Get('a'));
end;

procedure TKVConformanceTests.Value_Large_RoundTrips;
var
  LValue: string;
begin
  LValue := '{"blob":"' + StringOfChar('x', 1024 * 512) + '"}';

  Store.Put('a', LValue);
  Assert.AreEqual(LValue, Store.Get('a'));
end;

procedure TKVConformanceTests.Enumerable_ListsLiveKeys;
var
  LEnumerable: IKeyValueEnumerable;
  LKeys: TArray<string>;
begin
  if not Supports(Store, IKeyValueEnumerable, LEnumerable) then
    Exit;

  Store.Put('a', VALUE_A, 'users');
  Store.Put('b', VALUE_B, 'users', 60);
  Store.Put('c', VALUE_B, 'other');

  Assert.AreEqual(2, Length(LEnumerable.Keys('users')));

  Advance(120);
  LKeys := LEnumerable.Keys('users');
  Assert.AreEqual(1, Length(LKeys), 'the expired key is not a live key');
  Assert.AreEqual('a', LKeys[0]);
end;

procedure TKVConformanceTests.Enumerable_ListsCollections;
var
  LEnumerable: IKeyValueEnumerable;
begin
  if not Supports(Store, IKeyValueEnumerable, LEnumerable) then
    Exit;

  Store.Put('a', VALUE_A, 'one');
  Store.Put('a', VALUE_A, 'two');

  Assert.AreEqual(2, Length(LEnumerable.Collections));
end;

procedure TKVConformanceTests.Cullable_RemovesExpiredEntries;
var
  LCullable: IKeyValueCullable;
begin
  if not Supports(Store, IKeyValueCullable, LCullable) then
    Exit;

  Store.Put('a', VALUE_A);
  Store.Put('b', VALUE_B, '', 60);
  Store.Put('c', VALUE_B, 'other', 60);

  Assert.AreEqual(0, LCullable.Cull, 'nothing has expired yet');

  Advance(120);
  Assert.AreEqual(2, LCullable.Cull);
  Assert.AreEqual(0, LCullable.Cull, 'a second sweep finds nothing left');
  Assert.AreEqual(VALUE_A, Store.Get('a'), 'the live entry survived');
end;

procedure TKVConformanceTests.Destroyable_DropsOneCollection;
var
  LDestroyable: IKeyValueDestroyable;
begin
  if not Supports(Store, IKeyValueDestroyable, LDestroyable) then
    Exit;

  Store.Put('a', VALUE_A, 'one');
  Store.Put('a', VALUE_B, 'two');

  Assert.IsTrue(LDestroyable.DestroyCollection('one'));
  Assert.AreEqual('', Store.Get('a', 'one'));
  Assert.AreEqual(VALUE_B, Store.Get('a', 'two'));
  Assert.IsFalse(LDestroyable.DestroyCollection('one'), 'already gone');
end;

procedure TKVConformanceTests.Destroyable_DropsEverything;
var
  LDestroyable: IKeyValueDestroyable;
begin
  if not Supports(Store, IKeyValueDestroyable, LDestroyable) then
    Exit;

  Store.Put('a', VALUE_A, 'one');
  Store.Put('a', VALUE_B, 'two');

  LDestroyable.DestroyAll;

  Assert.AreEqual('', Store.Get('a', 'one'));
  Assert.AreEqual('', Store.Get('a', 'two'));
end;

{ A store may need a collection to exist before it can watch it - NATS has no
  bucket to watch until the first write - so each watch test writes a seed
  entry first. }

procedure TKVConformanceTests.Watchable_ReportsAPut;
var
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Store.Put('seed', VALUE_A, 'watched');
  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('watched', LLog.Handler());
    try
      Assert.IsTrue(LWatch.IsLive);
      Store.Put('a', VALUE_A, 'watched');
      Assert.IsTrue(LLog.WaitFor('a'), 'the put is reported');
      Assert.IsFalse(LLog.Contains('seed'), 'what was there before is not a change');
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVConformanceTests.Watchable_ReportsADelete;
var
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Store.Put('a', VALUE_A, 'watched');
  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('watched', LLog.Handler());
    try
      Assert.IsTrue(Store.Delete('a', 'watched'));
      Assert.IsTrue(LLog.WaitFor('a'), 'the delete is reported');
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVConformanceTests.Watchable_ReportsTheKeyAsWritten;
const
  ODD_KEY = 'a key/with: odd.chars*>';
var
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Store.Put('seed', VALUE_A, 'watched');
  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('watched', LLog.Handler());
    try
      Store.Put(ODD_KEY, VALUE_A, 'watched');
      Assert.IsTrue(LLog.WaitFor(ODD_KEY),
        'a key the backend has to encode is reported as the caller wrote it');
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVConformanceTests.Watchable_EmptyCollection_WatchesTheDefaultOne;
var
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Store.Put('seed', VALUE_A);
  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('', LLog.Handler());
    try
      Store.Put('a', VALUE_A);
      Assert.IsTrue(LLog.WaitFor('a'));
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVConformanceTests.Watchable_IgnoresOtherCollections;
var
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Store.Put('seed', VALUE_A, 'watched');
  Store.Put('seed', VALUE_A, 'other');
  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('watched', LLog.Handler());
    try
      Store.Put('x', VALUE_A, 'other');
      Store.Put('y', VALUE_A, 'watched');
      Assert.IsTrue(LLog.WaitFor('y'));
      Assert.IsFalse(LLog.Contains('x'), 'a write to another collection is not reported');
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVConformanceTests.Watchable_StopsWhenReleased;
var
  LWatchable: IKeyValueWatchable;
  LStopped, LRunning: TKVChangeLog;
  LFirst, LSecond: IKVWatch;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Store.Put('seed', VALUE_A, 'watched');
  LStopped := TKVChangeLog.Create;
  LRunning := TKVChangeLog.Create;
  try
    LFirst := LWatchable.Watch('watched', LStopped.Handler());
    LSecond := LWatchable.Watch('watched', LRunning.Handler());
    try
      LFirst := nil;
      Store.Put('a', VALUE_A, 'watched');

      // The watch still running is the proof that the change went out at all.
      Assert.IsTrue(LRunning.WaitFor('a'));
      Assert.AreEqual(0, LStopped.Count, 'a released watch reports nothing');
    finally
      LFirst := nil;
      LSecond := nil;
    end;
  finally
    LRunning.Free;
    LStopped.Free;
  end;
end;

procedure TKVConformanceTests.Watchable_NilHandler_Raises;
var
  LWatchable: IKeyValueWatchable;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Assert.WillRaise(
    procedure
    var
      LWatch: IKVWatch;
    begin
      LWatch := LWatchable.Watch('watched', nil);
    end, EKVArgumentError);
end;

procedure TKVConformanceTests.Watchable_InvalidCollection_Raises;
var
  LWatchable: IKeyValueWatchable;
begin
  if not Supports(Store, IKeyValueWatchable, LWatchable) then
    Exit;

  Assert.WillRaise(
    procedure
    var
      LWatch: IKVWatch;
    begin
      LWatch := LWatchable.Watch('bad'#1,
        procedure (const AKey: string)
        begin
        end);
    end, EKVInvalidCollectionError);
end;

end.
