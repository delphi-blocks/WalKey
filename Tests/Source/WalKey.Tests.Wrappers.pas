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
///   What each wrapper does that a bare store does not. That the transparent
///   ones stay transparent is settled elsewhere, by
///   WalKey.Tests.Wrappers.Conformance; this unit is about the behaviour that
///   is the point of having them.
/// </summary>
unit WalKey.Tests.Wrappers;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Threading,
  System.Generics.Collections,
  DUnitX.TestFramework,
  WalKey.Core, WalKey.Stores.Memory, WalKey.Stores.Null, WalKey.Wrappers,
  WalKey.Tests.Conformance;

type
  /// <summary>
  ///   A store that fails at everything, for testing what happens when a
  ///   store fails. Argument checking still runs first, since that lives in
  ///   TKVStoreBase - which is exactly the distinction the fallback wrapper
  ///   has to make.
  /// </summary>
  TKVFailingStore = class(TKVStoreBase)
  protected
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
    procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;
    function DoDelete(const ACollection, AKey: string): Boolean; override;
  end;

  /// <summary>
  ///   A store holding something that cannot be read back, for testing that a
  ///   fallback wrapper raises rather than answering from the standby.
  /// </summary>
  TKVCorruptStore = class(TKVFailingStore)
  protected
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
  end;

  /// <summary>
  ///   A store with no lock at all, which notices if two calls are ever inside
  ///   it at once. It exists to prove TKVThreadSafeWrapper serializes: wrapped,
  ///   the tripwire never fires.
  /// </summary>
  TKVUnsafeStore = class(TKVStoreBase)
  private
    FEntries: TDictionary<string, TKVEntry>;
    FInside: Integer;
    FTripped: Boolean;
    procedure Entering;
    procedure Leaving;
  protected
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
    procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;
    function DoDelete(const ACollection, AKey: string): Boolean; override;
  public
    constructor Create(const AClock: TKVClock = nil); override;
    destructor Destroy; override;
    property Tripped: Boolean read FTripped;
  end;

  /// <summary>
  ///   A memory store that counts the reads reaching it, so a test can tell a
  ///   value served by a cache from one fetched. AfterRead runs once a read
  ///   has its answer and before it is returned, which is where a test plants
  ///   a change that overtakes the read.
  /// </summary>
  TKVCountingStore = class(TKVMemoryStore)
  private
    FReads: Integer;
    FAfterRead: TProc<string>;
  protected
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
  public
    property Reads: Integer read FReads;
    property AfterRead: TProc<string> read FAfterRead write FAfterRead;
  end;

  /// <summary>
  ///   Watches a memory store, with a switch that makes every watch go dead -
  ///   reporting nothing and saying so - as a dropped connection does, and
  ///   another that makes a new watch fail outright.
  /// </summary>
  TKVSwitchedWatchStore = class(TKVWrapper, IKeyValueWatchable)
  private
    FLive: Boolean;
    FFailing: Boolean;
    FWatchesStarted: Integer;
  public
    constructor Create(const AInner: IKeyValue); reintroduce;
    function Watch(const ACollection: string; const AOnChange: TKVChangeProc): IKVWatch;
    property Live: Boolean read FLive write FLive;
    property Failing: Boolean read FFailing write FFailing;
    property WatchesStarted: Integer read FWatchesStarted;
  end;

  /// <summary>
  ///   Shared plumbing: a memory store to wrap and a clock to move.
  /// </summary>
  TKVWrapperTestCase = class abstract
  private
    FNow: TDateTime;
    FMemory: TKVMemoryStore;
    FInner: IKeyValue;
  protected
    procedure Advance(const ASeconds: Double);
    /// <summary>
    ///   The store being wrapped, reachable so a test can check where a value
    ///   really landed rather than take the wrapper's word for it.
    /// </summary>
    property Inner: IKeyValue read FInner;
    property Memory: TKVMemoryStore read FMemory;
    property Now: TDateTime read FNow;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
  end;

  [TestFixture]
  TKVWrapperBaseTests = class(TKVWrapperTestCase)
  public
    [Test] procedure NilInner_Refused;
    [Test] procedure Inner_IsReachable;
    [Test] procedure CollectionView_GoesThroughTheWrapper;
    [Test] procedure OptionalCapabilities_AreNotPassedOn;
  end;

  [TestFixture]
  TKVPrefixKeysWrapperTests = class(TKVWrapperTestCase)
  public
    [Test] procedure EmptyPrefix_Refused;
    [Test] procedure EmptySeparator_Refused;
    [Test] procedure PrefixEndingInSeparator_Refused;
    [Test] procedure Put_LandsUnderThePrefixedKey;
    [Test] procedure Get_ReadsItsOwnNamespace;
    [Test] procedure TwoNamespaces_DoNotSeeEachOther;
    [Test] procedure BulkCalls_ArePrefixedToo;
    [Test] procedure Keys_StripThePrefixAndHideTheRest;
    [Test] procedure Collections_AreNotPrefixed;
    [Test] procedure EmptyKey_IsRefusedBeforeItIsPrefixed;
    [Test] procedure AKeyAtTheLimit_NoLongerFits;
    [Test] procedure PutMany_LengthMismatch_RaisesEvenWhenTheInnerIsLax;
    [Test] procedure Keys_OverAStoreThatCannotEnumerate_Raises;
  end;

  [TestFixture]
  TKVPrefixCollectionsWrapperTests = class(TKVWrapperTestCase)
  public
    [Test] procedure Put_LandsInThePrefixedCollection;
    [Test] procedure EmptySeparator_Refused;
    [Test] procedure NamingTheDefaultCollection_AndNamingNone_Agree;
    [Test] procedure DefaultCollection_CanBeAlignedWithTheStore;
    [Test] procedure Collections_StripThePrefixAndHideTheRest;
    [Test] procedure Keys_ReadTheNamespacedCollection;
  end;

  [TestFixture]
  TKVReadOnlyWrapperTests = class(TKVWrapperTestCase)
  public
    [Test] procedure Reads_PassThrough;
    [Test] procedure Put_Refused;
    [Test] procedure Delete_Refused;
    [Test] procedure PutMany_Refused;
    [Test] procedure DeleteMany_Refused;
    [Test] procedure CullAndDestroy_Refused;
    [Test] procedure Enumeration_PassesThrough;
    [Test] procedure Ignore_DropsWritesQuietly;
    [Test] procedure Ignore_LeavesTheStoreUntouched;
  end;

  [TestFixture]
  TKVTTLClampWrapperTests = class(TKVWrapperTestCase)
  public
    [Test] procedure DefaultTtl_GivenToAWriteThatAsksForNone;
    [Test] procedure NoDefault_LeavesAWriteWithoutAnExpiry;
    [Test] procedure ShortTtl_RaisedToTheFloor;
    [Test] procedure LongTtl_LoweredToTheCeiling;
    [Test] procedure TtlInRange_LeftAlone;
    [Test] procedure NegativeTtl_StillRaises;
    [Test] procedure PutMany_IsClampedToo;
    [Test] procedure NegativeLimit_Raises;
  end;

  [TestFixture]
  TKVLoggingWrapperTests = class(TKVWrapperTestCase)
  private
    FLines: TStringList;
    FStore: IKeyValue;
    function Line(const AIndex: Integer): string;
  public
    [Setup] procedure SetupLogging;
    [TearDown] procedure TearDownLogging;

    [Test] procedure Get_LogsHitAndMiss;
    [Test] procedure TryGetEntry_LogsTheExpiryAsAnInstant;
    [Test] procedure Put_LogsTheTtl;
    [Test] procedure Delete_LogsWhetherAnythingWent;
    [Test] procedure BulkCalls_LogOneLine;
    [Test] procedure TheValue_IsNeverLogged;
    [Test] procedure TheTag_IsOnEveryLine;
    [Test] procedure NoSink_LogsNothingAndStillWorks;
    [Test] procedure EmptyValue_IsLoggedAsAHit;
  end;

  [TestFixture]
  TKVStatisticsWrapperTests = class(TKVWrapperTestCase)
  private
    FStats: TKVStatisticsWrapper;
    FStore: IKeyValue;
  public
    [Setup] procedure SetupStats;

    [Test] procedure Reads_AreCountedAsHitsAndMisses;
    [Test] procedure Writes_AreCounted;
    [Test] procedure Deletes_CountAttemptsAndRemovals;
    [Test] procedure BulkCalls_CountPerKey;
    [Test] procedure ExpiredRead_CountsAsAMiss;
    [Test] procedure HitRate_IsHitsOverGets;
    [Test] procedure EmptyValue_IsCountedAsAHit;
    [Test] procedure Reset_ClearsEverything;
    [Test] procedure ToString_MentionsTheCounts;
  end;

  [TestFixture]
  TKVFallbackWrapperTests = class(TKVWrapperTestCase)
  private
    FFallback: IKeyValue;
  public
    [Test] procedure NilFallback_Refused;
    [Test] procedure HealthyPrimary_LeavesTheStandbyAlone;
    [Test] procedure FailingPrimary_ReadsFromTheStandby;
    [Test] procedure FailingPrimary_WritesToTheStandby;
    [Test] procedure FallingBack_IsAnnounced;
    [Test] procedure AMiss_IsNotAFailure;
    [Test] procedure ABadArgument_IsRaisedNotWorkedAround;
    [Test] procedure AReadOnlyPrimary_IsNotBypassed;
    [Test] procedure ACorruptValue_IsNotWorkedAround;
  end;

  [TestFixture]
  TKVThreadSafeWrapperTests = class(TKVWrapperTestCase)
  public
    [Test] procedure OverlappingCalls_AreSerialized;
    [Test] procedure Capabilities_FollowTheStore;
    [Test] procedure Capabilities_RefuseWhenTheStoreHasNone;
  end;

  /// <summary>
  ///   Watching through the wrappers that rename: a watcher hears about its
  ///   own names, never the store's.
  /// </summary>
  [TestFixture]
  TKVWatchThroughWrappersTests = class(TKVWrapperTestCase)
  public
    [Test] procedure PrefixKeys_ReportsItsOwnKeysUnprefixed;
    [Test] procedure PrefixCollections_WatchesTheRenamedCollection;
    [Test] procedure ReadOnly_PassesTheWatchThrough;
    [Test] procedure ThreadSafe_RefusesWhenTheStoreCannotWatch;
  end;

  [TestFixture]
  TKVNearCacheWrapperTests = class(TKVWrapperTestCase)
  private
    FCounting: TKVCountingStore;
    FCountingRef: IKeyValue;
    function Clock: TKVClock;
    /// <summary>
    ///   A fresh counting store, and a cache over it, both reading the fixture
    ///   clock. The caller holds the cache by interface.
    /// </summary>
    function NewCache(const AMaxAge: TKVDuration = 60;
      const AMaxEntries: Integer = 100): TKVNearCacheWrapper;
  public
    [Test] procedure AStoreThatCannotWatch_IsRefused;
    [Test] procedure NonsenseLimits_AreRefused;
    [Test] procedure SecondRead_IsServedLocally;
    [Test] procedure AMiss_IsNotCached;
    [Test] procedure AWriteElsewhere_IsSeenAtOnce;
    [Test] procedure ADeleteElsewhere_IsSeenAtOnce;
    [Test] procedure ADroppedCollection_IsSeenAtOnce;
    [Test] procedure AWriteThrough_IsSeenAtOnce;
    [Test] procedure Expiry_IsJudgedLocally;
    [Test] procedure MaxAge_BoundsHowLongAnEntryIsTrusted;
    [Test] procedure MaxEntries_DropsTheLeastRecentlyRead;
    [Test] procedure AChangeOvertakingARead_IsNotKept;
    [Test] procedure ADeadWatch_IsNotTrusted;
    [Test] procedure AWatchThatCannotStart_LeavesReadsUncached;
    [Test] procedure Clear_DropsEverything;
    [Test] procedure OverAReadOnlyView_SeesWritesUnderneath;
    [Test] procedure OverPrefixedKeys_SeesWritesUnderneath;
  end;

