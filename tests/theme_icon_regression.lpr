program theme_icon_regression;

{$mode objfpc}{$H+}
{$codepage utf8}
{$R ../src/doublecmd.res}
{$R+}

uses
  {$IFDEF UNIX}cthreads, cwstring,{$ENDIF}
  Interfaces,
  {$IFDEF LCLQT6}uQtWSControls, uQtWSMenus,
    {$IFNDEF LCL_VER_499}uQtWSButtons,{$ENDIF}
  {$ENDIF}
  Forms, Classes, SysUtils, Graphics, FPImage, FPWritePNG,
  zipper, zstream, uGlobs, uGlobsPaths, uPixMapManager, uSpecialDir,
  uFile, uFileSystemFileSource, uDCIconTheme, uUnixIconTheme,
  DCStringHashListUtf8, DCBasicTypes, uXdg, DCOSUtils;

var
  Failures: Integer = 0;
  Skips: Integer = 0;
  Scratch, PixmapRoot, OriginalPixmapPath, OriginalIconTheme, ExpectedTheme: String;
  TestForm: TForm;
  ArgIndex: Integer;

type
  ESkipTest = class(Exception);

procedure Check(Value: Boolean; const MessageText: String);
begin
  if not Value then
    raise Exception.Create(MessageText);
end;

procedure MakeDir(const Path: String);
begin
  Check(ForceDirectories(Path), 'cannot create fixture directory: ' + Path);
end;

procedure PutText(const FileName, Text: String);
var
  Stream: TStringStream;
begin
  MakeDir(ExtractFileDir(FileName));
  Stream := TStringStream.Create(Text);
  try
    Stream.SaveToFile(FileName);
  finally
    Stream.Free;
  end;
end;

procedure CopyFixture(const Source, Target: String);
var
  Input, Output: TFileStream;
begin
  Input := TFileStream.Create(Source, fmOpenRead);
  try
    Output := TFileStream.Create(Target, fmCreate);
    try
      Output.CopyFrom(Input, 0);
    finally
      Output.Free;
    end;
  finally
    Input.Free;
  end;
end;

procedure PutTheme(const Root, Name, Inherits: String);
var
  Text: String;
begin
  Text := '[Icon Theme]' + LineEnding +
    'Name=' + Name + LineEnding +
    'Directories=16,24,96' + LineEnding;
  if Inherits <> '' then
    Text += 'Inherits=' + Inherits + LineEnding;
  Text += LineEnding +
    '[16]' + LineEnding + 'Size=16' + LineEnding + 'Type=Fixed' + LineEnding +
    '[24]' + LineEnding + 'Size=24' + LineEnding + 'Type=Fixed' + LineEnding +
    '[96]' + LineEnding + 'Size=96' + LineEnding + 'Type=Fixed' + LineEnding;
  PutText(Root + Name + '/index.theme', Text);
end;

procedure PutSVG(const FileName, Color: String; Size: Integer);
begin
  PutText(FileName, Format(
    '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d"><rect width="100%%" height="100%%" fill="%s"/></svg>',
    [Size, Size, Color]));
end;

procedure PutPNG(const FileName: String; Color: TFPColor; Size: Integer;
  WordSized: Boolean = False);
var
  Image: TFPMemoryImage;
  Writer: TFPWriterPNG;
  X, Y: Integer;
begin
  MakeDir(ExtractFileDir(FileName));
  Image := TFPMemoryImage.Create(Size, Size);
  Writer := TFPWriterPNG.Create;
  try
    Writer.WordSized := WordSized;
    for Y := 0 to Size - 1 do
      for X := 0 to Size - 1 do
        Image.Colors[X, Y] := Color;
    Image.SaveToFile(FileName, Writer);
  finally
    Writer.Free;
    Image.Free;
  end;
end;

procedure ZipFiles(const ZipName: String; const Files, Names: array of String;
  Compressed: Boolean = False);
var
  Zipper: TZipper;
  I: Integer;
begin
  MakeDir(ExtractFileDir(ZipName));
  Zipper := TZipper.Create;
  try
    Zipper.FileName := ZipName;
    for I := Low(Files) to High(Files) do
    begin
      Zipper.Entries.AddFileEntry(Files[I], Names[I]);
      if Compressed then
        Zipper.Entries[I].CompressionLevel := zstream.clDefault
      else
        Zipper.Entries[I].CompressionLevel := zstream.clNone;
    end;
    Zipper.ZipAllFiles;
  finally
    Zipper.Free;
  end;
end;

function NewTheme(const Name: String; var Roots: array of String): TDCIconTheme;
begin
  Result := TDCIconTheme.Create(Name, Roots);
  Check(Result.Load, 'theme did not load: ' + Name);
end;

function LoadColor(Theme: TDCIconTheme; const Icon: String; Size: Integer;
  out BitmapWidth, BitmapHeight: Integer; ScaleSize: Boolean = True): TColor;
var
  Bitmap: TBitmap;
