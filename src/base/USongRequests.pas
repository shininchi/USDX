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

unit USongRequests;

{*
 * Song request system: guests browse the song library from their phones
 * (see USongRequestsServer) and request songs. Repeated requests act as
 * votes and move a song up in the queue.
 *
 * All state lives in TSongRequests and is guarded by a single critical
 * section, because it is accessed from the HTTP worker threads as well as
 * from the main thread. The song catalog is a snapshot of Songs.SongList
 * taken in the main thread (see Tick), so the HTTP threads never touch
 * TSong objects directly.
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Classes,
  Contnrs,
  SyncObjs,
  SysUtils,
  fpjson,
  UPath;

type
  TSongRequestsConfig = record
    Enabled:        boolean;
    Port:           integer;
    Host:           UTF8String; // address shown in the QR code, empty = autodetect
    AllowRemote:    boolean;    // accept clients outside of private networks
    QRTimeout:      integer;    // seconds, 0 = until the key is pressed again
    AdminPin:       UTF8String;
    FFmpeg:         UTF8String; // ffmpeg executable for video previews, empty = autodetect
  end;

  TSongRequestsSettings = record
    Paused:            boolean;
    MaxPendingPerUser: integer; // 0 = unlimited
    CooldownSeconds:   integer; // minimum time between two requests of a user
    RecentMinutes:     integer; // songs sung within this time cannot be requested
  end;

  TSRSong = record
    Key:       UTF8String; // lower case "artist|title", stable between sessions
    Artist:    UTF8String;
    Title:     UTF8String;
    Language:  UTF8String;
    Genre:     UTF8String;
    Edition:   UTF8String;
    Folder:    UTF8String;
    Year:      integer;
    Duet:      boolean;
    HasVideo:  boolean;
    CoverFile: UTF8String; // native path, empty if the song has no cover
    AudioFile: UTF8String; // native path, empty if missing
    VideoFile: UTF8String; // native path, empty if missing
    VideoGap:  real;       // seconds the video is ahead of the audio
    PreviewStart: real;    // seconds, -1 = not set in the song file
    StartSec:  real;       // #START in seconds
    FinishSec: real;       // #END in seconds, 0 = end of the audio
    Search:    UTF8String; // lower case ASCII "artist title" for searching
  end;

  TSRStats = record
    TimesPlayed: integer;
    BestScore:   integer;
    BestPlayer:  UTF8String;
  end;

  TSRSearchParams = record
    Query:    UTF8String;
    Language: UTF8String;
    Genre:    UTF8String;
    Folder:   UTF8String;
    Decade:   integer; // 0 = any, otherwise e.g. 1980
    Duet:     integer; // -1 = any, 0 = no, 1 = yes
    Video:    integer; // -1 = any, 0 = no, 1 = yes
    Sort:     UTF8String;
    Offset:   integer;
    Limit:    integer;
  end;

  TSRRequest = class
    Key:      UTF8String;
    Artist:   UTF8String;
    Title:    UTF8String;
    Voters:   TStringList; // user ids, first entry is the original requester
    FirstAt:  TDateTime;
    PinnedAt: TDateTime;   // 0 = not pinned
    Bonus:    integer;     // manual priority adjustment by the admin
    constructor Create;
    destructor Destroy; override;
    function Priority: integer;
  end;

  TSRQueueEntry = record
    Key:    UTF8String;
    Artist: UTF8String;
    Title:  UTF8String;
    By:     UTF8String; // nicknames of everybody who requested it
    Votes:  integer;
  end;
  TSRQueueEntries = array of TSRQueueEntry;

  TSRActivity = record
    Time:   int64;      // unix time, UTC
    Kind:   UTF8String; // request, vote, withdraw, join, nick, sung, admin_*, ...
    Who:    UTF8String; // nickname, "admin" or an IP address
    Detail: UTF8String; // song or other details, depending on the kind
  end;

  TSRUser = class
    Id:            UTF8String;
    Nick:          UTF8String;
    LastIP:        UTF8String;
    CreatedAt:     TDateTime;
    LastSeen:      TDateTime;
    LastRequestAt: TDateTime;
    MutedUntil:    TDateTime;
    TotalRequests: integer;
    Blocked:       boolean;
  end;

  TSongRequests = class
    private
      fLock:          TCriticalSection;
      fConfig:        TSongRequestsConfig;
      fSettings:      TSongRequestsSettings;
      fStateFile:     IPath;
      fScoreFile:     IPath;
      fThumbDir:      IPath;
      fDirty:         boolean;
      fVersion:       integer; // grows with every change of the state
      fLastSave:      TDateTime;

      // catalog snapshot
      fSongs:         array of TSRSong;
      fStats:         array of TSRStats;
      fKeyIndex:      TStringList; // song key -> index into fSongs
      fCatalogCount:  integer;     // Songs.SongList.Count of the last snapshot
      fStatsLoadedAt: TDateTime;

      fQueue:         TObjectList; // of TSRRequest, kept sorted by priority
      fUsers:         TObjectList; // of TSRUser
      fBlockedIPs:    TStringList;
      fLastSung:      TStringList; // song key = unix time
      fRequestCounts: TStringList; // song key = number of requests ever

      fAccent:        UTF8String; // theme color as #rrggbb for the web client

      fActivity:      array of TSRActivity; // oldest first

      // video preview clips, made by a worker thread with ffmpeg
      fFFmpeg:        UTF8String; // empty = clips not available
      fClipDir:       IPath;
      fClipJobs:      TStringList; // target=video|start
      fClipFailed:    TStringList; // targets that could not be made
      fClipEvent:     TEvent;
      fClipWorker:    TThread;

      // song being sung right now
      fNowKey, fNowArtist, fNowTitle, fNowPlayers: UTF8String;
      fNowStartedAt: double; // unix time in seconds, 0 = nothing is sung
      fNowOffset:    double; // song position when it started, seconds
      fNowDuration:  double; // seconds

      // last new request, shown in the game
      fNewRequestSeq:  integer;
      fNewRequestText: UTF8String;

      // admin login protection
      fAdminSessions: TStringList; // session tokens
      fFailedLogins:  TStringList; // ip = count;unix time of first failure

      function NextClipJob(out Target, Video: UTF8String; out Start: double): boolean;
      procedure ClipDone(const Target: UTF8String; Success: boolean);
      procedure LoadConfig;
      procedure LoadState;
      procedure SaveState;
      procedure MarkDirty;
      procedure AddActivity(const Kind, Who, Detail: UTF8String);
      procedure RemoveVotesOf(const UserId: UTF8String);

      procedure RebuildCatalog;
      procedure LoadStats;
      procedure EnsureStats;

      function FindSongIndex(const Key: UTF8String): integer;
      function FindUser(const Id: UTF8String): TSRUser;
      function FindRequest(const Key: UTF8String): TSRRequest;
      function RequestPosition(Request: TSRRequest): integer;
      function PendingOfUser(const UserId: UTF8String): integer;
      function RequestCount(const Key: UTF8String): integer;
      procedure SortQueue;
      function CompareSongs(A, B: integer; const Sort: UTF8String): integer;
      procedure SortIndices(var Indices: array of integer; const Sort: UTF8String);
      function SongToJSON(Index: integer; const UserId: UTF8String): TJSONObject;
      function RequestToJSON(Request: TSRRequest; const UserId: UTF8String; Admin: boolean): TJSONObject;
      function UserToJSON(User: TSRUser): TJSONObject;
      function GetPendingCount: integer;
    public
      constructor Create;
      destructor Destroy; override;

      // called from the main thread
      procedure Tick;

      // guest API, called from HTTP threads. Error codes are short ids
      // that the web client translates.
      function IsIPBlocked(const IP: UTF8String): boolean;
      function InfoJSON(const UserId: UTF8String): UTF8String;
      function SetNick(const UserId, IP, Nick: UTF8String): UTF8String;
      function SearchJSON(const Params: TSRSearchParams; const UserId: UTF8String): UTF8String;
      function SongJSON(Id: integer; const UserId: UTF8String): UTF8String;
      function QueueJSON(const UserId: UTF8String): UTF8String;
      function RequestSong(const UserId, IP: UTF8String; Id: integer): UTF8String;
      function WithdrawVote(const UserId: UTF8String; Id: integer): UTF8String;
      function CoverFile(Id: integer; Thumbnail: boolean): UTF8String;
      function AudioFile(Id: integer): UTF8String;
      {* Returns the path of a short muted preview clip of the song's video.
       * Status is 200 when the clip is ready, 202 while it is being made and
       * 404 when there is none. *}
      function VideoClip(Id: integer; out Status: integer): UTF8String;

      // admin API
      function AdminLogin(const IP, Pin: UTF8String; out Token: UTF8String): UTF8String;
      function IsAdminSession(const Token: UTF8String): boolean;
      function AdminStateJSON: UTF8String;
      function AdminQueueAction(const Action, Key: UTF8String): UTF8String;
      function AdminUserAction(const Action, Id, Value: UTF8String): UTF8String;
      function AdminSettings(Data: TJSONObject): UTF8String;
      function AdminIPAction(const Action, IP: UTF8String): UTF8String;
      function AdminMaintenance(const Action: UTF8String): UTF8String;

      // game API (main thread)
      procedure MarkSung(const Artist, Title: UTF8String);
      function QueueSnapshot: TSRQueueEntries;
      procedure SetNowPlaying(const Artist, Title, Players: UTF8String; Position, Duration: double);
      procedure ClearNowPlaying;
      {* Returns a number that grows with every new request (not with votes)
       * and the description of the latest one. *}
      function NewRequestSeq(out Text: UTF8String): integer;

      property Config: TSongRequestsConfig read fConfig;
      property PendingCount: integer read GetPendingCount;
      property Version: integer read fVersion;
  end;

var
  SongRequests: TSongRequests;

function SongRequestKey(const Artist, Title: UTF8String): UTF8String;
function GetLocalIPAddress: UTF8String;

implementation

uses
  DateUtils,
  IniFiles,
  Math,
  Process,
  Sockets,
  FPImage,
  FPReadJPEG,
  FPReadPNG,
  FPWriteJPEG,
  jsonparser,
  SQLiteTable3,
  UCommandLine,
  UIni,
  ULog,
  UPlatform,
  UCommon,
  USkins,
  USong,
  USongs,
  UThemes,
  UUnicodeUtils;

const
  STATE_VERSION      = 1;
  SAVE_INTERVAL_SEC  = 2;
  STATS_INTERVAL_SEC = 60;
  MAX_ACTIVITY       = 300;
  CLIP_SECONDS       = 30; // as long as the audio preview of the web client
  CLIP_HEIGHT        = 360;
  THUMB_SIZE         = 240;
  MAX_NICK_LENGTH    = 24;
  MAX_FAILED_LOGINS  = 5;
  LOGIN_LOCK_SEC     = 300;
  INI_SECTION        = 'SongRequests';

function SongRequestKey(const Artist, Title: UTF8String): UTF8String;
begin
  Result := UTF8LowerCase(Trim(Artist)) + '|' + UTF8LowerCase(Trim(Title));
end;

{* Song files often use "Unknown" for missing values. *}
function CleanTag(const S: UTF8String): UTF8String;
begin
  Result := Trim(S);
  if SameText(Result, 'Unknown') then
    Result := '';
end;

function NormalizeSearch(const S: UTF8String): UTF8String;
begin
  Result := LowerCase(TransliterateToASCII(S));
end;

{$PUSH}{$Q-}{$R-} // the hash relies on integer overflow
function HashString(const S: UTF8String): cardinal;
var
  I: integer;
begin
  // FNV-1a
  Result := 2166136261;
  for I := 1 to Length(S) do
    Result := (Result xor Ord(S[I])) * 16777619;
end;
{$POP}

function NowUTC: TDateTime;
begin
  Result := LocalTimeToUniversal(SysUtils.Now);
end;

function UnixNow: int64;
begin
  Result := DateTimeToUnix(NowUTC);
end;

function RandomToken(Len: integer): UTF8String;
const
  CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789';
var
  I: integer;
begin
  SetLength(Result, Len);
  for I := 1 to Len do
    Result[I] := CHARS[Random(Length(CHARS)) + 1];
end;

{* Returns the address of the interface used for the default route. No packet
 * is sent: connecting an UDP socket only selects the outgoing interface. *}
function GetLocalIPAddress: UTF8String;
var
  Sock: TSocket;
  Addr: TInetSockAddr;
  Len:  TSockLen;
begin
  Result := '127.0.0.1';
  Sock := fpSocket(AF_INET, SOCK_DGRAM, 0);
  if Sock < 0 then
    Exit;
  try
    FillChar(Addr, SizeOf(Addr), 0);
    Addr.sin_family := AF_INET;
    Addr.sin_port := htons(53);
    Addr.sin_addr := StrToNetAddr('8.8.8.8');
    if fpConnect(Sock, @Addr, SizeOf(Addr)) <> 0 then
      Exit;
    Len := SizeOf(Addr);
    if fpGetSockName(Sock, @Addr, @Len) = 0 then
      Result := NetAddrToStr(Addr.sin_addr);
  finally
    CloseSocket(Sock);
  end;
end;

type
  TSRClipWorker = class(TThread)
    private
      fOwner: TSongRequests;
      function MakeClip(const Video, Target: UTF8String; Start: double): boolean;
    protected
      procedure Execute; override;
    public
      constructor Create(Owner: TSongRequests);
  end;

function FindFFmpeg(const Configured: UTF8String): UTF8String;
const
  // apps started from the Finder do not get the shell's PATH
  CANDIDATES: array[0..3] of string = (
    '/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg', '/usr/bin/ffmpeg', 'C:\ffmpeg\bin\ffmpeg.exe');
var
  I: integer;
begin
  Result := '';
  if (Configured <> '') then
  begin
    if FileExists(Configured) then
      Result := Configured;
    Exit;
  end;
  for I := Low(CANDIDATES) to High(CANDIDATES) do
    if FileExists(CANDIDATES[I]) then
    begin
      Result := CANDIDATES[I];
      Exit;
    end;
  Result := ExeSearch('ffmpeg', GetEnvironmentVariable('PATH'));
end;

function FileSizeOf(const FileName: UTF8String): int64;
var
  Info: TSearchRec;
begin
  Result := -1;
  if FindFirst(FileName, faAnyFile, Info) = 0 then
  begin
    Result := Info.Size;
    FindClose(Info);
  end;
end;

{* Song position (audio time, in seconds) where the preview clip starts. The
 * web client starts the audio preview there too, so both match. *}
function ClipStartOf(const Song: TSRSong): double;
begin
  if Song.PreviewStart >= 0 then
    Result := Song.PreviewStart
  else if Song.FinishSec > Song.StartSec then
    Result := Song.StartSec + Min(60, (Song.FinishSec - Song.StartSec) / 4)
  else
    Result := Song.StartSec + 45;
end;

{ TSRClipWorker }

constructor TSRClipWorker.Create(Owner: TSongRequests);
begin
  fOwner := Owner;
  inherited Create(false);
end;

function TSRClipWorker.MakeClip(const Video, Target: UTF8String; Start: double): boolean;
var
  Proc:    TProcess;
  TmpFile: UTF8String;
  Fmt:     TFormatSettings;
begin
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  TmpFile := Target + '.tmp.mp4';
  Proc := TProcess.Create(nil);
  try
    Proc.Executable := fOwner.fFFmpeg;
    Proc.Parameters.Add('-nostdin');
    Proc.Parameters.Add('-loglevel');
    Proc.Parameters.Add('error');
    Proc.Parameters.Add('-y');
    Proc.Parameters.Add('-ss');
    Proc.Parameters.Add(FormatFloat('0.00', Start, Fmt));
    Proc.Parameters.Add('-i');
    Proc.Parameters.Add(Video);
    Proc.Parameters.Add('-t');
    Proc.Parameters.Add(IntToStr(CLIP_SECONDS));
    Proc.Parameters.Add('-an');
    Proc.Parameters.Add('-vf');
    Proc.Parameters.Add(Format('scale=-2:%d', [CLIP_HEIGHT]));
    Proc.Parameters.Add('-c:v');
    Proc.Parameters.Add('libx264');
    Proc.Parameters.Add('-preset');
    Proc.Parameters.Add('veryfast');
    Proc.Parameters.Add('-crf');
    Proc.Parameters.Add('28');
    Proc.Parameters.Add('-pix_fmt');
    Proc.Parameters.Add('yuv420p');
    Proc.Parameters.Add('-movflags');
    Proc.Parameters.Add('+faststart');
    Proc.Parameters.Add(TmpFile);
    Proc.Options := [poWaitOnExit, poNoConsole];
    try
      Proc.Execute;
    except
      on E: Exception do
        Log.LogWarn('Could not run ffmpeg: ' + E.Message, 'TSRClipWorker');
    end;
    // a start past the end of the video gives an empty clip
    Result := FileSizeOf(TmpFile) > 2048;
    if Result then
      Result := RenameFile(TmpFile, Target);
    if FileExists(TmpFile) then
      DeleteFile(TmpFile);
  finally
    Proc.Free;
  end;
end;

procedure TSRClipWorker.Execute;
var
  Target, Video: UTF8String;
  Start:         double;
  Success:       boolean;
begin
  while not Terminated do
  begin
    if not fOwner.NextClipJob(Target, Video, Start) then
    begin
      fOwner.fClipEvent.WaitFor(1000);
      Continue;
    end;
    Success := MakeClip(Video, Target, Start);
    if (not Success) and (Start > 0) and (not Terminated) then
      Success := MakeClip(Video, Target, 0);
    fOwner.ClipDone(Target, Success);
  end;
end;

{ TSRRequest }

constructor TSRRequest.Create;
begin
  inherited;
  Voters := TStringList.Create;
end;

destructor TSRRequest.Destroy;
begin
  Voters.Free;
  inherited;
end;

function TSRRequest.Priority: integer;
begin
  Result := Voters.Count + Bonus;
end;

function CompareRequests(Item1, Item2: Pointer): integer;
var
  A, B: TSRRequest;
begin
  A := TSRRequest(Item1);
  B := TSRRequest(Item2);
  // pinned requests first, the most recently pinned on top
  if (A.PinnedAt <> 0) or (B.PinnedAt <> 0) then
  begin
    if A.PinnedAt = B.PinnedAt then
      Result := 0
    else if A.PinnedAt = 0 then
      Result := 1
    else if B.PinnedAt = 0 then
      Result := -1
    else
      Result := CompareValue(B.PinnedAt, A.PinnedAt);
    if Result <> 0 then
      Exit;
  end;
  // more votes first, older requests win ties
  Result := CompareValue(B.Priority, A.Priority);
  if Result = 0 then
    Result := CompareValue(A.FirstAt, B.FirstAt);
end;

{ TSongRequests }

constructor TSongRequests.Create;
begin
  inherited;
  Randomize;
  fLock := TCriticalSection.Create;
  fKeyIndex := TStringList.Create;
  fKeyIndex.Sorted := true;
  fKeyIndex.Duplicates := dupIgnore;
  fKeyIndex.CaseSensitive := true;
  fQueue := TObjectList.Create(true);
  fUsers := TObjectList.Create(true);
  fBlockedIPs := TStringList.Create;
  fBlockedIPs.Sorted := true;
  fBlockedIPs.Duplicates := dupIgnore;
  fLastSung := TStringList.Create;
  fRequestCounts := TStringList.Create;
  fAdminSessions := TStringList.Create;
  fFailedLogins := TStringList.Create;
  fCatalogCount := -1;

  if Params.ScoreFile.IsUnset then
    fScoreFile := Platform.GetGameUserPath.Append('Ultrastar.db')
  else
    fScoreFile := Params.ScoreFile;
  fStateFile := Platform.GetGameUserPath.Append('SongRequests.json');
  fThumbDir := Platform.GetGameUserPath.Append('cache').Append('request-covers');
  fClipDir := Platform.GetGameUserPath.Append('cache').Append('request-videos');
  fClipJobs := TStringList.Create;
  fClipFailed := TStringList.Create;
  fClipEvent := TEvent.Create(nil, false, false, '');

  fSettings.Paused := false;
  fSettings.MaxPendingPerUser := 3;
  fSettings.CooldownSeconds := 60;
  fSettings.RecentMinutes := 60;

  LoadConfig;
  LoadState;

  if fConfig.Enabled then
  begin
    fFFmpeg := FindFFmpeg(fConfig.FFmpeg);
    if fFFmpeg <> '' then
    begin
      Log.LogStatus('Video previews made with ' + fFFmpeg, 'TSongRequests');
      fClipWorker := TSRClipWorker.Create(Self);
    end
    else
      Log.LogStatus('ffmpeg not found, no video previews', 'TSongRequests');
  end;
end;

destructor TSongRequests.Destroy;
begin
  if fClipWorker <> nil then
  begin
    fClipWorker.Terminate;
    fClipEvent.SetEvent;
    fClipWorker.WaitFor;
    fClipWorker.Free;
  end;
  fClipEvent.Free;
  fClipJobs.Free;
  fClipFailed.Free;
  if fDirty then
    SaveState;
  fQueue.Free;
  fUsers.Free;
  fBlockedIPs.Free;
  fLastSung.Free;
  fRequestCounts.Free;
  fAdminSessions.Free;
  fFailedLogins.Free;
  fKeyIndex.Free;
  fLock.Free;
  inherited;
end;

procedure TSongRequests.LoadConfig;
var
  IniFile: TMemIniFile;
  Writer:  TIniFile;
  Missing: boolean;
begin
  IniFile := TMemIniFile.Create(Ini.Filename.ToNative);
  try
    Missing := not IniFile.SectionExists(INI_SECTION);
    fConfig.Enabled := SameText(IniFile.ReadString(INI_SECTION, 'Enabled', 'Off'), 'On');
    fConfig.Port := IniFile.ReadInteger(INI_SECTION, 'Port', 8080);
    fConfig.Host := Trim(IniFile.ReadString(INI_SECTION, 'Host', ''));
    fConfig.AllowRemote := SameText(IniFile.ReadString(INI_SECTION, 'AllowRemote', 'Off'), 'On');
    fConfig.QRTimeout := IniFile.ReadInteger(INI_SECTION, 'QRTimeout', 30);
    fConfig.AdminPin := Trim(IniFile.ReadString(INI_SECTION, 'AdminPin', ''));
    fConfig.FFmpeg := Trim(IniFile.ReadString(INI_SECTION, 'FFmpeg', ''));
  finally
    IniFile.Free;
  end;

  if (fConfig.Port <= 0) or (fConfig.Port > 65535) then
    fConfig.Port := 8080;
  if fConfig.QRTimeout < 0 then
    fConfig.QRTimeout := 0;

  // write the defaults once so they can be found and edited in config.ini
  if Missing or (fConfig.AdminPin = '') then
  begin
    if fConfig.AdminPin = '' then
      fConfig.AdminPin := Format('%.6d', [Random(1000000)]);
    Writer := TIniFile.Create(Ini.Filename.ToNative);
    try
      if fConfig.Enabled then
        Writer.WriteString(INI_SECTION, 'Enabled', 'On')
      else
        Writer.WriteString(INI_SECTION, 'Enabled', 'Off');
      Writer.WriteInteger(INI_SECTION, 'Port', fConfig.Port);
      Writer.WriteString(INI_SECTION, 'Host', fConfig.Host);
      if fConfig.AllowRemote then
        Writer.WriteString(INI_SECTION, 'AllowRemote', 'On')
      else
        Writer.WriteString(INI_SECTION, 'AllowRemote', 'Off');
      Writer.WriteInteger(INI_SECTION, 'QRTimeout', fConfig.QRTimeout);
      Writer.WriteString(INI_SECTION, 'AdminPin', fConfig.AdminPin);
    finally
      Writer.Free;
    end;
  end;
end;

{ persistence }

procedure TSongRequests.LoadState;
var
  Data:     TJSONData;
  Root, O:  TJSONObject;
  Arr:      TJSONArray;
  I, J:     integer;
  Request:  TSRRequest;
  User:     TSRUser;
  Stream:   TFileStream;
begin
  if not fStateFile.IsFile then
    Exit;

  Data := nil;
  try
    Stream := TFileStream.Create(fStateFile.ToNative, fmOpenRead or fmShareDenyWrite);
    try
      Data := GetJSON(Stream);
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
    begin
      Log.LogError('Could not read ' + fStateFile.ToUTF8 + ': ' + E.Message, 'TSongRequests.LoadState');
      FreeAndNil(Data);
      Exit;
    end;
  end;

  try
    if not (Data is TJSONObject) then
      Exit;
    Root := TJSONObject(Data);

    O := Root.Get('settings', TJSONObject(nil));
    if O <> nil then
    begin
      fSettings.Paused := O.Get('paused', fSettings.Paused);
      fSettings.MaxPendingPerUser := O.Get('maxPending', fSettings.MaxPendingPerUser);
      fSettings.CooldownSeconds := O.Get('cooldown', fSettings.CooldownSeconds);
      fSettings.RecentMinutes := O.Get('recentMinutes', fSettings.RecentMinutes);
    end;

    Arr := Root.Get('users', TJSONArray(nil));
    if Arr <> nil then
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr[I] is TJSONObject) then
          Continue;
        O := TJSONObject(Arr[I]);
        User := TSRUser.Create;
        User.Id := O.Get('id', '');
        User.Nick := O.Get('nick', '');
        User.LastIP := O.Get('ip', '');
        User.CreatedAt := UnixToDateTime(O.Get('created', int64(0)));
        User.LastSeen := UnixToDateTime(O.Get('seen', int64(0)));
        User.LastRequestAt := UnixToDateTime(O.Get('lastRequest', int64(0)));
        User.MutedUntil := UnixToDateTime(O.Get('mutedUntil', int64(0)));
        User.TotalRequests := O.Get('requests', 0);
        User.Blocked := O.Get('blocked', false);
        if User.Id <> '' then
          fUsers.Add(User)
        else
          User.Free;
      end;

    Arr := Root.Get('queue', TJSONArray(nil));
    if Arr <> nil then
      for I := 0 to Arr.Count - 1 do
      begin
        if not (Arr[I] is TJSONObject) then
          Continue;
        O := TJSONObject(Arr[I]);
        Request := TSRRequest.Create;
        Request.Key := O.Get('key', '');
        Request.Artist := O.Get('artist', '');
        Request.Title := O.Get('title', '');
        Request.FirstAt := UnixToDateTime(O.Get('firstAt', int64(0)));
        if O.Get('pinnedAt', int64(0)) <> 0 then
          Request.PinnedAt := UnixToDateTime(O.Get('pinnedAt', int64(0)));
        Request.Bonus := O.Get('bonus', 0);
        if O.Get('voters', TJSONArray(nil)) <> nil then
          for J := 0 to O.Arrays['voters'].Count - 1 do
            Request.Voters.Add(O.Arrays['voters'].Strings[J]);
        if Request.Key <> '' then
          fQueue.Add(Request)
        else
          Request.Free;
      end;

    Arr := Root.Get('blockedIps', TJSONArray(nil));
    if Arr <> nil then
      for I := 0 to Arr.Count - 1 do
        fBlockedIPs.Add(Arr.Strings[I]);

    O := Root.Get('lastSung', TJSONObject(nil));
    if O <> nil then
      for I := 0 to O.Count - 1 do
        fLastSung.Values[O.Names[I]] := IntToStr(O.Items[I].AsInt64);

    O := Root.Get('requestCounts', TJSONObject(nil));
    if O <> nil then
      for I := 0 to O.Count - 1 do
        fRequestCounts.Values[O.Names[I]] := IntToStr(O.Items[I].AsInteger);

    Arr := Root.Get('activity', TJSONArray(nil));
    if Arr <> nil then
    begin
      SetLength(fActivity, 0);
      for I := Max(0, Arr.Count - MAX_ACTIVITY) to Arr.Count - 1 do
      begin
        if not (Arr[I] is TJSONObject) then
          Continue;
        O := TJSONObject(Arr[I]);
        J := Length(fActivity);
        SetLength(fActivity, J + 1);
        fActivity[J].Time := O.Get('t', int64(0));
        fActivity[J].Kind := O.Get('k', '');
        fActivity[J].Who := O.Get('w', '');
        fActivity[J].Detail := O.Get('d', '');
      end;
    end;

    SortQueue;
  finally
    Data.Free;
  end;
