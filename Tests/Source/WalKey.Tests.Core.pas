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
///   The pieces of WalKey.Core that stand on their own: the entry record, the
///   persisted envelope and the key/collection rules. No store involved.
/// </summary>
unit WalKey.Tests.Core;

interface

uses
  System.SysUtils, System.DateUtils, System.TimeSpan, System.JSON,
  DUnitX.TestFramework,
  WalKey.Core;

type
  [TestFixture]
  TKVEntryTests = class
  private
    FNow: TDateTime;
  public
    [Setup] procedure Setup;

    [Test] procedure WithoutTtl_NeverExpires;
    [Test] procedure WithTtl_ExpiresAtCreationPlusTtl;
    [Test] procedure NegativeTtl_IsTreatedAsNoExpiry;
    [Test] procedure IsExpired_IsTrueOnTheInstantOfExpiry;
    [Test] procedure TTLRemaining_CountsDown;
    [Test] procedure TTLRemaining_NeverGoesNegativeForAnExpiredEntry;
  end;

  [TestFixture]
  TKVEnvelopeTests = class
  private
    FNow: TDateTime;
  public
    [Setup] procedure Setup;

    [Test] procedure RoundTrips_AnEntryWithoutExpiry;
    [Test] procedure RoundTrips_AnEntryWithExpiry;
    [Test] procedure RoundTrips_AValueThatIsNotJson;
    [Test] procedure RoundTrips_AValueWithQuotesAndNewlines;
    [Test] procedure RoundTrips_AnEmptyValue;
    [Test] procedure Encode_OmitsTheExpiryWhenThereIsNone;
    [Test] procedure Encode_CarriesTheValueAsAnEscapedString;
    [Test] procedure TryDecode_Garbage_ReturnsFalse;
    [Test] procedure TryDecode_NotAnObject_ReturnsFalse;
    [Test] procedure TryDecode_MissingValue_ReturnsFalse;
    [Test] procedure TryDecode_MissingCreatedAt_ReturnsFalse;
    [Test] procedure TryDecode_ReadsTheKeyBack;
    [Test] procedure TryDecode_WithoutAKey_LeavesTheKeyEmpty;
    [Test] procedure TryDecode_UnreadableKey_ReturnsFalse;
    [Test] procedure TryDecode_UnreadableExpiry_ReturnsFalse;
    [Test] procedure TryDecode_OnFailure_LeavesAnEmptyEntry;
    [Test] procedure Decode_Garbage_Raises;
    [Test] procedure Timestamps_SurviveToTheMillisecond;
  end;

  [TestFixture]
  TKVValidationTests = class
  public
    [TestCase('simple', 'abc')]
    [TestCase('with dots', 'user.profile.v2')]
    [TestCase('with slash', 'users/123')]
    [TestCase('with space', 'a key')]
    [TestCase('single char', 'a')]
    procedure ValidKeys_AreAccepted(const AKey: string);

    [Test] procedure Key_Empty_IsRejected;
    [Test] procedure Key_TooLong_IsRejected;
    [Test] procedure Key_AtTheLimit_IsAccepted;
    [Test] procedure Key_WithControlCharacters_IsRejected;
    [Test] procedure Key_WithDelete_IsRejected;
    [Test] procedure Collection_Empty_IsRejected;
    [Test] procedure Collection_TooLong_IsRejected;
    [Test] procedure CheckKey_Raises;
    [Test] procedure CheckCollection_Raises;
    [Test] procedure CheckTTL_Negative_Raises;
    [Test] procedure CheckTTL_ZeroAndPositive_AreAccepted;
    [Test] procedure UtcNow_IsNotLocalTimeUnlessTheZoneSaysSo;
  end;

implementation

{ TKVEntryTests }

procedure TKVEntryTests.Setup;
begin
  FNow := EncodeDate(2026, 1, 1) + EncodeTime(12, 0, 0, 0);
end;

procedure TKVEntryTests.WithoutTtl_NeverExpires;
var
  LEntry: TKVEntry;
begin
  LEntry := TKVEntry.Create('v', FNow, KV_NO_TTL);

  Assert.IsFalse(LEntry.HasExpiry);
  Assert.IsFalse(LEntry.IsExpiredAt(FNow + 3650));
end;

procedure TKVEntryTests.WithTtl_ExpiresAtCreationPlusTtl;
var
  LEntry: TKVEntry;
begin
  LEntry := TKVEntry.Create('v', FNow, 90);

  Assert.IsTrue(LEntry.HasExpiry);
  Assert.AreEqual(Double(FNow + 90 / SecsPerDay), Double(LEntry.ExpiresAt), 1E-9);