begin
  Bitmap := Theme.LoadThemeIcon(Icon, Size, ScaleSize);
  Check(Assigned(Bitmap), 'icon missing: ' + Icon);
  try
    Check((Bitmap.Width > 0) and (Bitmap.Height > 0), 'empty icon: ' + Icon);
    BitmapWidth := Bitmap.Width;
    BitmapHeight := Bitmap.Height;
    Result := Bitmap.Canvas.Pixels[Bitmap.Width div 2, Bitmap.Height div 2];
  finally
    Bitmap.Free;
  end;
end;

procedure TestFixtures;
var
  Roots: array of String;
  Theme, Missing, Defaulted: TDCIconTheme;
  File16, File24: String;
  FileReadme: String;
  Width, Height: Integer;
  Icons: TStringHashListUtf8;
  Archive: TZipArchive;
begin
  Roots := [Scratch + 'themes'];
  PutTheme(Roots[0] + PathDelim, 'loose', '');
  PutText(Roots[0] + '/loose/16/README', 'not an icon');
  PutSVG(Roots[0] + '/loose/16/check.svg', '#ff0000', 16);
  PutPNG(Roots[0] + '/loose/24/check.png', colGreen, 24);
  PutSVG(Roots[0] + '/loose/96/check.svg', '#0000ff', 96);
  PutSVG(Roots[0] + '/loose/16-other/nested/check.svg', '#ffff00', 16);
  Theme := NewTheme('loose', Roots);
  try
    Check(LoadColor(Theme, 'check', 16, Width, Height, False) = clRed,
      'loose 16px SVG or exact directory matching failed');
    Check((Width = 16) and (Height = 16),
      'unscaled icon dimensions changed');
    // At 20px the 16/24px candidates tie; the first declared size wins.
    if Round(16 * TestForm.GetCanvasScaleFactor) <= 20 then
      Check(LoadColor(Theme, 'check', 16, Width, Height) = clRed,
        'scaled 16px icon color is wrong')
    else if Round(16 * TestForm.GetCanvasScaleFactor) <= 60 then
      Check(LoadColor(Theme, 'check', 16, Width, Height) = clLime,
        'scaled lookup did not select the nearest physical-size icon')
    else
      Check(LoadColor(Theme, 'check', 16, Width, Height) = clBlue,
        'scaled lookup did not select the large physical-size icon');
    Check((Width = Round(16 * TestForm.GetCanvasScaleFactor)) and (Height = Width),
      'scaled icon dimensions do not match the widgetset canvas scale');
    Check(LoadColor(Theme, 'check', 24, Width, Height) = clLime,
      'loose PNG failed');
    Check((Width = Round(24 * TestForm.GetCanvasScaleFactor)) and (Height = Width),
      'scale-size lookup did not select the physical 24px directory');
    Check(LoadColor(Theme, 'check', 96, Width, Height) = clBlue,
      'large loose SVG failed');
  finally
    Theme.Free;
  end;

  PutTheme(Roots[0] + PathDelim, 'packed', '');
  File16 := Scratch + 'zip-input/16.svg';
  File24 := Scratch + 'zip-input/24.png';
  FileReadme := Scratch + 'zip-input/README';
  PutSVG(File16, '#00ff00', 16);
  PutPNG(File24, colRed, 24);
  PutText(FileReadme, 'not an icon');
  PutSVG(Scratch + 'zip-input/neighbor.svg', '#ffff00', 16);
  PutSVG(Scratch + 'zip-input/nested.svg', '#00ffff', 16);
  ZipFiles(Roots[0] + '/packed/icon-theme.zip',
    [FileReadme, File16, File24, Scratch + 'zip-input/neighbor.svg',
     Scratch + 'zip-input/nested.svg'],
    ['16/README', '16/check.svg', '24/check.png', '16-other/neighbor.svg',
     '16/nested/deep.svg']);
  PutSVG(Roots[0] + '/packed/16-other/nested/check.svg', '#ffff00', 16);
  Theme := NewTheme('packed', Roots);
  try
    Check(LoadColor(Theme, 'check', 16, Width, Height, False) = clLime,
      'stored ZIP SVG or non-icon directory entry handling failed');
    Check(LoadColor(Theme, 'check', 24, Width, Height) = clRed,
      'stored ZIP PNG failed');
    Archive := TZipArchive.Create(Roots[0] + '/packed/icon-theme.zip');
    try
      Icons := Archive.GetIcons('16');
      try
        Check(Icons.Find('check') >= 0, 'valid icon after README was omitted');
        Check((Icons.Find('neighbor') < 0) and (Icons.Find('deep') < 0),
          'ZIP icon lookup accepted a directory prefix or nested child');
      finally
        Icons.Free;
      end;
    finally
      Archive.Free;
    end;
  finally
    Theme.Free;
  end;

  PutTheme(Roots[0] + PathDelim, 'child', 'parentzip');
  PutTheme(Roots[0] + PathDelim, 'parentzip', '');
  File16 := Scratch + 'zip-input/parent.svg';
  PutSVG(File16, '#ff00ff', 16);
  ZipFiles(Roots[0] + '/parentzip/icon-theme.zip', [File16], ['16/inherited.svg']);
  Theme := NewTheme('child', Roots);
  try
    Check(LoadColor(Theme, 'inherited', 16, Width, Height) = clFuchsia,
      'parent ZIP-only icon was not inherited');
  finally
    Theme.Free;
  end;
  Missing := TDCIconTheme.Create('does-not-exist', Roots);
  try
    Check(not Missing.Load, 'missing theme unexpectedly loaded');
    Check(Missing.LoadThemeIcon('missing', 16) = nil,
      'missing theme icon did not return nil');
  finally
    Missing.Free;
  end;
  Defaulted := TDCIconTheme.Create('does-not-exist', Roots, 'packed');
  try
    Check(Defaulted.Load, 'configured default theme did not load after lookup miss');
    Check(LoadColor(Defaulted, 'check', 16, Width, Height, False) = clLime,
      'configured default theme ZIP icon was not returned');
  finally
    Defaulted.Free;
  end;
