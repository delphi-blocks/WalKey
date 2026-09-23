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
program WalKey.Tests.Framework;

{$IFNDEF TESTINSIGHT}
  {$APPTYPE CONSOLE}
{$ENDIF}

{$STRONGLINKTYPES ON}
uses
  System.SysUtils,
  {$IFDEF TESTINSIGHT}
  TestInsight.DUnitX,
  {$ELSE}
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  {$ENDIF }
  DUnitX.TestFramework,

  WalKey.Core in '..\Source\WalKey.Core.pas',
  WalKey.Wrappers in '..\Source\WalKey.Wrappers.pas',
  WalKey.Stores.Memory in '..\Source\WalKey.Stores.Memory.pas',
  WalKey.Stores.Null in '..\Source\WalKey.Stores.Null.pas',
  WalKey.Stores.FileTree in '..\Source\WalKey.Stores.FileTree.pas',
  WalKey.Adapters.Entity in '..\Source\WalKey.Adapters.Entity.pas',
  {$IFDEF WALKEY_NATS}
  WalKey.Stores.NATS in '..\Source\WalKey.Stores.NATS.pas',
  {$ENDIF}
  WalKey.Adapters.Neon in '..\Source\WalKey.Adapters.Neon.pas',

  WalKey.Tests.Conformance in 'Source\WalKey.Tests.Conformance.pas',
  WalKey.Tests.Core in 'Source\WalKey.Tests.Core.pas',
  WalKey.Tests.Stores.Memory in 'Source\WalKey.Tests.Stores.Memory.pas',
  WalKey.Tests.Stores.Null in 'Source\WalKey.Tests.Stores.Null.pas',
  WalKey.Tests.Stores.FileTree in 'Source\WalKey.Tests.Stores.FileTree.pas',
  WalKey.Tests.Wrappers in 'Source\WalKey.Tests.Wrappers.pas',
  WalKey.Tests.Wrappers.Conformance in 'Source\WalKey.Tests.Wrappers.Conformance.pas',
  WalKey.Tests.Adapters.Entity in 'Source\WalKey.Tests.Adapters.Entity.pas',
  {$IFDEF WALKEY_NATS}
  WalKey.Tests.Stores.NATS in 'Source\WalKey.Tests.Stores.NATS.pas',
  {$ENDIF}
  WalKey.Tests.Adapters.Neon in 'Source\WalKey.Tests.Adapters.Neon.pas';

var
  LRunner: ITestRunner;
  LResults: IRunResults;
  LLogger: ITestLogger;
  LNUnitLogger: ITestLogger;
begin
{$IFDEF TESTINSIGHT}
  TestInsight.DUnitX.RunRegisteredTests;
  Exit;
{$ENDIF}
  try
    TDUnitX.CheckCommandLine;
    LRunner := TDUnitX.CreateRunner;
    LRunner.UseRTTI := True;

    LLogger := TDUnitXConsoleLogger.Create(True);
    LRunner.AddLogger(LLogger);
    LNUnitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    LRunner.AddLogger(LNUnitLogger);
    LRunner.FailsOnNoAsserts := False;

    LResults := LRunner.Execute;
    if not LResults.AllPassed then
      System.ExitCode := EXIT_ERRORS;

    {$IFNDEF CI}
    if TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause then
    begin
      System.Write('Done.. press <Enter> key to quit.');
      System.Readln;
    end;
    {$ENDIF}
  except
    on E: Exception do
      System.Writeln(E.ClassName, ': ', E.Message);
  end;
end.
