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
///   A tour of WalKey in one console program: the stores, what TTL does, the
///   wrappers, a near cache per instance, and typed access through Neon. Everything it writes goes into
///   a folder under the system temp directory, which it removes on the way
///   out.
/// </summary>
program WalKeyDemo;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  Neon.Core.Persistence,
  WalKey.Core in '..\..\Source\WalKey.Core.pas',
  WalKey.Stores.Memory in '..\..\Source\WalKey.Stores.Memory.pas',
  WalKey.Stores.FileTree in '..\..\Source\WalKey.Stores.FileTree.pas',
  WalKey.Stores.Null in '..\..\Source\WalKey.Stores.Null.pas',
  WalKey.Wrappers in '..\..\Source\WalKey.Wrappers.pas',
  WalKey.Adapters.Entity in '..\..\Source\WalKey.Adapters.Entity.pas',
  WalKey.Adapters.Neon in '..\..\Source\WalKey.Adapters.Neon.pas';

type
  /// <summary>
  ///   Something to store: the typed adapter turns this into JSON and back.
  /// </summary>
  TUser = record
    Name: string;
    Email: string;
    Age: Integer;
  end;

var
  /// <summary>
  ///   "Now" for the whole demo, so expiry can be shown without waiting for
  ///   it. Every store below is built to read the clock from here.
  /// </summary>
  GNow: TDateTime;
  GRoot: string;

procedure Section(const ATitle: string);
begin
  Writeln;
  Writeln('== ', ATitle, ' ', StringOfChar('=', 60 - Length(ATitle)));
end;

procedure Say(const AMessage: string); overload;
begin
  Writeln('   ', AMessage);
end;

procedure Say(const AFormat: string; const AArgs: array of const); overload;
begin
  Writeln('   ', Format(AFormat, AArgs));
end;

function Clock: TKVClock;
begin
  Result :=
    function: TDateTime
    begin
      Result := GNow;
    end;
end;

procedure Advance(const ASeconds: Double);
begin
  GNow := GNow + (ASeconds / SecsPerDay);
  Say('(the clock moves on %.0f seconds)', [ASeconds]);
end;

function AUser(const AName, AEmail: string; const AAge: Integer): TUser;
begin
  Result.Name := AName;
  Result.Email := AEmail;
  Result.Age := AAge;
end;

{ The basics: a value under a key, in a collection }

procedure ShowTheBasics;
var
  LStore: IKeyValue;
  LValue: string;
begin
  Section('The basics');

  LStore := TKVMemoryStore.Create(Clock());

  LStore.Put('123', '{"name":"Alice"}', 'users');
  Say('Get       -> %s', [LStore.Get('123', 'users')]);
  Say('TryGet    -> %s', [BoolToStr(LStore.TryGet('123', 'users', LValue), True)]);
  Say('Exists    -> %s', [BoolToStr(LStore.Exists('123', 'users'), True)]);

  // A collection is a namespace: the same key elsewhere is a different entry.
  Say('other collection -> "%s"', [LStore.Get('123')]);

  Say('Delete    -> %s', [BoolToStr(LStore.Delete('123', 'users'), True)]);
  Say('Get again -> "%s"  (a miss reads as an empty string)', [LStore.Get('123', 'users')]);
end;

{ TTL, with the clock under our control }

procedure ShowExpiry;
var
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  Section('Expiry');

  LStore := TKVMemoryStore.Create(Clock());

  LStore.Put('session', '{"user":"alice"}', 'sessions', 60);
  LStore.TryGetEntry('session', 'sessions', LEntry);
  Say('stored with a 60 second life, %.0f seconds left',
    [LEntry.TTLRemainingAt(GNow)]);

  Advance(45);
  Say('still there -> %s', [BoolToStr(LStore.Exists('session', 'sessions'), True)]);

  Advance(30);
  Say('now gone    -> %s', [BoolToStr(LStore.Exists('session', 'sessions'), True)]);
  Say('expiry is the same on every store, whether or not the backend has it');
end;

{ The same code, a different store }

procedure ShowTheFileStore;
var
  LStore: IKeyValue;
  LFiles: TKVFileTreeStore;
  LSecond: IKeyValue;
  LFile: string;