end;

procedure TSongRequests.SaveState;
var
  Root, O:  TJSONObject;
  Arr, V:   TJSONArray;
  I, J:     integer;
  Request:  TSRRequest;
  User:     TSRUser;
  Content:  UTF8String;
  TmpFile:  UTF8String;
  Stream:   TFileStream;
begin
  Root := TJSONObject.Create;
  try
    Root.Add('version', STATE_VERSION);

    O := TJSONObject.Create;
    O.Add('paused', fSettings.Paused);
    O.Add('maxPending', fSettings.MaxPendingPerUser);
    O.Add('cooldown', fSettings.CooldownSeconds);
    O.Add('recentMinutes', fSettings.RecentMinutes);
    Root.Add('settings', O);

    Arr := TJSONArray.Create;
    for I := 0 to fQueue.Count - 1 do
    begin
      Request := TSRRequest(fQueue[I]);
      O := TJSONObject.Create;
      O.Add('key', Request.Key);
      O.Add('artist', Request.Artist);
      O.Add('title', Request.Title);
      O.Add('firstAt', DateTimeToUnix(Request.FirstAt));
      if Request.PinnedAt <> 0 then
        O.Add('pinnedAt', DateTimeToUnix(Request.PinnedAt));
      O.Add('bonus', Request.Bonus);
      V := TJSONArray.Create;
      for J := 0 to Request.Voters.Count - 1 do
        V.Add(Request.Voters[J]);
      O.Add('voters', V);
      Arr.Add(O);
    end;
    Root.Add('queue', Arr);

    Arr := TJSONArray.Create;
    for I := 0 to fUsers.Count - 1 do
    begin
      User := TSRUser(fUsers[I]);
      O := TJSONObject.Create;
      O.Add('id', User.Id);
      O.Add('nick', User.Nick);
      O.Add('ip', User.LastIP);
      O.Add('created', DateTimeToUnix(User.CreatedAt));
      O.Add('seen', DateTimeToUnix(User.LastSeen));
      O.Add('lastRequest', DateTimeToUnix(User.LastRequestAt));
      O.Add('mutedUntil', DateTimeToUnix(User.MutedUntil));
      O.Add('requests', User.TotalRequests);
      O.Add('blocked', User.Blocked);
      Arr.Add(O);
    end;
    Root.Add('users', Arr);

    Arr := TJSONArray.Create;
    for I := 0 to fBlockedIPs.Count - 1 do
      Arr.Add(fBlockedIPs[I]);
    Root.Add('blockedIps', Arr);

    O := TJSONObject.Create;
    for I := 0 to fLastSung.Count - 1 do
      O.Add(fLastSung.Names[I], StrToInt64Def(fLastSung.ValueFromIndex[I], 0));
    Root.Add('lastSung', O);

    O := TJSONObject.Create;
    for I := 0 to fRequestCounts.Count - 1 do
      O.Add(fRequestCounts.Names[I], StrToIntDef(fRequestCounts.ValueFromIndex[I], 0));
    Root.Add('requestCounts', O);

    Arr := TJSONArray.Create;
    for I := 0 to High(fActivity) do
    begin
      O := TJSONObject.Create;
      O.Add('t', fActivity[I].Time);
      O.Add('k', fActivity[I].Kind);
      O.Add('w', fActivity[I].Who);
      O.Add('d', fActivity[I].Detail);
      Arr.Add(O);
    end;
    Root.Add('activity', Arr);

    Content := Root.FormatJSON;
  finally
    Root.Free;
  end;

  // write to a temporary file first so a crash never leaves a broken file
  TmpFile := fStateFile.ToNative + '.tmp';
  try
    Stream := TFileStream.Create(TmpFile, fmCreate);
    try
      if Length(Content) > 0 then
        Stream.WriteBuffer(Content[1], Length(Content));
    finally
      Stream.Free;
    end;
    if FileExists(fStateFile.ToNative) then
      DeleteFile(fStateFile.ToNative);
    RenameFile(TmpFile, fStateFile.ToNative);
    fDirty := false;
    fLastSave := NowUTC;
  except
    on E: Exception do
      Log.LogError('Could not write ' + fStateFile.ToUTF8 + ': ' + E.Message, 'TSongRequests.SaveState');
  end;
