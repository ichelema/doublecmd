program functional_regression;

{$mode objfpc}{$H+}
{$codepage utf8}
{$R ../src/doublecmd.res}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  Interfaces, Forms, Classes, SysUtils, StdCtrls, SynHighlighterYAML, uDCUtils,
  uGlobs, uGlobsPaths, uPixMapManager, uSpecialDir, uFile,
  uFileSystemFileSource, fMultiRename;

type
  TPreviewRename = class(TfrmMultiRename)
  protected
    procedure DoCreate; override;
  end;

var
  Failures: Integer = 0;
  Scratch: String;

procedure TPreviewRename.DoCreate;
begin
  // Preview only: the hot-directory menus require a running main window.
  StringGrid.RowCount := 2;
end;

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then raise Exception.Create(MessageText);
end;

procedure TestSearchHistory;
var
  Form: TForm;
  Combo: TComboBox;
begin
  Form := TForm.CreateNew(nil);
  try
    Combo := TComboBox.Create(Form);
    Combo.Parent := Form;
    Combo.HandleNeeded;
    Combo.Items.Add('first search');
    Combo.Items.Add('second search');
    Combo.ItemIndex := 0;
    InsertFirstItem('second search', Combo, 42);
    Check(Combo.Text = 'second search', 'history move retains the previous search text');
    Check(Combo.ItemIndex = 0, 'history selection is not at the front');
    Check(PtrUInt(Combo.Items.Objects[0]) = 42, 'history loses search options');
    InsertFirstItem('first search', Combo);
    Check(Combo.Text = 'first search', 'consecutive search uses stale text');
    InsertFirstItem('new search', Combo);
    Check((Combo.Text = 'new search') and (Combo.Items.Count = 3),
      'new search is not inserted');
    InsertFirstItem('new search', Combo, 7);
    Check((Combo.Items.Count = 3) and (PtrUInt(Combo.Items.Objects[0]) = 7),
      'existing first search is duplicated or its options are not updated');
    InsertFirstItem('', Combo);
    Check((Combo.Text = 'new search') and (Combo.Items.Count = 3),
      'empty search changes history');
  finally
    Form.Free;
  end;
end;

procedure TestYAML;
var
  Highlighter: TSynYAMLSyn;
  TokenStart: PChar;
  TokenLength, Steps, I: Integer;
  Line: String;

  procedure Scan(const Text: String);
  begin
    Highlighter.SetLine(Text, 0);
    Steps := 0;
    repeat
      Highlighter.GetTokenEx(TokenStart, TokenLength);
      if Highlighter.GetTokenID <> tkNull then
        Check(Highlighter.GetTokenPos + TokenLength <= Length(Text),
          'YAML token runs beyond the end of the line');
      Inc(Steps);
      Check(Steps <= Length(Text) + 2, 'YAML highlighter does not terminate');
      if Highlighter.GetEol then Break;
      Highlighter.Next;
    until False;
  end;

begin
  Highlighter := TSynYAMLSyn.Create(nil);
  try
    for I := 0 to 32 do
    begin
      Highlighter.ResetRange;
      Line := 'key: "' + StringOfChar('x', I) + '\';
      Scan(Line);
      Check((PtrUInt(Highlighter.GetRange) and $FFFF) = rsString1,
        'unterminated YAML string loses continuation state');
      Scan('continued"');
      Check((PtrUInt(Highlighter.GetRange) and $FFFF) = rsUnknown,
        'continued YAML string does not close');
    end;
    Highlighter.ResetRange;
    Scan('key: "escaped \"quote\" and \\ slash"');
    Check((PtrUInt(Highlighter.GetRange) and $FFFF) = rsUnknown,
      'escaped YAML string does not close');
    Highlighter.ResetRange;
    Scan('key: "ends with a backslash\\"');
    Check((PtrUInt(Highlighter.GetRange) and $FFFF) = rsUnknown,
      'escaped backslash consumes the closing quote');
    Highlighter.ResetRange;
    Scan('key: ''single '''' quote''');
    Scan('');
    Scan('# comment');
  finally
    Highlighter.Free;
  end;
end;

procedure TestUnicodeRename;
var
  Files: TFiles;
  FileItem: TFile;
  Dialog: TfrmMultiRename;

  procedure CheckMask(const Mask, Expected: String);
  begin
    Dialog.cbName.Text := Mask;
    Dialog.StringGridTopLeftChanged(Dialog.StringGrid);
    Check(Dialog.StringGrid.Cells[1, 1] = Expected + '.txt',
      'multi-rename ' + Mask + ': expected ' + Expected + '.txt, got ' +
      Dialog.StringGrid.Cells[1, 1]);
  end;

begin
  Files := TFiles.Create(Scratch);
  try
    FileItem := TFileSystemFileSource.CreateFile(Scratch);
    FileItem.Name := 'café猫😀.txt';
    FileItem.Path := Scratch;
    Files.Add(FileItem);
    Dialog := TPreviewRename.Create(nil, TFileSystemFileSource.GetFileSource,
      Files, '');
    try
      Dialog.cbExt.Text := '[E]';
      CheckMask('[N-1]', '😀');
      // A negative comma range counts backwards from its end-relative index.
      CheckMask('[N-3,2]', 'fé');
      CheckMask('[N-1,2]', '猫😀');
      CheckMask('[N-3:-1]', 'é猫😀');
      CheckMask('[N2:-1]', 'afé猫😀');
      CheckMask('[N1:3]', 'caf');
    finally
      Dialog.Free;
    end;
  finally
    Files.Free;
  end;
end;

procedure RunCheck(const Name: String; Test: TProcedure);
begin
  try
    Test;
    WriteLn('PASS: ', Name);
  except
    on E: Exception do
    begin
      Inc(Failures);
      WriteLn(StdErr, 'FAIL: ', Name, ': ', E.Message);
      DumpExceptionBackTrace(StdErr);
    end;
  end;
end;

begin
  if (ParamCount <> 1) or (Copy(ParamStr(1), 1, 13) <> '--config-dir=') or
     (Length(ParamStr(1)) <= 13) then
    raise Exception.Create('Usage: functional_regression --config-dir=<scratch-directory>');
  Scratch := IncludeTrailingPathDelimiter(ExpandFileName(Copy(ParamStr(1), 14, MaxInt)));
  Check(DirectoryExists(Scratch), 'scratch directory must already exist');
  Application.Initialize;
  Application.CaptureExceptions := False;
  gpCfgDir := Scratch;
  gpCmdLineCfgDir := Scratch;
  gpGlobalCfgDir := Scratch;
  gpCacheDir := Scratch + 'cache';
  gpThumbCacheDir := Scratch + 'thumbnails';
  LoadWindowsSpecialDir;
  Check(InitGlobs, 'initialize isolated test configuration');
  LoadPixMapManager;
  gListFilesInThread := False;
  gWatchDirs := [];
  WriteLn('START: standalone functional regressions');
  RunCheck('search history', @TestSearchHistory);
  RunCheck('YAML line boundaries and escapes', @TestYAML);
  RunCheck('Unicode multi-rename preview', @TestUnicodeRename);
  if Failures > 0 then Halt(1);
  WriteLn('PASS: standalone functional regression checks');
end.
