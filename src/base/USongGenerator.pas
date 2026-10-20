{* UltraStar Deluxe - Karaoke Game
 *
 * UltraStar Deluxe is the legal property of its developers, whose names
 * are too numerous to list here. Please refer to the COPYRIGHT
 * file distributed with this source distribution.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; see the file COPYING. If not, write to
 * the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
 * Boston, MA 02110-1301, USA.
 *}

unit USongGenerator;

{*
 * Song generator: makes the notes and lyrics of a song from its audio with
 * UltraSinger (https://github.com/rakuri255/UltraSinger), an external
 * Python program. The game runs resources/generator/usdx_generate.py with
 * UltraSinger's Python in a worker thread and reads its progress lines.
 *
 * config.ini, section [SongGenerator]:
 *   UltraSingerDir  UltraSinger checkout with its .venv (default ~/UltraSinger)
 *   Whisper         transcription model (default large-v2)
 *   Language        language code for the lyrics, empty = detect
 *   OutputDir       folder for new songs (default <first song folder>/Generadas)
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Classes,
  SysUtils,
  SyncObjs,
  sdl2;

type
  TGeneratorState = (gsIdle, gsRunning, gsDone, gsFailed);

  TSongGenerator = class
    private
      fLock:      TCriticalSection;
      fThread:    TThread;
      fState:     TGeneratorState;
      fStage:     UTF8String;
      fLyricsSource: UTF8String; // where the lyrics came from: user, lrclib, whisper
      fMessage:   UTF8String;
      fResult:    UTF8String;  // txt written by the generator
      fReplace:   UTF8String;  // txt whose notes are replaced, empty = new song
      fInput:     UTF8String;
      fStarted:   TDateTime;
      fPending:   boolean;     // result not yet added to the song list
      fVersion:   integer;     // bumped when the song list changed
      fUltraSinger, fWhisper, fLanguage, fOutputDir: UTF8String;

      procedure LoadConfig;
      function GetState: TGeneratorState;
      function GetStage: UTF8String;
      function GetMessage: UTF8String;
      function GetResult: UTF8String;
      procedure SetStage(const Stage: UTF8String);
      procedure SetLyricsSource(const Source: UTF8String);
      function GetLyricsSource: UTF8String;
      procedure Finish(Success: boolean; const Text: UTF8String);
      procedure ApplyResult;
    public
      constructor Create;
      destructor Destroy; override;

      function PythonPath: UTF8String;
      function ScriptPath: UTF8String;
      function Available: boolean;
      // Input: audio/video file or URL; ReplaceTxt: song to fill in, or ''
      // Language: code of the lyrics ('es', 'en'), '' = the config default
      function Start(const Input, ReplaceTxt: UTF8String; const Language: UTF8String = ''): boolean;
      procedure Cancel;
      // main thread, every frame: adds finished songs to the song list
      procedure Tick;
      function ElapsedSeconds: integer;

      property State: TGeneratorState read GetState;
      property Stage: UTF8String read GetStage;
      property Message: UTF8String read GetMessage;
      property ResultFile: UTF8String read GetResult;
      property LyricsSource: UTF8String read GetLyricsSource;
      property Input: UTF8String read fInput;
      property Replacing: UTF8String read fReplace;
      property Version: integer read fVersion;
      property OutputDir: UTF8String read fOutputDir;
  end;

var
  SongGenerator: TSongGenerator;
  // file dropped onto the window, picked up by the generator screen
  SongGeneratorDroppedFile: UTF8String;

procedure StopSongGenerator;

// frees strings from SDL (dropped files, clipboard); missing in the SDL2 headers
procedure SDL_free(mem: Pointer); cdecl; external SDL_LibName;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  DateUtils,
  IniFiles,
  Math,
  Process,
  UGraphic,
  UIni,
  ULog,
  UPath,
  UPathUtils,
  USong,
  USongRequests,
  USongs;

type
  TGeneratorThread = class(TThread)
    private
      fOwner: TSongGenerator;
      fArgs:  TStringList;
      procedure HandleLine(const Line: UTF8String; var Success: boolean; var Text: UTF8String);
    protected
      procedure Execute; override;
    public
      constructor Create(Owner: TSongGenerator; Args: TStringList);
      destructor Destroy; override;
  end;

const
  INI_SECTION = 'SongGenerator';

{ TGeneratorThread }

constructor TGeneratorThread.Create(Owner: TSongGenerator; Args: TStringList);
begin
  fOwner := Owner;
  fArgs := Args;
  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TGeneratorThread.Destroy;
begin
  fArgs.Free;
  inherited;
end;

procedure TGeneratorThread.HandleLine(const Line: UTF8String; var Success: boolean; var Text: UTF8String);
begin
  if Copy(Line, 1, 8) = '@@STAGE ' then
    fOwner.SetStage(Trim(Copy(Line, 9, MaxInt)))
  else if Copy(Line, 1, 9) = '@@LYRICS ' then
    fOwner.SetLyricsSource(Trim(Copy(Line, 10, MaxInt)))
  else if Copy(Line, 1, 7) = '@@DONE ' then
  begin
    Success := true;
    Text := Trim(Copy(Line, 8, MaxInt));
  end
  else if Copy(Line, 1, 8) = '@@ERROR ' then
    Text := Trim(Copy(Line, 9, MaxInt));
end;

procedure TGeneratorThread.Execute;
var
  Proc:    TProcess;
  LogFile: TextFile;
  HasLog:  boolean;
  Buf:     array[0..4095] of AnsiChar;
  Pending: UTF8String;
  Line:    UTF8String;
  Text:    UTF8String;
  Success: boolean;
  N, P:    integer;
  StopAt:  TDateTime;  // when cancelling started, 0 = not cancelling

  procedure TakeLines;
  begin
    repeat
      P := Pos(#10, Pending);
      if P = 0 then
        P := Pos(#13, Pending);
      if P = 0 then
        Break;
      Line := TrimRight(Copy(Pending, 1, P - 1));
      Delete(Pending, 1, P);
      if Line = '' then
        Continue;
      if HasLog then
        WriteLn(LogFile, Line);
      HandleLine(Line, Success, Text);
    until false;
  end;

begin
  Success := false;
  Text := '';
  Pending := '';
  StopAt := 0;

  AssignFile(LogFile, ExtractFilePath(Ini.Filename.ToNative) + 'generator.log');
  try
    Rewrite(LogFile);
    HasLog := true;
  except
    HasLog := false;
  end;

  Proc := TProcess.Create(nil);
  try
    Proc.Executable := fOwner.PythonPath;
    Proc.Parameters.Add('-u');
    // no __pycache__ inside the signed app bundle
    Proc.Parameters.Add('-B');
    Proc.Parameters.Add(fOwner.ScriptPath);
    Proc.Parameters.AddStrings(fArgs);
    Proc.Options := [poUsePipes, poStderrToOutPut, poNoConsole];
    try
      Proc.Execute;
      while Proc.Running or (Proc.Output.NumBytesAvailable > 0) do
      begin
        if Terminated and Proc.Running then
        begin
          // ask nicely first, so the script stops UltraSinger and cleans up
          {$IFDEF UNIX}
          if StopAt = 0 then
          begin
            StopAt := Now;
            fpKill(Proc.ProcessID, SIGTERM);
          end
          else if SecondsBetween(Now, StopAt) >= 10 then
          {$ENDIF}
            Proc.Terminate(2);
        end;
        N := Proc.Output.NumBytesAvailable;
        if N > 0 then
        begin
          N := Proc.Output.Read(Buf, Min(N, SizeOf(Buf)));
          if N > 0 then
          begin
            SetString(Line, PAnsiChar(@Buf[0]), N);
            Pending := Pending + Line;
            TakeLines;
          end;
        end
        else
          Sleep(100);
      end;
      Pending := Pending + #10;
      TakeLines;
      if Terminated then
      begin
        Success := false;
        Text := 'cancelled';
      end
      else if (not Success) and (Text = '') then
        Text := Format('exit code %d', [Proc.ExitStatus]);
    except
      on E: Exception do
      begin
        Success := false;
        Text := E.Message;
      end;
    end;
  finally
    Proc.Free;
    if HasLog then
      CloseFile(LogFile);
  end;
  fOwner.Finish(Success, Text);
end;

{ TSongGenerator }

constructor TSongGenerator.Create;
begin
  inherited;
  fLock := TCriticalSection.Create;
  fState := gsIdle;
  LoadConfig;
end;

destructor TSongGenerator.Destroy;
begin
  Cancel;
  fLock.Free;
  inherited;
end;

procedure TSongGenerator.LoadConfig;
var
  IniFile: TMemIniFile;
  Home:    UTF8String;
  SongDir: UTF8String;
begin
  Home := GetEnvironmentVariable('HOME');
  if Home = '' then
    Home := GetEnvironmentVariable('USERPROFILE');
  IniFile := TMemIniFile.Create(Ini.Filename.ToNative);
  try
    fUltraSinger := Trim(IniFile.ReadString(INI_SECTION, 'UltraSingerDir', ''));
    fWhisper := Trim(IniFile.ReadString(INI_SECTION, 'Whisper', 'large-v2'));
    fLanguage := Trim(IniFile.ReadString(INI_SECTION, 'Language', ''));
    fOutputDir := Trim(IniFile.ReadString(INI_SECTION, 'OutputDir', ''));
    SongDir := Trim(IniFile.ReadString('Directories', 'SongDir1', ''));
  finally
    IniFile.Free;
  end;
  if fUltraSinger = '' then
    fUltraSinger := IncludeTrailingPathDelimiter(Home) + 'UltraSinger';
  if fWhisper = '' then
    fWhisper := 'large-v2';
  if fOutputDir = '' then
  begin
    if (SongDir = '') and (SongPaths.Count > 0) then
      SongDir := (SongPaths[SongPaths.Count - 1] as IPath).ToNative;
    fOutputDir := IncludeTrailingPathDelimiter(SongDir) + 'Generadas';
  end;
end;

function TSongGenerator.PythonPath: UTF8String;
begin
  {$IFDEF MSWINDOWS}
  Result := IncludeTrailingPathDelimiter(fUltraSinger) + '.venv\Scripts\python.exe';
  {$ELSE}
  Result := IncludeTrailingPathDelimiter(fUltraSinger) + '.venv/bin/python';
  {$ENDIF}
end;

function TSongGenerator.ScriptPath: UTF8String;
begin
  Result := ResourcesPath.Append('generator').Append('usdx_generate.py').ToNative;
end;

function TSongGenerator.Available: boolean;
begin
  Result := FileExists(PythonPath) and FileExists(ScriptPath);
end;

function TSongGenerator.GetState: TGeneratorState;
begin
  fLock.Enter;
  Result := fState;
  fLock.Leave;
end;

function TSongGenerator.GetStage: UTF8String;
begin
  fLock.Enter;
  Result := fStage;
  fLock.Leave;
end;

function TSongGenerator.GetMessage: UTF8String;
begin
  fLock.Enter;
  Result := fMessage;
  fLock.Leave;
end;

function TSongGenerator.GetResult: UTF8String;
begin
  fLock.Enter;
  Result := fResult;
  fLock.Leave;
end;

procedure TSongGenerator.SetStage(const Stage: UTF8String);
begin
  fLock.Enter;
  fStage := Stage;
  fLock.Leave;
end;

procedure TSongGenerator.SetLyricsSource(const Source: UTF8String);
begin
  fLock.Enter;
  fLyricsSource := Source;
  fLock.Leave;
end;

function TSongGenerator.GetLyricsSource: UTF8String;
begin
  fLock.Enter;
  Result := fLyricsSource;
  fLock.Leave;
end;

procedure TSongGenerator.Finish(Success: boolean; const Text: UTF8String);
begin
  fLock.Enter;
  try
    if Success then
    begin
      fState := gsDone;
      fResult := Text;
      fMessage := '';
      fPending := true;
    end
    else
    begin
      fState := gsFailed;
      fMessage := Text;
    end;
  finally
    fLock.Leave;
  end;
  if Success then
    Log.LogStatus('Generated ' + Text, 'SongGenerator')
  else
    Log.LogWarn('Generation failed: ' + Text, 'SongGenerator');
end;

function TSongGenerator.Start(const Input, ReplaceTxt: UTF8String; const Language: UTF8String): boolean;
var
  Args:   TStringList;
  FFmpeg: UTF8String;
begin
  Result := false;
  if (State = gsRunning) or (Trim(Input) = '') or not Available then
    Exit;

  // the previous run is over, its thread only needs to be collected
  FreeAndNil(fThread);

  fLock.Enter;
  try
    fState := gsRunning;
    fStage := '';
    fLyricsSource := '';
    fMessage := '';
    fResult := '';
    fPending := false;
    fInput := Trim(Input);
    fReplace := ReplaceTxt;
    fStarted := Now;
  finally
    fLock.Leave;
  end;

  Args := TStringList.Create;
  Args.Add('--ultrasinger');
  Args.Add(fUltraSinger);
  Args.Add('--input');
  Args.Add(fInput);
  if ReplaceTxt <> '' then
  begin
    Args.Add('--replace');
    Args.Add(ReplaceTxt);
  end
  else
  begin
    Args.Add('--out');
    Args.Add(fOutputDir);
  end;
  Args.Add('--whisper');
  Args.Add(fWhisper);
  if Language <> '' then
  begin
    Args.Add('--language');
    Args.Add(Language);
  end
  else if fLanguage <> '' then
  begin
    Args.Add('--language');
    Args.Add(fLanguage);
  end;
  FFmpeg := FindFFmpeg('');
  if FFmpeg <> '' then
  begin
    Args.Add('--ffmpeg');
    Args.Add(ExtractFileDir(FFmpeg));
  end;

  Log.LogStatus('Generating from ' + fInput, 'SongGenerator');
  fThread := TGeneratorThread.Create(Self, Args);
  Result := true;
end;

procedure TSongGenerator.Cancel;
begin
  if fThread = nil then
    Exit;
  fThread.Terminate;
  fThread.WaitFor;
  FreeAndNil(fThread);
end;

function TSongGenerator.ElapsedSeconds: integer;
begin
  Result := SecondsBetween(Now, fStarted);
end;

procedure TSongGenerator.ApplyResult;
var
  FileName: IPath;
  Song:     TSong;
  I:        integer;
  Found:    boolean;
begin
  FileName := Path(ResultFile);
  Found := false;

  // a song whose notes were replaced: read its header again (BPM, GAP);
  // the notes are read from the file when it is sung
  for I := 0 to Songs.SongList.Count - 1 do
  begin
    Song := TSong(Songs.SongList[I]);
    if Song.Path.Append(Song.FileName).Equals(FileName, true) then
    begin
      Song.Analyse;
      Found := true;
      Break;
    end;
  end;

  if not Found then
  begin
    Song := TSong.Create(FileName);
    if Song.Analyse then
      Songs.SongList.Add(Song)
    else
    begin
      Log.LogError('Could not load generated song ' + FileName.ToNative, 'SongGenerator');
      Song.Free;
      Exit;
    end;
  end;

  CatSongs.Refresh;
  ScreenSong.RefreshCovers;
  Inc(fVersion);
end;

procedure TSongGenerator.Tick;
var
  Apply: boolean;
begin
  fLock.Enter;
  Apply := fPending;
  fPending := false;
  fLock.Leave;
  if Apply and (Songs <> nil) and not Songs.Processing then
  try
    ApplyResult;
  except
    on E: Exception do
      Log.LogError('Adding the generated song failed: ' + E.Message, 'SongGenerator');
  end;
end;

procedure StopSongGenerator;
begin
  FreeAndNil(SongGenerator);
end;

end.