end;

procedure TestInvalidArchives;
var
  Roots: array of String;
  Good, Bad, Compressed: String;
  Bytes: TBytes;
  Stream: TFileStream;
  CentralOffset, EOCDOffset, I: Integer;
  Archive: TZipArchive;
  Theme: TDCIconTheme;
  Width, Height: Integer;
  IconColor: TColor;

  procedure ExpectRejected(const Name: String);
  var
    Rejected: Boolean;
  begin
    Rejected := False;
    try
      Archive := TZipArchive.Create(Name);
      Archive.Free;
    except
      on E: Exception do
        Rejected := True;
    end;
    Check(Rejected, 'invalid archive was accepted: ' + Name);
  end;

  procedure SaveMutation(const Suffix: String);
  begin
    Bad := Scratch + Suffix + '.zip';
    Stream := TFileStream.Create(Bad, fmCreate);
    try
      Stream.WriteBuffer(Bytes[0], Length(Bytes));
    finally
      Stream.Free;
    end;
    ExpectRejected(Bad);
  end;

begin
  Roots := [Scratch + 'invalid-themes'];
  PutTheme(Roots[0] + PathDelim, 'fallback', '');
  PutSVG(Roots[0] + '/fallback/16/icon.svg', '#123456', 16);
  PutSVG(Scratch + 'zip-input/invalid.svg', '#abcdef', 16);
  Good := Scratch + 'valid.zip';
  ZipFiles(Good, [Scratch + 'zip-input/invalid.svg'], ['16/icon.svg']);
  Stream := TFileStream.Create(Good, fmOpenRead);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  SetLength(Bytes, Length(Bytes) - 1);
  SaveMutation('truncated');

  Stream := TFileStream.Create(Good, fmOpenRead);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  CentralOffset := -1;
  for I := 0 to Length(Bytes) - 4 do
    if (Bytes[I] = $50) and (Bytes[I + 1] = $4b) and
       (Bytes[I + 2] = $01) and (Bytes[I + 3] = $02) then
    begin
      CentralOffset := I;
      Break;
    end;
  Check(CentralOffset >= 0, 'fixture has no central directory header');
  EOCDOffset := Length(Bytes) - 22;

  Bytes[6] := 1;
  Bytes[CentralOffset + 8] := 1;
  SaveMutation('encrypted');

  Stream := TFileStream.Create(Good, fmOpenRead);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  Bytes[26] := 0;
  Bytes[27] := 0;
  SaveMutation('empty-local-name');

  Stream := TFileStream.Create(Good, fmOpenRead);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  for I := 18 to 25 do Bytes[I] := $ff;
  for I := CentralOffset + 20 to CentralOffset + 27 do Bytes[I] := $ff;
  SaveMutation('out-of-bounds-local-data');

  Stream := TFileStream.Create(Good, fmOpenRead);
  try
    SetLength(Bytes, Stream.Size);
    Stream.ReadBuffer(Bytes[0], Length(Bytes));
  finally
    Stream.Free;
  end;
  for I := EOCDOffset + 16 to EOCDOffset + 19 do Bytes[I] := $ff;
  SaveMutation('bad-central-offset');

  PutText(Scratch + 'truncated.zip', 'short');
  ExpectRejected(Scratch + 'truncated.zip');
  PutSVG(Scratch + 'zip-input/compressed.svg', '#abcdef', 16);
  Compressed := Scratch + 'compressed.zip';
  ZipFiles(Compressed, [Scratch + 'zip-input/compressed.svg'],
    ['16/icon.svg'], True);
  ExpectRejected(Compressed);
  CopyFixture(Bad, Roots[0] + '/fallback/icon-theme.zip');
  Theme := NewTheme('fallback', Roots);
  try
    IconColor := LoadColor(Theme, 'icon', 16, Width, Height);
    Check(IconColor <> clBlack,
      'invalid archive did not fall back to loose icon');
  finally
    Theme.Free;
  end;
end;

procedure TestArchiveLifetime;
const
  Cycles = 12;
  HeapTolerance = 1024 * 1024;
var
  Roots: array of String;
  Theme: TDCIconTheme;
  BeforeHeap, AfterHeap, Growth: PtrUInt;
  IconWidth, IconHeight: Integer;
  I: Integer;
  ArchiveName, IconName: String;
  IconColor: TColor;