end;

procedure TSongRequests.MarkDirty;
begin
  fDirty := true;
  Inc(fVersion);
end;

{* Appends to the activity log; the caller holds the lock. *}
procedure TSongRequests.AddActivity(const Kind, Who, Detail: UTF8String);
var
  I, N: integer;
begin
  N := Length(fActivity);
  if N >= MAX_ACTIVITY then
  begin
    // drop the oldest entry
    for I := 0 to N - 2 do
      fActivity[I] := fActivity[I + 1];
    Dec(N);
  end
  else
    SetLength(fActivity, N + 1);
  fActivity[N].Time := UnixNow;
  fActivity[N].Kind := Kind;
  fActivity[N].Who := Who;
  fActivity[N].Detail := Detail;
  MarkDirty;
end;

{* Removes all votes of a user and the requests left without votes; the
 * caller holds the lock. *}
procedure TSongRequests.RemoveVotesOf(const UserId: UTF8String);
var
  I, VoteIdx: integer;
begin
  for I := fQueue.Count - 1 downto 0 do
  begin
    VoteIdx := TSRRequest(fQueue[I]).Voters.IndexOf(UserId);
    if VoteIdx >= 0 then
      TSRRequest(fQueue[I]).Voters.Delete(VoteIdx);
    if TSRRequest(fQueue[I]).Voters.Count = 0 then
      fQueue.Delete(I);
  end;
  SortQueue;
