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
///   The NATS store through the shared contract, against a live server.
///
///   This unit needs the nats.delphi checkout, so it is compiled only when
///   WALKEY_NATS is defined: the default test build carries no reference to
///   the NATS library at all. Build it with
///
///     BuildTests.bat 37.0 nats
///
///   which defines WALKEY_NATS and runs only the 'Nats' category. These tests
///   need a nats-server with JetStream on localhost:4222 - the same
///   requirement the nats.delphi library's own live tests have. Every test
///   gets a bucket namespace of its own and drops it again, so a crashed run
///   cannot block the next one.
/// </summary>
unit WalKey.Tests.Stores.NATS;

interface

uses
  System.SysUtils, System.Classes,
  DUnitX.TestFramework,
  Nats.Consts, Nats.Socket, Nats.Socket.Indy, Nats.Connection, Nats.Exceptions,
  Nats.JetStream.Consts, Nats.JetStream.Client, Nats.JetStream.Entities,
  Nats.JetStream.KV,
  { After Nats.JetStream.KV, so the unqualified TKVEntry is WalKey's }
  WalKey.Core, WalKey.Stores.NATS,
  WalKey.Tests.Conformance;

type
  [TestFixture]
  [Category('Nats')]
  TKVNatsStoreTests = class(TKVConformanceTests)
  private
    FConn: TNatsConnection;
    FJs: TJetStreamContext;
    FPrefix: string;
    /// <summary>
    ///   A bucket namespace nothing else has used.
    /// </summary>
    function NewPrefix: string;
    /// <summary>
    ///   Drops every bucket this test made.
    /// </summary>
    procedure DropPrefix;
  protected
    procedure SetupStore; override;
    procedure TearDownStore; override;
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  public
    [SetupFixture] procedure ConnectToServer;
    [TearDownFixture] procedure DisconnectFromServer;

    { What this store does that the contract cannot say }
    [Test] procedure BareMode_StoresTheValueVerbatim;
    [Test] procedure BareMode_RefusesATtl;
    [Test] procedure Names_ThatTheNatsSideCannotHold_AreEncoded;
  end;

implementation

const
  VALUE_BARE = '{"user":42}';

{ TKVNatsStoreTests }

procedure TKVNatsStoreTests.ConnectToServer;
begin
  FConn := TNatsConnection.Create;
  FConn.SetName('WalKeyNatsTests')
       .SetChannel('127.0.0.1', NatsConstants.DEFAULT_PORT, 5000)
       .Open(nil);

  if not FConn.WaitForReady(5000) then
    raise ENatsException.CreateFmt(
      'The NATS tests need a nats-server on 127.0.0.1:%d with JetStream enabled ' +
      '(%s). Start one with "nats-server -js".',
      [NatsConstants.DEFAULT_PORT, FConn.LastError]);

  FJs := TJetStreamContext.Create(FConn);
end;

procedure TKVNatsStoreTests.DisconnectFromServer;
begin
  FJs.Free;
  FConn.Free;
end;

function TKVNatsStoreTests.NewPrefix: string;
begin
  Result := 'walkeytest' + TGUID.NewGuid.ToString
    .Replace('{', '').Replace('}', '').Replace('-', '').Substring(0, 12);
end;

procedure TKVNatsStoreTests.DropPrefix;
var
  LBuckets: TArray<string>;
  LBucket: string;
begin
  if not Assigned(FJs) then
    Exit;

  LBuckets := TJetStreamKV.ListBuckets(FJs);
  for LBucket in LBuckets do
    if LBucket.StartsWith(FPrefix + '_') then
      try
        TJetStreamKV.DeleteBucket(FJs, LBucket);
      except
        on E: ENatsException do
          ; // a bucket that has already gone is not worth failing the teardown for
      end;
end;

procedure TKVNatsStoreTests.SetupStore;
begin
  FPrefix := NewPrefix;
end;

procedure TKVNatsStoreTests.TearDownStore;
begin
  DropPrefix;
end;

function TKVNatsStoreTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result := TKVNatsStore.Create(FJs, FPrefix, TKVNatsValueMode.Envelope, AClock);
end;

procedure TKVNatsStoreTests.BareMode_StoresTheValueVerbatim;
var
  LStore: TKVNatsStore;
  LKv: TJetStreamKV;
  LKeys: TArray<string>;
  LEntry: Nats.JetStream.KV.TKVEntry;
begin
  LStore := TKVNatsStore.Create(FJs, FPrefix, TKVNatsValueMode.Bare);
  try
    LStore.Put('session.1', VALUE_BARE, 'bare');

    { Read the bucket with the NATS client directly: a bare store must leave the
      payload itself there, not a WalKey envelope. }
    LKv := TJetStreamKV.Create(FJs, LStore.BucketName('bare'));
    try
      LKeys := LKv.Keys;
      Assert.AreEqual(1, Length(LKeys));
      Assert.IsTrue(LKv.Get(LKeys[0], LEntry));
      Assert.AreEqual(VALUE_BARE, LEntry.ValueString);
    finally
      LKv.Free;
    end;

    Assert.AreEqual(VALUE_BARE, LStore.Get('session.1', 'bare'));
  finally
    LStore.Free;
  end;
end;

procedure TKVNatsStoreTests.BareMode_RefusesATtl;
var
  LStore: TKVNatsStore;
begin
  LStore := TKVNatsStore.Create(FJs, FPrefix, TKVNatsValueMode.Bare);
  try
    Assert.WillRaise(
      procedure
      begin
        LStore.Put('a', VALUE_BARE, 'bare', 60);
      end, EKVArgumentError);
  finally
    LStore.Free;
  end;
end;

procedure TKVNatsStoreTests.Names_ThatTheNatsSideCannotHold_AreEncoded;
var
  LStore: TKVNatsStore;
  LKv: TJetStreamKV;
  LKeys: TArray<string>;
begin
  LStore := TKVNatsStore.Create(FJs, FPrefix);
  try
    LStore.Put('a key with spaces', VALUE_BARE, 'a collection with spaces');
    Assert.AreEqual(VALUE_BARE,
      LStore.Get('a key with spaces', 'a collection with spaces'));

    LKv := TJetStreamKV.Create(FJs, LStore.BucketName('a collection with spaces'));
    try
      LKeys := LKv.Keys;
      Assert.AreEqual(1, Length(LKeys));
      Assert.AreNotEqual('a key with spaces', LKeys[0],
        'the NATS key is an encoded form of the WalKey one');
    finally
      LKv.Free;
    end;
  finally
    LStore.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TKVNatsStoreTests);

end.