begin
  Roots := [Scratch + 'lifetime-themes'];
  PutTheme(Roots[0] + PathDelim, 'lifetime', '');
  PutText(Scratch + 'zip-input/large-readme',
    StringOfChar('R', 256 * 1024));
  IconName := Scratch + 'zip-input/lifetime.svg';
  PutSVG(IconName, '#326496', 16);
  ArchiveName := Roots[0] + '/lifetime/icon-theme.zip';
  ZipFiles(ArchiveName, [Scratch + 'zip-input/large-readme', IconName],
    ['README', '16/tiny.svg']);

  // Warm the code and allocator before measuring the repeated instance cycles.
  Theme := NewTheme('lifetime', Roots);
  try
    IconColor := LoadColor(Theme, 'tiny', 16, IconWidth, IconHeight);
    Check(IconColor <> clBlack, 'warm-up archive icon did not load');
  finally
    Theme.Free;
  end;
  BeforeHeap := GetFPCHeapStatus.CurrHeapUsed;
  for I := 1 to Cycles do
  begin
    Theme := NewTheme('lifetime', Roots);
    try
      IconColor := LoadColor(Theme, 'tiny', 16, IconWidth, IconHeight);
      Check(IconColor <> clBlack,
        'archive icon did not load during lifetime cycle ' + IntToStr(I));
    finally
      Theme.Free;
    end;
  end;
  AfterHeap := GetFPCHeapStatus.CurrHeapUsed;
  Growth := 0;
  if AfterHeap > BeforeHeap then
    Growth := AfterHeap - BeforeHeap;
  Check(AfterHeap <= BeforeHeap + HeapTolerance,
    Format('fresh archive themes retain heap: grew %d bytes after %d cycles',
      [Growth, Cycles]));
end;

procedure TestPixMapManager;
var
  Bitmap: TBitmap;
  Index: PtrInt;
  ZipIcon: String;
begin
  Check(DirectoryExists(PixmapRoot + 'dctheme'),
    'tracked default dctheme folder is missing: ' + PixmapRoot);
  FreeAndNil(PixMapManager);
  gIconTheme := DC_THEME_NAME;
  gpPixmapPath := PixmapRoot;
  LoadPixMapManager;
  Bitmap := PixMapManager.GetThemeIcon(ittInternal, 'folder', gIconsSize);
  Check(Assigned(Bitmap), 'default DC theme folder icon did not load');
  Bitmap.Free;

  PutTheme(Scratch + 'manager/', 'resized', '');
  PutSVG(Scratch + 'manager/resized/16/folder.svg', '#aa3300', 16);
  PutSVG(Scratch + 'manager/resized/24/folder.svg', '#00aacc', 24);
  PutPNG(Scratch + 'large.png', colRed, 96);
  PutPNG(Scratch + 'small.png', colBlue, 16);
  gIconTheme := 'resized';
  gpPixmapPath := Scratch + 'manager/';
  FreeAndNil(PixMapManager);
  gIconsSize := 24;
  LoadPixMapManager;
  Index := PixMapManager.GetIconByName(Scratch + 'large.png');
  Check(Index >= 0, 'GetIconByName did not load an absolute PNG');
  Bitmap := PixMapManager.GetBitmap(Index);
  try
    Check((Bitmap.Width = Round(24 * TestForm.GetCanvasScaleFactor)) and
      (Bitmap.Height = Bitmap.Width) and
      (Bitmap.Canvas.Pixels[Bitmap.Width div 2, Bitmap.Height div 2] = clRed),
      'GetBitmap did not shrink absolute 96px PNG at canvas scale');
  finally
    Bitmap.Free;
  end;
  Index := PixMapManager.GetIconByName(Scratch + 'small.png');
  Check(Index >= 0, 'GetIconByName did not load an undersized absolute PNG');
  Bitmap := PixMapManager.GetBitmap(Index);
  try
    Check((Bitmap.Width = Round(24 * TestForm.GetCanvasScaleFactor)) and
      (Bitmap.Height = Bitmap.Width) and
      (Bitmap.Canvas.Pixels[Bitmap.Width div 2, Bitmap.Height div 2] = clBlue),
      'GetBitmap did not enlarge absolute 16px PNG at canvas scale');
  finally
    Bitmap.Free;
  end;

  PutTheme(Scratch + 'manager/', 'zip-switch', '');
  ZipIcon := Scratch + 'zip-input/switch.svg';
  PutSVG(ZipIcon, '#0000ff', 16);
  ZipFiles(Scratch + 'manager/zip-switch/icon-theme.zip', [ZipIcon],
    ['16/folder.svg']);
  gIconTheme := 'zip-switch';
  FreeAndNil(PixMapManager);
  LoadPixMapManager;
  Bitmap := PixMapManager.GetThemeIcon(ittInternal, 'folder', gIconsSize);
  Check(Assigned(Bitmap), 'fresh manager did not load first ZIP theme');
  try
    Check(Bitmap.Canvas.Pixels[Bitmap.Width div 2, Bitmap.Height div 2] = clBlue,
      'first manager theme color is wrong');
  finally
    Bitmap.Free;
  end;
  PutSVG(ZipIcon, '#ffff00', 16);
  ZipFiles(Scratch + 'manager/zip-switch/icon-theme.zip', [ZipIcon],
    ['16/folder.svg']);
  FreeAndNil(PixMapManager);
  LoadPixMapManager;
  Bitmap := PixMapManager.GetThemeIcon(ittInternal, 'folder', gIconsSize);
  Check(Assigned(Bitmap), 'fresh manager did not reload replaced ZIP');
  try
    Check(Bitmap.Canvas.Pixels[Bitmap.Width div 2, Bitmap.Height div 2] = clYellow,
      'fresh manager returned stale ZIP icon after archive replacement');
  finally
    Bitmap.Free;
  end;