end;

{ catalog }

procedure TSongRequests.RebuildCatalog;
var
  I, N:     integer;
  Song:     TSong;
  CoverPath: IPath;
begin
  N := Songs.SongList.Count;
  SetLength(fSongs, N);
  SetLength(fStats, N);
  // keep the index sorted while adding so duplicates are ignored and the
  // first copy of a song wins
  fKeyIndex.Clear;
  for I := 0 to N - 1 do
  begin
    Song := TSong(Songs.SongList[I]);
    fSongs[I].Key := SongRequestKey(Song.Artist, Song.Title);
    fSongs[I].Artist := Song.Artist;
    fSongs[I].Title := Song.Title;
    fSongs[I].Language := CleanTag(Song.Language);
    fSongs[I].Genre := CleanTag(Song.Genre);
    fSongs[I].Edition := CleanTag(Song.Edition);
    fSongs[I].Folder := Song.Folder;
    fSongs[I].Year := Song.Year;
    fSongs[I].Duet := Song.isDuet;
    fSongs[I].HasVideo := not Song.Video.IsUnset;
    fSongs[I].CoverFile := '';
    if not Song.Cover.IsUnset then
    begin
      CoverPath := Song.Path.Append(Song.Cover);
      if CoverPath.IsFile then
        fSongs[I].CoverFile := CoverPath.ToNative;
    end;
    fSongs[I].AudioFile := '';
    if not Song.Audio.IsUnset and Song.Path.Append(Song.Audio).IsFile then
      fSongs[I].AudioFile := Song.Path.Append(Song.Audio).ToNative;
    fSongs[I].VideoFile := '';
    if not Song.Video.IsUnset and Song.Path.Append(Song.Video).IsFile then
      fSongs[I].VideoFile := Song.Path.Append(Song.Video).ToNative;
    fSongs[I].HasVideo := fSongs[I].VideoFile <> '';
    fSongs[I].VideoGap := Song.VideoGAP;
    if Song.HasPreview or (Song.PreviewStart > 0) then
      fSongs[I].PreviewStart := Song.PreviewStart
    else
      fSongs[I].PreviewStart := -1;
    fSongs[I].StartSec := Song.Start;
    fSongs[I].FinishSec := Song.Finish / 1000;
    fSongs[I].Search := Song.ArtistASCII + ' ' + Song.TitleASCII;
    fKeyIndex.AddObject(fSongs[I].Key, TObject(PtrInt(I)));
  end;
  fCatalogCount := N;
  fStatsLoadedAt := 0;
  Log.LogStatus(Format('Song request catalog: %d songs', [N]), 'TSongRequests');
end;

procedure TSongRequests.LoadStats;
var
  DB:     TSQLiteDatabase;
  Table:  TSQLiteUniTable;
  IDs:    TStringList; // database song id -> index in fSongs
  I, Idx: integer;
  Score:  integer;
begin
  for I := 0 to High(fStats) do
  begin
    fStats[I].TimesPlayed := 0;
    fStats[I].BestScore := 0;
    fStats[I].BestPlayer := '';
  end;
  fStatsLoadedAt := NowUTC;

  if not fScoreFile.IsFile then
    Exit;

  IDs := TStringList.Create;
  DB := nil;
  try
    try
      DB := TSQLiteDatabase.Create(fScoreFile.ToUTF8);
      DB.SetTimeout(500);

      Table := DB.GetUniTable('SELECT [ID], [Artist], [Title], [TimesPlayed] FROM [us_songs]');
      try
        while not Table.EOF do
        begin
          Idx := FindSongIndex(SongRequestKey(Table.FieldAsString(1), Table.FieldAsString(2)));
          if Idx >= 0 then
          begin
            Inc(fStats[Idx].TimesPlayed, Table.FieldAsInteger(3));
            IDs.Values[Table.FieldAsString(0)] := IntToStr(Idx);
          end;
          Table.Next;
        end;
      finally
        Table.Free;
      end;

      Table := DB.GetUniTable('SELECT [SongID], [Player], [Score] FROM [us_scores]');
      try
        while not Table.EOF do
        begin
          Idx := StrToIntDef(IDs.Values[Table.FieldAsString(0)], -1);
          Score := Table.FieldAsInteger(2);
          if (Idx >= 0) and (Score > fStats[Idx].BestScore) then
          begin
            fStats[Idx].BestScore := Score;
            fStats[Idx].BestPlayer := Table.FieldAsString(1);
          end;
          Table.Next;
        end;
      finally
        Table.Free;
      end;
    except
      on E: Exception do
        Log.LogError('Could not read scores: ' + E.Message, 'TSongRequests.LoadStats');
    end;
  finally
    DB.Free;
    IDs.Free;
  end;
end;

procedure TSongRequests.EnsureStats;
begin
  if (fStatsLoadedAt = 0) or (SecondsBetween(NowUTC, fStatsLoadedAt) >= STATS_INTERVAL_SEC) then
    LoadStats;
end;

function TSongRequests.FindSongIndex(const Key: UTF8String): integer;
var
  I: integer;
begin
  if fKeyIndex.Find(Key, I) then
    Result := PtrInt(fKeyIndex.Objects[I])
  else
    Result := -1;
end;

function TSongRequests.FindUser(const Id: UTF8String): TSRUser;
var
  I: integer;
begin
  Result := nil;
  if Id = '' then
    Exit;
  for I := 0 to fUsers.Count - 1 do
    if TSRUser(fUsers[I]).Id = Id then
    begin
      Result := TSRUser(fUsers[I]);
      Exit;
    end;