begin
  Section('The file store');

  LFiles := TKVFileTreeStore.Create(TPath.Combine(GRoot, 'store'), Clock());
  LStore := LFiles;

  // Exactly the calls the memory store took.
  LStore.Put('alice', '{"name":"Alice"}', 'users');
  LStore.Put('A Key With Spaces', '{"name":"Bob"}', 'users');

  Say('on disk, under %s:', [LFiles.RootPath]);
  for LFile in TDirectory.GetFiles(LFiles.RootPath, '*.json', TSearchOption.soAllDirectories) do
    Say('  %s', [ExtractFileName(LFile)]);
  Say('the second name is a hash, because the key is not a usable file name');

  Say('keys, recovered from the files: %s', [string.Join(', ', LFiles.Keys('users'))]);

  // Another instance over the same folder sees the same entries: the disk is
  // the state.
  LSecond := TKVFileTreeStore.Create(LFiles.RootPath, Clock());
  Say('read by a second store -> %s', [LSecond.Get('alice', 'users')]);
end;

{ Wrappers, stacked }

procedure ShowWrappers;
var
  LMemory: TKVMemoryStore;
  LStatistics: TKVStatisticsWrapper;
  LStore: IKeyValue;
  LEntry: TKVEntry;
begin
  Section('Wrappers');

  // Read from the inside out: a memory store, namespaced per tenant, with a
  // TTL policy over it, counted, and logged.
  LMemory := TKVMemoryStore.Create(Clock());
  LStatistics := TKVStatisticsWrapper.Create(
    TKVTTLClampWrapper.Create(
      TKVPrefixKeysWrapper.Create(LMemory, 'tenant-7'),
      0, 3600, 300));

  LStore := TKVLoggingWrapper.Create(LStatistics,
    procedure(const AMessage: string)
    begin
      Writeln('   ', AMessage);
    end);

  LStore.Put('a', '{"n":1}');           // no TTL asked for: the policy gives 300
  LStore.Put('b', '{"n":2}', '', 9999); // more than the ceiling: cut back to 3600
  LStore.Get('a');
  LStore.Get('nope');

  LStore.TryGetEntry('b', '', LEntry);
  Say('"b" asked for 9999 seconds and got %.0f', [LEntry.TTLRemainingAt(GNow)]);
  Say('%s', [LStatistics.Statistics.ToString]);

  // The keys the store underneath really holds still carry the prefix; the
  // caller above never sees it.
  Say('as stored underneath: %s', [string.Join(', ', LMemory.Keys)]);
end;

{ A near cache in each instance, over one shared store }

procedure ShowNearCache;
var
  LShared: IKeyValue;
  LCacheA, LCacheB: TKVNearCacheWrapper;
  LInstanceA, LInstanceB: IKeyValue;
  LBlind: IKeyValue;
begin
  Section('A near cache per instance');

  // One store shared by two instances of an application. In production this
  // is a TKVNatsStore; the memory store reports its changes the same way.
  LShared := TKVMemoryStore.Create(Clock());

  LCacheA := TKVNearCacheWrapper.Create(LShared, 60, 1000, Clock());
  LInstanceA := LCacheA;
  LCacheB := TKVNearCacheWrapper.Create(LShared, 60, 1000, Clock());
  LInstanceB := LCacheB;

  LShared.Put('jwks', '{"keys":["k1"]}', 'oauth');
  Say('A reads -> %s', [LInstanceA.Get('jwks', 'oauth')]);
  Say('B reads -> %s', [LInstanceB.Get('jwks', 'oauth')]);
  Say('each now answers from its own memory: A holds %d, B holds %d',
    [LCacheA.Count, LCacheB.Count]);

  // A writes through its cache. The store reports the change, and B drops its
  // copy without being told by A.
  LInstanceA.Put('jwks', '{"keys":["k2"]}', 'oauth');
  Say('A rotates the keys; the store tells B, which now holds %d', [LCacheB.Count]);
  Say('B reads -> %s', [LInstanceB.Get('jwks', 'oauth')]);

  // A store that cannot report its changes would leave the cache serving
  // stale values, so the cache refuses it.
  LBlind := TKVFileTreeStore.Create(TPath.Combine(GRoot, 'blind'), Clock());
  try
    TKVNearCacheWrapper.Create(LBlind);
  except
    on E: EKVArgumentError do
      Say('over the file store -> refused: %s', [E.Message]);
  end;
