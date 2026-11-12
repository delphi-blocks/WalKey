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
///   A WalKey store over NATS JetStream Key/Value.
///
///   A collection is a bucket and a key is a key - with two adjustments the
///   medium forces. NATS allows only letters, digits, '_' and '-' in a bucket
///   name and only a slightly wider set in a key, while WalKey allows any
///   printable text; a name that does not fit is therefore encoded, reversibly,
///   and decoded again when listing. Nothing else is translated: the value is a
///   WalKey envelope, so the entry keeps its own creation instant and expiry
///   and this store needs no view of the clock beyond the one every store has.
///
///   Buckets are named '&lt;prefix&gt;_&lt;collection&gt;' so one account can hold
///   several stores, and listing looks only under this store's prefix.
///
///   Requires a nats-server with JetStream enabled, and the nats.delphi client
///   library. Neither is a dependency of WalKey itself: this unit is not in any
///   package, and a project that does not use it never builds it.
/// </summary>
unit WalKey.Stores.NATS;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  System.NetEncoding,
  Nats.Consts,
  Nats.Connection,
  Nats.Exceptions,
  Nats.JetStream.Consts,
  Nats.JetStream.Client,
  Nats.JetStream.Entities,
  Nats.JetStream.KV,
  { Last, so the unqualified TKVEntry is WalKey's and not Nats.JetStream.KV's }
  WalKey.Core;