implementation

const
  VALUE_A = '{"name":"Alice"}';
  VALUE_B = '{"name":"Bob"}';

resourcestring
  SFailingStore = 'This store always fails';
  SCorruptValue = 'The stored value cannot be read';

{ TKVFailingStore }

function TKVFailingStore.DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean;
begin
  AEntry := Default(TKVEntry);
  raise EKVStoreError.Create(SFailingStore);
end;

procedure TKVFailingStore.DoPut(const ACollection, AKey: string; const AEntry: TKVEntry);
begin
  raise EKVStoreError.Create(SFailingStore);
end;

function TKVFailingStore.DoDelete(const ACollection, AKey: string): Boolean;
begin
  raise EKVStoreError.Create(SFailingStore);
end;

{ TKVCorruptStore }

function TKVCorruptStore.DoTryGet(const ACollection, AKey: string;
  out AEntry: TKVEntry): Boolean;
begin
  AEntry := Default(TKVEntry);
  raise EKVSerializationError.Create(SCorruptValue);
end;

{ TKVUnsafeStore }

constructor TKVUnsafeStore.Create(const AClock: TKVClock);
begin
  inherited Create(AClock);
  FEntries := TDictionary<string, TKVEntry>.Create;
end;

destructor TKVUnsafeStore.Destroy;
begin
  FEntries.Free;
  inherited;
end;

procedure TKVUnsafeStore.Entering;
begin
  if TInterlocked.Increment(FInside) > 1 then
    FTripped := True;

  // Widen the window so that, unwrapped, overlap would show up rather than
  // depend on the scheduler noticing.
  TThread.Yield;
end;

procedure TKVUnsafeStore.Leaving;
begin
  TInterlocked.Decrement(FInside);
end;

function TKVUnsafeStore.DoTryGet(const ACollection, AKey: string;
  out AEntry: TKVEntry): Boolean;
begin
  Entering;
  try
    Result := FEntries.TryGetValue(AKey, AEntry);
  finally
    Leaving;
  end;
end;

procedure TKVUnsafeStore.DoPut(const ACollection, AKey: string; const AEntry: TKVEntry);
begin
  Entering;
  try
    FEntries.AddOrSetValue(AKey, AEntry);
  finally
    Leaving;
  end;
end;

function TKVUnsafeStore.DoDelete(const ACollection, AKey: string): Boolean;
begin
  Entering;
  try
    Result := FEntries.ContainsKey(AKey);
    if Result then
      FEntries.Remove(AKey);
  finally
    Leaving;
  end;
end;

{ TKVWrapperTestCase }

{ TKVCountingStore }

function TKVCountingStore.DoTryGet(const ACollection, AKey: string;
  out AEntry: TKVEntry): Boolean;
begin
  // After the lock is let go, so AfterRead may write to the store.
  Result := inherited DoTryGet(ACollection, AKey, AEntry);
  TInterlocked.Increment(FReads);
  if Assigned(FAfterRead) then
    FAfterRead(AKey);
end;

{ TKVSwitchedWatchStore }

type
  TKVSwitchedWatch = class(TInterfacedObject, IKVWatch)
  private
    FOwner: TKVSwitchedWatchStore;
    FOwnerRef: IKeyValue;
    FInner: IKVWatch;
    FDead: Boolean;
  public
    constructor Create(const AOwner: TKVSwitchedWatchStore; const AInner: IKVWatch);
    function IsLive: Boolean;
  end;

constructor TKVSwitchedWatch.Create(const AOwner: TKVSwitchedWatchStore;
  const AInner: IKVWatch);
begin
  inherited Create;
  FOwner := AOwner;
  FOwnerRef := AOwner;
  FInner := AInner;
end;

function TKVSwitchedWatch.IsLive: Boolean;
begin
  // Dead once, dead for good - a real watch does not come back either.
  if not FOwner.Live then
    FDead := True;
  Result := not FDead and FInner.IsLive;
end;

constructor TKVSwitchedWatchStore.Create(const AInner: IKeyValue);
begin
  inherited Create(AInner);
  FLive := True;
end;

function TKVSwitchedWatchStore.Watch(const ACollection: string;
  const AOnChange: TKVChangeProc): IKVWatch;
var
  LWatchable: IKeyValueWatchable;
  LOnChange: TKVChangeProc;
  LSelf: TKVSwitchedWatchStore;
begin
  if FFailing then
    raise EKVStoreError.Create('This watch cannot start');
  if not Supports(Inner, IKeyValueWatchable, LWatchable) then
    raise EKVStoreError.Create('The store underneath cannot watch');

  Inc(FWatchesStarted);
  LOnChange := AOnChange;
  LSelf := Self;
  Result := TKVSwitchedWatch.Create(Self, LWatchable.Watch(ACollection,
    procedure (const AKey: string)
    begin
      // Switched off, a change is lost on the way - which is the point.
      if LSelf.Live then
        LOnChange(AKey);
    end));
end;

procedure TKVWrapperTestCase.Setup;
begin
  FNow := EncodeDate(2026, 1, 1) + EncodeTime(12, 0, 0, 0);
  FMemory := TKVMemoryStore.Create(
    function: TDateTime
    begin
      Result := FNow;
    end);
  FInner := FMemory;