end;

{ Read-only, and the store that keeps nothing }

procedure ShowReadOnlyAndNull;
var
  LSource, LReadOnly, LNull: IKeyValue;
begin
  Section('Read-only, and the null store');

  LSource := TKVMemoryStore.Create(Clock());
  LSource.Put('a', '{"n":1}');

  LReadOnly := TKVReadOnlyWrapper.Create(LSource);
  Say('reads still work -> %s', [LReadOnly.Get('a')]);
  try
    LReadOnly.Put('b', '{"n":2}');
  except
    on E: EKVReadOnlyError do
      Say('writes do not   -> %s', [E.Message]);
  end;

  // The /dev/null of stores: accepts everything, keeps nothing. Swap it in to
  // turn a cache off without unpicking the code around it.
  LNull := TKVNullStore.Create;
  LNull.Put('a', '{"n":1}');
  Say('the null store accepted a write and kept nothing -> "%s"', [LNull.Get('a')]);
end;

{ Typed access }

procedure ShowTypedAccess;
var
  LStore: IKeyValue;
  LUsers: IKVEntityAdapter<TUser>;
  LUser: TUser;
  LBoth: TArray<TUser>;
begin
  Section('Typed access, through Neon');

  LStore := TKVMemoryStore.Create(Clock());
  LUsers := TKVNeonAdapter<TUser>.Create(LStore, 'users');

  LUsers.Put('alice', AUser('Alice', 'alice@example.com', 42), 3600);
  LUsers.Put('bob', AUser('Bob', 'bob@example.com', 37));

  LUser := LUsers.Get('alice');
  Say('read back as a record: %s <%s>, %d', [LUser.Name, LUser.Email, LUser.Age]);
  Say('what the store actually holds: %s', [LStore.Get('alice', 'users')]);

  if not LUsers.TryGet('nobody', LUser) then
    Say('a miss is a miss, and TryGet says so', []);

  LBoth := LUsers.GetMany(['alice', 'bob']);
  Say('two at once: %s and %s', [LBoth[0].Name, LBoth[1].Name]);
end;

{ Listing and sweeping }

procedure ShowCapabilities;
var
  LMemory: TKVMemoryStore;
  LStore: IKeyValue;
  LCullable: IKeyValueCullable;
begin
  Section('Listing and sweeping');

  LMemory := TKVMemoryStore.Create(Clock());
  LStore := LMemory;

  LStore.Put('a', '{"n":1}', 'users');
  LStore.Put('b', '{"n":2}', 'users', 60);
  LStore.Put('c', '{"n":3}', 'orders');

  Say('collections: %s', [string.Join(', ', LMemory.Collections)]);
  Say('keys in users: %s', [string.Join(', ', LMemory.Keys('users'))]);

  Advance(120);
  Say('keys in users now: %s  (the expired one is not listed)',
    [string.Join(', ', LMemory.Keys('users'))]);

  // Expiry is lazy, so something has to sweep. Not every store can, hence the
  // separate interface.
  if Supports(LStore, IKeyValueCullable, LCullable) then
    Say('culled %d expired entries', [LCullable.Cull]);
  Say('%d entries left in all', [LMemory.Count]);
end;

begin
  try
    GNow := TKVUtils.UtcNow;
    GRoot := TPath.Combine(TPath.GetTempPath, 'walkey-demo');
    if TDirectory.Exists(GRoot) then
      TDirectory.Delete(GRoot, True);

    Writeln('WalKey - a tour');

    ShowTheBasics;
    ShowExpiry;
    ShowTheFileStore;
    ShowWrappers;
    ShowNearCache;
    ShowReadOnlyAndNull;
    ShowTypedAccess;
    ShowCapabilities;

    Section('Done');
    if TDirectory.Exists(GRoot) then
      TDirectory.Delete(GRoot, True);
    Say('the demo folder has been removed', []);
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;

  {$IFNDEF CI}
  Writeln;
  Write('Press <Enter> to quit.');
  Readln;
  {$ENDIF}
end.
