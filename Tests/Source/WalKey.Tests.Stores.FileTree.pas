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
///   The file-tree store through the shared contract, plus what is its own:
///   how names become file names, what the tree looks like on disk, and how
///   it behaves when the disk has something on it that the store did not put
///   there.
///
///   Every test runs against a fresh folder under the system temp directory,
///   removed again on the way out.
/// </summary>
unit WalKey.Tests.Stores.FileTree;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Types, System.Hash,
  System.JSON, System.SyncObjs, System.Threading,
  DUnitX.TestFramework,
  WalKey.Core, WalKey.Stores.FileTree,
  WalKey.Tests.Conformance;

type
  [TestFixture]
  TKVFileTreeStoreTests = class(TKVConformanceTests)
  private
    FRoot: string;
    FFiles: TKVFileTreeStore;
    /// <summary>
    ///   The file an entry should be in, worked out independently of the
    ///   store so a test can look at the tree rather than ask the store.
    /// </summary>
    function PathOf(const ACollection, AKey: string): string;
    /// <summary>
    ///   Starts a task that writes AValue under AKey AAttempts times, keeping
    ///   every failure in AErrors rather than letting it escape the task, so a
    ///   race shows up as a failed assertion and not as a crash.
    /// </summary>
    function StartWriter(const ACollection, AKey, AValue: string;
      const AAttempts: Integer; const AErrors: TStringList;
      const ALock: TCriticalSection): ITask;
    /// <summary>
    ///   Starts a task that writes, reads and deletes under one key AAttempts
    ///   times, keeping every distinct failure - so the read-then-delete race
    ///   shows up as a failed assertion rather than as a crash.
    /// </summary>
    function StartMangler(const AWorker, AAttempts: Integer;
      const AErrors: TStringList; const ALock: TCriticalSection): ITask;
  protected
    procedure SetupStore; override;
    procedure TearDownStore; override;
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  public
    { Names }
    [Test] procedure SafeName_KeepsAPlainName;
    [Test] procedure SafeName_HashesUppercase;
    [Test] procedure SafeName_HashesALongName;
    [Test] procedure SafeName_HashesAnAwkwardName;
    [Test] procedure SafeName_HashesAReservedDeviceName;
    [Test] procedure SafeName_IsStable;
    [Test] procedure SafeName_HashedNameIsNeverAPlainName;

    { The tree on disk }
    [Test] procedure Put_WritesOneFilePerEntry;
    [Test] procedure Put_WritesAnEnvelopeCarryingTheKey;
    [Test] procedure Put_CreatesNothingUntilItIsCalled;
    [Test] procedure Reads_CreateNothing;
    [Test] procedure Delete_RemovesTheFile;
    [Test] procedure DestroyAll_LeavesTheRootInPlace;
    [Test] procedure Create_EmptyRootPath_Raises;

    { Names that would escape or collide }
    [Test] procedure KeyWithAPath_StaysInsideItsCollection;
    [Test] procedure CollectionWithAPath_StaysInsideTheRoot;
    [Test] procedure KeysDifferingOnlyInCase_AreDistinctEntries;

    { What the store can recover from what is on disk }
    [Test] procedure Keys_RecoversAHashedKey;
    [Test] procedure Collections_RecoversAHashedCollectionName;
    [Test] procedure Collections_ReadsAMarkerWithABom;
    [Test] procedure Keys_IgnoresALeftoverTempFile;

    { Persistence, and disks that lie }
    [Test] procedure AnotherStoreOverTheSameFolder_SeesTheSameEntries;
    [Test] procedure ExpiryOutlivesTheInstance;
    [Test] procedure ACorruptFile_ReadsAsAMiss;
    [Test] procedure AFileUnderTheWrongName_ReadsAsAMiss;
    [Test] procedure AFileWithoutAKey_ReadsAsAMiss;
    [Test] procedure AFileWithAnUnreadableKey_ReadsAsAMiss;
    [Test] procedure AFileWithAnUnreadableExpiry_ReadsAsAMiss;
    [Test] procedure AFileWithABom_IsStillRead;

    { Concurrency }
    [Test] procedure ConcurrentWriters_OnOneKey_DoNotFail;
    [Test] procedure ConcurrentWriters_OnANewCollection_DoNotFail;
    [Test] procedure ConcurrentWritersAndDeleters_DoNotFail;
  end;

