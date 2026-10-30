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
      fLyricsSource: UTF8String; // where the lyrics came from: user, lrclib, lrcmux, whisper
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
    protected
      fName: UTF8String;  // for the log
      // runs the script with Args (freed by the run) on Input
      function Launch(const Input, ReplaceTxt: UTF8String; Args: TStringList): boolean;
      function ScriptName: UTF8String; virtual;
      function LogFileName: UTF8String; virtual;
      procedure ApplyResult; virtual;
    public
      constructor Create;
      destructor Destroy; override;

      function PythonPath: UTF8String;
      function ScriptPath: UTF8String;
      function LogPath: UTF8String;
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

  {* Adds a video to a song with resources/generator/add_video.py: found on
   * YouTube by the song's name, from a link or from a file, with the
   * #VIDEOGAP that puts its music where the song's is. A video that is
   * only a picture with the lyrics on it becomes the song's background
   * picture instead, as Source 'still' does with the song's own video. *}
  TVideoAdder = class(TSongGenerator)
    private
      fTxt:    UTF8String;
      fSource: UTF8String;
      fWrite:  boolean;
      function ResultPart(Index: integer): UTF8String;
    protected
      function ScriptName: UTF8String; override;
      function LogFileName: UTF8String; override;
      procedure ApplyResult; override;
    public
      constructor Create;
      // Source: 'search', 'still', a link or a video file; WriteTags: set
      // #VIDEO and #VIDEOGAP (or #BACKGROUND) in the txt (else the caller
      // sets them, as the editor does)
      function Add(const Txt, Source: UTF8String; WriteTags: boolean): boolean;
      // of the finished run
      function VideoName: UTF8String;
      function VideoGap: real;
      function GapSure: boolean;  // false: the gap is a guess, to be checked
      function IsStill: boolean;  // VideoName is a background picture
      property Txt: UTF8String read fTxt;
  end;

var
  SongGenerator: TSongGenerator;
  VideoAdder: TVideoAdder;
  // file dropped onto the window, picked up by the screen that enabled drops
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
  ULanguage,
  ULog,
  UPath,
  UPathUtils,
  USong,
  USongRequests,
  USongRequestsOverlay,
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

  AssignFile(LogFile, fOwner.LogPath);
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
  fName := 'SongGenerator';
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

function TSongGenerator.ScriptName: UTF8String;
begin
  Result := 'usdx_generate.py';
end;

function TSongGenerator.ScriptPath: UTF8String;
begin
  Result := ResourcesPath.Append('generator').Append(ScriptName).ToNative;
end;

function TSongGenerator.LogFileName: UTF8String;
begin
  Result := 'generator.log';
end;

function TSongGenerator.LogPath: UTF8String;
begin
  Result := ExtractFilePath(Ini.Filename.ToNative) + LogFileName;
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
      fPending := true;  // ApplyResult tells of it where it has to
    end;
  finally
    fLock.Leave;
  end;
  if Success then
    Log.LogStatus('Done: ' + Text, fName)
  else
    Log.LogWarn('Failed: ' + Text, fName);
end;

function TSongGenerator.Launch(const Input, ReplaceTxt: UTF8String; Args: TStringList): boolean;
var
  FFmpeg: UTF8String;
begin
  Result := false;
  if (State = gsRunning) or (Trim(Input) = '') or not Available then
  begin
    Args.Free;
    Exit;
  end;

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

  FFmpeg := FindFFmpeg('');
  if FFmpeg <> '' then
  begin
    Args.Add('--ffmpeg');
    Args.Add(ExtractFileDir(FFmpeg));
  end;

  Log.LogStatus('Starting on ' + fInput, fName);
  fThread := TGeneratorThread.Create(Self, Args);
  Result := true;
end;

function TSongGenerator.Start(const Input, ReplaceTxt: UTF8String; const Language: UTF8String): boolean;
var
  Args: TStringList;
begin
  Args := TStringList.Create;
  Args.Add('--ultrasinger');
  Args.Add(fUltraSinger);
  Args.Add('--input');
  Args.Add(Trim(Input));
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
  Result := Launch(Input, ReplaceTxt, Args);
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
  if State <> gsDone then
    Exit;
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

{ TVideoAdder }

constructor TVideoAdder.Create;
begin
  inherited Create;
  fName := 'VideoAdder';
end;

function TVideoAdder.ScriptName: UTF8String;
begin
  Result := 'add_video.py';
end;

function TVideoAdder.LogFileName: UTF8String;
begin
  Result := 'video.log';
end;

function TVideoAdder.Add(const Txt, Source: UTF8String; WriteTags: boolean): boolean;
var
  Args: TStringList;
begin
  Result := false;
  if State = gsRunning then
    Exit;
  fTxt := Txt;
  fSource := Trim(Source);
  fWrite := WriteTags;
  Args := TStringList.Create;
  Args.Add('--txt');
  Args.Add(Txt);
  Args.Add('--source');
  Args.Add(Trim(Source));
  if WriteTags then
    Args.Add('--write');
  Result := Launch(Source, Txt, Args);
end;

// "<file>\t<gap>\t<sure|unsure>\t<video|still>" from add_video.py
function TVideoAdder.ResultPart(Index: integer): UTF8String;
var
  Parts: TStringList;
begin
  Result := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := #9;
    Parts.StrictDelimiter := true;
    Parts.DelimitedText := ResultFile;
    if Index < Parts.Count then
      Result := Parts[Index];
  finally
    Parts.Free;
  end;
end;

function TVideoAdder.VideoName: UTF8String;
begin
  Result := ResultPart(0);
end;

function TVideoAdder.VideoGap: real;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result := StrToFloatDef(ResultPart(1), 0, FS);
end;

function TVideoAdder.GapSure: boolean;
begin
  Result := ResultPart(2) = 'sure';
end;

function TVideoAdder.IsStill: boolean;
begin
  Result := ResultPart(3) = 'still';
end;

// the song menu's runs wrote the txt: its header is read again so the
// song list shows the video
procedure TVideoAdder.ApplyResult;
var
  FileName: IPath;
  Song:     TSong;
  I:        integer;
begin
  if not fWrite then
    Exit;
  if State <> gsDone then
  begin
    SongRequestsShowNotice(Language.Translate('VIDEO_ADD_FAILED') + ': ' + Message);
    Exit;
  end;
  FileName := Path(fTxt);
  for I := 0 to Songs.SongList.Count - 1 do
  begin
    Song := TSong(Songs.SongList[I]);
    if Song.Path.Append(Song.FileName).Equals(FileName, true) then
    begin
      Song.Analyse;
      Break;
    end;
  end;
  if fSource = 'still' then
    SongRequestsShowNotice(Language.Translate('VIDEO_STILL_DONE'))
  else if IsStill then
    SongRequestsShowNotice(Language.Translate('VIDEO_ADD_STILL'))
  else if GapSure then
    SongRequestsShowNotice(Language.Translate('VIDEO_ADD_DONE') + ': ' + VideoName)
  else
    SongRequestsShowNotice(Language.Translate('VIDEO_ADD_UNSURE'));
  Inc(fVersion);
end;

procedure StopSongGenerator;
begin
  FreeAndNil(SongGenerator);
  FreeAndNil(VideoAdder);
end;

end.
