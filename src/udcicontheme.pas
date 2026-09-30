{
    Double Commander
    -------------------------------------------------------------------------
    Icon Theme with ZIP archive support

    Copyright (C) 2026 Alexander Koblov (alexx2000@mail.ru)

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program. If not, see <http://www.gnu.org/licenses/>.
}

unit uDCIconTheme;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Graphics, DCStringHashListUtf8, DCStringHashTable,
  uIconTheme;

type
  TZipItem = class
    FPos: PByte;
    FSize: Int64;
  end;

  TZipArchive = class
  private
    FStream: TMemoryStream;
    FList: TDCStringHashTable;
  public
    constructor Create(const FileName: String);
    destructor Destroy; override;
    function GetIcons(const Directory: String): TStringHashListUtf8;
  end;

  TDCIconTheme = class(TIconTheme)
  private
    FBasePath: String;
    FArchive: TZipArchive;
    function LoadIcon(AStream: TStream): TBitmap;
    function LoadIconFromFile(const FileName: String; ASize: Integer): TBitmap;
    function LoadIconFromArchive(const FileName: String; ASize: Integer): TBitmap;
  protected
    function CreateParentTheme(const sThemeName: String): TIconTheme; override;
    function LoadThemeWithInherited(AInherits: TStringList): Boolean; override;
  public
    destructor Destroy; override;
    function LoadThemeIcon(const AIconName: String; AIconSize: Integer; AScaleSize: Boolean = True): TBitmap;
  end;

implementation

uses
  DCOSUtils, DCStrUtils, uDCUtils, uPixMapManager, uClassesEx,
  uVectorImage, uDebug, uGraphics;

const
  ZIP_LOCAL_SIGN       = $04034b50;
  ZIP_CENTRAL_SIGN     = $02014b50;
  ZIP_END_CENTRAL_SIGN = $06054b50;

type
  TLocalFileHeader = packed record
    Signature: UInt32;
    VersionNeeded, GeneralPurposeFlag, CompressionMethod: UInt16;
    LastModFileTime, LastModFileDate: UInt16;
    CRC32, CompressedSize, UncompressedSize: UInt32;
    FileNameLength, ExtraFieldLength: UInt16;
  end;

  TCentralDirectoryHeader = packed record
    Signature: UInt32;
    VersionMadeBy, VersionNeeded, GeneralPurposeFlag, CompressionMethod: UInt16;
    LastModFileTime, LastModFileDate: UInt16;
    CRC32, CompressedSize, UncompressedSize: UInt32;
    FileNameLength, ExtraFieldLength, FileCommentLength: UInt16;
    DiskNumberStart, InternalFileAttributes: UInt16;
    ExternalFileAttributes, RelativeOffsetLocalHeader: UInt32;
  end;

  TEndCentralDirectory = packed record
    Signature: UInt32;
    DiskNumber, CentralDirectoryStartDisk, EntriesThisDisk, EntriesTotalNumber: UInt16;
    CentralDirectorySize, StartDiskOffset: UInt32;
    CommentLength: UInt16;
  end;

constructor TZipArchive.Create(const FileName: String);
var
  APos, ASize, AEndPos, ADataPos, AEntryEnd: Int64;
  AName, ALocalName: String;
  Index: Integer;
  AItem: TZipItem;
  ALocal: TLocalFileHeader;
  AEndDir: TEndCentralDirectory;
  AHeader: TCentralDirectoryHeader;