end;

procedure TestXDGThemeAndMimeCache;
var
  ThemeName, UserIcons, SystemIcons, UserMime, CacheName, FileName: String;
  OriginalDataDirs, AlternateDataDir: String;
  Roots: array of String;
  BaseDirs, SystemDirs: TDynamicStringArray;
  Theme: TDCIconTheme;
  Width, Height, I: Integer;
  HasUserIcons, HasSystemIcons: Boolean;
  FileItem: TFile;
  IconIndex: PtrInt;
  Bitmap: TBitmap;
  CacheTime: LongInt;
  Stream: TFileStream;
  Version: DWord;
  SourceTime, MaxSourceTime: LongInt;

  procedure RebuildFromVersion(OldVersion: DWord);
  begin
    CacheTime := FileAge(CacheName);
    Stream := TFileStream.Create(CacheName, fmOpenReadWrite);
    try
      Stream.Position := SizeOf(DWord);
      Version := OldVersion;
      Stream.WriteBuffer(Version, SizeOf(Version));
    finally
      Stream.Free;
    end;
    Check(FileSetDate(CacheName, CacheTime) = 0,
      'could not preserve MIME cache timestamp during version mutation');
    FreeAndNil(PixMapManager);
    LoadPixMapManager;
    Stream := TFileStream.Create(CacheName, fmOpenRead);
    try
      Stream.Position := SizeOf(DWord);
      Stream.ReadBuffer(Version, SizeOf(Version));
      Check(Version = 3, 'old MIME cache was not regenerated as version 3');
    finally
      Stream.Free;
    end;
  end;

  function QueryOrderIcon: TColor;
  var
    OrderFile: TFile;
    OrderIndex: PtrInt;
    OrderBitmap: TBitmap;
  begin
    FileName := Scratch + 'order.ich121order';
    PutText(FileName, '');
    OrderFile := TFileSystemFileSource.CreateFile(FileName);
    try
      OrderFile.Name := ExtractFileName(FileName);
      OrderFile.Path := Scratch;
      OrderIndex := PixMapManager.GetIconByFile(OrderFile, True, True, sim_all);
      Check(OrderIndex >= 0, 'ordered-source MIME lookup returned no icon');
      OrderBitmap := PixMapManager.GetBitmap(OrderIndex);
      try
        Result := OrderBitmap.Canvas.Pixels[OrderBitmap.Width div 2,
          OrderBitmap.Height div 2];
      finally
        OrderBitmap.Free;
      end;
    finally
      OrderFile.Free;
    end;
  end;
