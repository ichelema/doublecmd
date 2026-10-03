{
  Headless equivalent of the Lazarus IDE "update PO files" step performed
  when doublecmd.lpi is built inside the IDE (EnableI18N).

  Usage: updatelang <doublecmd.pot> <file.lrj|file.rsj> ...

  Rebuilds the .pot from the given .lrj/.rsj files, drops the originals
  excluded in doublecmd.lpi, then merges the result into every
  doublecmd.<lang>.po next to the .pot. Build with:

    fpc -Fu/usr/lib/lazarus/components/lazutils/lib/x86_64-linux tools/updatelang.lpr
}
program updatelang;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, FileUtil, Translations;

var
  Base, Po: TPOFile;
  Lines, Excluded, PoFiles: TStringList;
  i: Integer;
  PotName, Ext: String;
begin
  if ParamCount < 2 then
  begin
    WriteLn('Usage: updatelang <file.pot> <file.lrj|file.rsj> ...');
    Halt(1);
  end;
  PotName := ExpandFileName(ParamStr(1));
  Lines := TStringList.Create;
  Excluded := TStringList.Create;
  Base := TPOFile.Create(PotName, True);
  try
    Base.Tag := 1;
    Base.UntagAll;
    for i := 2 to ParamCount do
    begin
      Ext := LowerCase(ExtractFileExt(ParamStr(i)));
      Lines.LoadFromFile(ParamStr(i));
      if Ext = '.lrj' then
        Base.UpdateStrings(Lines, stLrj)
      else if Ext = '.rsj' then
        Base.UpdateStrings(Lines, stRsj)
      else
        raise Exception.Create('Unsupported file: ' + ParamStr(i));
    end;
    Base.RemoveTaggedItems(0);
    // <ExcludedOriginals> from src/doublecmd.lpi
    Excluded.AddStrings(['▾', '..', '>>', '=>']);
    Base.RemoveOriginals(Excluded);
    Base.SaveToFile(PotName);

    PoFiles := FindAllFiles(ExtractFilePath(PotName),
      ChangeFileExt(ExtractFileName(PotName), '.*.po'), False);
    try
      for i := 0 to PoFiles.Count - 1 do
      begin
        Po := TPOFile.Create(PoFiles[i], True);
        try
          Po.Tag := 1;
          Po.UpdateTranslation(Base);
          Po.SaveToFile(PoFiles[i]);
        finally
          Po.Free;
        end;
      end;
      WriteLn('Updated ', PotName, ' and ', PoFiles.Count, ' .po files');
    finally
      PoFiles.Free;
    end;
  finally
    Base.Free;
    Lines.Free;
    Excluded.Free;
  end;
end.