end;

function TSongRequests.FindRequest(const Key: UTF8String): TSRRequest;
var
  I: integer;
begin
  Result := nil;
  for I := 0 to fQueue.Count - 1 do
    if TSRRequest(fQueue[I]).Key = Key then
    begin
      Result := TSRRequest(fQueue[I]);
      Exit;
    end;
end;

function TSongRequests.RequestPosition(Request: TSRRequest): integer;
begin
  Result := fQueue.IndexOf(Request) + 1;
end;

function TSongRequests.PendingOfUser(const UserId: UTF8String): integer;
var
  I: integer;
begin
  Result := 0;
  for I := 0 to fQueue.Count - 1 do
    if (TSRRequest(fQueue[I]).Voters.Count > 0) and
       (TSRRequest(fQueue[I]).Voters[0] = UserId) then
      Inc(Result);
end;

function TSongRequests.RequestCount(const Key: UTF8String): integer;
begin
  Result := StrToIntDef(fRequestCounts.Values[Key], 0);
end;

procedure TSongRequests.SortQueue;
begin
  fQueue.Sort(CompareRequests);
end;

function TSongRequests.GetPendingCount: integer;
begin
  fLock.Enter;
  try
    Result := fQueue.Count;
  finally
    fLock.Leave;
  end;
end;

{ main thread }

procedure TSongRequests.Tick;
var
  Color: TRGB;
begin
  if (Songs = nil) or Songs.Processing then
    Exit;

  Color := GetSystemColor(Skin.Color);
  fLock.Enter;
  try
    fAccent := Format('#%.2x%.2x%.2x', [Round(Color.R * 255), Round(Color.G * 255), Round(Color.B * 255)]);
    if Songs.SongList.Count <> fCatalogCount then
      RebuildCatalog;
    if fDirty and (SecondsBetween(NowUTC, fLastSave) >= SAVE_INTERVAL_SEC) then
      SaveState;
  finally
    fLock.Leave;
  end;
end;

procedure TSongRequests.MarkSung(const Artist, Title: UTF8String);
var
  Key:     UTF8String;
  Request: TSRRequest;
begin
  Key := SongRequestKey(Artist, Title);
  fLock.Enter;
  try
    fLastSung.Values[Key] := IntToStr(UnixNow);
    Request := FindRequest(Key);
    if Request <> nil then
    begin
      AddActivity('sung', '', Request.Artist + ' - ' + Request.Title);
      fQueue.Remove(Request);
    end;
    fStatsLoadedAt := 0;
    MarkDirty;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.QueueSnapshot: TSRQueueEntries;
var
  I, J:    integer;
  Request: TSRRequest;
  User:    TSRUser;
begin
  fLock.Enter;
  try
    SetLength(Result, fQueue.Count);
    for I := 0 to fQueue.Count - 1 do
    begin
      Request := TSRRequest(fQueue[I]);
      Result[I].Key := Request.Key;
      Result[I].Artist := Request.Artist;
      Result[I].Title := Request.Title;
      Result[I].Votes := Request.Voters.Count;
      Result[I].By := '';
      for J := 0 to Request.Voters.Count - 1 do
      begin
        User := FindUser(Request.Voters[J]);
        if User = nil then
          Continue;
        if Result[I].By <> '' then
          Result[I].By := Result[I].By + ', ';
        Result[I].By := Result[I].By + User.Nick;
      end;
    end;
  finally
    fLock.Leave;
  end;
end;

procedure TSongRequests.SetNowPlaying(const Artist, Title, Players: UTF8String; Position, Duration: double);
begin
  fLock.Enter;
  try
    fNowKey := SongRequestKey(Artist, Title);
    fNowArtist := Artist;
    fNowTitle := Title;
    fNowPlayers := Players;
    fNowStartedAt := (NowUTC - UnixDateDelta) * SecsPerDay;
    fNowOffset := Position;
    fNowDuration := Duration;
  finally
    fLock.Leave;
  end;
end;

procedure TSongRequests.ClearNowPlaying;
begin
  fLock.Enter;
  try
    fNowStartedAt := 0;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.NewRequestSeq(out Text: UTF8String): integer;
begin
  fLock.Enter;
  try
    Result := fNewRequestSeq;
    Text := fNewRequestText;
  finally
    fLock.Leave;
  end;
end;

{ JSON helpers }

function TSongRequests.SongToJSON(Index: integer; const UserId: UTF8String): TJSONObject;
var
  Request: TSRRequest;
begin
  Result := TJSONObject.Create;
  with fSongs[Index] do
  begin
    Result.Add('id', Index);
    Result.Add('artist', Artist);
    Result.Add('title', Title);
    Result.Add('language', Language);
    Result.Add('genre', Genre);
    Result.Add('edition', Edition);
    Result.Add('folder', Folder);
    Result.Add('year', Year);
    Result.Add('duet', Duet);
    Result.Add('video', HasVideo);
    Result.Add('cover', CoverFile <> '');
    Result.Add('audio', AudioFile <> '');
    Result.Add('clip', (VideoFile <> '') and (fFFmpeg <> ''));
    Result.Add('clipStart', ClipStartOf(fSongs[Index]));
    Result.Add('previewStart', PreviewStart);
    Result.Add('start', StartSec);
    Result.Add('finish', FinishSec);
  end;
  Result.Add('played', fStats[Index].TimesPlayed);
  Result.Add('best', fStats[Index].BestScore);
  Result.Add('bestPlayer', fStats[Index].BestPlayer);
  Result.Add('requests', RequestCount(fSongs[Index].Key));
  Request := FindRequest(fSongs[Index].Key);
  if Request <> nil then
  begin
    Result.Add('queuePos', RequestPosition(Request));
    Result.Add('votes', Request.Voters.Count);
    Result.Add('voted', Request.Voters.IndexOf(UserId) >= 0);
  end;
end;

function TSongRequests.RequestToJSON(Request: TSRRequest; const UserId: UTF8String; Admin: boolean): TJSONObject;
var
  Idx, I: integer;
  Names:  TJSONArray;
  User:   TSRUser;
begin
  Result := TJSONObject.Create;
  Idx := FindSongIndex(Request.Key);
  Result.Add('id', Idx);
  Result.Add('key', Request.Key);
  Result.Add('artist', Request.Artist);
  Result.Add('title', Request.Title);
  Result.Add('position', RequestPosition(Request));
  Result.Add('votes', Request.Voters.Count);
  Result.Add('voted', Request.Voters.IndexOf(UserId) >= 0);
  Result.Add('pinned', Request.PinnedAt <> 0);
  Result.Add('cover', (Idx >= 0) and (fSongs[Idx].CoverFile <> ''));
  Result.Add('since', DateTimeToUnix(Request.FirstAt));
  Names := TJSONArray.Create;
  for I := 0 to Request.Voters.Count - 1 do
  begin
    User := FindUser(Request.Voters[I]);
    if User <> nil then
      Names.Add(User.Nick);
  end;
  Result.Add('by', Names);
  if Admin then
  begin
    Result.Add('bonus', Request.Bonus);
    Result.Add('available', Idx >= 0);
  end;
end;

function TSongRequests.UserToJSON(User: TSRUser): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('id', User.Id);
  Result.Add('nick', User.Nick);
  Result.Add('ip', User.LastIP);
  Result.Add('created', DateTimeToUnix(User.CreatedAt));
  Result.Add('seen', DateTimeToUnix(User.LastSeen));
  Result.Add('requests', User.TotalRequests);
  Result.Add('pending', PendingOfUser(User.Id));
  Result.Add('blocked', User.Blocked or (fBlockedIPs.IndexOf(User.LastIP) >= 0));
  if User.MutedUntil > NowUTC then
    Result.Add('mutedFor', SecondsBetween(User.MutedUntil, NowUTC))
  else
    Result.Add('mutedFor', 0);
end;

{ guest API }

function TSongRequests.IsIPBlocked(const IP: UTF8String): boolean;
begin
  fLock.Enter;
  try
    Result := fBlockedIPs.IndexOf(IP) >= 0;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.InfoJSON(const UserId: UTF8String): UTF8String;
var
  Root, Me:  TJSONObject;
  Langs, Genres, Folders, Decades: TStringList;
  I:         integer;
  User:      TSRUser;

  function ListToJSON(List: TStringList): TJSONArray;
  var
    J: integer;
  begin
    Result := TJSONArray.Create;
    for J := 0 to List.Count - 1 do
      Result.Add(List[J]);
  end;

begin
  Langs := TStringList.Create;
  Genres := TStringList.Create;
  Folders := TStringList.Create;
  Decades := TStringList.Create;
  Root := TJSONObject.Create;
  fLock.Enter;
  try
    for I := 0 to High(fSongs) do
    begin
      if (fSongs[I].Language <> '') and (Langs.IndexOf(fSongs[I].Language) < 0) then
        Langs.Add(fSongs[I].Language);
      if (fSongs[I].Genre <> '') and (Genres.IndexOf(fSongs[I].Genre) < 0) then
        Genres.Add(fSongs[I].Genre);
      if (fSongs[I].Folder <> '') and (Folders.IndexOf(fSongs[I].Folder) < 0) then
        Folders.Add(fSongs[I].Folder);
      if (fSongs[I].Year > 1900) and (Decades.IndexOf(IntToStr((fSongs[I].Year div 10) * 10)) < 0) then
        Decades.Add(IntToStr((fSongs[I].Year div 10) * 10));
    end;
    Langs.Sort;
    Genres.Sort;
    Folders.Sort;
    Decades.Sort;

    Root.Add('total', fKeyIndex.Count);
    Root.Add('accent', fAccent);
    Root.Add('loading', fCatalogCount < 0);
    Root.Add('paused', fSettings.Paused);
    Root.Add('maxPending', fSettings.MaxPendingPerUser);
    Root.Add('cooldown', fSettings.CooldownSeconds);
    Root.Add('queueLength', fQueue.Count);
    Root.Add('languages', ListToJSON(Langs));
    Root.Add('genres', ListToJSON(Genres));
    Root.Add('folders', ListToJSON(Folders));
    Root.Add('decades', ListToJSON(Decades));

    Me := TJSONObject.Create;
    User := FindUser(UserId);
    if User <> nil then
    begin
      Me.Add('nick', User.Nick);
      Me.Add('blocked', User.Blocked or (fBlockedIPs.IndexOf(User.LastIP) >= 0));
      Me.Add('pending', PendingOfUser(User.Id));
    end
    else
      Me.Add('nick', '');
    Root.Add('me', Me);

    Result := Root.AsJSON;
  finally
    fLock.Leave;
    Root.Free;
    Langs.Free;
    Genres.Free;
    Folders.Free;
    Decades.Free;
  end;