begin
  ThemeName := GetCurrentIconTheme;
  Check((ThemeName <> '') and (ExtractFileName(ThemeName) = ThemeName),
    'current icon theme name is not a safe fixture directory name');
  UserIcons := IncludeTrailingPathDelimiter(GetUserDataDir) + 'icons';
  SystemDirs := GetSystemDataDirs;
  Check(Length(SystemDirs) > 0, 'isolated XDG system data root is missing');
  SystemIcons := IncludeTrailingPathDelimiter(SystemDirs[Low(SystemDirs)]) + 'icons';
  BaseDirs := GetUnixIconThemeBaseDirList;
  Check(DirectoryExists(UserIcons) or ForceDirectories(UserIcons),
    'cannot create isolated XDG user icon root');
  Check(DirectoryExists(SystemIcons) or ForceDirectories(SystemIcons),
    'cannot create isolated XDG system icon root');
  HasUserIcons := False;
  HasSystemIcons := False;
  for I := Low(BaseDirs) to High(BaseDirs) do
  begin
    HasUserIcons := HasUserIcons or
      (IncludeTrailingPathDelimiter(BaseDirs[I]) = IncludeTrailingPathDelimiter(UserIcons));
    HasSystemIcons := HasSystemIcons or
      (IncludeTrailingPathDelimiter(BaseDirs[I]) = IncludeTrailingPathDelimiter(SystemIcons));
  end;
  Check(HasUserIcons and HasSystemIcons,
    'GetUnixIconThemeBaseDirList does not honor isolated XDG roots');
  PutTheme(UserIcons + PathDelim, ThemeName, '');
  PutTheme(SystemIcons + PathDelim, ThemeName, '');
  PutSVG(UserIcons + '/' + ThemeName + '/16/xdg-priority.svg', '#ff0000', 16);
  PutSVG(SystemIcons + '/' + ThemeName + '/16/xdg-priority.svg', '#0000ff', 16);
  Roots := BaseDirs;
  Theme := NewTheme(ThemeName, Roots);
  try
    Check(LoadColor(Theme, 'xdg-priority', 16, Width, Height) = clRed,
      'XDG user theme did not take priority over system theme');
  finally
    Theme.Free;
  end;
  FreeAndNil(PixMapManager);
  LoadPixMapManager;
  Bitmap := PixMapManager.GetThemeIcon(ittSystemOrInternal, 'xdg-priority', 16);
  Check(Assigned(Bitmap), 'pixmap manager missed the XDG fixture icon');
  try
    Check(Bitmap.Canvas.Pixels[Bitmap.Width div 2, Bitmap.Height div 2] = clRed,
      'pixmap manager did not prefer the user XDG theme icon');
  finally
    Bitmap.Free;
  end;

  UserMime := IncludeTrailingPathDelimiter(GetUserDataDir) + 'mime/';
  PutText(UserMime + 'globs',
    'application/x-ich121-compound:*.kcrash.ich121plain' + LineEnding +
    'application/x-ich121-plain:*.ich121plain' + LineEnding);
  PutText(UserMime + 'icons',
    'application/x-ich121-compound:application-x-ich121-compound' + LineEnding +
    'application/x-ich121-plain:application-x-ich121-plain' + LineEnding);
  PutSVG(UserIcons + '/' + ThemeName + '/16/application-x-ich121-compound.svg',
    '#ff0000', 16);
  PutSVG(UserIcons + '/' + ThemeName + '/16/application-x-ich121-plain.svg',
    '#00ff00', 16);
  PutSVG(UserIcons + '/' + ThemeName + '/16/application-x-generic.svg',
    '#0000ff', 16);
  FreeAndNil(PixMapManager);
  LoadPixMapManager;
  CacheName := gpCfgDir + 'pixmaps.cache';
  Check(FileExists(CacheName), 'MIME cache was not created');

  FileName := Scratch + 'sample.kcrash.ich121plain';
  PutText(FileName, '');
  FileItem := TFileSystemFileSource.CreateFile(FileName);
  try
    FileItem.Name := ExtractFileName(FileName);
    FileItem.Path := Scratch;
    IconIndex := PixMapManager.GetIconByFile(FileItem, True, True, sim_all);
    Check(IconIndex >= 0, 'MIME file icon lookup returned no icon');
    Bitmap := PixMapManager.GetBitmap(IconIndex);
    try
      Check(Bitmap.Canvas.Pixels[Bitmap.Width div 2, Bitmap.Height div 2] = clLime,
        'compound glob incorrectly outranked the plain *.ich121plain mapping');
    finally
      Bitmap.Free;
    end;
  finally
    FileItem.Free;
  end;

  RebuildFromVersion(1);
  RebuildFromVersion(2);

  OriginalDataDirs := GetEnvironmentVariable('XDG_DATA_DIRS');
  AlternateDataDir := Scratch + 'xdg-system-alt';
  PutText(Scratch + 'xdg-system/mime/globs',
    'application/x-ich121-order:*.ich121order' + LineEnding);
  PutText(Scratch + 'xdg-system/mime/icons',
    'application/x-ich121-order:application-x-ich121-order-a' + LineEnding);
  PutText(AlternateDataDir + '/mime/globs',
    'application/x-ich121-order:*.ich121order' + LineEnding);
  PutText(AlternateDataDir + '/mime/icons',
    'application/x-ich121-order:application-x-ich121-order-b' + LineEnding);
  PutSVG(UserIcons + '/' + ThemeName +
    '/16/application-x-ich121-order-a.svg', '#ff0000', 16);
  PutSVG(UserIcons + '/' + ThemeName +
    '/16/application-x-ich121-order-b.svg', '#0000ff', 16);
  SourceTime := FileAge(Scratch + 'xdg-system/mime/globs');
  Check(FileSetDate(AlternateDataDir + '/mime/globs', SourceTime) = 0,
    'could not equalize ordered-source glob timestamps');
  MaxSourceTime := FileAge(UserMime + 'globs');
  if SourceTime > MaxSourceTime then MaxSourceTime := SourceTime;

  FreeAndNil(PixMapManager);
  LoadPixMapManager;
  Check(QueryOrderIcon = clRed,
    'first XDG source did not supply its MIME icon');
  Check(FileAge(CacheName) = MaxSourceTime,
    'ordered-source cache timestamp is not the expected maximum source mtime');
  try
    DCOSUtils.mbSetEnvironmentVariable('XDG_DATA_DIRS',
      AlternateDataDir + PathSeparator + OriginalDataDirs);
    FreeAndNil(PixMapManager);
    LoadPixMapManager;
    Check(FileAge(CacheName) = MaxSourceTime,
      'reordered source fixture changed the maximum glob timestamp');
    Check(QueryOrderIcon = clBlue,
      'MIME cache ignored XDG source reordering with unchanged maximum mtime');
  finally
    DCOSUtils.mbSetEnvironmentVariable('XDG_DATA_DIRS', OriginalDataDirs);
    FreeAndNil(PixMapManager);
    LoadPixMapManager;
  end;
  Check(QueryOrderIcon = clRed,
    'MIME cache retained a removed XDG source');
  SourceTime := FileAge(Scratch + 'xdg-system/mime/icons');
  PutText(Scratch + 'xdg-system/mime/icons',
    'application/x-ich121-order:application-x-ich121-order-b' + LineEnding);
  Check(FileSetDate(Scratch + 'xdg-system/mime/icons', SourceTime + 1) = 0,
    'could not change the icons-only source timestamp');
  FreeAndNil(PixMapManager);
  LoadPixMapManager;
  Check(FileAge(CacheName) = MaxSourceTime,
    'icons-only update unexpectedly changed the maximum glob timestamp');
  Check(QueryOrderIcon = clBlue,
    'MIME cache ignored an icons-only update');