end;

procedure TKVWrapperTestCase.TearDown;
begin
  FInner := nil;
  FMemory := nil;
end;

procedure TKVWrapperTestCase.Advance(const ASeconds: Double);
begin
  FNow := FNow + (ASeconds / SecsPerDay);
end;

{ TKVWrapperBaseTests }

procedure TKVWrapperBaseTests.NilInner_Refused;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVStatisticsWrapper.Create(nil);
    end, EKVArgumentError);
end;

procedure TKVWrapperBaseTests.Inner_IsReachable;
var
  LWrapper: TKVStatisticsWrapper;
  LStore: IKeyValue;
begin
  LWrapper := TKVStatisticsWrapper.Create(Inner);
  LStore := LWrapper;

  Assert.AreSame(TObject(Inner), TObject(LWrapper.Inner));
end;

procedure TKVWrapperBaseTests.CollectionView_GoesThroughTheWrapper;
var
  LWrapper: TKVStatisticsWrapper;
  LStore, LView: IKeyValue;
begin
  LWrapper := TKVStatisticsWrapper.Create(Inner);
  LStore := LWrapper;

  LView := LStore.Collection('users');
  LView.Put('a', VALUE_A);

  Assert.AreEqual(VALUE_A, Inner.Get('a', 'users'));
  Assert.AreEqual(Int64(1), LWrapper.Statistics.Puts, 'the view went through the wrapper');
end;

procedure TKVWrapperBaseTests.OptionalCapabilities_AreNotPassedOn;
var
  LStore: IKeyValue;
begin
  // Deliberate: whether passing one on is safe depends on the wrapper, so
  // none of them do it by default and Inner is the way through.
  LStore := TKVStatisticsWrapper.Create(Inner);

  Assert.IsFalse(Supports(LStore, IKeyValueCullable), 'not through the wrapper');
  Assert.IsTrue(Supports(Inner, IKeyValueCullable), 'but still there underneath');
end;

{ TKVPrefixKeysWrapperTests }

procedure TKVPrefixKeysWrapperTests.EmptyPrefix_Refused;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVPrefixKeysWrapper.Create(Inner, '');
    end, EKVArgumentError);
end;

procedure TKVPrefixKeysWrapperTests.EmptySeparator_Refused;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVPrefixKeysWrapper.Create(Inner, 'tenant-7', '');
    end, EKVArgumentError);
end;

procedure TKVPrefixKeysWrapperTests.PrefixEndingInSeparator_Refused;
begin
  // 'tenant-7:' with ':' and 'tenant-7' with ':' would name the same key space.
  Assert.WillRaise(
    procedure
    begin
      TKVPrefixKeysWrapper.Create(Inner, 'tenant-7:', ':');
    end, EKVArgumentError);
end;

procedure TKVPrefixKeysWrapperTests.Put_LandsUnderThePrefixedKey;
var
  LStore: IKeyValue;
begin
  LStore := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');
  LStore.Put('a', VALUE_A, 'users');

  Assert.AreEqual(VALUE_A, Inner.Get('tenant-7:a', 'users'));
  Assert.AreEqual('', Inner.Get('a', 'users'), 'nothing under the bare key');
end;

procedure TKVPrefixKeysWrapperTests.Get_ReadsItsOwnNamespace;
var
  LStore: IKeyValue;
begin
  LStore := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');
  Inner.Put('tenant-7:a', VALUE_A);
  Inner.Put('a', VALUE_B);

  Assert.AreEqual(VALUE_A, LStore.Get('a'));
end;

procedure TKVPrefixKeysWrapperTests.TwoNamespaces_DoNotSeeEachOther;
var
  LSeven, LEight: IKeyValue;
begin
  LSeven := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');
  LEight := TKVPrefixKeysWrapper.Create(Inner, 'tenant-8');

  LSeven.Put('a', VALUE_A);
  LEight.Put('a', VALUE_B);

  Assert.AreEqual(VALUE_A, LSeven.Get('a'));
  Assert.AreEqual(VALUE_B, LEight.Get('a'));
  Assert.IsFalse(LSeven.Delete('nope'));
end;

procedure TKVPrefixKeysWrapperTests.BulkCalls_ArePrefixedToo;
var
  LStore: IKeyValue;
  LValues: TArray<string>;
begin
  LStore := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');
  LStore.PutMany(['a', 'b'], [VALUE_A, VALUE_B]);

  Assert.AreEqual(VALUE_A, Inner.Get('tenant-7:a'));

  LValues := LStore.GetMany(['a', 'b']);
  Assert.AreEqual(VALUE_A, LValues[0]);
  Assert.AreEqual(VALUE_B, LValues[1]);
  Assert.AreEqual(2, LStore.DeleteMany(['a', 'b']));
end;

procedure TKVPrefixKeysWrapperTests.Keys_StripThePrefixAndHideTheRest;
var
  LStore: TKVPrefixKeysWrapper;
  LRef: IKeyValue;
  LKeys: TArray<string>;
begin
  LStore := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');
  LRef := LStore;

  LStore.Put('a', VALUE_A, 'users');
  Inner.Put('tenant-8:b', VALUE_B, 'users');

  LKeys := LStore.Keys('users');
  Assert.AreEqual(1, Length(LKeys));
  Assert.AreEqual('a', LKeys[0]);
end;

procedure TKVPrefixKeysWrapperTests.Collections_AreNotPrefixed;
var
  LStore: TKVPrefixKeysWrapper;
  LRef: IKeyValue;
begin
  LStore := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');
  LRef := LStore;

  LStore.Put('a', VALUE_A, 'users');

  Assert.AreEqual(1, Length(LStore.Collections));
  Assert.AreEqual('users', LStore.Collections[0]);
end;

procedure TKVPrefixKeysWrapperTests.EmptyKey_IsRefusedBeforeItIsPrefixed;
var
  LStore: IKeyValue;
begin
  // Without the check the prefix alone would make a perfectly valid key.
  LStore := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');

  Assert.WillRaise(
    procedure
    begin
      LStore.Put('', VALUE_A);
    end, EKVInvalidKeyError);
  Assert.AreEqual('', Inner.Get('tenant-7:'));
end;

procedure TKVPrefixKeysWrapperTests.AKeyAtTheLimit_NoLongerFits;
var
  LStore: IKeyValue;
begin
  // The documented cost of prefixing: the prefix comes out of the same budget.
  LStore := TKVPrefixKeysWrapper.Create(Inner, 'tenant-7');

  Assert.WillRaise(
    procedure
    begin
      LStore.Put(StringOfChar('k', KV_MAX_KEY_LENGTH), VALUE_A);
    end, EKVInvalidKeyError);

  LStore.Put(StringOfChar('k', KV_MAX_KEY_LENGTH - Length('tenant-7:')), VALUE_A);
end;

procedure TKVPrefixKeysWrapperTests.PutMany_LengthMismatch_RaisesEvenWhenTheInnerIsLax;
var
  LLax: IKeyValue;
  LStore: IKeyValue;
begin
  // A read-only Ignore store answers a mismatched PutMany with nothing at all,
  // so the wrapper has to do the checking itself rather than forward and hope.
  LLax := TKVReadOnlyWrapper.Create(Inner, TKVReadOnlyMode.Ignore);
  LStore := TKVPrefixKeysWrapper.Create(LLax, 'tenant-7');

  Assert.WillRaise(
    procedure
    begin
      LStore.PutMany(['a', 'b'], [VALUE_A]);
    end, EKVArgumentError);
end;

procedure TKVPrefixKeysWrapperTests.Keys_OverAStoreThatCannotEnumerate_Raises;
var
  LStore: TKVPrefixKeysWrapper;
  LRef: IKeyValue;
begin
  LStore := TKVPrefixKeysWrapper.Create(TKVFailingStore.Create, 'tenant-7');
  LRef := LStore;

  Assert.WillRaise(
    procedure
    begin
      LStore.Keys;
    end, EKVStoreError);
end;

{ TKVPrefixCollectionsWrapperTests }

procedure TKVPrefixCollectionsWrapperTests.Put_LandsInThePrefixedCollection;
var
  LStore: IKeyValue;
begin
  LStore := TKVPrefixCollectionsWrapper.Create(Inner, 'app1');
  LStore.Put('a', VALUE_A, 'users');

  Assert.AreEqual(VALUE_A, Inner.Get('a', 'app1_users'));
  Assert.AreEqual('', Inner.Get('a', 'users'));
end;

procedure TKVPrefixCollectionsWrapperTests.NamingTheDefaultCollection_AndNamingNone_Agree;
var
  LStore: IKeyValue;
