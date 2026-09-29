program audioinfo_regression;

{$mode objfpc}{$H+}

{ Generate Opus (48 kHz and 44.1 kHz input) and Vorbis fixtures with ffmpeg.
  Use decoded s16 mono bytes / 96000 as expected seconds. }
uses
  Classes, SysUtils, OggVorbis;

var
  Reader: TOggVorbis;
  Index, ErrorCode: Integer;
  Expected, Actual: Double;
begin
  if (ParamCount < 2) or (ParamCount mod 2 <> 0) then
  begin
    WriteLn(StdErr, 'Usage: audioinfo_regression file expected-duration [file expected-duration ...]');
    Halt(2);
  end;

  Reader := TOggVorbis.Create;
  try
    Index := 1;
    while Index <= ParamCount do
    begin
      Val(ParamStr(Index + 1), Expected, ErrorCode);
      if ErrorCode <> 0 then
      begin
        WriteLn(StdErr, 'Invalid expected duration: ', ParamStr(Index + 1));
        Halt(2);
      end;
      if not Reader.ReadFromFile(ParamStr(Index)) then
      begin
        WriteLn(StdErr, 'Could not read: ', ParamStr(Index));
        Halt(1);
      end;

      Actual := Reader.Duration;
      if Abs(Actual - Expected) > 0.0001 then
      begin
        WriteLn(StdErr, ParamStr(Index), ': expected ', Expected:0:6,
                ' seconds, got ', Actual:0:6);
        Halt(1);
      end;
      WriteLn(ParamStr(Index), ': ', Actual:0:6, ' seconds');
      Inc(Index, 2);
    end;

    try
      Reader.ReadFromFile(ParamStr(1) + '.missing');
    except
      on E: EFOpenError do ;
    end;
    if Reader.Duration <> 0 then
    begin
      WriteLn(StdErr, 'Duration was not reset after a failed read');
      Halt(1);
    end;
  finally
    Reader.Free;
  end;
  WriteLn('PASS: audio duration and failed-read reset');
end.