end;

function TSongRequests.SetNick(const UserId, IP, Nick: UTF8String): UTF8String;
var
  User:    TSRUser;
  Clean:   UTF8String;
  I:       integer;
begin
  // strip control characters and limit the length
  Clean := '';
  for I := 1 to Length(Nick) do
    if Nick[I] >= ' ' then
      Clean := Clean + Nick[I];
  Clean := Trim(Clean);
  if LengthUTF8(Clean) > MAX_NICK_LENGTH then
    Clean := Trim(UTF8Copy(Clean, 1, MAX_NICK_LENGTH));
  if Clean = '' then
  begin
    Result := 'nick_empty';
    Exit;
  end;

  fLock.Enter;
  try
    User := FindUser(UserId);
    if User = nil then
    begin
      User := TSRUser.Create;
      User.Id := UserId;
      User.CreatedAt := NowUTC;
      fUsers.Add(User);
      AddActivity('join', Clean, IP);
    end
    else if User.Blocked then
    begin
      Result := 'blocked';
      Exit;
    end
    else if User.Nick <> Clean then
      AddActivity('nick', Clean, User.Nick);
    User.Nick := Clean;
    User.LastIP := IP;
    User.LastSeen := NowUTC;
    MarkDirty;
    Result := '';
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.CompareSongs(A, B: integer; const Sort: UTF8String): integer;
begin
  Result := 0;
  if Sort = 'title' then
    Result := CompareText(fSongs[A].Title, fSongs[B].Title)
  else if Sort = 'popular' then
  begin
    Result := CompareValue(fStats[B].TimesPlayed, fStats[A].TimesPlayed);
    if Result = 0 then
      Result := CompareValue(RequestCount(fSongs[B].Key), RequestCount(fSongs[A].Key));
  end
  else if Sort = 'requested' then
  begin
    // most songs were never requested, sung ones come next among them
    Result := CompareValue(RequestCount(fSongs[B].Key), RequestCount(fSongs[A].Key));
    if Result = 0 then
      Result := CompareValue(fStats[B].TimesPlayed, fStats[A].TimesPlayed);
  end
  else if Sort = 'score' then
    Result := CompareValue(fStats[B].BestScore, fStats[A].BestScore)
  else if Sort = 'year' then
    Result := CompareValue(fSongs[B].Year, fSongs[A].Year);

  // artist and title as tie breakers (and default order)
  if Result = 0 then
    Result := CompareText(fSongs[A].Artist, fSongs[B].Artist);
  if Result = 0 then
    Result := CompareText(fSongs[A].Title, fSongs[B].Title);
end;

procedure TSongRequests.SortIndices(var Indices: array of integer; const Sort: UTF8String);

  procedure QuickSort(L, R: integer);
  var
    I, J, P, T: integer;
  begin
    repeat
      I := L;
      J := R;
      P := Indices[(L + R) shr 1];
      repeat
        while CompareSongs(Indices[I], P, Sort) < 0 do
          Inc(I);
        while CompareSongs(Indices[J], P, Sort) > 0 do
          Dec(J);
        if I <= J then
        begin
          T := Indices[I];
          Indices[I] := Indices[J];
          Indices[J] := T;
          Inc(I);
          Dec(J);
        end;
      until I > J;
      if L < J then
        QuickSort(L, J);
      L := I;
    until I >= R;
  end;

begin
  if Length(Indices) > 1 then
    QuickSort(0, High(Indices));
end;

function TSongRequests.SearchJSON(const Params: TSRSearchParams; const UserId: UTF8String): UTF8String;
var
  Indices: array of integer;
  Count:   integer;
  I:       integer;
  Words:   TStringList;
  Match:   boolean;
  W:       integer;
  Root:    TJSONObject;
  Items:   TJSONArray;
  Limit:   integer;
begin
  Words := TStringList.Create;
  Root := TJSONObject.Create;
  fLock.Enter;
  try
    EnsureStats;

    // every word of the query has to appear in artist or title
    Words.Delimiter := ' ';
    Words.StrictDelimiter := true;
    Words.DelimitedText := NormalizeSearch(Params.Query);
    for W := Words.Count - 1 downto 0 do
      if Trim(Words[W]) = '' then
        Words.Delete(W);

    SetLength(Indices, Length(fSongs));
    Count := 0;
    for I := 0 to High(fSongs) do
    begin
      // the same song can exist in several folders, list it once
      Match := FindSongIndex(fSongs[I].Key) = I;
      for W := 0 to Words.Count - 1 do
        if not Match then
          Break
        else
        if Pos(Words[W], fSongs[I].Search) = 0 then
        begin
          Match := false;
          Break;
        end;
      if Match and (Params.Language <> '') then
      begin
        if Params.Language = '-' then
          Match := fSongs[I].Language = ''
        else
          Match := SameText(fSongs[I].Language, Params.Language);
      end;
      if Match and (Params.Genre <> '') then
        Match := SameText(fSongs[I].Genre, Params.Genre);
      if Match and (Params.Folder <> '') then
        Match := fSongs[I].Folder = Params.Folder;
      if Match and (Params.Decade > 0) then
        Match := (fSongs[I].Year >= Params.Decade) and (fSongs[I].Year < Params.Decade + 10);
      if Match and (Params.Duet >= 0) then
        Match := fSongs[I].Duet = (Params.Duet = 1);
      if Match and (Params.Video >= 0) then
        Match := fSongs[I].HasVideo = (Params.Video = 1);
      if Match then
      begin
        Indices[Count] := I;
        Inc(Count);
      end;
    end;
    SetLength(Indices, Count);
    SortIndices(Indices, Params.Sort);

    Limit := Params.Limit;
    if (Limit <= 0) or (Limit > 200) then
      Limit := 60;

    Root.Add('total', Count);
    Root.Add('offset', Params.Offset);
    Items := TJSONArray.Create;
    for I := Max(0, Params.Offset) to Min(Count, Params.Offset + Limit) - 1 do
      Items.Add(SongToJSON(Indices[I], UserId));
    Root.Add('items', Items);

    Result := Root.AsJSON;
  finally
    fLock.Leave;
    Root.Free;
    Words.Free;
  end;
end;

function TSongRequests.SongJSON(Id: integer; const UserId: UTF8String): UTF8String;
var
  Song:   TJSONObject;
  DB:     TSQLiteDatabase;
  Table:  TSQLiteUniTable;
  Scores: TJSONArray;
  Score:  TJSONObject;
  Artist, Title: UTF8String;
begin
  Result := '';
  fLock.Enter;
  try
    if (Id < 0) or (Id > High(fSongs)) then
      Exit;
    EnsureStats;
    Song := SongToJSON(Id, UserId);
    Artist := fSongs[Id].Artist;
    Title := fSongs[Id].Title;
  finally
    fLock.Leave;
  end;

  // top scores are read outside of the lock, the database has its own locking
  Scores := TJSONArray.Create;
  Song.Add('scores', Scores);
  DB := nil;
  try
    try
      if fScoreFile.IsFile then
      begin
        DB := TSQLiteDatabase.Create(fScoreFile.ToUTF8);
        DB.SetTimeout(500);
        Table := DB.GetUniTable(
          'SELECT sc.[Player], sc.[Score], sc.[Difficulty], sc.[Date] ' +
          'FROM [us_scores] sc JOIN [us_songs] so ON so.[ID] = sc.[SongID] ' +
          'WHERE so.[Artist] = ? AND so.[Title] = ? ' +
          'ORDER BY sc.[Score] DESC LIMIT 5', [Artist, Title]);
        try
          while not Table.EOF do
          begin
            Score := TJSONObject.Create;
            Score.Add('player', Table.FieldAsString(0));
            Score.Add('score', Table.FieldAsInteger(1));
            Score.Add('difficulty', Table.FieldAsInteger(2));
            if Table.FieldIsNull(3) then
              Score.Add('date', 0)
            else
              Score.Add('date', Table.FieldAsInteger(3));
            Scores.Add(Score);
            Table.Next;
          end;
        finally
          Table.Free;
        end;
      end;
    except
      on E: Exception do
        Log.LogError('Could not read scores: ' + E.Message, 'TSongRequests.SongJSON');
    end;
    Result := Song.AsJSON;
  finally
    DB.Free;
    Song.Free;
  end;
end;

function TSongRequests.QueueJSON(const UserId: UTF8String): UTF8String;
var
  Root, Now: TJSONObject;
  Items: TJSONArray;
  I, Idx: integer;
begin
  Root := TJSONObject.Create;
  fLock.Enter;
  try
    Root.Add('paused', fSettings.Paused);
    if fNowStartedAt > 0 then
    begin
      Now := TJSONObject.Create;
      Idx := FindSongIndex(fNowKey);
      Now.Add('id', Idx);
      Now.Add('artist', fNowArtist);
      Now.Add('title', fNowTitle);
      Now.Add('players', fNowPlayers);
      Now.Add('cover', (Idx >= 0) and (fSongs[Idx].CoverFile <> ''));
      Now.Add('startedAt', fNowStartedAt);
      Now.Add('offset', fNowOffset);
      Now.Add('duration', fNowDuration);
      Root.Add('now', Now);
    end
    else
      Root.Add('now', TJSONNull.Create);
    Items := TJSONArray.Create;
    for I := 0 to fQueue.Count - 1 do
      Items.Add(RequestToJSON(TSRRequest(fQueue[I]), UserId, false));
    Root.Add('items', Items);
    Result := Root.AsJSON;
  finally
    fLock.Leave;
    Root.Free;
  end;
