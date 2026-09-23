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
///   A wrapper is a store, so the wrappers that are meant to be invisible are
///   put through the same contract as a real one, over a memory store. If any
///   of them changes what a caller sees, the shared suite says so.
///
///   Two wrappers are not here, and for the same reason the null store is
///   not: they change the contract on purpose.
///
///   TKVReadOnlyWrapper refuses writes, so it cannot round-trip anything.
///
///   TKVPrefixKeysWrapper passes everything except the key-length test - the
///   prefix comes out of the same budget, so a key of exactly the maximum
///   length fits a bare store and not a prefixed one. That is a real
///   consequence of prefixing rather than a defect, so it is documented and
///   tested in WalKey.Tests.Wrappers instead.
/// </summary>
unit WalKey.Tests.Wrappers.Conformance;

interface

uses
  System.SysUtils,
  DUnitX.TestFramework,
  WalKey.Core, WalKey.Stores.Memory, WalKey.Stores.Null, WalKey.Wrappers,
  WalKey.Tests.Conformance;

type
  /// <summary>
  ///   Counting must not change what is counted.
  /// </summary>
  [TestFixture]
  TKVStatisticsWrapperConformanceTests = class(TKVConformanceTests)
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  end;

  /// <summary>
  ///   Logging must not change what is logged. The sink is real but discards,
  ///   so every message is still formatted - a bad format string fails here.
  /// </summary>
  [TestFixture]
  TKVLoggingWrapperConformanceTests = class(TKVConformanceTests)
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  end;

  /// <summary>
  ///   With no limits set, a TTL policy must be a pass-through - including
  ///   for the negative TTL the store underneath has to keep refusing.
  /// </summary>
  [TestFixture]
  TKVTTLClampWrapperConformanceTests = class(TKVConformanceTests)
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  end;

  /// <summary>
  ///   Renaming every collection must be invisible from the outside,
  ///   isolation between collections included.
  /// </summary>
  [TestFixture]
  TKVPrefixCollectionsWrapperConformanceTests = class(TKVConformanceTests)
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  end;

  /// <summary>
  ///   A standby that is never needed must never be noticed: with a healthy
  ///   primary the whole contract is the primary's.
  /// </summary>
  [TestFixture]
  TKVFallbackWrapperConformanceTests = class(TKVConformanceTests)
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  end;

  /// <summary>
  ///   Wrappers stack, and a stack is still a store.
  /// </summary>
  [TestFixture]
  TKVWrapperStackConformanceTests = class(TKVConformanceTests)
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  end;

  /// <summary>
  ///   A lock changes nothing a caller can see, so the whole contract runs
  ///   through it.
  /// </summary>
  [TestFixture]
  TKVThreadSafeWrapperConformanceTests = class(TKVConformanceTests)
  protected
    function CreateStore(const AClock: TKVClock): IKeyValue; override;
  end;

implementation

{ TKVStatisticsWrapperConformanceTests }

function TKVStatisticsWrapperConformanceTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result := TKVStatisticsWrapper.Create(TKVMemoryStore.Create(AClock));
end;

{ TKVLoggingWrapperConformanceTests }

function TKVLoggingWrapperConformanceTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result := TKVLoggingWrapper.Create(TKVMemoryStore.Create(AClock),
    procedure(const AMessage: string)
    begin
      // Formatted and thrown away.
    end);
end;

{ TKVTTLClampWrapperConformanceTests }

function TKVTTLClampWrapperConformanceTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result := TKVTTLClampWrapper.Create(TKVMemoryStore.Create(AClock));
end;

{ TKVPrefixCollectionsWrapperConformanceTests }

function TKVPrefixCollectionsWrapperConformanceTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result := TKVPrefixCollectionsWrapper.Create(TKVMemoryStore.Create(AClock), 'app1');
end;

{ TKVFallbackWrapperConformanceTests }

function TKVFallbackWrapperConformanceTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result := TKVFallbackWrapper.Create(TKVMemoryStore.Create(AClock), TKVNullStore.Create);
end;

{ TKVWrapperStackConformanceTests }

function TKVWrapperStackConformanceTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result :=
    TKVLoggingWrapper.Create(
      TKVStatisticsWrapper.Create(
        TKVTTLClampWrapper.Create(
          TKVPrefixCollectionsWrapper.Create(
            TKVMemoryStore.Create(AClock), 'app1'))), nil);
end;

{ TKVThreadSafeWrapperConformanceTests }

function TKVThreadSafeWrapperConformanceTests.CreateStore(const AClock: TKVClock): IKeyValue;
begin
  Result := TKVThreadSafeWrapper.Create(TKVMemoryStore.Create(AClock));
end;

initialization
  TDUnitX.RegisterTestFixture(TKVStatisticsWrapperConformanceTests);
  TDUnitX.RegisterTestFixture(TKVLoggingWrapperConformanceTests);
  TDUnitX.RegisterTestFixture(TKVTTLClampWrapperConformanceTests);
  TDUnitX.RegisterTestFixture(TKVPrefixCollectionsWrapperConformanceTests);
  TDUnitX.RegisterTestFixture(TKVFallbackWrapperConformanceTests);
  TDUnitX.RegisterTestFixture(TKVWrapperStackConformanceTests);
  TDUnitX.RegisterTestFixture(TKVThreadSafeWrapperConformanceTests);

end.