end;

procedure TKVEntryTests.NegativeTtl_IsTreatedAsNoExpiry;
var
  LEntry: TKVEntry;
begin
  // TKVEntry does not police the argument - TKVStoreBase.Put does, and raises.
  LEntry := TKVEntry.Create('v', FNow, -10);
  Assert.IsFalse(LEntry.HasExpiry);
end;

procedure TKVEntryTests.IsExpired_IsTrueOnTheInstantOfExpiry;
var
  LEntry: TKVEntry;
begin
  LEntry := TKVEntry.Create('v', FNow, 60);

  Assert.IsFalse(LEntry.IsExpiredAt(FNow + 59 / SecsPerDay));
  Assert.IsTrue(LEntry.IsExpiredAt(LEntry.ExpiresAt), 'expiry is inclusive');
end;

procedure TKVEntryTests.TTLRemaining_CountsDown;
var
  LEntry: TKVEntry;
begin
  LEntry := TKVEntry.Create('v', FNow, 60);

  Assert.AreEqual(Double(60), Double(LEntry.TTLRemainingAt(FNow)), 0.001);
  Assert.AreEqual(Double(15), Double(LEntry.TTLRemainingAt(FNow + 45 / SecsPerDay)), 0.001);
end;

procedure TKVEntryTests.TTLRemaining_NeverGoesNegativeForAnExpiredEntry;
var
  LEntry: TKVEntry;
begin
  LEntry := TKVEntry.Create('v', FNow, 60);
  Assert.AreEqual(Double(0), Double(LEntry.TTLRemainingAt(FNow + 1)), 0.001);
end;

{ TKVEnvelopeTests }

procedure TKVEnvelopeTests.Setup;
begin
  FNow := EncodeDate(2026, 1, 1) + EncodeTime(12, 0, 0, 0);
end;

procedure TKVEnvelopeTests.RoundTrips_AnEntryWithoutExpiry;
var
  LEntry, LDecoded: TKVEntry;
begin
  LEntry := TKVEntry.Create('{"name":"Alice"}', FNow, KV_NO_TTL);

  Assert.IsTrue(TKVEnvelope.TryDecode(TKVEnvelope.Encode(LEntry), LDecoded));
  Assert.AreEqual(LEntry.Value, LDecoded.Value);
  Assert.IsFalse(LDecoded.HasExpiry);
end;

procedure TKVEnvelopeTests.RoundTrips_AnEntryWithExpiry;
var
  LEntry, LDecoded: TKVEntry;
begin
  LEntry := TKVEntry.Create('{"name":"Alice"}', FNow, 3600);

  Assert.IsTrue(TKVEnvelope.TryDecode(TKVEnvelope.Encode(LEntry), LDecoded));
  Assert.IsTrue(LDecoded.HasExpiry);
  Assert.AreEqual(Double(3600), Double(LDecoded.TTLRemainingAt(FNow)), 0.001);
end;

procedure TKVEnvelopeTests.RoundTrips_AValueThatIsNotJson;
var
  LDecoded: TKVEntry;
begin
  // The library never parses a value, so a plain string survives untouched.
  Assert.IsTrue(TKVEnvelope.TryDecode(
    TKVEnvelope.Encode(TKVEntry.Create('not json at all', FNow, 0)), LDecoded));
  Assert.AreEqual('not json at all', LDecoded.Value);
end;

procedure TKVEnvelopeTests.RoundTrips_AValueWithQuotesAndNewlines;
var
  LValue: string;
  LDecoded: TKVEntry;
begin
  LValue := '{"text":"she said \"hi\""}' + sLineBreak + #9 + 'tail';

  Assert.IsTrue(TKVEnvelope.TryDecode(
    TKVEnvelope.Encode(TKVEntry.Create(LValue, FNow, 0)), LDecoded));
  Assert.AreEqual(LValue, LDecoded.Value);
end;

procedure TKVEnvelopeTests.RoundTrips_AnEmptyValue;
var
  LDecoded: TKVEntry;
begin
  Assert.IsTrue(TKVEnvelope.TryDecode(
    TKVEnvelope.Encode(TKVEntry.Create('', FNow, 0)), LDecoded));
  Assert.AreEqual('', LDecoded.Value);
end;

procedure TKVEnvelopeTests.Encode_OmitsTheExpiryWhenThereIsNone;
var
  LJson: string;