begin
  // '' has to be resolved here rather than in the store underneath, or these
  // two would land in different places.
  LStore := TKVPrefixCollectionsWrapper.Create(Inner, 'app1');

  LStore.Put('a', VALUE_A, '');
  Assert.AreEqual(VALUE_A, LStore.Get('a', KV_DEFAULT_COLLECTION));
  Assert.AreEqual(VALUE_A, Inner.Get('a', 'app1_' + KV_DEFAULT_COLLECTION));
end;

procedure TKVPrefixCollectionsWrapperTests.Collections_StripThePrefixAndHideTheRest;
var
  LStore: TKVPrefixCollectionsWrapper;
  LRef: IKeyValue;
  LCollections: TArray<string>;
begin
  LStore := TKVPrefixCollectionsWrapper.Create(Inner, 'app1');
  LRef := LStore;

  LStore.Put('a', VALUE_A, 'users');
  Inner.Put('a', VALUE_B, 'app2_users');

  LCollections := LStore.Collections;
  Assert.AreEqual(1, Length(LCollections));
  Assert.AreEqual('users', LCollections[0]);
end;

procedure TKVPrefixCollectionsWrapperTests.Keys_ReadTheNamespacedCollection;
var
  LStore: TKVPrefixCollectionsWrapper;
  LRef: IKeyValue;
begin
  LStore := TKVPrefixCollectionsWrapper.Create(Inner, 'app1');
  LRef := LStore;

  LStore.Put('a', VALUE_A, 'users');
  Inner.Put('b', VALUE_B, 'users');

  Assert.AreEqual(1, Length(LStore.Keys('users')));
  Assert.AreEqual('a', LStore.Keys('users')[0]);
end;

procedure TKVPrefixCollectionsWrapperTests.EmptySeparator_Refused;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVPrefixCollectionsWrapper.Create(Inner, 'app1', '');
    end, EKVArgumentError);
end;

procedure TKVPrefixCollectionsWrapperTests.DefaultCollection_CanBeAlignedWithTheStore;
var
  LStore: TKVPrefixCollectionsWrapper;
  LRef: IKeyValue;
begin
  // A store whose own DefaultCollection is not 'default' can be matched here,
  // so '' means the same place through the wrapper as through the store.
  Memory.DefaultCollection := 'app';
  LStore := TKVPrefixCollectionsWrapper.Create(Inner, 'app1');
  LStore.DefaultCollection := 'app';
  LRef := LStore;

  LStore.Put('a', VALUE_A, '');
  Assert.AreEqual(VALUE_A, Inner.Get('a', 'app1_app'));
  Assert.AreEqual(VALUE_A, LStore.Get('a', 'app'));
end;

{ TKVReadOnlyWrapperTests }

procedure TKVReadOnlyWrapperTests.Reads_PassThrough;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  Inner.Put('a', VALUE_A, 'users', 60);
  LStore := TKVReadOnlyWrapper.Create(Inner);

  Assert.AreEqual(VALUE_A, LStore.Get('a', 'users'));
  Assert.IsTrue(LStore.Exists('a', 'users'));
  Assert.IsTrue(LStore.TryGetEntry('a', 'users', LEntry));
  Assert.AreEqual(1, Length(LStore.GetMany(['a'], 'users')));
end;

procedure TKVReadOnlyWrapperTests.Put_Refused;
var
  LStore: IKeyValue;
begin
  LStore := TKVReadOnlyWrapper.Create(Inner);

  Assert.WillRaise(
    procedure
    begin
      LStore.Put('a', VALUE_A);
    end, EKVReadOnlyError);
  Assert.AreEqual('', Inner.Get('a'));
end;

procedure TKVReadOnlyWrapperTests.Delete_Refused;
var
  LStore: IKeyValue;
begin
  Inner.Put('a', VALUE_A);
  LStore := TKVReadOnlyWrapper.Create(Inner);

  Assert.WillRaise(
    procedure
    begin
      LStore.Delete('a');
    end, EKVReadOnlyError);
  Assert.AreEqual(VALUE_A, Inner.Get('a'));
end;

procedure TKVReadOnlyWrapperTests.PutMany_Refused;
var
  LStore: IKeyValue;
begin
  LStore := TKVReadOnlyWrapper.Create(Inner);

  Assert.WillRaise(
    procedure
    begin
      LStore.PutMany(['a'], [VALUE_A]);
    end, EKVReadOnlyError);
end;

procedure TKVReadOnlyWrapperTests.DeleteMany_Refused;
var
  LStore: IKeyValue;
begin
  LStore := TKVReadOnlyWrapper.Create(Inner);

  Assert.WillRaise(
    procedure
    begin
      LStore.DeleteMany(['a']);
    end, EKVReadOnlyError);
end;

procedure TKVReadOnlyWrapperTests.CullAndDestroy_Refused;
var
  LStore: TKVReadOnlyWrapper;
  LRef: IKeyValue;
begin
  LStore := TKVReadOnlyWrapper.Create(Inner);
  LRef := LStore;

  Assert.WillRaise(
    procedure
    begin
      LStore.Cull;
    end, EKVReadOnlyError);
  Assert.WillRaise(
    procedure
    begin
      LStore.DestroyCollection('users');
    end, EKVReadOnlyError);
  Assert.WillRaise(
    procedure
    begin
      LStore.DestroyAll;
    end, EKVReadOnlyError);
end;

procedure TKVReadOnlyWrapperTests.Ignore_DropsWritesQuietly;
var
  LStore: IKeyValue;
begin
  LStore := TKVReadOnlyWrapper.Create(Inner, TKVReadOnlyMode.Ignore);

  LStore.Put('a', VALUE_A);
  LStore.PutMany(['b'], [VALUE_B]);

  Assert.IsFalse(LStore.Delete('a'));
  Assert.AreEqual(0, LStore.DeleteMany(['a']));
end;

procedure TKVReadOnlyWrapperTests.Ignore_LeavesTheStoreUntouched;
var
  LStore: IKeyValue;
begin
  Inner.Put('a', VALUE_A);
  LStore := TKVReadOnlyWrapper.Create(Inner, TKVReadOnlyMode.Ignore);

  LStore.Put('a', VALUE_B);
  LStore.Delete('a');

  Assert.AreEqual(VALUE_A, Inner.Get('a'), 'neither write reached the store');
end;

procedure TKVReadOnlyWrapperTests.Enumeration_PassesThrough;
var
  LStore: TKVReadOnlyWrapper;
  LRef: IKeyValue;
begin
  // Reading is what this wrapper allows, so listing what is there is allowed
  // too; only culling and destroying are refused.
  Inner.Put('a', VALUE_A, 'users');
  Inner.Put('b', VALUE_B, 'users');

  LStore := TKVReadOnlyWrapper.Create(Inner);
  LRef := LStore;

  Assert.AreEqual(2, Length(LStore.Keys('users')));
  Assert.AreEqual(1, Length(LStore.Collections));
  Assert.AreEqual('users', LStore.Collections[0]);
end;

{ TKVTTLClampWrapperTests }

procedure TKVTTLClampWrapperTests.DefaultTtl_GivenToAWriteThatAsksForNone;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  LStore := TKVTTLClampWrapper.Create(Inner, 0, 0, 300);
  LStore.Put('a', VALUE_A);

  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntry));
  Assert.AreEqual(Double(300), Double(LEntry.TTLRemainingAt(Now)), 0.001);
end;

procedure TKVTTLClampWrapperTests.NoDefault_LeavesAWriteWithoutAnExpiry;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  LStore := TKVTTLClampWrapper.Create(Inner);
  LStore.Put('a', VALUE_A);

  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntry));
  Assert.IsFalse(LEntry.HasExpiry);
end;

procedure TKVTTLClampWrapperTests.ShortTtl_RaisedToTheFloor;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  LStore := TKVTTLClampWrapper.Create(Inner, 60, 3600);
  LStore.Put('a', VALUE_A, '', 5);

  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntry));
  Assert.AreEqual(Double(60), Double(LEntry.TTLRemainingAt(Now)), 0.001);
end;

procedure TKVTTLClampWrapperTests.LongTtl_LoweredToTheCeiling;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  LStore := TKVTTLClampWrapper.Create(Inner, 60, 3600);
  LStore.Put('a', VALUE_A, '', 999999);

  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntry));
  Assert.AreEqual(Double(3600), Double(LEntry.TTLRemainingAt(Now)), 0.001);
end;