end;

procedure TestLegacyPixmapFallback;
var
  BaseDirs: TDynamicStringArray;
  Search: TSearchRec;
  Root, PixmapFile, IconName, Extension: String;
  DirectBitmap, ThemeBitmap: TBitmap;
begin
  BaseDirs := GetUnixIconThemeBaseDirList;
  PixmapFile := '';
  for Root in BaseDirs do
    if (Root = '/usr/share/pixmaps') or (Root = '/usr/local/share/pixmaps') then
    begin
      if FindFirst(IncludeTrailingPathDelimiter(Root) + '*', faAnyFile, Search) = 0 then
      try
        repeat
          Extension := LowerCase(ExtractFileExt(Search.Name));
          if ((Search.Attr and faDirectory) = 0) and
             ((Extension = '.png') or (Extension = '.svg') or
              (Extension = '.xpm')) then
          begin
            PixmapFile := IncludeTrailingPathDelimiter(Root) + Search.Name;
            Break;
          end;
        until FindNext(Search) <> 0;
      finally
        FindClose(Search);
      end;
      if FileExists(PixmapFile) then Break;
    end;
  if not FileExists(PixmapFile) then
    raise ESkipTest.Create('no readable PNG/SVG/XPM found in /usr/share/pixmaps fallback roots');

  IconName := ChangeFileExt(ExtractFileName(PixmapFile), '');
  DirectBitmap := PixMapManager.LoadBitmapEnhanced(PixmapFile, gIconsSize,
    True, Graphics.clNone);
  Check(Assigned(DirectBitmap), 'cannot load legacy fixture: ' + PixmapFile);
  try
    ThemeBitmap := PixMapManager.GetThemeIcon(ittSystemOrInternal, IconName, gIconsSize);
    Check(Assigned(ThemeBitmap), 'legacy pixmaps fallback missed ' + IconName);
    try
      Check((ThemeBitmap.Canvas.Pixels[ThemeBitmap.Width div 2, ThemeBitmap.Height div 2] =
         DirectBitmap.Canvas.Pixels[DirectBitmap.Width div 2, DirectBitmap.Height div 2]),
        'legacy pixmaps fallback differs from direct graphic load');
    finally
      ThemeBitmap.Free;
    end;
  finally
    DirectBitmap.Free;
  end;
end;

procedure TestWordSizedPng;
var
  Roots: array of String;
  Theme: TDCIconTheme;
  SourceBitmap, LoadedBitmap: TBitmap;
  Picture: TPicture;
  Width, Height: Integer;
  FileName: String;
begin
  Roots := [Scratch + 'word-png-theme'];
  PutTheme(Roots[0] + PathDelim, 'word-png', '');
  FileName := Roots[0] + '/word-png/16/word.png';
  PutPNG(FileName, colRed, 16, True);
  Picture := TPicture.Create;
  SourceBitmap := TBitmap.Create;
  try
    Picture.LoadFromFile(FileName);
    SourceBitmap.Assign(Picture.Graphic);
    WriteLn('CHECKPOINT: decoded PNG depth = ',
      SourceBitmap.RawImage.Description.BitsPerPixel, ' bpp');
    if SourceBitmap.RawImage.Description.BitsPerPixel <= 32 then
      raise ESkipTest.Create(
        'WordSized PNG decoder produced <=32bpp; no conversion coverage available');
  finally
    SourceBitmap.Free;
    Picture.Free;
  end;
  Check(PixMapManager.LoadBitmapFromFile(FileName, LoadedBitmap),
    'WordSized PNG fixture could not be converted');
  try
    Check(LoadedBitmap.RawImage.Description.BitsPerPixel <= 32,
      'file loader did not convert the >32bpp PNG');
  finally
    LoadedBitmap.Free;
  end;
  Theme := NewTheme('word-png', Roots);
  try
    LoadedBitmap := Theme.LoadThemeIcon('word', 16, True);
    Check(Assigned(LoadedBitmap), 'WordSized theme PNG was not loaded');
    try
      Check(LoadedBitmap.RawImage.Description.BitsPerPixel <= 32,
        'theme loader did not convert the >32bpp PNG');
      Check(LoadColor(Theme, 'word', 16, Width, Height) = clRed,
        'converted WordSized PNG pixel changed');
    finally
      LoadedBitmap.Free;
    end;
  finally
    Theme.Free;
  end;
  ZipFiles(Roots[0] + '/word-png/icon-theme.zip', [FileName], ['16/word.png']);
  Check(DeleteFile(FileName), 'cannot remove loose PNG before archive-only check');
  Theme := NewTheme('word-png', Roots);
  try
    Check(LoadColor(Theme, 'word', 16, Width, Height) = clRed,
      'converted ZIP-backed WordSized PNG pixel changed');
  finally
    Theme.Free;
  end;