begin
  LJson := TKVEnvelope.Encode(TKVEntry.Create('v', FNow, KV_NO_TTL));

  Assert.IsTrue(LJson.Contains('"c"'));
  Assert.IsFalse(LJson.Contains('"e"'), 'no expiry means no member');
end;

procedure TKVEnvelopeTests.Encode_CarriesTheValueAsAnEscapedString;
var
  LValue: TJSONValue;
begin
  LValue := TJSONObject.ParseJSONValue(
    TKVEnvelope.Encode(TKVEntry.Create('{"n":1}', FNow, 0)));
  try
    Assert.IsTrue(LValue is TJSONObject);
    // Not nested JSON: the member is a string holding the whole document.
    Assert.IsTrue(TJSONObject(LValue).GetValue('v') is TJSONString);
    Assert.AreEqual('{"n":1}', TJSONObject(LValue).GetValue<string>('v'));
  finally
    LValue.Free;
  end;
end;

procedure TKVEnvelopeTests.TryDecode_Garbage_ReturnsFalse;
var
  LDecoded: TKVEntry;
begin
  Assert.IsFalse(TKVEnvelope.TryDecode('not json', LDecoded));
  Assert.IsFalse(TKVEnvelope.TryDecode('', LDecoded));
end;

procedure TKVEnvelopeTests.TryDecode_NotAnObject_ReturnsFalse;
var
  LDecoded: TKVEntry;
begin
  Assert.IsFalse(TKVEnvelope.TryDecode('[1,2,3]', LDecoded));
end;

procedure TKVEnvelopeTests.TryDecode_MissingValue_ReturnsFalse;
var
  LDecoded: TKVEntry;
begin
  Assert.IsFalse(TKVEnvelope.TryDecode('{"c":1767268800000}', LDecoded));
end;

procedure TKVEnvelopeTests.TryDecode_MissingCreatedAt_ReturnsFalse;
var
  LDecoded: TKVEntry;
begin
  Assert.IsFalse(TKVEnvelope.TryDecode('{"v":"x"}', LDecoded));
end;

procedure TKVEnvelopeTests.TryDecode_ReadsTheKeyBack;
var
  LDecoded: TKVEntry;
  LKey: string;
begin
  Assert.IsTrue(TKVEnvelope.TryDecode(
    TKVEnvelope.Encode(TKVEntry.Create('v', FNow, 0), 'the-key'), LDecoded, LKey));
  Assert.AreEqual('the-key', LKey);
end;

procedure TKVEnvelopeTests.TryDecode_WithoutAKey_LeavesTheKeyEmpty;
var
  LDecoded: TKVEntry;
  LKey: string;
begin
  // The one-argument Encode writes no key at all, and that is not corruption:
  // it is a document that carries none.
  Assert.IsTrue(TKVEnvelope.TryDecode(
    TKVEnvelope.Encode(TKVEntry.Create('v', FNow, 0)), LDecoded, LKey));
  Assert.AreEqual('', LKey);
end;

procedure TKVEnvelopeTests.TryDecode_UnreadableKey_ReturnsFalse;
var
  LDecoded: TKVEntry;
  LKey: string;
begin
  // Present but not a string: malformed, and deliberately not the same as
  // carrying no key, or a store that insists on one could not tell the two
  // apart.
  Assert.IsFalse(TKVEnvelope.TryDecode('{"v":"x","c":1,"k":{}}', LDecoded, LKey));
  Assert.IsFalse(TKVEnvelope.TryDecode('{"v":"x","c":1,"k":[]}', LDecoded, LKey));
end;

procedure TKVEnvelopeTests.TryDecode_UnreadableExpiry_ReturnsFalse;
var
  LDecoded: TKVEntry;
begin
  // An expiry that is there but unreadable is corruption, not "no expiry":
  // reading it as the latter would make a broken entry permanent.
  Assert.IsFalse(TKVEnvelope.TryDecode('{"v":"x","c":1,"e":{}}', LDecoded));
  Assert.IsFalse(TKVEnvelope.TryDecode('{"v":"x","c":1,"e":"zz"}', LDecoded));
  Assert.IsFalse(TKVEnvelope.TryDecode('{"v":"x","c":1,"e":1e30}', LDecoded));

  Assert.IsTrue(TKVEnvelope.TryDecode('{"v":"x","c":1,"e":2}', LDecoded));
  Assert.IsTrue(LDecoded.HasExpiry, 'a readable expiry is still read');
end;

procedure TKVEnvelopeTests.TryDecode_OnFailure_LeavesAnEmptyEntry;
var
  LDecoded: TKVEntry;
  LKey: string;
