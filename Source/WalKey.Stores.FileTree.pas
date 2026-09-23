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
///   The store on disk: one folder per collection, one file per entry, each
///   file a TKVEnvelope. Nothing indexes it, so what the store holds can be
///   read, diffed, backed up and deleted with ordinary tools.
///
///   Names are kept readable where the filesystem allows it. A key of nothing
///   but lowercase letters, digits, '-', '_' and '.', short enough and not a
///   reserved device name, becomes that file name; anything else becomes a
///   SHA-256 hash of the key. Uppercase counts as "anything else" on purpose:
///   Windows would otherwise fold 'Key' and 'key' onto one file and quietly
///   merge two entries the contract says are distinct.
///
///   Because a name can be a hash, every file also carries the key it was
///   written under. That is what lets the store enumerate what it holds, and
///   what makes a read verify that the file it opened is really the key that
///   was asked for.
///
///   Writes go to a temporary file which then replaces the target, so a
///   process that dies mid-write leaves the old entry or no entry, never half
///   of one. Reads are forgiving in the same spirit: a file that cannot be
///   read or parsed is a miss, not an exception.
///
///   Instances hold no state and coordinate through the filesystem alone.
///   Concurrent writers are safe in that no reader ever sees a torn entry, but
///   two writers racing on one key resolve as last-write-wins. A delete is
///   forgiving the same way: a file another writer already removed counts as
///   deleted, and one held open for a moment is retried.
/// </summary>
unit WalKey.Stores.FileTree;

interface

uses
  System.SysUtils, System.Classes, System.IOUtils, System.Types, System.Hash,
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
  WalKey.Core;