procedure TKVTTLClampWrapperTests.TtlInRange_LeftAlone;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  LStore := TKVTTLClampWrapper.Create(Inner, 60, 3600);
  LStore.Put('a', VALUE_A, '', 120);

  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntry));
  Assert.AreEqual(Double(120), Double(LEntry.TTLRemainingAt(Now)), 0.001);
end;

procedure TKVTTLClampWrapperTests.NegativeTtl_StillRaises;
var
  LStore: IKeyValue;
begin
  // A negative TTL is a mistake, not a short life: a default must not swallow
  // it on the way past.
  LStore := TKVTTLClampWrapper.Create(Inner, 60, 3600, 300);

  Assert.WillRaise(
    procedure
    begin
      LStore.Put('a', VALUE_A, '', -1);
    end, EKVArgumentError);
end;

procedure TKVTTLClampWrapperTests.PutMany_IsClampedToo;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  LStore := TKVTTLClampWrapper.Create(Inner, 60, 3600);
  LStore.PutMany(['a', 'b'], [VALUE_A, VALUE_B], '', 5);

  Assert.IsTrue(LStore.TryGetEntry('b', '', LEntry));
  Assert.AreEqual(Double(60), Double(LEntry.TTLRemainingAt(Now)), 0.001);
end;

procedure TKVTTLClampWrapperTests.NegativeLimit_Raises;
var
  LStore: TKVTTLClampWrapper;
begin
  // A negative floor, ceiling or default is a mistake, not a limit to ignore.
  Assert.WillRaise(
    procedure
    begin
      TKVTTLClampWrapper.Create(Inner, -1);
    end, EKVArgumentError);

  LStore := TKVTTLClampWrapper.Create(Inner);
  try
    Assert.WillRaise(
      procedure
      begin
        LStore.DefaultTTL := -1;
      end, EKVArgumentError);
  finally
    LStore.Free;
  end;
end;

{ TKVLoggingWrapperTests }

procedure TKVLoggingWrapperTests.SetupLogging;
var
  LLines: TStringList;
begin
  Setup;
  FLines := TStringList.Create;
  LLines := FLines;
  FStore := TKVLoggingWrapper.Create(Inner,
    procedure(const AMessage: string)
    begin
      LLines.Add(AMessage);
    end, 'test');
end;

procedure TKVLoggingWrapperTests.TearDownLogging;
begin
  FStore := nil;
  FreeAndNil(FLines);
  TearDown;
end;

function TKVLoggingWrapperTests.Line(const AIndex: Integer): string;
begin
  Assert.IsTrue(AIndex < FLines.Count,
    Format('expected at least %d lines, got %d', [AIndex + 1, FLines.Count]));
  Result := FLines[AIndex];
end;

procedure TKVLoggingWrapperTests.Get_LogsHitAndMiss;
begin
  FStore.Put('a', VALUE_A, 'users');
  FStore.Get('a', 'users');
  FStore.Get('nope', 'users');

  Assert.IsTrue(Line(1).Contains('GET users/a'), Line(1));
  Assert.IsTrue(Line(1).Contains('hit'), Line(1));
  Assert.IsTrue(Line(2).Contains('miss'), Line(2));
end;

procedure TKVLoggingWrapperTests.TryGetEntry_LogsTheExpiryAsAnInstant;
var
  LEntry: TKVEntry;
begin
  // Not "3600 seconds left": a wrapper has no clock, and the store's may not
  // be the wall clock, so a lifetime it worked out itself would be wrong.
  FStore.Put('a', VALUE_A, 'users', 3600);
  FStore.TryGetEntry('a', 'users', LEntry);

  Assert.IsTrue(Line(1).Contains('expires 2026-01-01 13:00:00Z'), Line(1));

  FStore.Put('b', VALUE_A, 'users');
  FStore.TryGetEntry('b', 'users', LEntry);
  Assert.IsFalse(Line(3).Contains('expires'), Line(3));
end;

procedure TKVLoggingWrapperTests.Put_LogsTheTtl;
begin
  FStore.Put('a', VALUE_A, 'users', 60);
  Assert.IsTrue(Line(0).Contains('PUT users/a'), Line(0));
  Assert.IsTrue(Line(0).Contains('ttl 60'), Line(0));

  FStore.Put('b', VALUE_A, 'users');
  Assert.IsFalse(Line(1).Contains('ttl'), Line(1));
end;

procedure TKVLoggingWrapperTests.Delete_LogsWhetherAnythingWent;
begin
  FStore.Put('a', VALUE_A);
  FStore.Delete('a');
  FStore.Delete('a');

  Assert.IsTrue(Line(1).Contains('removed'), Line(1));
  Assert.IsTrue(Line(2).Contains('nothing there'), Line(2));
end;

procedure TKVLoggingWrapperTests.BulkCalls_LogOneLine;
begin
  FStore.PutMany(['a', 'b'], [VALUE_A, VALUE_B]);
  FStore.GetMany(['a', 'b']);
  FStore.DeleteMany(['a', 'b']);

  Assert.AreEqual(3, FLines.Count);
  Assert.IsTrue(Line(0).Contains('PUTMANY 2 keys'), Line(0));
  Assert.IsTrue(Line(2).Contains('2 removed'), Line(2));
end;

procedure TKVLoggingWrapperTests.TheValue_IsNeverLogged;
var
  LLine: string;
begin
  // A value can be large, and it can be somebody's personal data.
  FStore.Put('a', VALUE_A);
  FStore.Get('a');

  for LLine in FLines do
    Assert.IsFalse(LLine.Contains('Alice'), LLine);
end;

procedure TKVLoggingWrapperTests.TheTag_IsOnEveryLine;
var
  LLine: string;
begin
  FStore.Put('a', VALUE_A);
  FStore.Get('a');

  for LLine in FLines do
    Assert.IsTrue(LLine.StartsWith('[test]'), LLine);
end;

procedure TKVLoggingWrapperTests.NoSink_LogsNothingAndStillWorks;
var
  LStore: IKeyValue;
begin
  LStore := TKVLoggingWrapper.Create(Inner, nil);

  LStore.Put('a', VALUE_A);
  Assert.AreEqual(VALUE_A, LStore.Get('a'));
  Assert.AreEqual(0, FLines.Count);
end;

procedure TKVLoggingWrapperTests.EmptyValue_IsLoggedAsAHit;
begin
  // A value deliberately stored as '' is a hit, and must not be logged as a
  // miss just because the answer is empty.
  FStore.Put('a', '', 'users');
  FStore.Get('a', 'users');

  Assert.IsTrue(Line(1).Contains('hit'), Line(1));
end;

{ TKVStatisticsWrapperTests }

procedure TKVStatisticsWrapperTests.SetupStats;
begin
  Setup;
  FStats := TKVStatisticsWrapper.Create(Inner);
  FStore := FStats;
end;

procedure TKVStatisticsWrapperTests.Reads_AreCountedAsHitsAndMisses;
var
  LValue: string;
begin
  FStore.Put('a', VALUE_A);
  FStore.Get('a');
  FStore.Get('nope');
  FStore.TryGet('a', LValue);

  Assert.AreEqual(Int64(3), FStats.Statistics.Gets);
  Assert.AreEqual(Int64(2), FStats.Statistics.Hits);
  Assert.AreEqual(Int64(1), FStats.Statistics.Misses);
end;

procedure TKVStatisticsWrapperTests.Writes_AreCounted;
begin
  FStore.Put('a', VALUE_A);
  FStore.Put('b', VALUE_B);

  Assert.AreEqual(Int64(2), FStats.Statistics.Puts);
end;

procedure TKVStatisticsWrapperTests.Deletes_CountAttemptsAndRemovals;
begin
  FStore.Put('a', VALUE_A);
  FStore.Delete('a');
  FStore.Delete('nope');

  Assert.AreEqual(Int64(2), FStats.Statistics.Deletes, 'both were asked for');
  Assert.AreEqual(Int64(1), FStats.Statistics.Removals, 'one was there');
end;

procedure TKVStatisticsWrapperTests.BulkCalls_CountPerKey;
begin
  FStore.PutMany(['a', 'b'], [VALUE_A, VALUE_B]);
  FStore.GetMany(['a', 'b', 'nope']);
  FStore.DeleteMany(['a', 'nope']);

  Assert.AreEqual(Int64(2), FStats.Statistics.Puts);
  Assert.AreEqual(Int64(3), FStats.Statistics.Gets);
  Assert.AreEqual(Int64(2), FStats.Statistics.Hits);
  Assert.AreEqual(Int64(2), FStats.Statistics.Deletes);
  Assert.AreEqual(Int64(1), FStats.Statistics.Removals);
end;