type
  {$SCOPEDENUMS ON}
  /// <summary>
  ///   What a value is stored as.
  /// </summary>
  TKVNatsValueMode = (
    /// <summary>
    ///   The WalKey envelope: the value plus its creation instant and expiry,
    ///   as JSON. The default, and the only mode in which an entry has a TTL
    ///   of its own.
    /// </summary>
    Envelope,
    /// <summary>
    ///   The value verbatim, so another NATS client that knows nothing of
    ///   WalKey can read and write the same bucket. An entry then has no expiry
    ///   of its own, and a Put that asks for one is refused.
    /// </summary>
    Bare
  );
  {$SCOPEDENUMS OFF}

  /// <summary>
  ///   Keeps entries in NATS JetStream Key/Value buckets, one bucket per
  ///   collection. Every call is a round trip to the server; there is no local
  ///   cache of values.
  /// </summary>
  TKVNatsStore = class(TKVStoreBase,
    IKeyValueEnumerable,
    IKeyValueCullable,
    IKeyValueDestroyable,
    IKeyValueWatchable)
  private
    FContext: TJetStreamContext;
    FBucketPrefix: string;
    FValueMode: TKVNatsValueMode;
    FLock: TCriticalSection;
    { Collections whose bucket this instance has already created, so a write
      does not pay for the check every time. }
    FBuckets: TDictionary<string, Boolean>;

    /// <summary>
    ///   The collection a bucket belongs to, or False when the bucket is not
    ///   this store's.
    /// </summary>
    function CollectionOfBucket(const ABucket: string; out ACollection: string): Boolean;
    /// <summary>
    ///   Whether the bucket's stream is there.
    /// </summary>
    function BucketExists(const ABucket: string): Boolean;
    /// <summary>
    ///   Creates the collection's bucket if it is not already known to be
    ///   there. Creating one that exists is not an error, so a lost race is
    ///   not one either.
    /// </summary>
    procedure EnsureBucket(const ACollection: string);
    /// <summary>
    ///   Forgets a collection whose bucket has been dropped.
    /// </summary>
    procedure ForgetCollection(const ACollection: string);
    /// <summary>
    ///   Reads and decodes one entry. False for a miss, a deleted key, a
    ///   collection that does not exist, or a value that is not a WalKey
    ///   envelope.
    /// </summary>
    function ReadEntry(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean;
    /// <summary>
    ///   Every key of a collection, expired ones included - what Cull needs and
    ///   Keys filters.
    /// </summary>
    function RawKeys(const ACollection: string): TArray<string>;
  protected
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
    procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;
    function DoDelete(const ACollection, AKey: string): Boolean; override;
  public
    /// <summary>
    ///   Opens a store over a JetStream context.
    /// </summary>
    /// <param name="AContext">
    ///   The JetStream context every bucket is created and read through; nil is
    ///   refused. Neither it nor the connection under it is owned here, so both
    ///   must outlive the store.
    /// </param>
    /// <param name="ABucketPrefix">
    ///   The namespace buckets are created under. Letters, digits, '_' and '-'
    ///   only, since it is part of every bucket name.
    /// </param>
    /// <param name="AValueMode">
    ///   Whether a value is stored as a WalKey envelope or verbatim. Every
    ///   bucket a store touches agrees, so it is fixed here rather than
    ///   changed later.
    /// </param>
    /// <param name="AClock">
    ///   Where the store reads "now" from. Leave it nil for the wall clock.
    /// </param>
    constructor Create(const AContext: TJetStreamContext;
      const ABucketPrefix: string = 'walkey';
      const AValueMode: TKVNatsValueMode = TKVNatsValueMode.Envelope;
      const AClock: TKVClock = nil); reintroduce;
    destructor Destroy; override;

    /// <summary>
    ///   The live keys of a collection. Expired entries are not reported, and
    ///   finding that out means reading each value, so this is not cheap.
    /// </summary>
    function Keys(const ACollection: string = ''): TArray<string>;
    /// <summary>
    ///   Every collection this store has a bucket for, empty ones included.
    /// </summary>
    function Collections: TArray<string>;
    /// <summary>
    ///   Deletes every expired entry, across every collection.
    /// </summary>
    function Cull: Integer;
    /// <summary>
    ///   Drops a collection's bucket and everything in it.
    /// </summary>
    function DestroyCollection(const AName: string): Boolean;
    /// <summary>
    ///   Drops every bucket this store owns.
    /// </summary>
    procedure DestroyAll;

    /// <summary>
    ///   Reports every write and removal in a collection, by any client of the
    ///   bucket, through a JetStream KV watch. Changes arrive on the
    ///   connection's reader thread, a moment after they are made.
    /// </summary>
    /// <remarks>
    ///   <para>
    ///     The watch stops being live when the connection drops, and does not
    ///     come back when it is reopened: the subscription under it is gone.
    ///     A connection that drops and reopens between two IsLive calls is not
    ///     noticed, and neither is the bucket being deleted - a cache built on
    ///     a watch needs a bound on how long it trusts what it holds.
    ///   </para>
    ///   <para>
    ///     A collection with no bucket yet cannot be watched: the watch comes
    ///     back not live, and the bucket is not created for it.
    ///   </para>
    /// </remarks>
    /// <param name="ACollection">The collection to watch; '' is the default one</param>
    /// <param name="AOnChange">Called once per change; nil is refused</param>
    function Watch(const ACollection: string; const AOnChange: TKVChangeProc): IKVWatch;

    /// <summary>
    ///   The bucket a collection is kept in, for anything that wants to look
    ///   at it with the NATS client directly.
    /// </summary>
    /// <param name="ACollection">The collection; '' is the default one</param>
    function BucketName(const ACollection: string): string;
    /// <summary>
    ///   The stream behind a collection's bucket: 'KV_' and the bucket name.
    /// </summary>
    /// <param name="ACollection">The collection; '' is the default one</param>
    function StreamName(const ACollection: string): string;

    /// <summary>
    ///   The JetStream context the store was built over.
    /// </summary>
    property Context: TJetStreamContext read FContext;
    /// <summary>
    ///   The namespace every bucket name starts with.
    /// </summary>
    property BucketPrefix: string read FBucketPrefix;
    /// <summary>
    ///   Whether a value is stored as a WalKey envelope or verbatim.
    /// </summary>
    property ValueMode: TKVNatsValueMode read FValueMode;
  end;

implementation

resourcestring
  SKVNatsNoContext = 'A NATS store needs a JetStream context';
  SKVNatsBareNoTtl = 'A bare NATS value cannot carry a TTL: there is nowhere to record one. Put without a TTL, or build the store in the envelope mode';
  SKVNatsBadPrefix = 'A bucket prefix may hold only letters, digits, "_" and "-"';
  SKVNatsGetFailed = 'Could not read key "%s" in collection "%s": %s';
  SKVNatsPutFailed = 'Could not write key "%s" in collection "%s": %s';
  SKVNatsDeleteFailed = 'Could not delete key "%s" in collection "%s": %s';
  SKVNatsKeysFailed = 'Could not list collection "%s": %s';
  SKVNatsCollectionsFailed = 'Could not list the buckets: %s';
  SKVNatsWatchFailed = 'Could not watch collection "%s": %s';
  SKVNatsNoChangeHandler = 'A watch needs a handler to report changes to';

const
  { A name that fits its namespace is stored as itself under the first mark; one
    that does not is stored base64url under the second. Every stored name starts
    with one of them, which is what makes the decode a function. }
  NAME_PLAIN = 'v';
  NAME_ENCODED = 'x';
  BUCKET_SEPARATOR = '_';

/// <summary>
///   Base64url, unpadded - the RTL encoder emits standard base64 with line
///   breaks, and neither '+' nor a line break is allowed in a NATS name.
/// </summary>
function Base64UrlEncode(const AText: string): string;
begin
  Result := TNetEncoding.Base64.EncodeBytesToString(TEncoding.UTF8.GetBytes(AText));
  Result := Result.Replace(sLineBreak, '').Replace(#13, '').Replace(#10, '')
                   .Replace('+', '-').Replace('/', '_').Replace('=', '');
end;

function Base64UrlDecode(const AText: string): string;
var
  LText: string;
begin
  LText := AText.Replace('-', '+').Replace('_', '/');
  case Length(LText) mod 4 of
    2: LText := LText + '==';
    3: LText := LText + '=';
  end;

  Result := TEncoding.UTF8.GetString(TNetEncoding.Base64.DecodeStringToBytes(LText));
end;

/// <summary>
///   A WalKey name as something the given NATS namespace can hold: verbatim
///   when every character is allowed, base64url when one is not.
/// </summary>
function EncodeName(const AName: string; const AAllowed: TSysCharSet;
  const ANoEdgeDot: Boolean): string;
var
  LChar: Char;
  LFits: Boolean;
begin
  LFits := AName <> '';
  if LFits and ANoEdgeDot then
    LFits := (AName[1] <> NatsConstants.SEP) and (AName[Length(AName)] <> NatsConstants.SEP);

  if LFits then
    for LChar in AName do
      if not CharInSet(LChar, AAllowed) then
      begin
        LFits := False;
        Break;
      end;

  if LFits then
    Result := NAME_PLAIN + AName
  else
    Result := NAME_ENCODED + Base64UrlEncode(AName);
end;

/// <summary>
///   The name EncodeName was given. A name that is not this store's - no mark -
///   is reported as it stands rather than guessed at.
/// </summary>
function DecodeName(const AName: string): string;
begin
  if AName.StartsWith(NAME_PLAIN) then
    Result := AName.Substring(Length(NAME_PLAIN))
  else if AName.StartsWith(NAME_ENCODED) then
    Result := Base64UrlDecode(AName.Substring(Length(NAME_ENCODED)))
  else
    Result := AName;
end;

/// <summary>
///   A key as a NATS KV key.
/// </summary>
function NatsKeyOf(const AKey: string): string;
begin
  Result := EncodeName(AKey, JetStreamConstants.KV.VALID_KEY_CHARS, True);
end;

/// <summary>
///   A NATS KV key back as a WalKey key.
/// </summary>
function WalKeyOf(const ANatsKey: string): string;
begin
  Result := DecodeName(ANatsKey);
end;

type
  /// <summary>
  ///   A running NATS watch. Live for as long as the connection it was made on
  ///   is up; releasing it stops the watch on the server.
  /// </summary>
  TKVNatsWatch = class(TInterfacedObject, IKVWatch)
  private
    FConnection: TNatsConnection;
    FWatcher: IJetStreamKVWatcher;
    FDead: Boolean;
  public
    constructor Create(const AConnection: TNatsConnection; const AWatcher: IJetStreamKVWatcher);
    function IsLive: Boolean;
  end;

  /// <summary>
  ///   What a collection that cannot be watched gets: a watch that was never
  ///   live and reports nothing.
  /// </summary>
  TKVNatsDeadWatch = class(TInterfacedObject, IKVWatch)
  public
    function IsLive: Boolean;
  end;

{ TKVNatsWatch }

constructor TKVNatsWatch.Create(const AConnection: TNatsConnection; const AWatcher: IJetStreamKVWatcher);
begin
  inherited Create;
  FConnection := AConnection;
  FWatcher := AWatcher;
end;

function TKVNatsWatch.IsLive: Boolean;
begin
  { Once down, the subscription is gone for good, even if the connection is
    opened again - so a drop seen once is remembered. A benign race: two
    threads may both write True. }
  if not FDead and not FConnection.Connected then
    FDead := True;
  Result := not FDead;
end;

{ TKVNatsDeadWatch }

function TKVNatsDeadWatch.IsLive: Boolean;
begin
  Result := False;
end;

{ TKVNatsStore }

constructor TKVNatsStore.Create(const AContext: TJetStreamContext;
  const ABucketPrefix: string; const AValueMode: TKVNatsValueMode;
  const AClock: TKVClock);
var
  LChar: Char;
begin
  inherited Create(AClock);

  if not Assigned(AContext) then
    raise EKVArgumentError.Create(SKVNatsNoContext);

  if ABucketPrefix = '' then
    raise EKVArgumentError.Create(SKVNatsBadPrefix);

  for LChar in ABucketPrefix do
    if not CharInSet(LChar, JetStreamConstants.KV.VALID_BUCKET_CHARS) then
      raise EKVArgumentError.Create(SKVNatsBadPrefix);

  FContext := AContext;
  FBucketPrefix := ABucketPrefix;
  FValueMode := AValueMode;
  FLock := TCriticalSection.Create;
  FBuckets := TDictionary<string, Boolean>.Create;
end;

destructor TKVNatsStore.Destroy;
begin
  FBuckets.Free;
  FLock.Free;
  inherited;
end;

function TKVNatsStore.BucketName(const ACollection: string): string;
begin
  Result := FBucketPrefix + BUCKET_SEPARATOR
    + EncodeName(ACollection, JetStreamConstants.KV.VALID_BUCKET_CHARS, False);
end;

function TKVNatsStore.CollectionOfBucket(const ABucket: string;
  out ACollection: string): Boolean;
var
  LRest: string;
  LHead: string;
begin
  ACollection := '';
  LHead := FBucketPrefix + BUCKET_SEPARATOR;

  if not ABucket.StartsWith(LHead) then
    Exit(False);

  LRest := ABucket.Substring(Length(LHead));
  Result := LRest.StartsWith(NAME_PLAIN) or LRest.StartsWith(NAME_ENCODED);
  if Result then
    ACollection := DecodeName(LRest);
end;

function TKVNatsStore.StreamName(const ACollection: string): string;
begin
  Result := JetStreamConstants.KV.STREAM_PREFIX + BucketName(ResolveCollection(ACollection));
end;

function TKVNatsStore.BucketExists(const ABucket: string): Boolean;
begin
  try
    FContext.StreamInfo(JetStreamConstants.KV.STREAM_PREFIX + ABucket);
    Result := True;
  except
    on E: EJetStreamApiError do
      if E.ErrCode = JetStreamConstants.ErrCode.STREAM_NOT_FOUND then
        Result := False
      else
        raise;
  end;
end;

procedure TKVNatsStore.EnsureBucket(const ACollection: string);
var
  LHandle: TJetStreamKV;
begin
  FLock.Enter;
  try
    if FBuckets.ContainsKey(ACollection) then
      Exit;

    { Creating a bucket that is already there is not an error, so a bucket
      another writer made in the meantime is fine and needs no second look. }
    LHandle := TJetStreamKV.CreateBucket(FContext, BucketName(ACollection));
    LHandle.Free;

    FBuckets.Add(ACollection, True);
  finally
    FLock.Leave;
  end;
end;

procedure TKVNatsStore.ForgetCollection(const ACollection: string);
begin
  FLock.Enter;
  try
    FBuckets.Remove(ACollection);
  finally
    FLock.Leave;
  end;
end;

function TKVNatsStore.ReadEntry(const ACollection, AKey: string;
  out AEntry: TKVEntry): Boolean;
var
  LHandle: TJetStreamKV;
  LNatsEntry: Nats.JetStream.KV.TKVEntry;
  LStoredKey: string;
begin
  AEntry := Default(TKVEntry);
  Result := False;

  try
    LHandle := nil;
    try
      LHandle := TJetStreamKV.Create(FContext, BucketName(ACollection));
      if not LHandle.Get(NatsKeyOf(AKey), LNatsEntry) then
        Exit;

      if FValueMode = TKVNatsValueMode.Bare then
      begin
        { The value is the caller's text verbatim, and there is nowhere for an
          entry's own timestamps to live, so it has none: such an entry never
          expires. A bucket TTL, if the bucket was given one, is the server's
          business and shows up as a miss rather than as a short TTL. }
        AEntry.Value := LNatsEntry.ValueString;
        Result := True;
        Exit;
      end;

      if not TKVEnvelope.TryDecode(LNatsEntry.ValueString, AEntry, LStoredKey) then
        Exit;

      { A value that records a different key is not this key's entry. A wrong
        value would be far worse than a miss. }
      if (LStoredKey <> '') and (LStoredKey <> AKey) then
      begin
        AEntry := Default(TKVEntry);
        Exit;
      end;

      Result := True;
    finally
      LHandle.Free;
    end;
  except
    on E: EJetStreamApiError do
      if E.ErrCode <> JetStreamConstants.ErrCode.STREAM_NOT_FOUND then
        raise EKVStoreError.CreateFmt(SKVNatsGetFailed, [AKey, ACollection, E.Message]);
    on E: ENatsException do
      raise EKVStoreError.CreateFmt(SKVNatsGetFailed, [AKey, ACollection, E.Message]);
  end;
end;

function TKVNatsStore.DoTryGet(const ACollection, AKey: string;
  out AEntry: TKVEntry): Boolean;
begin
  Result := ReadEntry(ACollection, AKey, AEntry);
end;

procedure TKVNatsStore.DoPut(const ACollection, AKey: string; const AEntry: TKVEntry);
var
  LHandle: TJetStreamKV;
  LText: string;
begin
  if (FValueMode = TKVNatsValueMode.Bare) and AEntry.HasExpiry then
    raise EKVArgumentError.Create(SKVNatsBareNoTtl);

  if FValueMode = TKVNatsValueMode.Bare then
    LText := AEntry.Value
  else
    LText := TKVEnvelope.Encode(AEntry, AKey);

  try
    EnsureBucket(ACollection);

    LHandle := nil;
    try
      LHandle := TJetStreamKV.Create(FContext, BucketName(ACollection));
      LHandle.Put(NatsKeyOf(AKey), LText);
    finally
      LHandle.Free;
    end;
  except
    on E: ENatsException do
      raise EKVStoreError.CreateFmt(SKVNatsPutFailed, [AKey, ACollection, E.Message]);
  end;
end;

function TKVNatsStore.DoDelete(const ACollection, AKey: string): Boolean;
var
  LHandle: TJetStreamKV;
  LBucket: string;
begin
  Result := False;
  LBucket := BucketName(ACollection);

  try
    { A tombstone published to a subject no stream captures would wait out the
      publish timeout, so a collection that is not there is left alone. }
    if not BucketExists(LBucket) then
      Exit;

    LHandle := nil;
    try
      LHandle := TJetStreamKV.Create(FContext, LBucket);
      LHandle.Delete(NatsKeyOf(AKey));
      Result := True;
    finally
      LHandle.Free;
    end;
  except
    on E: ENatsException do
      raise EKVStoreError.CreateFmt(SKVNatsDeleteFailed, [AKey, ACollection, E.Message]);
  end;
end;

function TKVNatsStore.RawKeys(const ACollection: string): TArray<string>;
var
  LHandle: TJetStreamKV;
  LKeys: TArray<string>;
  LKey: string;
  LResult: TList<string>;
begin
  LResult := TList<string>.Create;
  try
    try
      LHandle := nil;
      try
        LHandle := TJetStreamKV.Create(FContext, BucketName(ACollection));
        LKeys := LHandle.Keys;
      finally
        LHandle.Free;
      end;

      for LKey in LKeys do
        LResult.Add(WalKeyOf(LKey));
    except
      on E: EJetStreamApiError do
        if E.ErrCode <> JetStreamConstants.ErrCode.STREAM_NOT_FOUND then
          raise EKVStoreError.CreateFmt(SKVNatsKeysFailed, [ACollection, E.Message]);
      on E: ENatsException do
        raise EKVStoreError.CreateFmt(SKVNatsKeysFailed, [ACollection, E.Message]);
    end;

    Result := LResult.ToArray;
  finally
    LResult.Free;
  end;
end;

function TKVNatsStore.Keys(const ACollection: string): TArray<string>;
var
  LCollection: string;
  LKeys: TArray<string>;
  LKey: string;
  LEntry: TKVEntry;
  LResult: TList<string>;
  LNow: TDateTime;
begin
  LNow := UtcNow;
  LCollection := ResolveCollection(ACollection);
  LKeys := RawKeys(LCollection);

  LResult := TList<string>.Create;
  try
    { Expiry lives in the value, not in the bucket, so a key can only be called
      live once its value has been read. Keys is a listing, not a hot path. }
    for LKey in LKeys do
      if ReadEntry(LCollection, LKey, LEntry) and not LEntry.IsExpiredAt(LNow) then
        LResult.Add(LKey);

    Result := LResult.ToArray;
  finally
    LResult.Free;
  end;
end;

function TKVNatsStore.Collections: TArray<string>;
var
  LBuckets: TArray<string>;
  LBucket: string;
  LCollection: string;
  LResult: TList<string>;
begin
  LResult := TList<string>.Create;
  try
    try
      LBuckets := TJetStreamKV.ListBuckets(FContext);
      for LBucket in LBuckets do
        if CollectionOfBucket(LBucket, LCollection) then
          LResult.Add(LCollection);
    except
      on E: ENatsException do
        raise EKVStoreError.CreateFmt(SKVNatsCollectionsFailed, [E.Message]);
    end;

    Result := LResult.ToArray;
  finally
    LResult.Free;
  end;
end;

function TKVNatsStore.Cull: Integer;
var
  LCollection: string;
  LKey: string;
  LEntry: TKVEntry;
  LNow: TDateTime;
begin
  Result := 0;
  LNow := UtcNow;

  for LCollection in Collections do
    for LKey in RawKeys(LCollection) do
      if ReadEntry(LCollection, LKey, LEntry) and LEntry.IsExpiredAt(LNow) then
      begin
        DoDelete(LCollection, LKey);
        Inc(Result);
      end;
end;

function TKVNatsStore.DestroyCollection(const AName: string): Boolean;
var
  LCollection: string;
  LBucket: string;
begin
  LCollection := ResolveCollection(AName);
  LBucket := BucketName(LCollection);

  try
    Result := BucketExists(LBucket);
    if Result then
      TJetStreamKV.DeleteBucket(FContext, LBucket);
  except
    on E: ENatsException do
      raise EKVStoreError.CreateFmt(SKVNatsDeleteFailed, [LCollection, E.Message]);
  end;

  if Result then
    ForgetCollection(LCollection);
end;

function TKVNatsStore.Watch(const ACollection: string; const AOnChange: TKVChangeProc): IKVWatch;
var
  LCollection: string;
  LBucket: string;
  LHandle: TJetStreamKV;
  LWatcher: IJetStreamKVWatcher;
  LOnChange: TKVChangeProc;
begin
  if not Assigned(AOnChange) then
    raise EKVArgumentError.Create(SKVNatsNoChangeHandler);

  LCollection := ResolveCollection(ACollection);
  LBucket := BucketName(LCollection);
  LOnChange := AOnChange;

  try
    LHandle := nil;
    try
      LHandle := TJetStreamKV.Create(FContext, LBucket);
      { UpdatesOnly: the watcher wants to hear about changes, and the current
        contents are not one. The consumer exists by the time this returns,
        so nothing written afterwards is missed. }
      LWatcher := LHandle.WatchAll(
        procedure (const AEntry: Nats.JetStream.KV.TKVEntry)
        begin
          LOnChange(WalKeyOf(AEntry.Key));
        end,
        [TKVWatchOption.UpdatesOnly]);
    finally
      LHandle.Free;
    end;
  except
    on E: EJetStreamApiError do
      if E.ErrCode = JetStreamConstants.ErrCode.STREAM_NOT_FOUND then
        Exit(TKVNatsDeadWatch.Create)
      else
        raise EKVStoreError.CreateFmt(SKVNatsWatchFailed, [LCollection, E.Message]);
    on E: ENatsException do
      raise EKVStoreError.CreateFmt(SKVNatsWatchFailed, [LCollection, E.Message]);
  end;

  Result := TKVNatsWatch.Create(FContext.Connection, LWatcher);
end;

procedure TKVNatsStore.DestroyAll;
var
  LBuckets: TArray<string>;
  LBucket: string;
  LCollection: string;
begin
  try
    LBuckets := TJetStreamKV.ListBuckets(FContext);
    for LBucket in LBuckets do
      if CollectionOfBucket(LBucket, LCollection) then
        TJetStreamKV.DeleteBucket(FContext, LBucket);
  except
    on E: ENatsException do
      raise EKVStoreError.CreateFmt(SKVNatsCollectionsFailed, [E.Message]);
  end;

  FLock.Enter;
  try
    FBuckets.Clear;
  finally
    FLock.Leave;
  end;
end;

end.