type
  TKVFileTreeStore = class(TKVStoreBase,
    IKeyValueEnumerable,
    IKeyValueCullable,
    IKeyValueDestroyable)
  private
    FRootPath: string;

    /// <summary>
    ///   The folder a collection lives in. It is not created here.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    function CollectionPath(const ACollection: string): string;

    /// <summary>
    ///   The file an entry lives in. It is not created here.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <param name="AKey">The validated key</param>
    function EntryPath(const ACollection, AKey: string): string;

    /// <summary>
    ///   Creates a collection's folder if it is not there yet, and writes the
    ///   marker file that records what the collection is really called.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    /// <returns>The folder's path</returns>
    function EnsureCollection(const ACollection: string): string;

    /// <summary>
    ///   The collection name a folder stands for: what its marker file says,
    ///   or the folder's own name when there is no marker.
    /// </summary>
    /// <param name="APath">The folder to name</param>
    function CollectionOf(const APath: string): string;

    /// <summary>
    ///   Reads an entry file, treating anything unreadable as absent.
    /// </summary>
    /// <param name="APath">The file to read</param>
    /// <param name="AEntry">Receives the entry</param>
    /// <param name="AKey">Receives the key the entry was written under</param>
    /// <returns>True when the file held an entry</returns>
    function ReadEntryFile(const APath: string; out AEntry: TKVEntry; out AKey: string): Boolean;

    /// <summary>
    ///   Writes a file through a temporary one, so a reader never sees a
    ///   partial write.
    /// </summary>
    /// <param name="APath">The file to end up with</param>
    /// <param name="AContent">What to put in it, written as UTF-8 without BOM</param>
    procedure WriteFileAtomically(const APath, AContent: string);

    /// <summary>
    ///   Deletes a file, answering False when the filesystem says it is not
    ///   there, is busy, or cannot be removed, and reporting why in AError.
    ///   Anything other than a filesystem failure is passed on.
    /// </summary>
    /// <param name="APath">The file to delete</param>
    /// <param name="AError">Receives the reason when the answer is False</param>
    /// <returns>True when the file is gone</returns>
    function TryDeleteFile(const APath: string; out AError: string): Boolean; overload;

    /// <summary>
    ///   TryDeleteFile when the reason is not wanted.
    /// </summary>
    /// <param name="APath">The file to delete</param>
    /// <returns>True when the file is gone</returns>
    function TryDeleteFile(const APath: string): Boolean; overload;

    /// <summary>
    ///   The temporary file a write goes through. Unique per call, so two
    ///   writers racing on one key never share a temporary file.
    /// </summary>
    /// <param name="APath">The file the write is ultimately for</param>
    /// <returns>The path to put the content in first</returns>
    function TempPath(const APath: string): string;

    /// <summary>
    ///   Moves ASource over ADestination, replacing whatever was there. A
    ///   reader sees the old file or the new one, never a moment with neither.
    /// </summary>
    /// <param name="ASource">The freshly written file</param>
    /// <param name="ADestination">The file to end up with</param>
    procedure MoveOver(const ASource, ADestination: string);

    /// <summary>
    ///   The file names of one collection's entries.
    /// </summary>
    /// <param name="ACollection">The resolved collection name</param>
    function EntryFiles(const ACollection: string): TStringDynArray;
  protected
    function DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean; override;
    procedure DoPut(const ACollection, AKey: string; const AEntry: TKVEntry); override;
    function DoDelete(const ACollection, AKey: string): Boolean; override;
  public
    /// <summary>
    ///   Opens - or, on the first write, starts - a store under a folder.
    /// </summary>
    /// <param name="ARootPath">
    ///   The folder the collections live in. It is created when something is
    ///   first written, so pointing at a folder that does not exist yet is
    ///   fine, and a store nobody writes to leaves no trace.
    /// </param>
    /// <param name="AClock">
    ///   Where the store reads "now" from. Leave it nil for the wall clock.
    /// </param>
    constructor Create(const ARootPath: string; const AClock: TKVClock = nil); reintroduce;

    /// <summary>
    ///   The file name a key or collection name is stored under, extension
    ///   aside: the name itself when the filesystem can hold it verbatim, a
    ///   SHA-256 hash of it otherwise.
    /// </summary>
    /// <param name="AName">The key or collection name to translate</param>
    class function SafeName(const AName: string): string; static;

    /// <summary>
    ///   The live keys of a collection. Every entry file is opened, since a
    ///   key is not always recoverable from its file name and an expired entry
    ///   must not be listed.
    /// </summary>
    /// <param name="ACollection">Collection to list; '' is the default one</param>
    function Keys(const ACollection: string = ''): TArray<string>;

    /// <summary>
    ///   Every collection with a folder on disk, empty ones included.
    /// </summary>
    function Collections: TArray<string>;

    /// <summary>
    ///   Deletes the file of every expired entry, across every collection.
    /// </summary>
    /// <returns>How many entries were removed</returns>
    function Cull: Integer;

    /// <summary>
    ///   Deletes a collection's folder and everything in it.
    /// </summary>
    /// <param name="AName">The collection to drop; '' is the default one</param>
    /// <returns>True when the folder was there</returns>
    function DestroyCollection(const AName: string): Boolean;

    /// <summary>
    ///   Deletes every collection folder, leaving the root itself in place.
    /// </summary>
    procedure DestroyAll;

    /// <summary>
    ///   The folder the collections live in.
    /// </summary>
    property RootPath: string read FRootPath;
  end;

implementation