begin
  inherited Create;
  FStream:= TMemoryStream.Create;
  FList:= TDCStringHashTable.Create;
  try
    FStream.LoadFromFile(FileName);
    ASize:= FStream.Size;
    if ASize < SizeOf(TEndCentralDirectory) then
      raise EInvalidContainer.Create(EmptyStr);

    APos:= FStream.Seek(-SizeOf(TEndCentralDirectory), soEnd);
    FStream.ReadBuffer(AEndDir, SizeOf(AEndDir));
    if (AEndDir.Signature <> ZIP_END_CENTRAL_SIGN) or
       (AEndDir.DiskNumber <> 0) or (AEndDir.CentralDirectoryStartDisk <> 0) or
       (AEndDir.EntriesThisDisk <> AEndDir.EntriesTotalNumber) or
       (APos + SizeOf(AEndDir) + AEndDir.CommentLength <> ASize) then
      raise EInvalidContainer.Create(EmptyStr);

    AEndPos:= AEndDir.StartDiskOffset + Int64(AEndDir.CentralDirectorySize);
    if (AEndDir.StartDiskOffset > APos) or (AEndPos <> APos) then
      raise EInvalidContainer.Create(EmptyStr);
    FStream.Position:= AEndDir.StartDiskOffset;

    for Index:= 0 to AEndDir.EntriesTotalNumber - 1 do
    begin
      if FStream.Position + SizeOf(AHeader) > AEndPos then
        raise EInvalidContainer.Create(EmptyStr);
      FStream.ReadBuffer(AHeader, SizeOf(AHeader));
      if (AHeader.Signature <> ZIP_CENTRAL_SIGN) or
         (AHeader.DiskNumberStart <> 0) or
         (AHeader.FileNameLength = 0) or
         (AHeader.CompressionMethod <> 0) or
         ((AHeader.GeneralPurposeFlag and $F7FF) <> 0) or
         (FStream.Position + AHeader.FileNameLength + AHeader.ExtraFieldLength +
          AHeader.FileCommentLength > AEndPos) then
        raise EInvalidContainer.Create(EmptyStr);

      SetLength(AName, AHeader.FileNameLength);
      if AHeader.FileNameLength > 0 then
        FStream.ReadBuffer(AName[1], AHeader.FileNameLength);
      FStream.Seek(AHeader.ExtraFieldLength + AHeader.FileCommentLength, soCurrent);
      AEntryEnd:= FStream.Position;

      if (AHeader.ExternalFileAttributes and faDirectory = 0) and (AName <> '') then
      begin
        APos:= AHeader.RelativeOffsetLocalHeader;
        if (APos + SizeOf(ALocal) > AEndDir.StartDiskOffset) then
          raise EInvalidContainer.Create(EmptyStr);
        FStream.Position:= APos;
        FStream.ReadBuffer(ALocal, SizeOf(ALocal));
        if (ALocal.Signature <> ZIP_LOCAL_SIGN) or (ALocal.CompressionMethod <> 0) or
           (ALocal.GeneralPurposeFlag <> AHeader.GeneralPurposeFlag) or
           ((ALocal.GeneralPurposeFlag and $F7FF) <> 0) or
           (ALocal.CompressedSize <> AHeader.CompressedSize) or
           (ALocal.UncompressedSize <> AHeader.UncompressedSize) or
           (ALocal.FileNameLength = 0) or
           (ALocal.FileNameLength <> AHeader.FileNameLength) or
           (FStream.Position + ALocal.FileNameLength + ALocal.ExtraFieldLength >
            AEndDir.StartDiskOffset) then
          raise EInvalidContainer.Create(EmptyStr);

        SetLength(ALocalName, ALocal.FileNameLength);
        FStream.ReadBuffer(ALocalName[1], ALocal.FileNameLength);
        if ALocalName <> AName then
          raise EInvalidContainer.Create(EmptyStr);
        FStream.Seek(ALocal.ExtraFieldLength, soCurrent);
        ADataPos:= FStream.Position;
        if (ADataPos + ALocal.CompressedSize > AEndDir.StartDiskOffset) or
           (ALocal.CompressedSize <> ALocal.UncompressedSize) then
          raise EInvalidContainer.Create(EmptyStr);

        AItem:= TZipItem.Create;
        AItem.FSize:= ALocal.UncompressedSize;
        AItem.FPos:= PByte(FStream.Memory) + ADataPos;
        AName:= NormalizePathDelimiters(AName);
        FList.Add(AName, AItem);
      end;
      FStream.Position:= AEntryEnd;
    end;
    if FStream.Position <> AEndPos then
      raise EInvalidContainer.Create(EmptyStr);
  except
    FreeAndNil(FList);
    FreeAndNil(FStream);
    raise;
  end;
end;

destructor TZipArchive.Destroy;
begin
  FList.Free;
  FStream.Free;
  inherited Destroy;
end;

function TZipArchive.GetIcons(const Directory: String): TStringHashListUtf8;
var
  I: Integer;
  ExtIdx: IntPtr;
  D, S, E: String;
begin
  D:= IncludeTrailingPathDelimiter(NormalizePathDelimiters(Directory));
  Result:= TStringHashListUtf8.Create(True);
  for I:= 0 to FList.Count - 1 do
  begin
    S:= FList.Items[I]^.Key;
    if NormalizePathDelimiters(ExtractFileDir(S) + PathDelim) <> D then
      Continue;
    E:= LowerCase(ExtractOnlyFileExt(S));
    if E = 'svg' then
      ExtIdx:= EXT_IDX_SVG
    else if E = 'png' then
      ExtIdx:= EXT_IDX_PNG
    else if E = 'xpm' then
      ExtIdx:= EXT_IDX_XPM
    else
      Continue;
    Result.Add(ExtractOnlyFileName(S), Pointer(ExtIdx));
  end;
end;

function TDCIconTheme.LoadIcon(AStream: TStream): TBitmap;
var
  Picture: TPicture;