procedure TKVStatisticsWrapperTests.EmptyValue_IsCountedAsAHit;
begin
  // On both the single and the bulk read, a stored '' is a hit.
  FStore.Put('a', '', 'users');
  FStore.Get('a', 'users');
  FStore.GetMany(['a'], 'users');

  Assert.AreEqual(Int64(2), FStats.Statistics.Gets);
  Assert.AreEqual(Int64(2), FStats.Statistics.Hits);
  Assert.AreEqual(Int64(0), FStats.Statistics.Misses);
end;

procedure TKVStatisticsWrapperTests.ExpiredRead_CountsAsAMiss;
begin
  FStore.Put('a', VALUE_A, '', 60);
  Advance(120);
  FStore.Get('a');

  Assert.AreEqual(Int64(1), FStats.Statistics.Misses);
end;

procedure TKVStatisticsWrapperTests.HitRate_IsHitsOverGets;
begin
  Assert.AreEqual(Double(0), FStats.Statistics.HitRate, 0.001, 'nothing read yet');

  FStore.Put('a', VALUE_A);
  FStore.Get('a');
  FStore.Get('nope');

  Assert.AreEqual(Double(0.5), FStats.Statistics.HitRate, 0.001);
end;

procedure TKVStatisticsWrapperTests.Reset_ClearsEverything;
begin
  FStore.Put('a', VALUE_A);
  FStore.Get('a');
  FStore.Delete('a');

  FStats.Reset;

  Assert.AreEqual(Int64(0), FStats.Statistics.Gets);
  Assert.AreEqual(Int64(0), FStats.Statistics.Puts);
  Assert.AreEqual(Int64(0), FStats.Statistics.Deletes);
end;

procedure TKVStatisticsWrapperTests.ToString_MentionsTheCounts;
begin
  FStore.Put('a', VALUE_A);
  FStore.Get('a');

  Assert.IsTrue(FStats.Statistics.ToString.Contains('gets 1'), FStats.Statistics.ToString);
  Assert.IsTrue(FStats.Statistics.ToString.Contains('puts 1'), FStats.Statistics.ToString);
end;

{ TKVFallbackWrapperTests }

procedure TKVFallbackWrapperTests.NilFallback_Refused;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVFallbackWrapper.Create(Inner, nil);
    end, EKVArgumentError);
end;

procedure TKVFallbackWrapperTests.HealthyPrimary_LeavesTheStandbyAlone;
var
  LStore: IKeyValue;
begin
  FFallback := TKVMemoryStore.Create;
  LStore := TKVFallbackWrapper.Create(Inner, FFallback);

  LStore.Put('a', VALUE_A);

  Assert.AreEqual(VALUE_A, Inner.Get('a'));
  Assert.AreEqual('', FFallback.Get('a'), 'the standby was never touched');
end;

procedure TKVFallbackWrapperTests.FailingPrimary_ReadsFromTheStandby;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  FFallback := TKVMemoryStore.Create;
  FFallback.Put('a', VALUE_A);
  LStore := TKVFallbackWrapper.Create(TKVFailingStore.Create, FFallback);

  Assert.AreEqual(VALUE_A, LStore.Get('a'));
  Assert.IsTrue(LStore.Exists('a'));
  Assert.IsTrue(LStore.TryGetEntry('a', '', LEntry));
  Assert.AreEqual(VALUE_A, LStore.GetMany(['a'])[0]);
end;

procedure TKVFallbackWrapperTests.FailingPrimary_WritesToTheStandby;
var
  LStore: IKeyValue;
begin
  FFallback := TKVMemoryStore.Create;
  LStore := TKVFallbackWrapper.Create(TKVFailingStore.Create, FFallback);

  LStore.Put('a', VALUE_A);
  Assert.AreEqual(VALUE_A, FFallback.Get('a'));

  LStore.PutMany(['b'], [VALUE_B]);
  Assert.AreEqual(VALUE_B, FFallback.Get('b'));

  Assert.IsTrue(LStore.Delete('a'));
  Assert.AreEqual(0, LStore.DeleteMany(['nope']));
end;

procedure TKVFallbackWrapperTests.FallingBack_IsAnnounced;
var
  LWrapper: TKVFallbackWrapper;
  LStore: IKeyValue;
  LOperations: TStringList;
begin
  // A fallback nobody hears about is an outage nobody hears about.
  FFallback := TKVMemoryStore.Create;
  LWrapper := TKVFallbackWrapper.Create(TKVFailingStore.Create, FFallback);
  LStore := LWrapper;

  LOperations := TStringList.Create;
  try
    LWrapper.OnFallback :=
      procedure(const AOperation, AError: string)
      begin
        LOperations.Add(AOperation + ': ' + AError);
      end;

    LStore.Get('a');
    LStore.Put('a', VALUE_A);

    Assert.AreEqual(2, LOperations.Count);
    Assert.IsTrue(LOperations[0].StartsWith('Get: '), LOperations[0]);
    Assert.IsTrue(LOperations[1].Contains('always fails'), LOperations[1]);
  finally
    LOperations.Free;
  end;
end;

procedure TKVFallbackWrapperTests.AMiss_IsNotAFailure;
var
  LStore: IKeyValue;
begin
  // Otherwise the standby becomes a second place to look on every read, and
  // starts serving values the primary deliberately no longer has.
  FFallback := TKVMemoryStore.Create;
  FFallback.Put('a', VALUE_B);
  LStore := TKVFallbackWrapper.Create(Inner, FFallback);

  Assert.AreEqual('', LStore.Get('a'), 'the primary answered, and its answer was no');
end;

procedure TKVFallbackWrapperTests.ABadArgument_IsRaisedNotWorkedAround;
var
  LStore: IKeyValue;
begin
  // The standby would refuse it too, so falling back would only hide the bug.
  FFallback := TKVMemoryStore.Create;
  LStore := TKVFallbackWrapper.Create(TKVFailingStore.Create, FFallback);

  Assert.WillRaise(
    procedure
    begin
      LStore.Put('', VALUE_A);
    end, EKVInvalidKeyError);
  Assert.AreEqual(0, Length((FFallback as IKeyValueEnumerable).Keys));
end;

procedure TKVFallbackWrapperTests.AReadOnlyPrimary_IsNotBypassed;
var
  LReadOnly: IKeyValue;
  LStore: IKeyValue;
begin
  // The primary refuses writes on purpose; a fallback that answered them
  // anyway would defeat the wrapper it is standing in front of.
  FFallback := TKVMemoryStore.Create;
  LReadOnly := TKVReadOnlyWrapper.Create(Inner);
  LStore := TKVFallbackWrapper.Create(LReadOnly, FFallback);

  Assert.WillRaise(
    procedure
    begin
      LStore.Put('a', VALUE_A);
    end, EKVReadOnlyError);
  Assert.AreEqual('', FFallback.Get('a'), 'the standby never saw the write');
end;

procedure TKVFallbackWrapperTests.ACorruptValue_IsNotWorkedAround;
var
  LStore: IKeyValue;
begin
  // A value the primary cannot decode is not a reason to quietly serve the
  // standby's copy instead: that would hide the corruption.
  FFallback := TKVMemoryStore.Create;
  FFallback.Put('a', VALUE_B);
  LStore := TKVFallbackWrapper.Create(TKVCorruptStore.Create, FFallback);

  Assert.WillRaise(
    procedure
    begin
      LStore.Get('a');
    end, EKVSerializationError);
end;

{ TKVThreadSafeWrapperTests }

procedure TKVThreadSafeWrapperTests.OverlappingCalls_AreSerialized;
const
  WORKERS = 4;
  PER_WORKER = 300;
var
  LUnsafe: TKVUnsafeStore;
  LStore: IKeyValue;
  LMismatches: Integer;
begin
  // The store is deliberately unlocked and notices if two calls are ever
  // inside it at once; wrapped, that must never happen.
  LUnsafe := TKVUnsafeStore.Create;
  LStore := TKVThreadSafeWrapper.Create(LUnsafe);

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

        LStore.Put(LKey, LWritten);
        if not LStore.TryGet(LKey, LRead) or (LRead <> LWritten) then
          TInterlocked.Increment(LMismatches);
      end;
    end);

  Assert.AreEqual(0, LMismatches, 'every worker read back what it wrote');
  Assert.IsFalse(LUnsafe.Tripped, 'no two calls were ever inside the store at once');
end;

procedure TKVThreadSafeWrapperTests.Capabilities_FollowTheStore;
var
  LStore: IKeyValue;
  LEnumerable: IKeyValueEnumerable;
  LCullable: IKeyValueCullable;