const
  /// <summary>
  ///   Extension of an entry file. The content is a JSON envelope, so this is
  ///   what it says it is.
  /// </summary>
  ENTRY_EXTENSION = '.json';

  /// <summary>
  ///   Suffix of the temporary file a write goes through first.
  /// </summary>
  TEMP_EXTENSION = '.tmp';

  /// <summary>
  ///   File recording what a collection folder is really called, for the
  ///   folders whose name is a hash. Deliberately not a .json, so listing a
  ///   collection's entries never picks it up.
  /// </summary>
  COLLECTION_MARKER = '.walkey-collection';

  /// <summary>
  ///   Marks a file name that is a hash rather than the name itself.
  /// </summary>
  HASH_PREFIX = 'h_';

  /// <summary>
  ///   Longest name kept verbatim. Well under any filesystem's limit, which
  ///   leaves room for the extension and for a long root path.
  /// </summary>
  MAX_PLAIN_NAME = 64;

  /// <summary>
  ///   How many times a filesystem call another writer can make lose its race
  ///   is retried before the failure is reported. The window is the time a
  ///   writer spends renaming one file, so a handful of tries is plenty and
  ///   the bound keeps a genuinely broken path from spinning forever.
  /// </summary>
  WRITE_RETRIES = 50;

  /// <summary>
  ///   How long to wait between those tries, in milliseconds.
  /// </summary>
  WRITE_RETRY_DELAY_MS = 1;

resourcestring
  SKVWriteFailed = 'Could not write "%s": %s';
  SKVDeleteFailed = 'Could not delete "%s": %s';
  SKVEmptyRootPath = 'A file store needs a root path';

function IsReservedDeviceName(const AName: string): Boolean;
const
  RESERVED: array [0 .. 21] of string = ('con', 'prn', 'aux', 'nul', 'com1',
    'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9', 'lpt1',
    'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9');
var
  LReserved: string;
begin
  for LReserved in RESERVED do
    if AName = LReserved then
      Exit(True);

  Result := False;
end;

/// <summary>
///   The text without a leading UTF-8 byte-order mark. A file written by
///   something else may carry one; a JSON parser and a collection name will
///   not.
/// </summary>
/// <param name="AText">The text to strip</param>
/// <returns>The text as this store would have written it</returns>
function WithoutBom(const AText: string): string;
begin
  Result := AText;
  if (Result <> '') and (Result[1] = #$FEFF) then
    System.Delete(Result, 1, 1);
end;

{ TKVFileTreeStore }

constructor TKVFileTreeStore.Create(const ARootPath: string; const AClock: TKVClock);
begin
  inherited Create(AClock);
  // An empty root would silently be the working directory, which is not what
  // a caller who forgot to configure one meant.
  if Trim(ARootPath) = '' then
    raise EKVArgumentError.Create(SKVEmptyRootPath);

  FRootPath := ExcludeTrailingPathDelimiter(ARootPath);
end;

class function TKVFileTreeStore.SafeName(const AName: string): string;
var
  LChar: Char;
  LPlain: Boolean;
begin
  LPlain := (AName <> '') and (Length(AName) <= MAX_PLAIN_NAME) and (AName[1] <> '.');

  if LPlain then
    for LChar in AName do
      if not CharInSet(LChar, ['a' .. 'z', '0' .. '9', '-', '_', '.']) then
      begin
        LPlain := False;
        Break;
      end;

  if LPlain and IsReservedDeviceName(AName) then
    LPlain := False;

  if LPlain then
    Result := AName
  else
    Result := HASH_PREFIX + THashSHA2.GetHashString(AName).ToLower;
end;

function TKVFileTreeStore.CollectionPath(const ACollection: string): string;
begin
  Result := TPath.Combine(FRootPath, SafeName(ACollection));
end;

function TKVFileTreeStore.EntryPath(const ACollection, AKey: string): string;
begin
  Result := TPath.Combine(CollectionPath(ACollection), SafeName(AKey) + ENTRY_EXTENSION);
end;

function TKVFileTreeStore.EnsureCollection(const ACollection: string): string;
var
  LMarker: string;
  LAttempt: Integer;
  LError: string;
begin
  Result := CollectionPath(ACollection);
  LError := 'the folder could not be created';

  // Another writer can create the folder, or one of the folders on the way to
  // it, between the check and the call; CreateDirectory then reports that it
  // already exists. That is a lost race, not a failure, so it is retried until
  // the folder is really there or the tries run out.
  for LAttempt := 1 to WRITE_RETRIES do
  begin
    if TDirectory.Exists(Result) then
      Break;

    try
      TDirectory.CreateDirectory(Result);
      Break;
    except
      on E: EInOutError do
      begin
        LError := E.Message;
        TThread.Sleep(WRITE_RETRY_DELAY_MS);
      end;
    end;
  end;

  if not TDirectory.Exists(Result) then
    raise EKVStoreError.CreateFmt(SKVWriteFailed, [Result, LError]);

  LMarker := TPath.Combine(Result, COLLECTION_MARKER);
  WriteFileAtomically(LMarker, ACollection);
end;

function TKVFileTreeStore.CollectionOf(const APath: string): string;
var
  LMarker: string;
begin
  Result := TPath.GetFileName(APath);
  LMarker := TPath.Combine(APath, COLLECTION_MARKER);
  if not TFile.Exists(LMarker) then
    Exit;

  try
    Result := WithoutBom(TEncoding.UTF8.GetString(TFile.ReadAllBytes(LMarker)));
  except
    // A marker that is there but cannot be read is not a reason to fail a
    // listing: the folder name stands in for the collection.
    on E: EInOutError do
      Result := TPath.GetFileName(APath);
    on E: EStreamError do
      Result := TPath.GetFileName(APath);
  end;
end;

function TKVFileTreeStore.ReadEntryFile(const APath: string; out AEntry: TKVEntry; out AKey: string): Boolean;
var
  LText: string;
begin
  AEntry := Default(TKVEntry);
  AKey := '';

  try
    LText := TEncoding.UTF8.GetString(TFile.ReadAllBytes(APath));
  except
    // Locked, vanished between the listing and the read, or unreadable: as far
    // as a caller is concerned there is nothing there. Anything else is a real
    // failure and is passed on.
    on E: EInOutError do
      Exit(False);
    on E: EStreamError do
      Exit(False);
  end;

  // TryDecode answers False for anything that is not a WalKey envelope rather
  // than raising, so there is nothing to silence here.
  Result := TKVEnvelope.TryDecode(WithoutBom(LText), AEntry, AKey);
end;

function TKVFileTreeStore.TempPath(const APath: string): string;
begin
  Result := APath + '.' + TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '')
    + TEMP_EXTENSION;