implementation

const
  VALUE_A = '{"name":"Alice"}';
  VALUE_B = '{"name":"Bob"}';

{ TKVFileTreeStoreTests }

procedure TKVFileTreeStoreTests.SetupStore;
begin
  FRoot := TPath.Combine(TPath.GetTempPath,
    'walkey-test-' + TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
end;

procedure TKVFileTreeStoreTests.TearDownStore;
begin
  FFiles := nil;
  if TDirectory.Exists(FRoot) then
    try
      TDirectory.Delete(FRoot, True);
    except
      // A test folder left behind is not worth failing a green run for.
    end;
end;

function TKVFileTreeStoreTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  FFiles := TKVFileTreeStore.Create(FRoot, AClock);
  Result := FFiles;
end;

function TKVFileTreeStoreTests.PathOf(const ACollection, AKey: string): string;
begin
  Result := TPath.Combine(TPath.Combine(FRoot, TKVFileTreeStore.SafeName(ACollection)),
    TKVFileTreeStore.SafeName(AKey) + '.json');
end;

procedure TKVFileTreeStoreTests.SafeName_KeepsAPlainName;
begin
  Assert.AreEqual('abc', TKVFileTreeStore.SafeName('abc'));
  Assert.AreEqual('user.profile.v2', TKVFileTreeStore.SafeName('user.profile.v2'));
  Assert.AreEqual('order-1234_x', TKVFileTreeStore.SafeName('order-1234_x'));
end;

procedure TKVFileTreeStoreTests.SafeName_HashesUppercase;
begin
  // Not because uppercase is unsafe, but because Windows would fold these two
  // onto one file and merge entries the contract keeps apart.
  Assert.AreNotEqual('Key', TKVFileTreeStore.SafeName('Key'));
  Assert.AreNotEqual(TKVFileTreeStore.SafeName('Key'), TKVFileTreeStore.SafeName('key'));
end;

procedure TKVFileTreeStoreTests.SafeName_HashesALongName;
var
  LKey: string;
begin
  LKey := StringOfChar('k', 200);
  Assert.AreNotEqual(LKey, TKVFileTreeStore.SafeName(LKey));
  Assert.IsTrue(Length(TKVFileTreeStore.SafeName(LKey)) < 100, 'a hash is short');
end;

procedure TKVFileTreeStoreTests.SafeName_HashesAnAwkwardName;
begin
  Assert.AreNotEqual('a/b', TKVFileTreeStore.SafeName('a/b'));
  Assert.AreNotEqual('a b', TKVFileTreeStore.SafeName('a b'));
  Assert.AreNotEqual('..', TKVFileTreeStore.SafeName('..'));
  Assert.AreNotEqual('a:b', TKVFileTreeStore.SafeName('a:b'));
end;

procedure TKVFileTreeStoreTests.SafeName_HashesAReservedDeviceName;
begin
  // 'con.json' is not a file Windows will let you make.
  Assert.AreNotEqual('con', TKVFileTreeStore.SafeName('con'));
  Assert.AreNotEqual('lpt1', TKVFileTreeStore.SafeName('lpt1'));
  Assert.AreEqual('console', TKVFileTreeStore.SafeName('console'), 'only the exact names');
end;

procedure TKVFileTreeStoreTests.SafeName_IsStable;
begin
  // The same key must reach the same file in another process, another run and
  // another version: the hash is the address of the entry.
  Assert.AreEqual(TKVFileTreeStore.SafeName('Key'), TKVFileTreeStore.SafeName('Key'));
end;

procedure TKVFileTreeStoreTests.SafeName_HashedNameIsNeverAPlainName;
var
  LHex: string;
begin
  // The two name spaces stay apart only while a hashed name is longer than any
  // plain one: 'h_' plus 64 hex digits is 66 characters, and MAX_PLAIN_NAME is
  // 64. Raise MAX_PLAIN_NAME to 66 and this key becomes a plain name that can
  // collide with whichever hash lands on it.
  LHex := 'h_' + StringOfChar('a', 64);
  Assert.AreEqual(66, Length(LHex));
  Assert.AreNotEqual(LHex, TKVFileTreeStore.SafeName(LHex));
  Assert.IsTrue(TKVFileTreeStore.SafeName(LHex).StartsWith('h_'));
end;

procedure TKVFileTreeStoreTests.Put_WritesOneFilePerEntry;
begin
  Store.Put('a', VALUE_A, 'users');

  Assert.IsTrue(TFile.Exists(PathOf('users', 'a')), 'the entry file');
  Assert.AreEqual(1, Length(TDirectory.GetFiles(
    TPath.Combine(FRoot, 'users'), '*.json')));
end;

procedure TKVFileTreeStoreTests.Put_WritesAnEnvelopeCarryingTheKey;
var
  LJson: TJSONObject;
begin
  Store.Put('Mixed Case Key', VALUE_A, 'users', 60);

  LJson := TJSONObject.ParseJSONValue(
    TEncoding.UTF8.GetString(TFile.ReadAllBytes(PathOf('users', 'Mixed Case Key'))))
    as TJSONObject;
  try
    Assert.AreEqual(VALUE_A, LJson.GetValue<string>('v'));
    Assert.AreEqual('Mixed Case Key', LJson.GetValue<string>('k'),
      'the key, since the file name is a hash');
    Assert.IsNotNull(LJson.GetValue('e'), 'the expiry');
  finally
    LJson.Free;
  end;
end;

procedure TKVFileTreeStoreTests.Put_CreatesNothingUntilItIsCalled;
begin
  Assert.IsFalse(TDirectory.Exists(FRoot), 'constructing a store touches no disk');

  Store.Put('a', VALUE_A);
  Assert.IsTrue(TDirectory.Exists(FRoot));
end;

procedure TKVFileTreeStoreTests.Reads_CreateNothing;
begin
  Assert.AreEqual('', Store.Get('a'));
  Assert.AreEqual(0, Length(FFiles.Keys));
  Assert.AreEqual(0, Length(FFiles.Collections));
  Assert.AreEqual(0, FFiles.Cull);

  Assert.IsFalse(TDirectory.Exists(FRoot), 'a store only read from leaves no trace');
end;

procedure TKVFileTreeStoreTests.Delete_RemovesTheFile;
begin
  Store.Put('a', VALUE_A);
  Assert.IsTrue(TFile.Exists(PathOf(KV_DEFAULT_COLLECTION, 'a')));

  Store.Delete('a');
  Assert.IsFalse(TFile.Exists(PathOf(KV_DEFAULT_COLLECTION, 'a')));
end;

procedure TKVFileTreeStoreTests.DestroyAll_LeavesTheRootInPlace;
begin
  Store.Put('a', VALUE_A, 'one');
  Store.Put('a', VALUE_B, 'two');

  FFiles.DestroyAll;

  Assert.IsTrue(TDirectory.Exists(FRoot), 'the root is the store, not its contents');
  Assert.AreEqual(0, Length(TDirectory.GetDirectories(FRoot)));
end;

procedure TKVFileTreeStoreTests.Create_EmptyRootPath_Raises;
begin
  // An empty root would be the process's working directory, which is never
  // what a caller who forgot to configure one meant.
  Assert.WillRaise(
    procedure
    begin
      TKVFileTreeStore.Create('');
    end, EKVArgumentError);
end;

procedure TKVFileTreeStoreTests.KeyWithAPath_StaysInsideItsCollection;
begin
  Store.Put('../../escaped', VALUE_A, 'users');

  Assert.AreEqual(VALUE_A, Store.Get('../../escaped', 'users'), 'still readable');
  Assert.AreEqual(1, Length(TDirectory.GetFiles(TPath.Combine(FRoot, 'users'), '*.json')),
    'written inside the collection, under a hashed name');
  Assert.AreEqual(1, Length(TDirectory.GetDirectories(FRoot)), 'nothing climbed out');
end;

procedure TKVFileTreeStoreTests.CollectionWithAPath_StaysInsideTheRoot;
begin
  Store.Put('a', VALUE_A, '../escaped');

  Assert.AreEqual(VALUE_A, Store.Get('a', '../escaped'));
  Assert.AreEqual(1, Length(TDirectory.GetDirectories(FRoot)));
end;

procedure TKVFileTreeStoreTests.KeysDifferingOnlyInCase_AreDistinctEntries;
begin
  // The whole reason uppercase names are hashed.
  Store.Put('Key', VALUE_A);
  Store.Put('key', VALUE_B);

  Assert.AreEqual(VALUE_A, Store.Get('Key'));
  Assert.AreEqual(VALUE_B, Store.Get('key'));
end;

procedure TKVFileTreeStoreTests.Keys_RecoversAHashedKey;
var
  LKeys: TArray<string>;
begin
  Store.Put('A Key With Spaces', VALUE_A, 'users');

  LKeys := FFiles.Keys('users');
  Assert.AreEqual(1, Length(LKeys));
  Assert.AreEqual('A Key With Spaces', LKeys[0], 'read back out of the envelope');
end;

procedure TKVFileTreeStoreTests.Collections_RecoversAHashedCollectionName;
var
  LCollections: TArray<string>;
begin
  Store.Put('a', VALUE_A, 'A Collection');

  LCollections := FFiles.Collections;
  Assert.AreEqual(1, Length(LCollections));
  Assert.AreEqual('A Collection', LCollections[0], 'read back out of the marker file');
end;

procedure TKVFileTreeStoreTests.Collections_ReadsAMarkerWithABom;
var
  LMarker: string;
begin
  // A marker written by an editor can carry a BOM; the name it holds must not
  // gain one.
  Store.Put('a', VALUE_A, 'A Collection');
  LMarker := TPath.Combine(
    TPath.Combine(FRoot, TKVFileTreeStore.SafeName('A Collection')),
    '.walkey-collection');
  TFile.WriteAllBytes(LMarker,
    TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes('A Collection'));

  Assert.AreEqual(1, Length(FFiles.Collections));
  Assert.AreEqual('A Collection', FFiles.Collections[0]);
end;

procedure TKVFileTreeStoreTests.Keys_IgnoresALeftoverTempFile;
begin
  Store.Put('a', VALUE_A, 'users');
  // What a process killed mid-write leaves behind.
  TFile.WriteAllText(PathOf('users', 'a') + '.tmp', 'half a file');

  Assert.AreEqual(1, Length(FFiles.Keys('users')));
end;

procedure TKVFileTreeStoreTests.AnotherStoreOverTheSameFolder_SeesTheSameEntries;
var
  LOther: IKeyValue;
begin
  Store.Put('a', VALUE_A, 'users');

  LOther := TKVFileTreeStore.Create(FRoot);
  Assert.AreEqual(VALUE_A, LOther.Get('a', 'users'), 'the disk is the state');
end;

procedure TKVFileTreeStoreTests.ExpiryOutlivesTheInstance;
var
  LNow: TDateTime;
  LOther: IKeyValue;
begin
  Store.Put('a', VALUE_A, 'users', 60);
  Advance(120);
  LNow := Now;

  // A second store, same folder, same clock: the expiry travelled in the file.
  LOther := TKVFileTreeStore.Create(FRoot,
    function: TDateTime
    begin
      Result := LNow;
    end);
  Assert.AreEqual('', LOther.Get('a', 'users'));
end;

procedure TKVFileTreeStoreTests.ACorruptFile_ReadsAsAMiss;
begin
  Store.Put('a', VALUE_A, 'users');
  TFile.WriteAllText(PathOf('users', 'a'), 'this is not an envelope');

  Assert.AreEqual('', Store.Get('a', 'users'), 'a miss, not an exception');
  Assert.AreEqual(0, Length(FFiles.Keys('users')));
end;

procedure TKVFileTreeStoreTests.AFileUnderTheWrongName_ReadsAsAMiss;
var
  LEntry: TKVEntry;
begin
  // Whatever put this file here, it is not the entry for 'a': the envelope
  // says so. A wrong value would be far worse than a miss.
  Store.Put('a', VALUE_A, 'users');
  LEntry := TKVEntry.Create(VALUE_B, Now, 0);
  TFile.WriteAllBytes(PathOf('users', 'a'),
    TEncoding.UTF8.GetBytes(TKVEnvelope.Encode(LEntry, 'a-different-key')));

  Assert.AreEqual('', Store.Get('a', 'users'));
end;

procedure TKVFileTreeStoreTests.AFileWithoutAKey_ReadsAsAMiss;
var
  LEntry: TKVEntry;
begin
  // The store writes a key into every file it makes, so a file with none is
  // not one of its entries and must not be served as though it were the key
  // that was asked for.
  Store.Put('a', VALUE_A, 'users');
  LEntry := TKVEntry.Create(VALUE_B, Now, 0);
  TFile.WriteAllBytes(PathOf('users', 'a'),
    TEncoding.UTF8.GetBytes(TKVEnvelope.Encode(LEntry)));

  Assert.AreEqual('', Store.Get('a', 'users'));
  Assert.AreEqual(0, Length(FFiles.Keys('users')), 'and it is not listed either');
end;

procedure TKVFileTreeStoreTests.AFileWithAnUnreadableKey_ReadsAsAMiss;
begin
  // Present but not a string: the envelope is malformed, and a malformed key
  // must never pass for a matching one.
  Store.Put('a', VALUE_A, 'users');
  TFile.WriteAllText(PathOf('users', 'a'), '{"v":"BBBB","c":1,"k":{}}');

  Assert.AreEqual('', Store.Get('a', 'users'));
  Assert.AreEqual(0, Length(FFiles.Keys('users')), 'and it is not listed either');
end;

procedure TKVFileTreeStoreTests.AFileWithAnUnreadableExpiry_ReadsAsAMiss;
begin
  // A corrupt expiry must not read as "never expires": that would promote a
  // broken entry to a permanent one.
  Store.Put('a', VALUE_A, 'users');
  TFile.WriteAllText(PathOf('users', 'a'), '{"v":"BBBB","c":1,"e":{}}');

  Assert.AreEqual('', Store.Get('a', 'users'));
end;

procedure TKVFileTreeStoreTests.AFileWithABom_IsStillRead;
var
  LBytes: TBytes;
  LEntry: TKVEntry;
begin
  // Not something the store writes, but something an editor or another tool
  // readily produces.
  LEntry := TKVEntry.Create(VALUE_A, Now, 0);
  TDirectory.CreateDirectory(TPath.Combine(FRoot, 'users'));
  LBytes := TEncoding.UTF8.GetPreamble;
  LBytes := LBytes + TEncoding.UTF8.GetBytes(TKVEnvelope.Encode(LEntry, 'a'));
  TFile.WriteAllBytes(PathOf('users', 'a'), LBytes);

  Assert.AreEqual(VALUE_A, Store.Get('a', 'users'));
end;

{ Concurrency }

function TKVFileTreeStoreTests.StartWriter(const ACollection, AKey, AValue: string;
  const AAttempts: Integer; const AErrors: TStringList;
  const ALock: TCriticalSection): ITask;
begin
  Result := TTask.Run(
    procedure
    var
      LAttempt: Integer;
    begin
      for LAttempt := 1 to AAttempts do
        try
          Store.Put(AKey, AValue, ACollection);
        except
          on E: Exception do
          begin
            ALock.Enter;
            try
              AErrors.Add(E.ClassName + ': ' + E.Message);
            finally
              ALock.Leave;
            end;
          end;
        end;
    end);
end;

function TKVFileTreeStoreTests.StartMangler(const AWorker, AAttempts: Integer;
  const AErrors: TStringList; const ALock: TCriticalSection): ITask;
begin
  Result := TTask.Run(
    procedure
    var
      LItem: Integer;
      LKey, LValue: string;
    begin
      for LItem := 0 to AAttempts - 1 do
      begin
        LKey := 'hot-' + IntToStr(LItem mod 4);
        LValue := Format('{"w":%d,"i":%d}', [AWorker, LItem]);
        try
          case (AWorker + LItem) mod 4 of
            0, 1: Store.Put(LKey, LValue);
            2: Store.Delete(LKey);
          else
            Store.Get(LKey);
          end;
        except
          on E: Exception do
          begin
            ALock.Enter;
            try
              if AErrors.IndexOf(E.ClassName + ': ' + E.Message) < 0 then
                AErrors.Add(E.ClassName + ': ' + E.Message);
            finally
              ALock.Leave;
            end;
          end;
        end;
      end;
    end);
end;

procedure TKVFileTreeStoreTests.ConcurrentWriters_OnOneKey_DoNotFail;
const
  WRITERS = 8;
  WRITES = 60;
var
  LTasks: TArray<ITask>;
  LErrors: TStringList;
  LLock: TCriticalSection;
  LIndex: Integer;
  LValue: string;
  LKnown: TArray<string>;
  LFound: Boolean;
  LTemps: TStringDynArray;
begin
  // Both races at once: the writers all create a collection folder that does
  // not exist yet, and they all write the same entry file.
  LErrors := TStringList.Create;
  LLock := TCriticalSection.Create;
  try
    SetLength(LKnown, WRITERS);
    for LIndex := 0 to WRITERS - 1 do
      LKnown[LIndex] := '{"writer":' + IntToStr(LIndex) + '}';

    SetLength(LTasks, WRITERS);
    for LIndex := 0 to WRITERS - 1 do
      LTasks[LIndex] := StartWriter('concurrent', 'shared', LKnown[LIndex],
        WRITES, LErrors, LLock);

    TTask.WaitForAll(LTasks);

    Assert.AreEqual(0, LErrors.Count, LErrors.Text);

    LValue := Store.Get('shared', 'concurrent');
    LFound := False;
    for LIndex := 0 to High(LKnown) do
      if LValue = LKnown[LIndex] then
        LFound := True;
    Assert.IsTrue(LFound, 'the value read back is one that was written: ' + LValue);

    LTemps := TDirectory.GetFiles(
      TPath.Combine(FRoot, TKVFileTreeStore.SafeName('concurrent')), '*.tmp');
    Assert.AreEqual(0, Length(LTemps), 'no temporary file is left behind');
  finally
    LLock.Free;
    LErrors.Free;
  end;
end;

procedure TKVFileTreeStoreTests.ConcurrentWriters_OnANewCollection_DoNotFail;
const
  WRITERS = 8;
  WRITES = 40;
var
  LTasks: TArray<ITask>;
  LErrors: TStringList;
  LLock: TCriticalSection;
  LIndex: Integer;
begin
  // Every writer races to create the collection folder, then writes a key of
  // its own; losing the creation race must not become a failed write.
  LErrors := TStringList.Create;
  LLock := TCriticalSection.Create;
  try
    SetLength(LTasks, WRITERS);
    for LIndex := 0 to WRITERS - 1 do
      LTasks[LIndex] := StartWriter('fresh', 'key-' + IntToStr(LIndex),
        '{"writer":' + IntToStr(LIndex) + '}', WRITES, LErrors, LLock);

    TTask.WaitForAll(LTasks);

    Assert.AreEqual(0, LErrors.Count, LErrors.Text);
    for LIndex := 0 to WRITERS - 1 do
      Assert.AreEqual('{"writer":' + IntToStr(LIndex) + '}',
        Store.Get('key-' + IntToStr(LIndex), 'fresh'));
  finally
    LLock.Free;
    LErrors.Free;
  end;
end;

procedure TKVFileTreeStoreTests.ConcurrentWritersAndDeleters_DoNotFail;
const
  WORKERS = 8;
  AROUND = 150;
var
  LTasks: TArray<ITask>;
  LErrors: TStringList;
  LLock: TCriticalSection;
  LIndex: Integer;
begin
  // A write and a delete on one key race the store's read-then-delete: the file
  // can be replaced, removed or held open between the two. None of those is a
  // failure, and a delete must not report one.
  LErrors := TStringList.Create;
  LLock := TCriticalSection.Create;
  try
    SetLength(LTasks, WORKERS);
    for LIndex := 0 to WORKERS - 1 do
      LTasks[LIndex] := StartMangler(LIndex, AROUND, LErrors, LLock);

    TTask.WaitForAll(LTasks);

    Assert.AreEqual(0, LErrors.Count, LErrors.Text);
  finally
    LLock.Free;
    LErrors.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TKVFileTreeStoreTests);

end.