begin
  // The value member parses and the created member does not, so this is the
  // failure that used to leave the value half-read behind it.
  LDecoded := TKVEntry.Create('leftover', FNow, 60);

  Assert.IsFalse(TKVEnvelope.TryDecode('{"v":"x","c":{}}', LDecoded, LKey));

  Assert.AreEqual('', LDecoded.Value);
  Assert.IsFalse(LDecoded.HasExpiry);
  Assert.AreEqual('', LKey);
end;

procedure TKVEnvelopeTests.Decode_Garbage_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVEnvelope.Decode('nonsense');
    end, EKVSerializationError);
end;

procedure TKVEnvelopeTests.Timestamps_SurviveToTheMillisecond;
var
  LEntry, LDecoded: TKVEntry;
begin
  LEntry := TKVEntry.Create('v', EncodeDate(2026, 1, 1) + EncodeTime(12, 34, 56, 789), 0);

  Assert.IsTrue(TKVEnvelope.TryDecode(TKVEnvelope.Encode(LEntry), LDecoded));
  Assert.AreEqual(Int64(0), MilliSecondsBetween(LEntry.CreatedAt, LDecoded.CreatedAt));
end;

{ TKVValidationTests }

procedure TKVValidationTests.ValidKeys_AreAccepted(const AKey: string);
begin
  Assert.IsTrue(TKVUtils.IsValidKey(AKey));
end;

procedure TKVValidationTests.Key_Empty_IsRejected;
begin
  Assert.IsFalse(TKVUtils.IsValidKey(''));
end;

procedure TKVValidationTests.Key_TooLong_IsRejected;
begin
  Assert.IsFalse(TKVUtils.IsValidKey(StringOfChar('k', KV_MAX_KEY_LENGTH + 1)));
end;

procedure TKVValidationTests.Key_AtTheLimit_IsAccepted;
begin
  Assert.IsTrue(TKVUtils.IsValidKey(StringOfChar('k', KV_MAX_KEY_LENGTH)));
end;

procedure TKVValidationTests.Key_WithControlCharacters_IsRejected;
begin
  Assert.IsFalse(TKVUtils.IsValidKey('a' + #0 + 'b'));
  Assert.IsFalse(TKVUtils.IsValidKey('a' + #10 + 'b'));
  Assert.IsFalse(TKVUtils.IsValidKey('a' + #13 + 'b'));
  Assert.IsFalse(TKVUtils.IsValidKey('a' + #9 + 'b'));
end;

procedure TKVValidationTests.Key_WithDelete_IsRejected;
begin
  Assert.IsFalse(TKVUtils.IsValidKey('a' + #127));
end;

procedure TKVValidationTests.Collection_Empty_IsRejected;
begin
  Assert.IsFalse(TKVUtils.IsValidCollection(''));
end;

procedure TKVValidationTests.Collection_TooLong_IsRejected;
begin
  Assert.IsFalse(TKVUtils.IsValidCollection(StringOfChar('c', KV_MAX_COLLECTION_LENGTH + 1)));
  Assert.IsTrue(TKVUtils.IsValidCollection(StringOfChar('c', KV_MAX_COLLECTION_LENGTH)));
end;

procedure TKVValidationTests.CheckKey_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVUtils.CheckKey('');
    end, EKVInvalidKeyError);
end;

procedure TKVValidationTests.CheckCollection_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVUtils.CheckCollection('');
    end, EKVInvalidCollectionError);
end;

procedure TKVValidationTests.CheckTTL_Negative_Raises;
begin
  Assert.WillRaise(
    procedure
    begin
      TKVUtils.CheckTTL(-1);
    end, EKVArgumentError);
end;

procedure TKVValidationTests.CheckTTL_ZeroAndPositive_AreAccepted;
begin
  TKVUtils.CheckTTL(KV_NO_TTL);
  TKVUtils.CheckTTL(3600);
end;

procedure TKVValidationTests.UtcNow_IsNotLocalTimeUnlessTheZoneSaysSo;
var
  LOffset: Double;
begin
  LOffset := System.SysUtils.Now - TKVUtils.UtcNow;
  Assert.AreEqual(Double(TTimeZone.Local.GetUtcOffset(System.SysUtils.Now).TotalDays),
    LOffset, 1 / SecsPerDay);
end;

initialization
  TDUnitX.RegisterTestFixture(TKVEntryTests);
  TDUnitX.RegisterTestFixture(TKVEnvelopeTests);
  TDUnitX.RegisterTestFixture(TKVValidationTests);

end.