begin
  // The memory store offers all three, so the wrapper answers them, and the
  // calls, guarded, still work.
  LStore := TKVThreadSafeWrapper.Create(Inner);

  Assert.IsTrue(Supports(LStore, IKeyValueEnumerable, LEnumerable));
  Assert.IsTrue(Supports(LStore, IKeyValueCullable, LCullable));

  Inner.Put('a', VALUE_A, 'users');
  Assert.AreEqual(1, Length(LEnumerable.Keys('users')));
  Assert.AreEqual(1, Length(LEnumerable.Collections));
  Assert.AreEqual(0, LCullable.Cull);
end;

procedure TKVThreadSafeWrapperTests.Capabilities_RefuseWhenTheStoreHasNone;
var
  LStore: IKeyValue;
  LEnumerable: IKeyValueEnumerable;
  LCullable: IKeyValueCullable;
  LDestroyable: IKeyValueDestroyable;
begin
  // The wrapper implements all four so a capability call is guarded like any
  // other. Over a store that has none, Supports is optimistic and the call
  // raises - the same bargain the prefix wrappers make.
  LStore := TKVThreadSafeWrapper.Create(TKVFailingStore.Create);

  Assert.IsTrue(Supports(LStore, IKeyValueEnumerable, LEnumerable));
  Assert.IsTrue(Supports(LStore, IKeyValueCullable, LCullable));
  Assert.IsTrue(Supports(LStore, IKeyValueDestroyable, LDestroyable));

  Assert.WillRaise(
    procedure
    begin
      LEnumerable.Keys('users');
    end, EKVStoreError);
  Assert.WillRaise(
    procedure
    begin
      LCullable.Cull;
    end, EKVStoreError);
  Assert.WillRaise(
    procedure
    begin
      LDestroyable.DestroyAll;
    end, EKVStoreError);
end;

{ TKVWatchThroughWrappersTests }

procedure TKVWatchThroughWrappersTests.PrefixKeys_ReportsItsOwnKeysUnprefixed;
var
  LStore: IKeyValue;
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  LStore := TKVPrefixKeysWrapper.Create(Inner, 't1');
  Assert.IsTrue(Supports(LStore, IKeyValueWatchable, LWatchable));

  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('users', LLog.Handler());
    try
      Memory.Put('t2:b', VALUE_A, 'users');
      Memory.Put('t1:a', VALUE_A, 'users');

      Assert.IsTrue(LLog.Contains('a'), 'its own key, without the prefix');
      Assert.AreEqual(1, LLog.Count, 'another namespace''s key is not reported');

      Memory.DestroyCollection('users');
      Assert.IsTrue(LLog.Contains(''), '"anything may have changed" is passed on');
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVWatchThroughWrappersTests.PrefixCollections_WatchesTheRenamedCollection;
var
  LStore: IKeyValue;
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  LStore := TKVPrefixCollectionsWrapper.Create(Inner, 'app1');
  Assert.IsTrue(Supports(LStore, IKeyValueWatchable, LWatchable));

  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('users', LLog.Handler());
    try
      Memory.Put('b', VALUE_A, 'users');
      Memory.Put('a', VALUE_A, 'app1_users');

      Assert.IsTrue(LLog.Contains('a'));
      Assert.AreEqual(1, LLog.Count, 'the unprefixed collection is someone else''s');
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVWatchThroughWrappersTests.ReadOnly_PassesTheWatchThrough;
var
  LStore: IKeyValue;
  LWatchable: IKeyValueWatchable;
  LLog: TKVChangeLog;
  LWatch: IKVWatch;
begin
  LStore := TKVReadOnlyWrapper.Create(Inner, TKVReadOnlyMode.Refuse);
  Assert.IsTrue(Supports(LStore, IKeyValueWatchable, LWatchable));

  LLog := TKVChangeLog.Create;
  try
    LWatch := LWatchable.Watch('users', LLog.Handler());
    try
      Memory.Put('a', VALUE_A, 'users');
      Assert.IsTrue(LLog.Contains('a'));
    finally
      LWatch := nil;
    end;
  finally
    LLog.Free;
  end;
end;

procedure TKVWatchThroughWrappersTests.ThreadSafe_RefusesWhenTheStoreCannotWatch;
var
  LFailing: IKeyValue;
  LStore: IKeyValue;
  LWatchable: IKeyValueWatchable;
begin
  LFailing := TKVFailingStore.Create;
  LStore := TKVThreadSafeWrapper.Create(LFailing);

  // Optimistic, like the other three capabilities it always implements.
  Assert.IsTrue(Supports(LStore, IKeyValueWatchable, LWatchable));
  Assert.WillRaise(
    procedure
    var
      LWatch: IKVWatch;
    begin
      LWatch := LWatchable.Watch('users',
        procedure (const AKey: string)
        begin
        end);
    end, EKVStoreError);
end;

{ TKVNearCacheWrapperTests }

function TKVNearCacheWrapperTests.Clock: TKVClock;
begin
  Result :=
    function: TDateTime
    begin
      Result := Self.Now;
    end;
end;

function TKVNearCacheWrapperTests.NewCache(const AMaxAge: TKVDuration;
  const AMaxEntries: Integer): TKVNearCacheWrapper;
begin
  FCounting := TKVCountingStore.Create(Clock());
  FCountingRef := FCounting;
  Result := TKVNearCacheWrapper.Create(FCountingRef, AMaxAge, AMaxEntries, Clock());
end;

procedure TKVNearCacheWrapperTests.AStoreThatCannotWatch_IsRefused;
var
  LBlind: IKeyValue;
begin
  // A statistics wrapper does not pass the watch on, so over it the cache
  // would never hear of a change.
  LBlind := TKVStatisticsWrapper.Create(Inner);
  Assert.WillRaise(
    procedure
    var
      LStore: IKeyValue;
    begin
      LStore := TKVNearCacheWrapper.Create(LBlind);
    end, EKVArgumentError);
end;

procedure TKVNearCacheWrapperTests.NonsenseLimits_AreRefused;
begin
  Assert.WillRaise(
    procedure
    var
      LStore: IKeyValue;
    begin
      LStore := TKVNearCacheWrapper.Create(Inner, 0);
    end, EKVArgumentError, 'a MaxAge of 0 would trust a missed change for ever');
  Assert.WillRaise(
    procedure
    var
      LStore: IKeyValue;
    begin
      LStore := TKVNearCacheWrapper.Create(Inner, -1);
    end, EKVArgumentError);
  Assert.WillRaise(
    procedure
    var
      LStore: IKeyValue;
    begin
      LStore := TKVNearCacheWrapper.Create(Inner, 60, 0);
    end, EKVArgumentError);
end;

procedure TKVNearCacheWrapperTests.SecondRead_IsServedLocally;
var
  LCache: IKeyValue;
begin
  LCache := NewCache;
  FCounting.Put('a', VALUE_A, 'users');

  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));
  Assert.IsTrue(LCache.Exists('a', 'users'));
  Assert.AreEqual(1, FCounting.Reads, 'only the first read reached the store');
end;

procedure TKVNearCacheWrapperTests.AMiss_IsNotCached;
var
  LCache: IKeyValue;
begin
  LCache := NewCache;

  Assert.AreEqual('', LCache.Get('nope', 'users'));
  Assert.AreEqual('', LCache.Get('nope', 'users'));
  Assert.AreEqual(2, FCounting.Reads);
end;

procedure TKVNearCacheWrapperTests.AWriteElsewhere_IsSeenAtOnce;
var
  LCache: IKeyValue;
begin
  LCache := NewCache;
  FCounting.Put('a', VALUE_A, 'users');
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));

  // Straight into the store, around the cache: another process, in effect.
  FCounting.Put('a', VALUE_B, 'users');

  Assert.AreEqual(VALUE_B, LCache.Get('a', 'users'));
  Assert.AreEqual(2, FCounting.Reads);
end;

procedure TKVNearCacheWrapperTests.ADeleteElsewhere_IsSeenAtOnce;
var
  LCache: IKeyValue;
begin
  LCache := NewCache;
  FCounting.Put('a', VALUE_A, 'users');
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));

  FCounting.Delete('a', 'users');

  Assert.AreEqual('', LCache.Get('a', 'users'));
end;

procedure TKVNearCacheWrapperTests.ADroppedCollection_IsSeenAtOnce;
var
  LCache: IKeyValue;
begin
  LCache := NewCache;
  FCounting.Put('a', VALUE_A, 'users');
  FCounting.Put('b', VALUE_B, 'users');
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));
  Assert.AreEqual(VALUE_B, LCache.Get('b', 'users'));

  FCounting.DestroyCollection('users');

  Assert.AreEqual('', LCache.Get('a', 'users'));
  Assert.AreEqual('', LCache.Get('b', 'users'));