end;

procedure TKVFileTreeStore.MoveOver(const ASource, ADestination: string);
{$IFDEF MSWINDOWS}
var
  LAttempt: Integer;
  LError: Integer;
begin
  for LAttempt := 1 to WRITE_RETRIES do
  begin
    // One rename: the destination is swapped, so a reader sees the old file
    // or the new one and never a moment with neither. TFile.Move would
    // refuse, because it refuses an existing destination, which is why this
    // is not it.
    if MoveFileEx(PChar(ASource), PChar(ADestination),
      MOVEFILE_REPLACE_EXISTING) then
      Exit;

    LError := GetLastError;
    // Another writer replacing the same destination can make this lose the
    // race; wait and try again. A source that has gone means somebody else
    // already finished, which is as good as success.
    if not TFile.Exists(ASource) then
      Exit;

    TThread.Sleep(WRITE_RETRY_DELAY_MS);
  end;

  SetLastError(LError);
  RaiseLastOSError;
end;
{$ELSE}
var
  LAttempt: Integer;
begin
  // No portable replace in the RTL: remove the old file first. The Windows
  // branch above is what keeps this atomic.
  for LAttempt := 1 to WRITE_RETRIES do
    try
      if TFile.Exists(ADestination) then
        TFile.Delete(ADestination);
      TFile.Move(ASource, ADestination);
      Exit;
    except
      on E: EInOutError do
	  begin
        if LAttempt = WRITE_RETRIES then
          raise
        else
          TThread.Sleep(WRITE_RETRY_DELAY_MS);
	  end;	  
      on E: EStreamError do
	  begin
        if LAttempt = WRITE_RETRIES then
          raise
        else
          TThread.Sleep(WRITE_RETRY_DELAY_MS);
	  end;	  
    end;