end;

function TSongRequests.RequestSong(const UserId, IP: UTF8String; Id: integer): UTF8String;
var
  User:     TSRUser;
  Request:  TSRRequest;
  Key:      UTF8String;
  SungAt:   int64;
begin
  fLock.Enter;
  try
    if (Id < 0) or (Id > High(fSongs)) then
    begin
      Result := 'not_found';
      Exit;
    end;
    User := FindUser(UserId);
    if (User = nil) or (User.Nick = '') then
    begin
      Result := 'nick_required';
      Exit;
    end;
    User.LastSeen := NowUTC;
    User.LastIP := IP;
    if User.Blocked or (fBlockedIPs.IndexOf(IP) >= 0) then
    begin
      Result := 'blocked';
      Exit;
    end;
    if User.MutedUntil > NowUTC then
    begin
      Result := 'muted';
      Exit;
    end;
    if fSettings.Paused then
    begin
      Result := 'paused';
      Exit;
    end;

    Key := fSongs[Id].Key;
    Request := FindRequest(Key);
    if (Request <> nil) and (Request.Voters.IndexOf(UserId) >= 0) then
    begin
      Result := 'already_voted';
      Exit;
    end;

    // the cooldown applies to votes and new requests alike
    if (fSettings.CooldownSeconds > 0) and (User.LastRequestAt > 0) and
       (SecondsBetween(NowUTC, User.LastRequestAt) < fSettings.CooldownSeconds) then
    begin
      Result := 'cooldown:' + IntToStr(fSettings.CooldownSeconds - SecondsBetween(NowUTC, User.LastRequestAt));
      Exit;
    end;

    if Request = nil then
    begin
      SungAt := StrToInt64Def(fLastSung.Values[Key], 0);
      if (fSettings.RecentMinutes > 0) and (SungAt > 0) and
         (UnixNow - SungAt < fSettings.RecentMinutes * 60) then
      begin
        Result := 'recently_sung';
        Exit;
      end;
      if (fSettings.MaxPendingPerUser > 0) and (PendingOfUser(UserId) >= fSettings.MaxPendingPerUser) then
      begin
        Result := 'limit';
        Exit;
      end;
      Request := TSRRequest.Create;
      Request.Key := Key;
      Request.Artist := fSongs[Id].Artist;
      Request.Title := fSongs[Id].Title;
      Request.FirstAt := NowUTC;
      fQueue.Add(Request);
      Inc(fNewRequestSeq);
      fNewRequestText := Request.Artist + ' - ' + Request.Title + ' (' + User.Nick + ')';
      AddActivity('request', User.Nick, Request.Artist + ' - ' + Request.Title);
    end
    else
      AddActivity('vote', User.Nick, Request.Artist + ' - ' + Request.Title);

    Request.Voters.Add(UserId);
    User.LastRequestAt := NowUTC;
    Inc(User.TotalRequests);
    fRequestCounts.Values[Key] := IntToStr(RequestCount(Key) + 1);
    SortQueue;
    MarkDirty;
    Result := '';
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.WithdrawVote(const UserId: UTF8String; Id: integer): UTF8String;
var
  Request: TSRRequest;
  I:       integer;
begin
  fLock.Enter;
  try
    Result := 'not_found';
    if (Id < 0) or (Id > High(fSongs)) then
      Exit;
    Request := FindRequest(fSongs[Id].Key);
    if Request = nil then
      Exit;
    I := Request.Voters.IndexOf(UserId);
    if I < 0 then
      Exit;
    Request.Voters.Delete(I);
    if FindUser(UserId) <> nil then
      AddActivity('withdraw', FindUser(UserId).Nick, Request.Artist + ' - ' + Request.Title);
    if Request.Voters.Count = 0 then
      fQueue.Remove(Request)
    else
      SortQueue;
    MarkDirty;
    Result := '';
  finally
    fLock.Leave;
  end;
end;

{ covers }

function MakeThumbnail(const Source, Target: UTF8String): boolean;
var
  Src, Dst:   TFPMemoryImage;
  Writer:     TFPWriterJPEG;
  Side, OffX, OffY: integer;
  X, Y, SX, SY, X0, X1, Y0, Y1, N: integer;
  R, G, B:    int64;
  C:          TFPColor;
  TmpFile:    UTF8String;
begin
  Result := false;
  Src := TFPMemoryImage.Create(0, 0);
  Dst := nil;
  Writer := nil;
  try
    try
      Src.LoadFromFile(Source);
      if (Src.Width = 0) or (Src.Height = 0) then
        Exit;
      // crop the center square and scale it down with a box filter
      Side := Min(Src.Width, Src.Height);
      OffX := (Src.Width - Side) div 2;
      OffY := (Src.Height - Side) div 2;
      Dst := TFPMemoryImage.Create(THUMB_SIZE, THUMB_SIZE);
      for Y := 0 to THUMB_SIZE - 1 do
      begin
        Y0 := OffY + Y * Side div THUMB_SIZE;
        Y1 := Max(Y0 + 1, OffY + (Y + 1) * Side div THUMB_SIZE);
        for X := 0 to THUMB_SIZE - 1 do
        begin
          X0 := OffX + X * Side div THUMB_SIZE;
          X1 := Max(X0 + 1, OffX + (X + 1) * Side div THUMB_SIZE);
          R := 0;
          G := 0;
          B := 0;
          N := 0;
          for SY := Y0 to Y1 - 1 do
            for SX := X0 to X1 - 1 do
            begin
              C := Src.Colors[SX, SY];
              Inc(R, C.red);
              Inc(G, C.green);
              Inc(B, C.blue);
              Inc(N);
            end;
          C.red := R div N;
          C.green := G div N;
          C.blue := B div N;
          C.alpha := alphaOpaque;
          Dst.Colors[X, Y] := C;
        end;
      end;
      Writer := TFPWriterJPEG.Create;
      Writer.CompressionQuality := 80;
      TmpFile := Target + '.' + RandomToken(6) + '.tmp';
      Dst.SaveToFile(TmpFile, Writer);
      if not RenameFile(TmpFile, Target) then
        DeleteFile(TmpFile);
      Result := FileExists(Target);
    except
      on E: Exception do
        Log.LogWarn('Could not create thumbnail for ' + Source + ': ' + E.Message, 'TSongRequests');
    end;
  finally
    Writer.Free;
    Dst.Free;
    Src.Free;
  end;
end;

function TSongRequests.CoverFile(Id: integer; Thumbnail: boolean): UTF8String;
var
  Source, Target: UTF8String;
  Age: integer;
begin
  Result := '';
  fLock.Enter;
  try
    if (Id < 0) or (Id > High(fSongs)) then
      Exit;
    Source := fSongs[Id].CoverFile;
    Target := fThumbDir.Append(Format('%.8x.jpg', [HashString(fSongs[Id].Key + '|' + Source)])).ToNative;
  finally
    fLock.Leave;
  end;
  if Source = '' then
    Exit;
  if not Thumbnail then
  begin
    Result := Source;
    Exit;
  end;

  // regenerate the thumbnail when the cover was replaced
  if FileExists(Target) then
  begin
    Age := FileAge(Target);
    if (Age <> -1) and (Age >= FileAge(Source)) then
    begin
      Result := Target;
      Exit;
    end;
  end;
  ForceDirectories(fThumbDir.ToNative);
  if MakeThumbnail(Source, Target) then
    Result := Target
  else
    Result := Source;
end;

function TSongRequests.AudioFile(Id: integer): UTF8String;
begin
  Result := '';
  fLock.Enter;
  try
    if (Id >= 0) and (Id <= High(fSongs)) then
      Result := fSongs[Id].AudioFile;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.VideoClip(Id: integer; out Status: integer): UTF8String;
var
  Start:  double;
  Song:   TSRSong;
  Target: UTF8String;
begin
  Result := '';
  Status := 404;
  fLock.Enter;
  try
    if (fFFmpeg = '') or (Id < 0) or (Id > High(fSongs)) or (fSongs[Id].VideoFile = '') then
      Exit;
    Song := fSongs[Id];
    Target := fClipDir.Append(Format('%.8x-%d.mp4',
      [HashString(Song.Key + '|' + Song.VideoFile), CLIP_SECONDS])).ToNative;

    if FileExists(Target) then
    begin
      Result := Target;
      Status := 200;
      Exit;
    end;
    if fClipFailed.IndexOf(Target) >= 0 then
      Exit;

    Status := 202;
    if fClipJobs.IndexOfName(Target) >= 0 then
      Exit;

    // the video runs VideoGap seconds ahead of the audio
    Start := Max(0, ClipStartOf(Song) + Song.VideoGap);
    // the newest request goes first, older ones may belong to closed pages
    fClipJobs.Insert(0, Target + '=' + Song.VideoFile + '|' + FloatToStr(Start, DefaultFormatSettings));
  finally
    fLock.Leave;
  end;
  ForceDirectories(fClipDir.ToNative);
  fClipEvent.SetEvent;
end;

function TSongRequests.NextClipJob(out Target, Video: UTF8String; out Start: double): boolean;
var
  Value: UTF8String;
  P:     integer;
begin
  fLock.Enter;
  try
    Result := fClipJobs.Count > 0;
    if not Result then
      Exit;
    Target := fClipJobs.Names[0];
    Value := fClipJobs.ValueFromIndex[0];
    P := LastDelimiter('|', Value);
    Video := Copy(Value, 1, P - 1);
    Start := StrToFloatDef(Copy(Value, P + 1, MaxInt), 0, DefaultFormatSettings);
    fClipJobs.Delete(0);
  finally
    fLock.Leave;
  end;