end;

procedure TKVNearCacheWrapperTests.AWriteThrough_IsSeenAtOnce;
var
  LCache: IKeyValue;
begin
  LCache := NewCache;
  LCache.Put('a', VALUE_A, 'users');
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));

  LCache.Put('a', VALUE_B, 'users');
  Assert.AreEqual(VALUE_B, LCache.Get('a', 'users'));

  LCache.Delete('a', 'users');
  Assert.AreEqual('', LCache.Get('a', 'users'));
end;

procedure TKVNearCacheWrapperTests.Expiry_IsJudgedLocally;
var
  LCache: IKeyValue;
begin
  LCache := NewCache;
  FCounting.Put('a', VALUE_A, 'users', 30);
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));

  Advance(31);

  Assert.AreEqual('', LCache.Get('a', 'users'), 'expired here as it has in the store');
  Assert.AreEqual(1, FCounting.Reads, 'and known without asking the store');
end;

procedure TKVNearCacheWrapperTests.MaxAge_BoundsHowLongAnEntryIsTrusted;
var
  LCache: IKeyValue;
begin
  LCache := NewCache(10);
  FCounting.Put('a', VALUE_A, 'users');
  LCache.Get('a', 'users');

  Advance(11);
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));
  Assert.AreEqual(2, FCounting.Reads, 'held too long, so read again');

  LCache.Get('a', 'users');
  Assert.AreEqual(2, FCounting.Reads, 'and trusted again from then on');
end;

procedure TKVNearCacheWrapperTests.MaxEntries_DropsTheLeastRecentlyRead;
var
  LNear: TKVNearCacheWrapper;
  LCache: IKeyValue;
begin
  LNear := NewCache(60, 2);
  LCache := LNear;
  FCounting.Put('a', VALUE_A, 'users');
  FCounting.Put('b', VALUE_A, 'users');
  FCounting.Put('c', VALUE_A, 'users');

  LCache.Get('a', 'users');
  LCache.Get('b', 'users');
  LCache.Get('a', 'users');   // a is now more recent than b
  LCache.Get('c', 'users');   // full: b goes
  Assert.AreEqual(2, LNear.Count);
  Assert.AreEqual(3, FCounting.Reads);

  LCache.Get('a', 'users');
  Assert.AreEqual(3, FCounting.Reads, 'a was kept');
  LCache.Get('b', 'users');
  Assert.AreEqual(4, FCounting.Reads, 'b was not');
end;

procedure TKVNearCacheWrapperTests.AChangeOvertakingARead_IsNotKept;
var
  LCache: IKeyValue;
  LDone: Boolean;
begin
  LCache := NewCache;
  FCounting.Put('a', VALUE_A, 'users');

  // The read has its answer; before it is back, someone else writes.
  LDone := False;
  FCounting.AfterRead :=
    procedure (AKey: string)
    begin
      if not LDone then
      begin
        LDone := True;
        FCounting.Put('a', VALUE_B, 'users');
      end;
    end;

  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'), 'the read answers what it read');
  Assert.AreEqual(VALUE_B, LCache.Get('a', 'users'), 'but did not keep it');
  FCounting.AfterRead := nil;
end;

procedure TKVNearCacheWrapperTests.ADeadWatch_IsNotTrusted;
var
  LSwitched: TKVSwitchedWatchStore;
  LSwitchedRef: IKeyValue;
  LCache: IKeyValue;
begin
  FCounting := TKVCountingStore.Create(Clock());
  FCountingRef := FCounting;
  LSwitched := TKVSwitchedWatchStore.Create(FCountingRef);
  LSwitchedRef := LSwitched;
  LCache := TKVNearCacheWrapper.Create(LSwitchedRef, 60, 100, Clock());

  FCounting.Put('a', VALUE_A, 'users');
  LCache.Get('a', 'users');
  LCache.Get('a', 'users');
  Assert.AreEqual(1, FCounting.Reads);

  // The connection drops, and a change made meanwhile is never reported.
  LSwitched.Live := False;
  FCounting.Put('a', VALUE_B, 'users');

  Assert.AreEqual(VALUE_B, LCache.Get('a', 'users'), 'a dead watch vouches for nothing');
  LCache.Get('a', 'users');
  Assert.AreEqual(3, FCounting.Reads, 'and nothing is cached until a watch is live again');

  LSwitched.Live := True;
  LCache.Get('a', 'users');
  LCache.Get('a', 'users');
  Assert.AreEqual(4, FCounting.Reads, 'a new watch, and caching resumes');
  Assert.IsTrue(LSwitched.WatchesStarted >= 2);
end;

procedure TKVNearCacheWrapperTests.AWatchThatCannotStart_LeavesReadsUncached;
var
  LSwitched: TKVSwitchedWatchStore;
  LSwitchedRef: IKeyValue;
  LCache: IKeyValue;
begin
  FCounting := TKVCountingStore.Create(Clock());
  FCountingRef := FCounting;
  LSwitched := TKVSwitchedWatchStore.Create(FCountingRef);
  LSwitchedRef := LSwitched;
  LSwitched.Failing := True;
  LCache := TKVNearCacheWrapper.Create(LSwitchedRef, 60, 100, Clock());

  FCounting.Put('a', VALUE_A, 'users');

  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'), 'the read still works');
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));
  Assert.AreEqual(2, FCounting.Reads, 'but nothing was cached');
end;

procedure TKVNearCacheWrapperTests.Clear_DropsEverything;
var
  LNear: TKVNearCacheWrapper;
  LCache: IKeyValue;
begin
  LNear := NewCache;
  LCache := LNear;
  FCounting.Put('a', VALUE_A, 'users');
  LCache.Get('a', 'users');
  Assert.AreEqual(1, LNear.Count);

  LNear.Clear;

  Assert.AreEqual(0, LNear.Count);
  LCache.Get('a', 'users');
  Assert.AreEqual(2, FCounting.Reads);
end;

procedure TKVNearCacheWrapperTests.OverAReadOnlyView_SeesWritesUnderneath;
var
  LReadOnly: IKeyValue;
  LCache: IKeyValue;
begin
  FCounting := TKVCountingStore.Create(Clock());
  FCountingRef := FCounting;
  LReadOnly := TKVReadOnlyWrapper.Create(FCountingRef, TKVReadOnlyMode.Refuse);
  LCache := TKVNearCacheWrapper.Create(LReadOnly, 60, 100, Clock());

  FCounting.Put('a', VALUE_A, 'users');
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));
  FCounting.Put('a', VALUE_B, 'users');
  Assert.AreEqual(VALUE_B, LCache.Get('a', 'users'));
end;

procedure TKVNearCacheWrapperTests.OverPrefixedKeys_SeesWritesUnderneath;
var
  LPrefixed: IKeyValue;
  LCache: IKeyValue;
begin
  FCounting := TKVCountingStore.Create(Clock());
  FCountingRef := FCounting;
  LPrefixed := TKVPrefixKeysWrapper.Create(FCountingRef, 't1');
  LCache := TKVNearCacheWrapper.Create(LPrefixed, 60, 100, Clock());

  FCounting.Put('t1:a', VALUE_A, 'users');
  Assert.AreEqual(VALUE_A, LCache.Get('a', 'users'));
  FCounting.Put('t1:a', VALUE_B, 'users');
  Assert.AreEqual(VALUE_B, LCache.Get('a', 'users'));
  Assert.AreEqual(2, FCounting.Reads);

  FCounting.Put('t2:a', VALUE_A, 'users');
  Assert.AreEqual(VALUE_B, LCache.Get('a', 'users'));
  Assert.AreEqual(2, FCounting.Reads, 'another namespace''s write leaves this one cached');
end;

initialization
  TDUnitX.RegisterTestFixture(TKVWrapperBaseTests);
  TDUnitX.RegisterTestFixture(TKVPrefixKeysWrapperTests);
  TDUnitX.RegisterTestFixture(TKVPrefixCollectionsWrapperTests);
  TDUnitX.RegisterTestFixture(TKVReadOnlyWrapperTests);
  TDUnitX.RegisterTestFixture(TKVTTLClampWrapperTests);
  TDUnitX.RegisterTestFixture(TKVLoggingWrapperTests);
  TDUnitX.RegisterTestFixture(TKVStatisticsWrapperTests);
  TDUnitX.RegisterTestFixture(TKVFallbackWrapperTests);
  TDUnitX.RegisterTestFixture(TKVThreadSafeWrapperTests);
  TDUnitX.RegisterTestFixture(TKVWatchThroughWrappersTests);
  TDUnitX.RegisterTestFixture(TKVNearCacheWrapperTests);

end.