end;
{$ENDIF}

procedure TKVFileTreeStore.WriteFileAtomically(const APath, AContent: string);
var
  LTemp: string;
  LError: string;
begin
  LTemp := TempPath(APath);
  LError := '';

  try
    TFile.WriteAllBytes(LTemp, TEncoding.UTF8.GetBytes(AContent));
    MoveOver(LTemp, APath);
    Exit;
  except
    on E: EStreamError do
      LError := E.Message;
    on E: EInOutError do
      LError := E.Message;
    on E: EOSError do
      LError := E.Message;
  end;

  // The write failed. A leftover temporary file is harmless - EntryFiles
  // ignores one - but there is no reason to keep it, and no reason for its
  // removal to mask the failure that got us here.
  TryDeleteFile(LTemp);

  if LError = '' then
    LError := 'the file could not be written';

  raise EKVStoreError.CreateFmt(SKVWriteFailed, [APath, LError]);
end;

function TKVFileTreeStore.TryDeleteFile(const APath: string; out AError: string): Boolean;
begin
  AError := '';
  try
    TFile.Delete(APath);
    Result := True;
  except
    on E: EInOutError do
    begin
      AError := E.Message;
      Result := False;
    end;
    on E: EStreamError do
    begin
      AError := E.Message;
      Result := False;
    end;
  end;
end;

function TKVFileTreeStore.TryDeleteFile(const APath: string): Boolean;
var
  LError: string;
begin
  Result := TryDeleteFile(APath, LError);
end;

function TKVFileTreeStore.EntryFiles(const ACollection: string): TStringDynArray;
var
  LPath, LFile: string;
  LFound: TStringDynArray;
  LCount: Integer;
begin
  Result := nil;
  LPath := CollectionPath(ACollection);
  if not TDirectory.Exists(LPath) then
    Exit;

  try
    LFound := TDirectory.GetFiles(LPath, '*' + ENTRY_EXTENSION);
  except
    // A folder that cannot be listed has no entries as far as a caller is
    // concerned. Anything else is a real failure and is passed on.
    on E: EInOutError do
      Exit;
    on E: EStreamError do
      Exit;
  end;

  // The mask is not the last word: a Windows wildcard can still match through
  // a short name, and a write interrupted at the wrong moment leaves a
  // ".json.tmp" behind. Only an exact extension counts as an entry.
  SetLength(Result, Length(LFound));
  LCount := 0;
  for LFile in LFound do
    if SameText(TPath.GetExtension(LFile), ENTRY_EXTENSION) then
    begin
      Result[LCount] := LFile;
      Inc(LCount);
    end;
  SetLength(Result, LCount);
end;

function TKVFileTreeStore.DoTryGet(const ACollection, AKey: string; out AEntry: TKVEntry): Boolean;
var
  LStoredKey: string;
begin
  AEntry := Default(TKVEntry);

  Result := ReadEntryFile(EntryPath(ACollection, AKey), AEntry, LStoredKey);
  if not Result then
    Exit;

  // Every file this store writes carries the key it was written under, so a
  // file with none, or with one that cannot be read, is not this key's entry:
  // a hashed file name could in principle be reached by a different key, and
  // only an exact match settles that. Anything else is a miss, never somebody
  // else's value.
  if LStoredKey <> AKey then
  begin
    AEntry := Default(TKVEntry);
    Result := False;
  end;
end;

procedure TKVFileTreeStore.DoPut(const ACollection, AKey: string; const AEntry: TKVEntry);
begin
  EnsureCollection(ACollection);
  WriteFileAtomically(EntryPath(ACollection, AKey), TKVEnvelope.Encode(AEntry, AKey));
end;

function TKVFileTreeStore.DoDelete(const ACollection, AKey: string): Boolean;
var
  LPath: string;
  LAttempt: Integer;
  LError: string;