end;

procedure TSongRequests.ClipDone(const Target: UTF8String; Success: boolean);
begin
  if Success then
    Exit;
  fLock.Enter;
  try
    fClipFailed.Add(Target);
  finally
    fLock.Leave;
  end;
end;

{ admin API }

function TSongRequests.AdminLogin(const IP, Pin: UTF8String; out Token: UTF8String): UTF8String;
var
  Entry:  UTF8String;
  Count:  integer;
  Since:  int64;
  P:      integer;
begin
  Token := '';
  fLock.Enter;
  try
    Entry := fFailedLogins.Values[IP];
    Count := 0;
    Since := 0;
    if Entry <> '' then
    begin
      P := Pos(';', Entry);
      Count := StrToIntDef(Copy(Entry, 1, P - 1), 0);
      Since := StrToInt64Def(Copy(Entry, P + 1, MaxInt), 0);
      if UnixNow - Since > LOGIN_LOCK_SEC then
      begin
        Count := 0;
        fFailedLogins.Values[IP] := '';
      end;
    end;
    if Count >= MAX_FAILED_LOGINS then
    begin
      Result := 'locked';
      Exit;
    end;

    if (fConfig.AdminPin <> '') and (Pin = fConfig.AdminPin) then
    begin
      fFailedLogins.Values[IP] := '';
      Token := RandomToken(32);
      fAdminSessions.Add(Token);
      AddActivity('admin_login', IP, '');
      Result := '';
    end
    else
    begin
      if Count = 0 then
        Since := UnixNow;
      fFailedLogins.Values[IP] := IntToStr(Count + 1) + ';' + IntToStr(Since);
      AddActivity('admin_fail', IP, '');
      Result := 'wrong_pin';
    end;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.IsAdminSession(const Token: UTF8String): boolean;
begin
  if Token = '' then
  begin
    Result := false;
    Exit;
  end;
  fLock.Enter;
  try
    Result := fAdminSessions.IndexOf(Token) >= 0;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.AdminStateJSON: UTF8String;
var
  Root, S, A: TJSONObject;
  Arr:     TJSONArray;
  I:       integer;
begin
  Root := TJSONObject.Create;
  fLock.Enter;
  try
    S := TJSONObject.Create;
    S.Add('paused', fSettings.Paused);
    S.Add('maxPending', fSettings.MaxPendingPerUser);
    S.Add('cooldown', fSettings.CooldownSeconds);
    S.Add('recentMinutes', fSettings.RecentMinutes);
    Root.Add('settings', S);

    Arr := TJSONArray.Create;
    for I := 0 to fQueue.Count - 1 do
      Arr.Add(RequestToJSON(TSRRequest(fQueue[I]), '', true));
    Root.Add('queue', Arr);

    Arr := TJSONArray.Create;
    for I := 0 to fUsers.Count - 1 do
      Arr.Add(UserToJSON(TSRUser(fUsers[I])));
    Root.Add('users', Arr);

    Arr := TJSONArray.Create;
    for I := 0 to fBlockedIPs.Count - 1 do
      Arr.Add(fBlockedIPs[I]);
    Root.Add('blockedIps', Arr);

    // newest first
    Arr := TJSONArray.Create;
    for I := High(fActivity) downto 0 do
    begin
      A := TJSONObject.Create;
      A.Add('time', fActivity[I].Time);
      A.Add('kind', fActivity[I].Kind);
      A.Add('who', fActivity[I].Who);
      A.Add('detail', fActivity[I].Detail);
      Arr.Add(A);
    end;
    Root.Add('activity', Arr);

    if fNowStartedAt > 0 then
    begin
      A := TJSONObject.Create;
      A.Add('artist', fNowArtist);
      A.Add('title', fNowTitle);
      A.Add('players', fNowPlayers);
      Root.Add('now', A);
    end
    else
      Root.Add('now', TJSONNull.Create);

    Result := Root.AsJSON;
  finally
    fLock.Leave;
    Root.Free;
  end;
end;

function TSongRequests.AdminQueueAction(const Action, Key: UTF8String): UTF8String;
var
  Request, Other: TSRRequest;
  Idx:            integer;
  PinTime:        TDateTime;
begin
  Result := '';
  fLock.Enter;
  try
    if Action = 'clear' then
    begin
      fQueue.Clear;
      AddActivity('admin_clear', 'admin', '');
      MarkDirty;
      Exit;
    end;

    Request := FindRequest(Key);
    if Request = nil then
    begin
      Result := 'not_found';
      Exit;
    end;
    Idx := fQueue.IndexOf(Request);
    if (Action = 'remove') or (Action = 'sung') or (Action = 'pin') or (Action = 'unpin') then
      AddActivity('admin_' + Action, 'admin', Request.Artist + ' - ' + Request.Title);

    if Action = 'remove' then
      fQueue.Remove(Request)
    else if Action = 'sung' then
    begin
      fLastSung.Values[Request.Key] := IntToStr(UnixNow);
      fQueue.Remove(Request);
    end
    else if Action = 'pin' then
      Request.PinnedAt := NowUTC
    else if Action = 'unpin' then
      Request.PinnedAt := 0
    else if (Action = 'up') or (Action = 'down') then
    begin
      if Action = 'up' then
        Dec(Idx)
      else
        Inc(Idx);
      if (Idx < 0) or (Idx >= fQueue.Count) then
        Exit;
      Other := TSRRequest(fQueue[Idx]);
      // swap places: pinned items swap their pin time, others get a
      // priority bonus that places them just past the neighbour
      if (Request.PinnedAt <> 0) and (Other.PinnedAt <> 0) then
      begin
        PinTime := Request.PinnedAt;
        Request.PinnedAt := Other.PinnedAt;
        Other.PinnedAt := PinTime;
      end
      else if (Request.PinnedAt = 0) and (Other.PinnedAt = 0) then
      begin
        if Action = 'up' then
        begin
          Request.Bonus := Other.Priority - Request.Voters.Count;
          if Request.FirstAt > Other.FirstAt then
            Inc(Request.Bonus);
        end
        else
        begin
          Request.Bonus := Other.Priority - Request.Voters.Count;
          if Request.FirstAt < Other.FirstAt then
            Dec(Request.Bonus);
        end;
      end
      else
      begin
        Result := 'pinned';
        Exit;
      end;
    end
    else
    begin
      Result := 'unknown_action';
      Exit;
    end;

    SortQueue;
    MarkDirty;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.AdminUserAction(const Action, Id, Value: UTF8String): UTF8String;
var
  User:    TSRUser;
  I:       integer;
  Minutes: integer;
begin
  Result := '';
  fLock.Enter;
  try
    User := FindUser(Id);
    if User = nil then
    begin
      Result := 'not_found';
      Exit;
    end;

    AddActivity('admin_' + Action, 'admin', User.Nick);

    if Action = 'block' then
    begin
      User.Blocked := true;
      if User.LastIP <> '' then
        fBlockedIPs.Add(User.LastIP);
      // drop the requests of a blocked user
      RemoveVotesOf(User.Id);
    end
    else if Action = 'delete' then
    begin
      RemoveVotesOf(User.Id);
      fUsers.Remove(User);
    end
    else if Action = 'unblock' then
    begin
      User.Blocked := false;
      I := fBlockedIPs.IndexOf(User.LastIP);
      if I >= 0 then
        fBlockedIPs.Delete(I);
    end
    else if Action = 'mute' then
    begin
      Minutes := StrToIntDef(Value, 15);
      if Minutes <= 0 then
        Minutes := 15;
      User.MutedUntil := IncMinute(NowUTC, Minutes);
    end
    else if Action = 'unmute' then
      User.MutedUntil := 0
    else if Action = 'rename' then
    begin
      if Trim(Value) = '' then
      begin
        Result := 'nick_empty';
        Exit;
      end;
      User.Nick := Trim(UTF8Copy(Trim(Value), 1, MAX_NICK_LENGTH));
    end
    else
    begin
      Result := 'unknown_action';
      Exit;
    end;
    MarkDirty;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.AdminSettings(Data: TJSONObject): UTF8String;
begin
  Result := '';
  fLock.Enter;
  try
    fSettings.Paused := Data.Get('paused', fSettings.Paused);
    fSettings.MaxPendingPerUser := Max(0, Data.Get('maxPending', fSettings.MaxPendingPerUser));
    fSettings.CooldownSeconds := Max(0, Data.Get('cooldown', fSettings.CooldownSeconds));
    fSettings.RecentMinutes := Max(0, Data.Get('recentMinutes', fSettings.RecentMinutes));
    AddActivity('admin_settings', 'admin', '');
    MarkDirty;
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.AdminIPAction(const Action, IP: UTF8String): UTF8String;
var
  I: integer;
begin
  Result := '';
  fLock.Enter;
  try
    if Action <> 'unblock' then
    begin
      Result := 'unknown_action';
      Exit;
    end;
    I := fBlockedIPs.IndexOf(IP);
    if I < 0 then
    begin
      Result := 'not_found';
      Exit;
    end;
    fBlockedIPs.Delete(I);
    // users on that address can request again
    for I := 0 to fUsers.Count - 1 do
      if TSRUser(fUsers[I]).LastIP = IP then
        TSRUser(fUsers[I]).Blocked := false;
    AddActivity('admin_unblock_ip', 'admin', IP);
  finally
    fLock.Leave;
  end;
end;

function TSongRequests.AdminMaintenance(const Action: UTF8String): UTF8String;
begin
  Result := '';
  fLock.Enter;
  try
    if Action = 'reset_stats' then
    begin
      fRequestCounts.Clear;
      fLastSung.Clear;
      AddActivity('admin_reset_stats', 'admin', '');
    end
    else if Action = 'clear_activity' then
    begin
      SetLength(fActivity, 0);
      MarkDirty;
    end
    else
      Result := 'unknown_action';
  finally
    fLock.Leave;
  end;
end;

end.