end;

procedure RunCheck(const Name: String; Test: TProcedure);
begin
  WriteLn('START: ', Name);
  try
    Test;
    WriteLn('PASS: ', Name);
  except
    on E: ESkipTest do
    begin
      Inc(Skips);
      WriteLn('SKIP: ', Name, ': ', E.Message);
    end;
    on E: Exception do
    begin
      Inc(Failures);
      WriteLn(StdErr, 'FAIL: ', Name, ': ', E.Message);
    end;
  end;
end;

begin
  Scratch := '';
  ExpectedTheme := '';
  for ArgIndex := 1 to ParamCount do
  begin
    if Copy(ParamStr(ArgIndex), 1, 13) = '--config-dir=' then
      Scratch := Copy(ParamStr(ArgIndex), 14, MaxInt)
    else if Copy(ParamStr(ArgIndex), 1, 15) = '--expect-theme=' then
      ExpectedTheme := Copy(ParamStr(ArgIndex), 16, MaxInt)
    else
      raise Exception.Create('Unknown argument: ' + ParamStr(ArgIndex));
  end;
  if Scratch = '' then
    raise Exception.Create('Usage: theme_icon_regression --config-dir=<scratch-directory> [--expect-theme=<name>]');
  Scratch := IncludeTrailingPathDelimiter(ExpandFileName(Scratch));
  Check(DirectoryExists(Scratch), 'scratch directory must already exist');
  Check(GetEnvironmentVariable('XDG_DATA_HOME') = Scratch + 'xdg-user',
    'XDG_DATA_HOME must be the isolated scratch xdg-user directory');
  Check(GetEnvironmentVariable('XDG_DATA_DIRS') = Scratch + 'xdg-system',
    'XDG_DATA_DIRS must be the isolated scratch xdg-system directory');
  MakeDir(Scratch + 'xdg-user');
  MakeDir(Scratch + 'xdg-system');
  PixmapRoot := ExpandFileName(ExtractFilePath(ParamStr(0)) + '../../../pixmaps') + PathDelim;
  Application.Initialize;
  Application.CaptureExceptions := False;
  gpCfgDir := Scratch;
  gpCmdLineCfgDir := Scratch;
  gpGlobalCfgDir := Scratch;
  gpCacheDir := Scratch + 'cache';
  gpThumbCacheDir := Scratch + 'thumbnails';
  gpPixmapPath := PixmapRoot;
  LoadWindowsSpecialDir;
  Check(InitGlobs, 'initialize isolated test configuration');
  OriginalPixmapPath := gpPixmapPath;
  OriginalIconTheme := gIconTheme;
  if (ExpectedTheme <> '') and (gIconTheme <> ExpectedTheme) then
    raise Exception.CreateFmt('saved theme mismatch: expected %s, got %s',
      [ExpectedTheme, gIconTheme]);
  TestForm := TForm.CreateNew(nil);
  TestForm.HandleNeeded;
  WriteLn('CHECKPOINT: canvas scale = ', TestForm.GetCanvasScaleFactor:0:2,
    '; requested Qt factor = ', GetEnvironmentVariable('QT_SCALE_FACTOR'));
  gListFilesInThread := False;
  gWatchDirs := [];
  gIconsSize := 24;
  LoadPixMapManager;
  WriteLn('START: theme/icon regressions');
  RunCheck('loose, stored ZIP, inherited and missing themes', @TestFixtures);
  RunCheck('invalid ZIP rejection and loose fallback', @TestInvalidArchives);
  RunCheck('ZIP archive instance lifetime', @TestArchiveLifetime);
  RunCheck('XDG theme discovery, MIME globs and cache migration', @TestXDGThemeAndMimeCache);
  RunCheck('WordSized PNG conversion', @TestWordSizedPng);
  RunCheck('default theme and bitmap resizing', @TestPixMapManager);
  RunCheck('legacy /usr/share/pixmaps fallback', @TestLegacyPixmapFallback);
  if Failures = 0 then
  begin
    gIconTheme := 'resized';
    SaveGlobs;
  end;
  FreeAndNil(PixMapManager);
  TestForm.Free;
  gpPixmapPath := OriginalPixmapPath;
  gIconTheme := OriginalIconTheme;
  if Failures > 0 then
  begin
    WriteLn(StdErr, 'FAIL: ', Failures, ' regression group(s)');
    Halt(1);
  end;
  WriteLn('PASS: theme/icon regressions (', Skips, ' skipped)');
end.