begin
  Picture:= TPicture.Create;
  try
    Result:= Graphics.TBitmap.Create;
    try
      Picture.LoadFromStream(AStream);
      Result.Assign(Picture.Graphic);
      if Result.RawImage.Description.BitsPerPixel > 32 then
        BitmapConvert(Result);
    except
      on E: Exception do
      begin
        FreeAndNil(Result);
        DCDebug(Format('Error: Cannot load pixmap : %s', [E.Message]));
      end;
    end;
  finally
    Picture.Free;
  end;
end;

function TDCIconTheme.LoadIconFromArchive(const FileName: String; ASize: Integer): TBitmap;
var
  AItem: TZipItem;
  AStream: TStream;
  AFileName: String;
  ANode: PDCHashItem;
begin
  AFileName:= NormalizePathDelimiters(Copy(FileName, Length(FBasePath) + 1, MaxInt));
  ANode:= FArchive.FList.Find(AFileName);
  if ANode = nil then Exit(nil);
  AItem:= TZipItem(ANode^.Value);
  AStream:= TBlobStream.Create(AItem.FPos, AItem.FSize);
  try
    if TScalableVectorGraphics.IsFileExtensionSupported(ExtractFileExt(AFileName)) then
      Result:= TScalableVectorGraphics.CreateBitmap(AStream, ASize, ASize)
    else begin
      Result:= LoadIcon(AStream);
      if Assigned(Result) then
        Result:= StretchBitmap(Result, ASize, clNone, True);
    end;
  finally
    AStream.Free;
  end;
end;

function TDCIconTheme.LoadIconFromFile(const FileName: String; ASize: Integer): TBitmap;
begin
  if TScalableVectorGraphics.IsFileExtensionSupported(ExtractFileExt(FileName)) then
    Result:= TScalableVectorGraphics.CreateBitmap(FileName, ASize, ASize)
  else begin
    PixMapManager.LoadBitmapFromFile(FileName, Result);
    if Assigned(Result) then
      Result:= StretchBitmap(Result, ASize, clNone, True);
  end;
end;

function TDCIconTheme.CreateParentTheme(const sThemeName: String): TIconTheme;
begin
  Result:= TDCIconTheme.Create(sThemeName, FBaseDirListAtCreate);
end;

function TDCIconTheme.LoadThemeWithInherited(AInherits: TStringList): Boolean;
var
  I: Integer;
  FileName: String;
  NewArchive: TZipArchive;
  IconLists: array of TStringHashListUtf8;
begin
  Result:= inherited LoadThemeWithInherited(AInherits);
  if not Result then Exit;
  FBasePath:= FBaseDirList[FCacheIndex] + PathDelim + FTheme + PathDelim;
  FileName:= FBasePath + 'icon-theme.zip';
  if not mbFileExists(FileName) then Exit;

  NewArchive:= nil;
  SetLength(IconLists, FDirectories.Count);
  try
    NewArchive:= TZipArchive.Create(FileName);
    DCDebug('Loading theme icons from zip');
    for I:= 0 to FDirectories.Count - 1 do
      IconLists[I]:= NewArchive.GetIcons(FDirectories[I]);
    FArchive:= NewArchive;
    NewArchive:= nil;
    for I:= 0 to FDirectories.Count - 1 do
    begin
      FDirectories.Items[I]^.FileListCache[FCacheIndex].Free;
      FDirectories.Items[I]^.FileListCache[FCacheIndex]:= IconLists[I];
      IconLists[I]:= nil;
    end;
  except
    DCDebug('ERROR: Invalid archive - ', FileName);
    FreeAndNil(NewArchive);
  end;
  for I:= 0 to High(IconLists) do
    IconLists[I].Free;
end;

destructor TDCIconTheme.Destroy;
begin
  FArchive.Free;
  inherited Destroy;
end;

function TDCIconTheme.LoadThemeIcon(const AIconName: String; AIconSize: Integer; AScaleSize: Boolean): TBitmap;
var
  FileName: String;
  BitmapSize: Integer;
  AIconTheme: TDCIconTheme;
begin
  if AScaleSize then
    BitmapSize:= Round(AIconSize * findScaleFactorByFirstForm())
  else
    BitmapSize:= AIconSize;
  FileName:= FindIcon(AIconName, BitmapSize, 1);
  if FileName = EmptyStr then Exit(nil);
  if FParentIndex < 0 then
    AIconTheme:= Self
  else
    AIconTheme:= TDCIconTheme(FInherits.Objects[FParentIndex]);
  with AIconTheme do
    if Assigned(FArchive) and (FBaseDirIndex = FCacheIndex) then
      Result:= LoadIconFromArchive(FileName, BitmapSize)
    else
      Result:= LoadIconFromFile(FileName, BitmapSize);
end;

end.