begin
  LPath := EntryPath(ACollection, AKey);
  Result := TFile.Exists(LPath);
  if not Result then
    Exit;

  // Between that check and the delete another writer can remove the file, or
  // hold it open while it reads. Neither is a failure: a file that is already
  // gone is as deleted as one this call removed, and a file held for a moment
  // can be deleted a moment later. Only a delete that keeps failing is
  // reported, with the last reason it did.
  LError := '';
  for LAttempt := 1 to WRITE_RETRIES do
  begin
    if not TFile.Exists(LPath) then
      Exit(True);

    if TryDeleteFile(LPath, LError) then
      Exit(True);

    TThread.Sleep(WRITE_RETRY_DELAY_MS);
  end;

  // The last failure may itself have been the file vanishing.
  if not TFile.Exists(LPath) then
    Exit(True);

  if LError = '' then
    LError := 'the file could not be deleted';

  raise EKVStoreError.CreateFmt(SKVDeleteFailed, [LPath, LError]);
end;

function TKVFileTreeStore.Keys(const ACollection: string): TArray<string>;
var
  LFiles: TStringDynArray;
  LFile, LKey: string;
  LEntry: TKVEntry;
  LNow: TDateTime;
  LCount: Integer;
begin
  LNow := UtcNow;
  LFiles := EntryFiles(ResolveCollection(ACollection));

  SetLength(Result, Length(LFiles));
  LCount := 0;
  for LFile in LFiles do
    if ReadEntryFile(LFile, LEntry, LKey) and not LEntry.IsExpiredAt(LNow) and (LKey <> '') then
    begin
      Result[LCount] := LKey;
      Inc(LCount);
    end;
  SetLength(Result, LCount);
end;

function TKVFileTreeStore.Collections: TArray<string>;
var
  LFolders: TStringDynArray;
  LIndex: Integer;
begin
  Result := nil;
  if not TDirectory.Exists(FRootPath) then
    Exit;

  LFolders := TDirectory.GetDirectories(FRootPath);
  SetLength(Result, Length(LFolders));
  for LIndex := 0 to High(LFolders) do
    Result[LIndex] := CollectionOf(LFolders[LIndex]);
end;

function TKVFileTreeStore.Cull: Integer;
var
  LCollection, LFile, LKey: string;
  LEntry: TKVEntry;
  LNow: TDateTime;
begin
  Result := 0;
  LNow := UtcNow;

  for LCollection in Collections do
    for LFile in EntryFiles(LCollection) do
      if ReadEntryFile(LFile, LEntry, LKey) and LEntry.IsExpiredAt(LNow) then
      begin
        // Someone else got there first, or it is locked: leave it for the next
        // sweep rather than failing the whole one.
        if TryDeleteFile(LFile) then
          Inc(Result);
      end;
end;

function TKVFileTreeStore.DestroyCollection(const AName: string): Boolean;
var
  LPath: string;
begin
  LPath := CollectionPath(ResolveCollection(AName));
  Result := TDirectory.Exists(LPath);
  if not Result then
    Exit;

  try
    TDirectory.Delete(LPath, True);
  except
    on E: EInOutError do
      raise EKVStoreError.CreateFmt(SKVDeleteFailed, [LPath, E.Message]);
    on E: EStreamError do
      raise EKVStoreError.CreateFmt(SKVDeleteFailed, [LPath, E.Message]);
  end;
end;

procedure TKVFileTreeStore.DestroyAll;
var
  LFolder: string;
begin
  if not TDirectory.Exists(FRootPath) then
    Exit;

  for LFolder in TDirectory.GetDirectories(FRootPath) do
    try
      TDirectory.Delete(LFolder, True);
    except
      on E: EInOutError do
        raise EKVStoreError.CreateFmt(SKVDeleteFailed, [LFolder, E.Message]);
      on E: EStreamError do
        raise EKVStoreError.CreateFmt(SKVDeleteFailed, [LFolder, E.Message]);
    end;
end;

end.
