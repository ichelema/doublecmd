{
  ICH-125: language catalogs consistency check.

  Loads language/doublecmd.pot and every doublecmd.<lang>.po with the same
  TPOFile parser Double Commander uses at runtime, then asserts that every
  catalog carries exactly the identifiers of the template, that the fork's
  Tree File View strings survived regeneration (Italian translated) and that
  strings of upstream features not integrated in the fork are gone.

  Build and run from the repository root:

    fpc -FE/tmp -FU/tmp -Fu/usr/lib/lazarus/components/lazutils/lib/x86_64-linux \
        tests/language_regression.lpr && /tmp/language_regression
}
program language_regression;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, FileUtil, Translations;

const
  LangDir = 'language/';
  TreeCaption = 'tfrmmain.acttreefileview.caption';
  TreeHint = 'tfrmmain.acttreefileview.hint';
  NotInFork: array[0..2] of String = (
    'tfrmoptionscolors.lbldirselection.caption',
    'tfrmoptionstabs.cbtabsunavailablemarker.caption',
    'tfrmsyncdirsperformdlg.chkverify.caption');

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: String);
begin
  if Cond then Exit;
  Inc(Failures);
  WriteLn('FAIL: ', Msg);
end;

function Idents(Po: TPOFile): TStringList;
var
  i: Integer;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  for i := 0 to Po.Items.Count - 1 do
    Result.Add(TPOFileItem(Po.Items[i]).IdentifierLow);
end;

var
  Pot, Po: TPOFile;
  PotIds, PoIds, Files: TStringList;
  F, Id: String;
  Item: TPOFileItem;
begin
  Pot := TPOFile.Create(LangDir + 'doublecmd.pot', True);
  PotIds := Idents(Pot);
  Check(PotIds.Count > 1000, 'template looks empty');
  Check(PotIds.IndexOf(TreeCaption) >= 0, 'template misses ' + TreeCaption);
  Check(PotIds.IndexOf(TreeHint) >= 0, 'template misses ' + TreeHint);
  for Id in NotInFork do
    Check(PotIds.IndexOf(Id) < 0, 'template still has ' + Id);

  Files := FindAllFiles(LangDir, 'doublecmd.*.po', False);
  Files.Sort;
  Check(Files.Count >= 31, 'expected at least 31 catalogs');
  for F in Files do
  begin
    Po := TPOFile.Create(F, True);
    PoIds := Idents(Po);
    Check(PoIds.Equals(PotIds), F + ': identifiers differ from template');
    Item := Po.FindPoItem(TreeCaption);
    Check(Item <> nil, F + ': misses ' + TreeCaption);
    if ExtractFileName(F) = 'doublecmd.it.po' then
    begin
      Check((Item <> nil) and (Item.Translation = 'Albero'), F + ': Tree caption not Italian');
      Item := Po.FindPoItem(TreeHint);
      Check((Item <> nil) and (Item.Translation = 'Vista ad albero'), F + ': Tree hint not Italian');
    end;
    PoIds.Free;
    Po.Free;
  end;
  WriteLn(Files.Count, ' catalogs checked, ', Failures, ' failure(s)');
  Files.Free;
  PotIds.Free;
  Pot.Free;
  if Failures > 0 then Halt(1);
end.
