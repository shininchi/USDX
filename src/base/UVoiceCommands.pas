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

unit UVoiceCommands;

{*
 * Voice commands on a player's microphone: after two taps the game listens
 * for a moment. Saying a nickname puts the microphone in that name, so the
 * scores are saved for that player; saying goodbye ("adiós", "lo dejo",
 * "me voy"...) gives the microphone back to its default name (PlayerN).
 *
 * The speech is turned into text by whisper.cpp's server
 * (https://github.com/ggml-org/whisper.cpp), started by the game with the
 * model kept loaded. The text is compared with the nicknames already known
 * (scores, the song request page, the players' names), allowing for small
 * differences, as Whisper often writes names a bit differently.
 *
 * config.ini, section [Voice]:
 *   Enabled   On/Off
 *   Server    whisper-server executable (default: Homebrew's)
 *   Model     ggml model file
 *   Port      port of the local server (default 8178)
 *   Language  language spoken (default es)
 *   Names     players known from the start, separated by commas
 *
 * Each phrase is recognised twice: as it is, which gets goodbyes right, and
 * with the known names as a hint, which gets the names right.
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

type
  TVoiceResult = (vrNone, vrHello, vrGoodbye, vrNotUnderstood, vrNotHeard);

var
  VoiceEnabled: boolean = false;

procedure VoiceStart;  // startup: reads the config and starts the server
procedure VoiceStop;   // exit: stops the server
// audio thread: new samples of a player's microphone (signed 16 bit, mono)
procedure VoiceFeed(Player: integer; Samples: PSmallInt; Count, SampleRate: integer);
// main thread
function VoiceListen(Player: integer): boolean;
procedure VoiceTick;
function VoiceListeningPlayer: integer;  // -1 = nobody
function VoiceBusy: boolean;             // listening or recognising
// the last result, for a few seconds
function VoiceLastResult(out Player: integer; out Kind: TVoiceResult;
  out Name: UTF8String; out Ticks: cardinal): boolean;
// puts a microphone in a player's name ('' = its default name), taking the
// name off any other microphone
procedure AssignMic(Player: integer; const Name: UTF8String);
function IsDefaultName(const Name: UTF8String): boolean;

implementation

uses
  Classes,
  SysUtils,
  StrUtils,
  Math,
  SyncObjs,
  IniFiles,
  Process,
  fpjson,
  jsonparser,
  fphttpclient,
  sdl2,
  SQLiteTable3,
  UIni,
  ULog,
  UMusic,
  UNote,
  UPlatform,
  USongRequests;

const
  RATE          = 16000;  // what Whisper wants
  MAX_SECONDS   = 4;
  FRAME         = RATE div 50;  // 20 ms
  QUIET_START   = 2500;   // ms without speech: nobody spoke
  END_SILENCE   = 700;    // ms of silence after speech ends the phrase
  MIN_SPEECH    = 200;    // ms of speech needed
  SPEECH_LEVEL  = 0.04;   // level of speech, 0..1
  MATCH_LIMIT   = 0.72;   // similarity needed to take a known nickname ...
  CLEAR_LIMIT   = 0.6;    // ... or this much, when far ahead of the next name
  CLEAR_MARGIN  = 0.15;
  FAREWELL_LIMIT = 0.75;  // "salvo" is "salgo", "me rechiro" is "me retiro"

  FAREWELLS: array[0..15] of string = (
    'adios', 'hasta luego', 'lo dejo', 'me voy', 'salgo', 'me salgo', 'chao',
    'chau', 'hasta otra', 'nos vemos', 'me retiro', 'bye', 'agur', 'adeu',
    'hasta manana', 'me piro');
  // what Whisper writes for noise or silence
  HALLUCINATIONS: array[0..5] of string = (
    'suscribete', 'gracias por ver', 'subtitulos', 'amara', 'musica', 'gracias');
  PREFIXES: array[0..7] of string = (
    'hola soy ', 'yo soy ', 'soy ', 'me llamo ', 'mi nombre es ', 'hola ', 'es ', 'el ');

type
  TRecState = (rsIdle, rsRecording, rsRecognising);

  TRecognizer = class(TThread)
    private
      fWav: TMemoryStream;
      fHint: UTF8String;
      fText: UTF8String;      // as heard
      fHinted: UTF8String;    // with the names as a hint
      fError: UTF8String;
      function Recognise(const Prompt: UTF8String): UTF8String;
    protected
      procedure Execute; override;
    public
      constructor Create(Wav: TMemoryStream; const Hint: UTF8String);
      destructor Destroy; override;
  end;

var
  Lock:        TCriticalSection;
  Server:      TProcess;
  ServerPath, ModelPath, Language: UTF8String;
  Port:        integer = 8178;
  ConfigNames: TStringList;

  // recording, shared with the audio thread
  RecState:    TRecState = rsIdle;
  RecPlayer:   integer = -1;
  RecBuf:      array of SmallInt;
  RecLen:      integer;
  RecPos:      double;     // position in the input samples, for resampling
  FramePeak:   integer;
  FrameFill:   integer;
  SpeechMs:    integer;
  LastSpeech:  integer;    // RecLen when speech was last heard
  RecStarted:  cardinal;

  Recognizer:  TRecognizer;
  MusicDucked: boolean;

  LastPlayer:  integer = -1;
  LastKind:    TVoiceResult = vrNone;
  LastName:    UTF8String;
  LastTicks:   cardinal;

{ text helpers }

function Normalize(const Text: UTF8String): UTF8String;
const
  FROM: array[0..13] of string = ('á','é','í','ó','ú','ü','ñ','Á','É','Í','Ó','Ú','Ü','Ñ');
  TOO:  array[0..13] of string = ('a','e','i','o','u','u','n','a','e','i','o','u','u','n');
var
  I: integer;
  S: UTF8String;
begin
  S := Text;
  for I := 0 to High(FROM) do
    S := StringReplace(S, FROM[I], TOO[I], [rfReplaceAll]);
  S := LowerCase(S);
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['a'..'z', '0'..'9'] then
      Result := Result + S[I]
    else if (Result <> '') and (Result[Length(Result)] <> ' ') then
      Result := Result + ' ';
  Result := Trim(Result);
end;

// how a Spanish speaker says it, so "Balen" and "Valen" are the same
function Sounds(const Text: UTF8String): UTF8String;
var
  S: UTF8String;
  I: integer;
begin
  S := StringReplace(Normalize(Text), ' ', '', [rfReplaceAll]);
  S := StringReplace(S, 'v', 'b', [rfReplaceAll]);
  S := StringReplace(S, 'ce', 'se', [rfReplaceAll]);
  S := StringReplace(S, 'ci', 'si', [rfReplaceAll]);
  S := StringReplace(S, 'z', 's', [rfReplaceAll]);
  S := StringReplace(S, 'qu', 'k', [rfReplaceAll]);
  S := StringReplace(S, 'c', 'k', [rfReplaceAll]);
  S := StringReplace(S, 'll', 'y', [rfReplaceAll]);
  S := StringReplace(S, 'h', '', [rfReplaceAll]);
  S := StringReplace(S, 'w', 'u', [rfReplaceAll]);
  Result := '';
  for I := 1 to Length(S) do
    if (Result = '') or (Result[Length(Result)] <> S[I]) then
      Result := Result + S[I];
end;

function Levenshtein(const A, B: UTF8String): integer;
var
  D: array of array of integer;
  I, J: integer;
begin
  SetLength(D, Length(A) + 1, Length(B) + 1);
  for I := 0 to Length(A) do D[I][0] := I;
  for J := 0 to Length(B) do D[0][J] := J;
  for I := 1 to Length(A) do
    for J := 1 to Length(B) do
      D[I][J] := Min(Min(D[I-1][J] + 1, D[I][J-1] + 1), D[I-1][J-1] + Ord(A[I] <> B[J]));
  Result := D[Length(A)][Length(B)];
end;

function Similarity(const A, B: UTF8String): double;
var
  SA, SB: UTF8String;
begin
  SA := Sounds(A);
  SB := Sounds(B);
  if (SA = '') or (SB = '') then
    Exit(0);
  Result := 1 - Levenshtein(SA, SB) / Max(Length(SA), Length(SB));
end;

function ContainsPhrase(const Text: UTF8String; const Phrases: array of string): boolean;
var
  I: integer;
begin
  Result := false;
  for I := 0 to High(Phrases) do
    if Pos(' ' + Phrases[I] + ' ', ' ' + Text + ' ') > 0 then
      Exit(true);
end;

// a goodbye, also when Whisper wrote it a bit differently
function IsFarewell(const Text: UTF8String): boolean;
var
  Words, Phrase: TStringList;
  I, J, K: integer;
  Part: UTF8String;
begin
  Result := ContainsPhrase(Text, FAREWELLS);
  if Result then
    Exit;
  Words := TStringList.Create;
  Phrase := TStringList.Create;
  try
    Words.Delimiter := ' ';
    Words.DelimitedText := Text;
    Phrase.Delimiter := ' ';
    for I := 0 to High(FAREWELLS) do
    begin
      Phrase.DelimitedText := FAREWELLS[I];
      for J := 0 to Words.Count - Phrase.Count do
      begin
        Part := '';
        for K := 0 to Phrase.Count - 1 do
          Part := Part + Words[J + K] + ' ';
        if Similarity(Trim(Part), FAREWELLS[I]) >= FAREWELL_LIMIT then
          Exit(true);
      end;
    end;
  finally
    Phrase.Free;
    Words.Free;
  end;
end;

function DefaultName(Player: integer): UTF8String;
begin
  Result := 'Player' + IntToStr(Player + 1);
end;

function IsDefaultName(const Name: UTF8String): boolean;
begin
  Result := (Trim(Name) = '') or
            ((LowerCase(Copy(Trim(Name), 1, 6)) = 'player') and
             (StrToIntDef(Copy(Trim(Name), 7, 3), -1) > 0));
end;

procedure KnownNames(List: TStringList);
var
  DB: TSQLiteDatabase;
  Table: TSQLiteUniTable;
  I: integer;
begin
  List.Sorted := true;
  List.Duplicates := dupIgnore;
  List.CaseSensitive := false;
  for I := 0 to High(Ini.Name) do
    if not IsDefaultName(Ini.Name[I]) then
      List.Add(Trim(Ini.Name[I]));
  if ConfigNames <> nil then
    List.AddStrings(ConfigNames);
  if SongRequests <> nil then
    SongRequests.AddNicks(List);
  DB := nil;
  try
    try
      DB := TSQLiteDatabase.Create(Platform.GetGameUserPath.Append('Ultrastar.db').ToUTF8);
      DB.SetTimeout(500);
      Table := DB.GetUniTable('SELECT DISTINCT [Player] FROM [us_scores]');
      try
        while not Table.EOF do
        begin
          if not IsDefaultName(Table.FieldAsString(0)) then
            List.Add(Trim(Table.FieldAsString(0)));
          Table.Next;
        end;
      finally
        Table.Free;
      end;
    except
      on E: Exception do
        Log.LogWarn('Could not read the player names: ' + E.Message, 'Voice');
    end;
  finally
    DB.Free;
  end;
end;

function TitleCase(const Text: UTF8String): UTF8String;
var
  I: integer;
  Up: boolean;
begin
  Result := Text;
  Up := true;
  for I := 1 to Length(Result) do
  begin
    if Up and (Result[I] in ['a'..'z']) then
      Result[I] := UpCase(Result[I]);
    Up := Result[I] = ' ';
  end;
end;

{ recogniser thread }

constructor TRecognizer.Create(Wav: TMemoryStream; const Hint: UTF8String);
begin
  fWav := Wav;
  fHint := Hint;
  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TRecognizer.Destroy;
begin
  fWav.Free;
  inherited;
end;

function TRecognizer.Recognise(const Prompt: UTF8String): UTF8String;
var
  Client: TFPHTTPClient;
  Form: TStringList;
  Response: TStringStream;
  Data: TJSONData;
begin
  Result := '';
  Client := TFPHTTPClient.Create(nil);
  Form := TStringList.Create;
  Response := TStringStream.Create('');
  try
    Client.IOTimeout := 15000;
    Form.Values['response_format'] := 'json';
    Form.Values['language'] := Language;
    Form.Values['temperature'] := '0.0';
    if Prompt <> '' then
      Form.Values['prompt'] := Prompt;
    fWav.Position := 0;
    Client.StreamFormPost(Format('http://127.0.0.1:%d/inference', [Port]), Form,
      'file', 'voice.wav', fWav, Response);
    Data := GetJSON(Response.DataString);
    try
      if Data is TJSONObject then
        Result := Trim(TJSONObject(Data).Get('text', ''));
    finally
      Data.Free;
    end;
  finally
    Response.Free;
    Form.Free;
    Client.Free;
  end;
end;

procedure TRecognizer.Execute;
begin
  try
    fText := Recognise('');
    if fHint <> '' then
      fHinted := Recognise(fHint);
  except
    on E: Exception do
      fError := E.Message;
  end;
end;

{ server }

function FindServer(const Configured: UTF8String): UTF8String;
const
  CANDIDATES: array[0..1] of string = ('/opt/homebrew/bin/whisper-server', '/usr/local/bin/whisper-server');
var
  I: integer;
begin
  Result := '';
  if Configured <> '' then
  begin
    if FileExists(Configured) then
      Result := Configured;
    Exit;
  end;
  for I := 0 to High(CANDIDATES) do
    if FileExists(CANDIDATES[I]) then
      Exit(CANDIDATES[I]);
end;

procedure VoiceStart;
var
  IniFile: TMemIniFile;
  Enabled: boolean;
  I: integer;
begin
  IniFile := TMemIniFile.Create(Ini.Filename.ToNative);
  try
    Enabled := not SameText(IniFile.ReadString('Voice', 'Enabled', 'On'), 'Off');
    ServerPath := FindServer(Trim(IniFile.ReadString('Voice', 'Server', '')));
    ModelPath := Trim(IniFile.ReadString('Voice', 'Model',
      Platform.GetGameUserPath.Append('whisper').Append('ggml-base.bin').ToNative));
    Port := IniFile.ReadInteger('Voice', 'Port', 8178);
    Language := Trim(IniFile.ReadString('Voice', 'Language', 'es'));
    FreeAndNil(ConfigNames);
    ConfigNames := TStringList.Create;
    ConfigNames.StrictDelimiter := true;
    ConfigNames.Delimiter := ',';
    ConfigNames.DelimitedText := IniFile.ReadString('Voice', 'Names', '');
    for I := ConfigNames.Count - 1 downto 0 do
      if Trim(ConfigNames[I]) = '' then
        ConfigNames.Delete(I)
      else
        ConfigNames[I] := Trim(ConfigNames[I]);
  finally
    IniFile.Free;
  end;

  VoiceEnabled := Enabled and (ServerPath <> '') and FileExists(ModelPath);
  if not Enabled then
    Exit;
  if not VoiceEnabled then
  begin
    Log.LogWarn('Voice commands off: whisper-server or the model ' + ModelPath + ' was not found', 'Voice');
    Exit;
  end;

  Server := TProcess.Create(nil);
  Server.Executable := ServerPath;
  Server.Parameters.Add('-m');
  Server.Parameters.Add(ModelPath);
  Server.Parameters.Add('--host');
  Server.Parameters.Add('127.0.0.1');
  Server.Parameters.Add('--port');
  Server.Parameters.Add(IntToStr(Port));
  Server.Parameters.Add('-l');
  Server.Parameters.Add(Language);
  Server.Options := [poNoConsole];
  try
    Server.Execute;
    Log.LogStatus('Voice commands: whisper-server on port ' + IntToStr(Port), 'Voice');
  except
    on E: Exception do
    begin
      Log.LogWarn('Could not start whisper-server: ' + E.Message, 'Voice');
      VoiceEnabled := false;
      FreeAndNil(Server);
    end;
  end;
end;

procedure VoiceStop;
begin
  if Recognizer <> nil then
  begin
    Recognizer.WaitFor;
    FreeAndNil(Recognizer);
  end;
  if Server <> nil then
  begin
    if Server.Running then
      Server.Terminate(0);
    FreeAndNil(Server);
  end;
  VoiceEnabled := false;
end;

{ recording }

procedure VoiceFeed(Player: integer; Samples: PSmallInt; Count, SampleRate: integer);
var
  Step: double;
  I, A, B, Sum, N: integer;
  V: integer;
begin
  if (RecState <> rsRecording) or (Player <> RecPlayer) or (SampleRate <= 0) then
    Exit;
  Lock.Enter;
  try
    if (RecState <> rsRecording) or (Player <> RecPlayer) then
      Exit;
    // down to 16 kHz, averaging the input samples of each output sample
    Step := SampleRate / RATE;
    while (RecPos < Count) and (RecLen < Length(RecBuf)) do
    begin
      A := Trunc(RecPos);
      B := Min(Count, Max(A + 1, Trunc(RecPos + Step)));
      Sum := 0;
      N := 0;
      for I := A to B - 1 do
      begin
        Inc(Sum, Samples[I]);
        Inc(N);
      end;
      V := Sum div Max(1, N);
      RecBuf[RecLen] := V;
      Inc(RecLen);
      RecPos := RecPos + Step;

      // speech or silence, in frames of 20 ms
      if Abs(V) > FramePeak then
        FramePeak := Abs(V);
      Inc(FrameFill);
      if FrameFill >= FRAME then
      begin
        if FramePeak / 32768 >= SPEECH_LEVEL then
        begin
          Inc(SpeechMs, 20);
          LastSpeech := RecLen;
        end;
        FramePeak := 0;
        FrameFill := 0;
      end;
    end;
    RecPos := RecPos - Count;
  finally
    Lock.Leave;
  end;
end;

procedure DuckMusic(Duck: boolean);
begin
  if Duck = MusicDucked then
    Exit;
  MusicDucked := Duck;
  if Duck then
    AudioPlayback.SetVolume(0.1 * EnsureRange(Ini.PreviewVolume, 0, 100) / 100)
  else
    AudioPlayback.SetVolume(EnsureRange(Ini.PreviewVolume, 0, 100) / 100);
end;

function VoiceListen(Player: integer): boolean;
begin
  Result := false;
  if not VoiceEnabled or (RecState <> rsIdle) or (Player < 0) then
    Exit;
  Lock.Enter;
  try
    SetLength(RecBuf, RATE * MAX_SECONDS);
    RecLen := 0;
    RecPos := 0;
    FramePeak := 0;
    FrameFill := 0;
    SpeechMs := 0;
    LastSpeech := 0;
    RecPlayer := Player;
    RecStarted := SDL_GetTicks;
    RecState := rsRecording;
  finally
    Lock.Leave;
  end;
  DuckMusic(true);
  Log.LogStatus(Format('Listening to player %d', [Player + 1]), 'Voice');
  Result := true;
end;

function VoiceListeningPlayer: integer;
begin
  if RecState = rsIdle then
    Result := -1
  else
    Result := RecPlayer;
end;

function VoiceBusy: boolean;
begin
  Result := RecState <> rsIdle;
end;

function VoiceLastResult(out Player: integer; out Kind: TVoiceResult;
  out Name: UTF8String; out Ticks: cardinal): boolean;
begin
  Player := LastPlayer;
  Kind := LastKind;
  Name := LastName;
  Ticks := LastTicks;
  Result := Kind <> vrNone;
end;

function MakeWav(const Samples: array of SmallInt; Count: integer): TMemoryStream;

  procedure W32(V: longword); begin Result.WriteBuffer(V, 4); end;
  procedure W16(V: word); begin Result.WriteBuffer(V, 2); end;

begin
  Result := TMemoryStream.Create;
  Result.WriteBuffer(PAnsiChar('RIFF')^, 4);
  W32(36 + Count * 2);
  Result.WriteBuffer(PAnsiChar('WAVEfmt ')^, 8);
  W32(16); W16(1); W16(1); W32(RATE); W32(RATE * 2); W16(2); W16(16);
  Result.WriteBuffer(PAnsiChar('data')^, 4);
  W32(Count * 2);
  if Count > 0 then
    Result.WriteBuffer(Samples[0], Count * 2);
end;

procedure Finish(Kind: TVoiceResult; const Name: UTF8String);
begin
  LastPlayer := RecPlayer;
  LastKind := Kind;
  LastName := Name;
  LastTicks := SDL_GetTicks;
  RecState := rsIdle;
  DuckMusic(false);
end;

procedure SetName(Player: integer; const Name: UTF8String);
begin
  Ini.Name[Player] := Name;
  if Player <= High(UNote.Player) then
    UNote.Player[Player].Name := Name;
end;

function StripPrefix(const Text: UTF8String): UTF8String;
var
  I: integer;
begin
  Result := Text;
  for I := 0 to High(PREFIXES) do
    if Copy(Result + ' ', 1, Length(PREFIXES[I])) = PREFIXES[I] then
      Exit(Trim(Copy(Result, Length(PREFIXES[I]) + 1, MaxInt)));
end;

// the known name closest to Text, '' if none is close enough
function BestName(const Text: UTF8String; Known: TStrings; out Score: double): UTF8String;
var
  I: integer;
  S, Second: double;
begin
  Result := '';
  Score := 0;
  Second := 0;
  for I := 0 to Known.Count - 1 do
  begin
    S := Similarity(Text, Known[I]);
    if S > Score then
    begin
      Second := Score;
      Score := S;
      Result := Known[I];
    end
    else if S > Second then
      Second := S;
  end;
  if not ((Score >= MATCH_LIMIT) or ((Score >= CLEAR_LIMIT) and (Score - Second >= CLEAR_MARGIN))) then
    Result := '';
end;

function NewName(const Text: UTF8String): UTF8String;
begin
  Result := '';
  if (Text <> '') and (WordCount(Text, [' ']) <= 2) and (Length(Text) >= 2) and (Length(Text) <= 16) then
    Result := TitleCase(Text);
end;

procedure Understand(const Heard, Hinted: UTF8String);
var
  Plain, WithHint, Name, Candidate: UTF8String;
  Known: TStringList;
  I: integer;
  Score, CandidateScore: double;
begin
  Plain := Normalize(Heard);
  WithHint := Normalize(Hinted);
  Log.LogStatus(Format('Player %d said "%s" ("%s" with the names hint)',
    [RecPlayer + 1, Heard, Hinted]), 'Voice');
  if ContainsPhrase(Plain, HALLUCINATIONS) then
    Plain := '';
  if ContainsPhrase(WithHint, HALLUCINATIONS) then
    WithHint := '';

  // goodbyes come out right without the hint (with it Whisper hears names)
  if (Plain <> '') and IsFarewell(Plain) then
  begin
    Name := Ini.Name[RecPlayer];
    if IsDefaultName(Name) then
      Name := '';
    SetName(RecPlayer, DefaultName(RecPlayer));
    Log.LogStatus(Format('Microphone %d is free again', [RecPlayer + 1]), 'Voice');
    Finish(vrGoodbye, Name);
    Exit;
  end;

  Plain := StripPrefix(Plain);
  WithHint := StripPrefix(WithHint);
  Name := '';
  Score := 0;
  Known := TStringList.Create;
  try
    KnownNames(Known);
    if WithHint <> '' then
      Name := BestName(WithHint, Known, Score);
    if Plain <> '' then
    begin
      Candidate := BestName(Plain, Known, CandidateScore);
      if (Candidate <> '') and (CandidateScore > Score) then
      begin
        Name := Candidate;
        Score := CandidateScore;
      end;
    end;
  finally
    Known.Free;
  end;

  // somebody new: the name as heard with the hint, or as heard
  if Name = '' then
    Name := NewName(WithHint);
  if Name = '' then
    Name := NewName(Plain);
  if Name = '' then
  begin
    Finish(vrNotUnderstood, '');
    Exit;
  end;

  AssignMic(RecPlayer, Name);
  Log.LogStatus(Format('Microphone %d is now %s (%.2f)', [RecPlayer + 1, Name, Score]), 'Voice');
  Finish(vrHello, Name);
end;

procedure AssignMic(Player: integer; const Name: UTF8String);
var
  I: integer;
begin
  if (Player < 0) or (Player > High(Ini.Name)) then
    Exit;
  if Trim(Name) = '' then
  begin
    SetName(Player, DefaultName(Player));
    Exit;
  end;
  // a name is on one microphone at a time
  for I := 0 to High(Ini.Name) do
    if (I <> Player) and SameText(Trim(Ini.Name[I]), Trim(Name)) then
      SetName(I, DefaultName(I));
  SetName(Player, Trim(Name));
end;

// the known names, as a hint for Whisper
function NamesHint: UTF8String;
var
  Known: TStringList;
  I: integer;
begin
  Result := '';
  Known := TStringList.Create;
  try
    KnownNames(Known);
    for I := 0 to Known.Count - 1 do
      Result := Result + Known[I] + '. ';
  finally
    Known.Free;
  end;
  Result := Trim(Result);
end;

procedure VoiceTick;
var
  Elapsed: int64;
  Done, Heard: boolean;
  Wav: TMemoryStream;
begin
  case RecState of
    rsRecording:
      begin
        Elapsed := int64(SDL_GetTicks) - int64(RecStarted);
        Lock.Enter;
        try
          Heard := SpeechMs >= MIN_SPEECH;
          Done := (RecLen >= Length(RecBuf)) or
                  (Heard and ((RecLen - LastSpeech) * 1000 div RATE >= END_SILENCE)) or
                  ((not Heard) and (Elapsed > QUIET_START));
          if Done then
          begin
            if Heard then
              RecState := rsRecognising;
            Wav := nil;
            if Heard then
              Wav := MakeWav(RecBuf, RecLen);
          end;
        finally
          Lock.Leave;
        end;
        if Done and not Heard then
          Finish(vrNotHeard, '')
        else if Done then
          Recognizer := TRecognizer.Create(Wav, NamesHint);
      end;
    rsRecognising:
      if (Recognizer <> nil) and Recognizer.Finished then
      begin
        if Recognizer.fError <> '' then
        begin
          Log.LogWarn('Speech recognition failed: ' + Recognizer.fError, 'Voice');
          Finish(vrNotUnderstood, '');
        end
        else
          Understand(Recognizer.fText, Recognizer.fHinted);
        FreeAndNil(Recognizer);
      end;
  end;
end;

initialization
  Lock := TCriticalSection.Create;

finalization
  Lock.Free;

end.
