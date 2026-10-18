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

unit USongRequestsServer;

{*
 * Embedded HTTP server for the song request web client. It serves the
 * static files from resources/web and a small JSON API backed by
 * USongRequests.SongRequests.
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  Classes,
  SysUtils,
  fphttpserver,
  httpdefs;

type
  TSongRequestsServer = class(TThread)
    private
      fServer:   TFPHttpServer;
      fStopping: boolean;
      fPort:     integer;
      procedure HandleRequest(Sender: TObject;
        var ARequest: TFPHTTPConnectionRequest;
        var AResponse: TFPHTTPConnectionResponse);
      procedure HandleAcceptIdle(Sender: TObject);
    protected
      procedure Execute; override;
    public
      constructor Create(Port: integer);
      destructor Destroy; override;
      procedure Stop;
  end;

procedure StartSongRequests;
procedure StopSongRequests;
{* Starts again with the options in config.ini, e.g. after switching the
 * server on or off or changing its port in the options screen. *}
procedure RestartSongRequests;
function SongRequestsURL: UTF8String;

implementation

uses
  {$IFDEF UNIX}
  BaseUnix,
  {$ENDIF}
  fpjson,
  jsonparser,
  UPathUtils,
  ULog,
  USongRequests;

const
  USER_COOKIE  = 'srid';
  ADMIN_COOKIE = 'sradm';

var
  Server: TSongRequestsServer;

procedure StartSongRequests;
begin
  SongRequests := TSongRequests.Create;
  if SongRequests.Config.Enabled then
  begin
    {$IFDEF UNIX}
    // Browsers often cancel audio and video downloads halfway. Writing to
    // such a closed connection raises SIGPIPE, which ends the whole game
    // unless it is ignored; the write then just fails with an error.
    FpSignal(SIGPIPE, SignalHandler(SIG_IGN));
    {$ENDIF}
    Server := TSongRequestsServer.Create(SongRequests.Config.Port);
    Log.LogStatus('Song requests available at ' + SongRequestsURL, 'StartSongRequests');
  end;
end;

procedure StopSongRequests;
begin
  if Server <> nil then
  begin
    Server.Stop;
    Server.WaitFor;
    FreeAndNil(Server);
  end;
  FreeAndNil(SongRequests);
end;

procedure RestartSongRequests;
begin
  StopSongRequests;
  StartSongRequests;
end;

function SongRequestsURL: UTF8String;
var
  Host: UTF8String;
begin
  Result := '';
  if SongRequests = nil then
    Exit;
  if SongRequests.Config.PublicURL <> '' then
  begin
    Result := SongRequests.Config.PublicURL;
    Exit;
  end;
  Host := SongRequests.Config.Host;
  if Host = '' then
    Host := GetLocalIPAddress;
  Result := 'http://' + Host;
  if SongRequests.Config.Port <> 80 then
    Result := Result + ':' + IntToStr(SongRequests.Config.Port);
end;

{ helpers }

function IsPrivateAddress(const IP: UTF8String): boolean;
var
  Parts: TStringList;
  A, B:  integer;
begin
  Result := false;
  if (IP = '::1') or (Pos('fe80:', LowerCase(IP)) = 1) or
     (Pos('fc', LowerCase(IP)) = 1) or (Pos('fd', LowerCase(IP)) = 1) then
  begin
    Result := true;
    Exit;
  end;
  Parts := TStringList.Create;
  try
    Parts.Delimiter := '.';
    Parts.StrictDelimiter := true;
    Parts.DelimitedText := IP;
    if Parts.Count <> 4 then
      Exit;
    A := StrToIntDef(Parts[0], -1);
    B := StrToIntDef(Parts[1], -1);
    Result := (A = 10) or (A = 127) or
              ((A = 172) and (B >= 16) and (B <= 31)) or
              ((A = 192) and (B = 168)) or
              ((A = 169) and (B = 254));
  finally
    Parts.Free;
  end;
end;

function IsLocalhost(const IP: UTF8String): boolean;
begin
  Result := (IP = '127.0.0.1') or (IP = '::1');
end;

function IsValidToken(const S: UTF8String): boolean;
var
  I: integer;
begin
  Result := (Length(S) >= 16) and (Length(S) <= 64);
  if Result then
    for I := 1 to Length(S) do
      if not (S[I] in ['a'..'z', '0'..'9']) then
      begin
        Result := false;
        Exit;
      end;
end;

function NewToken: UTF8String;
const
  CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789';
var
  I: integer;
begin
  SetLength(Result, 24);
  for I := 1 to 24 do
    Result[I] := CHARS[Random(Length(CHARS)) + 1];
end;

function ContentTypeFor(const FileName: UTF8String): UTF8String;
var
  Ext: UTF8String;
begin
  Ext := LowerCase(ExtractFileExt(FileName));
  if Ext = '.html' then
    Result := 'text/html; charset=utf-8'
  else if Ext = '.js' then
    Result := 'application/javascript; charset=utf-8'
  else if Ext = '.css' then
    Result := 'text/css; charset=utf-8'
  else if Ext = '.svg' then
    Result := 'image/svg+xml'
  else if Ext = '.png' then
    Result := 'image/png'
  else if (Ext = '.jpg') or (Ext = '.jpeg') then
    Result := 'image/jpeg'
  else if Ext = '.json' then
    Result := 'application/json'
  else if Ext = '.webmanifest' then
    Result := 'application/manifest+json'
  else if Ext = '.ico' then
    Result := 'image/x-icon'
  else if Ext = '.mp3' then
    Result := 'audio/mpeg'
  else if Ext = '.ogg' then
    Result := 'audio/ogg'
  else if (Ext = '.m4a') or (Ext = '.aac') then
    Result := 'audio/mp4'
  else if Ext = '.mp4' then
    Result := 'video/mp4'
  else if Ext = '.webm' then
    Result := 'video/webm'
  else
    Result := 'application/octet-stream';
end;

function IsSafeAssetName(const Name: UTF8String): boolean;
var
  I: integer;
begin
  Result := (Name <> '') and (Pos('..', Name) = 0);
  if Result then
    for I := 1 to Length(Name) do
      if not (Name[I] in ['a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-']) then
      begin
        Result := false;
        Exit;
      end;
end;

procedure SendJSON(AResponse: TFPHTTPConnectionResponse; Code: integer; const JSON: UTF8String);
begin
  AResponse.Code := Code;
  AResponse.ContentType := 'application/json; charset=utf-8';
  AResponse.SetCustomHeader('Cache-Control', 'no-store');
  AResponse.Content := JSON;
end;

procedure SendError(AResponse: TFPHTTPConnectionResponse; Code: integer; const Error: UTF8String);
var
  O: TJSONObject;
begin
  O := TJSONObject.Create;
  try
    O.Add('error', Error);
    SendJSON(AResponse, Code, O.AsJSON);
  finally
    O.Free;
  end;
end;

{* Sends the result of an action: an empty error id means success. *}
procedure SendResult(AResponse: TFPHTTPConnectionResponse; const Error: UTF8String);
begin
  if Error = '' then
    SendJSON(AResponse, 200, '{"ok":true}')
  else if Error = 'not_found' then
    SendError(AResponse, 404, Error)
  else
    SendError(AResponse, 409, Error);
end;

procedure SendFile(AResponse: TFPHTTPConnectionResponse; const FileName: UTF8String; const CacheControl: UTF8String);
begin
  if (FileName = '') or not FileExists(FileName) then
  begin
    AResponse.Code := 404;
    AResponse.Content := 'Not found';
    Exit;
  end;
  AResponse.Code := 200;
  AResponse.ContentType := ContentTypeFor(FileName);
  AResponse.SetCustomHeader('Cache-Control', CacheControl);
  AResponse.ContentStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  AResponse.FreeContentStream := true;
  AResponse.ContentLength := AResponse.ContentStream.Size;
end;

{* Sends a media file and honours "Range: bytes=a-b" requests, which browsers
 * need to seek in audio and video (Safari does not play media without it).
 * Open ranges are answered with a limited chunk to keep memory use low. *}
procedure SendMediaFile(ARequest: TFPHTTPConnectionRequest; AResponse: TFPHTTPConnectionResponse;
  const FileName: UTF8String);
const
  MAX_CHUNK = 2 * 1024 * 1024;
var
  Stream:     TFileStream;
  Chunk:      TMemoryStream;
  Size, First, Last: int64;
  Range:      UTF8String;
  Dash:       integer;
begin
  if (FileName = '') or not FileExists(FileName) then
  begin
    AResponse.Code := 404;
    AResponse.Content := 'Not found';
    Exit;
  end;

  Range := Trim(ARequest.GetCustomHeader('Range'));
  if Pos('bytes=', Range) <> 1 then
  begin
    SendFile(AResponse, FileName, 'public, max-age=3600');
    AResponse.SetCustomHeader('Accept-Ranges', 'bytes');
    Exit;
  end;

  Stream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Size := Stream.Size;
    Range := Copy(Range, 7, MaxInt);
    Dash := Pos('-', Range);
    if Dash = 1 then
    begin
      // suffix range: the last N bytes
      First := Size - StrToInt64Def(Copy(Range, 2, MaxInt), 0);
      Last := Size - 1;
    end
    else
    begin
      First := StrToInt64Def(Copy(Range, 1, Dash - 1), 0);
      Last := StrToInt64Def(Copy(Range, Dash + 1, MaxInt), -1);
      if (Last < 0) or (Last >= Size) then
        Last := Size - 1;
    end;
    if First < 0 then
      First := 0;
    if Last - First + 1 > MAX_CHUNK then
      Last := First + MAX_CHUNK - 1;
    if (Size = 0) or (First >= Size) or (Last < First) then
    begin
      AResponse.Code := 416;
      AResponse.SetCustomHeader('Content-Range', 'bytes */' + IntToStr(Size));
      Exit;
    end;

    Chunk := TMemoryStream.Create;
    Stream.Position := First;
    Chunk.CopyFrom(Stream, Last - First + 1);
    Chunk.Position := 0;
    AResponse.Code := 206;
    AResponse.ContentType := ContentTypeFor(FileName);
    AResponse.SetCustomHeader('Accept-Ranges', 'bytes');
    AResponse.SetCustomHeader('Content-Range', Format('bytes %d-%d/%d', [First, Last, Size]));
    AResponse.SetCustomHeader('Cache-Control', 'public, max-age=3600');
    AResponse.ContentStream := Chunk;
    AResponse.FreeContentStream := true;
    AResponse.ContentLength := Chunk.Size;
  finally
    Stream.Free;
  end;
end;

function ParseBody(ARequest: TFPHTTPConnectionRequest): TJSONObject;
var
  Data: TJSONData;
begin
  Result := nil;
  if ARequest.Content = '' then
    Exit;
  try
    Data := GetJSON(ARequest.Content);
    if Data is TJSONObject then
      Result := TJSONObject(Data)
    else
      Data.Free;
  except
    Result := nil;
  end;
end;

procedure SetCookie(AResponse: TFPHTTPConnectionResponse; const CookieName, CookieValue: UTF8String; MaxAge: integer);
var
  Cookie: TCookie;
begin
  Cookie := AResponse.Cookies.Add;
  Cookie.Name := CookieName;
  Cookie.Value := CookieValue;
  Cookie.Path := '/';
  Cookie.HttpOnly := true;
  if MaxAge > 0 then
    Cookie.Expires := Now + MaxAge / SecsPerDay;
end;

{ TSongRequestsServer }

constructor TSongRequestsServer.Create(Port: integer);
begin
  fPort := Port;
  fServer := TFPHttpServer.Create(nil);
  fServer.Port := Port;
  fServer.Threaded := true;
  fServer.AcceptIdleTimeout := 500;
  fServer.OnAcceptIdle := HandleAcceptIdle;
  fServer.OnRequest := HandleRequest;
  inherited Create(false);
end;

destructor TSongRequestsServer.Destroy;
begin
  fServer.Free;
  inherited;
end;

procedure TSongRequestsServer.Stop;
begin
  fStopping := true;
end;

procedure TSongRequestsServer.HandleAcceptIdle(Sender: TObject);
begin
  if fStopping then
    fServer.Active := false;
end;

procedure TSongRequestsServer.Execute;
begin
  try
    fServer.Active := true;
  except
    on E: Exception do
      Log.LogError(Format('Song request server could not listen on port %d: %s', [fPort, E.Message]),
        'TSongRequestsServer.Execute');
  end;
end;

procedure TSongRequestsServer.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  IP, URLPath, UserId, Method, Token, Err, Rest: UTF8String;
  Admin:  boolean;
  Body:   TJSONObject;
  Search: TSRSearchParams;
  Id:     integer;
  WebDir: UTF8String;
  JSON:   UTF8String;
  Status: integer;
  Proxied:   boolean;
  Forwarded: UTF8String;

  function QueryInt(const Name: UTF8String; Default: integer): integer;
  begin
    Result := StrToIntDef(ARequest.QueryFields.Values[Name], Default);
  end;

  function BodyStr(const Name: UTF8String): UTF8String;
  begin
    if Body <> nil then
      Result := Body.Get(Name, '')
    else
      Result := '';
  end;

  function BodyInt(const Name: UTF8String): integer;
  begin
    Result := -1;
    if Body <> nil then
      Result := Body.Get(Name, -1);
  end;

begin
  Body := nil;
  try
    try
      IP := ARequest.RemoteAddress;
      // Behind a local HTTPS proxy (e.g. Caddy) every request comes from this
      // computer; the guest's address is then in X-Forwarded-For. It is only
      // trusted from localhost, so guests cannot fake it.
      Proxied := false;
      if IsLocalhost(IP) and (ARequest.GetCustomHeader('X-Forwarded-For') <> '') then
      begin
        Forwarded := ARequest.GetCustomHeader('X-Forwarded-For');
        if Pos(',', Forwarded) > 0 then
          Forwarded := Copy(Forwarded, 1, Pos(',', Forwarded) - 1);
        IP := Trim(Forwarded);
        Proxied := true;
      end;
      if (not SongRequests.Config.AllowRemote) and (not IsPrivateAddress(IP)) then
      begin
        AResponse.Code := 403;
        AResponse.Content := 'Forbidden';
        Exit;
      end;

      URLPath := ARequest.PathInfo;
      if URLPath = '' then
        URLPath := '/';
      Method := UpperCase(ARequest.Method);
      WebDir := ResourcesPath.Append('web').ToNative;

      // identify the device with a long-lived random cookie
      UserId := ARequest.CookieFields.Values[USER_COOKIE];
      if not IsValidToken(UserId) then
      begin
        UserId := NewToken;
        SetCookie(AResponse, USER_COOKIE, UserId, 365 * 24 * 3600);
      end;

      Token := ARequest.CookieFields.Values[ADMIN_COOKIE];
      Admin := (IsLocalhost(IP) and not Proxied) or SongRequests.IsAdminSession(Token);

      // static files
      if (URLPath = '/') or (URLPath = '/index.html') then
      begin
        SendFile(AResponse, IncludeTrailingPathDelimiter(WebDir) + 'index.html', 'no-cache');
        Exit;
      end;
      if (URLPath = '/admin') or (URLPath = '/admin.html') then
      begin
        SendFile(AResponse, IncludeTrailingPathDelimiter(WebDir) + 'admin.html', 'no-cache');
        Exit;
      end;
      if Pos('/assets/', URLPath) = 1 then
      begin
        Rest := Copy(URLPath, Length('/assets/') + 1, MaxInt);
        if IsSafeAssetName(Rest) then
          SendFile(AResponse, IncludeTrailingPathDelimiter(WebDir) + Rest, 'no-cache')
        else
        begin
          AResponse.Code := 404;
          AResponse.Content := 'Not found';
        end;
        Exit;
      end;

      if Pos('/api/', URLPath) <> 1 then
      begin
        AResponse.Code := 404;
        AResponse.Content := 'Not found';
        Exit;
      end;

      if Method = 'POST' then
        Body := ParseBody(ARequest);

      // remember which device each guest uses (shown in the admin page)
      if Pos('/api/admin/', URLPath) <> 1 then
        SongRequests.TouchUser(UserId, IP, ARequest.UserAgent);

      // guest API
      if (URLPath = '/api/info') and (Method = 'GET') then
        SendJSON(AResponse, 200, SongRequests.InfoJSON(UserId))
      else if (URLPath = '/api/me') and (Method = 'POST') then
        SendResult(AResponse, SongRequests.SetNick(UserId, IP, BodyStr('nick')))
      else if (URLPath = '/api/songs') and (Method = 'GET') then
      begin
        Search.Query := ARequest.QueryFields.Values['q'];
        Search.Language := ARequest.QueryFields.Values['language'];
        Search.Genre := ARequest.QueryFields.Values['genre'];
        Search.Folder := ARequest.QueryFields.Values['folder'];
        Search.Decade := QueryInt('decade', 0);
        Search.Duet := QueryInt('duet', -1);
        Search.Video := QueryInt('video', -1);
        Search.Sort := ARequest.QueryFields.Values['sort'];
        Search.Offset := QueryInt('offset', 0);
        Search.Limit := QueryInt('limit', 60);
        SendJSON(AResponse, 200, SongRequests.SearchJSON(Search, UserId));
      end
      else if (Pos('/api/songs/', URLPath) = 1) and (Method = 'GET') then
      begin
        Id := StrToIntDef(Copy(URLPath, Length('/api/songs/') + 1, MaxInt), -1);
        JSON := SongRequests.SongJSON(Id, UserId);
        if JSON = '' then
          SendError(AResponse, 404, 'not_found')
        else
          SendJSON(AResponse, 200, JSON);
      end
      else if (Pos('/api/cover/', URLPath) = 1) and (Method = 'GET') then
      begin
        Id := StrToIntDef(Copy(URLPath, Length('/api/cover/') + 1, MaxInt), -1);
        SendFile(AResponse, SongRequests.CoverFile(Id, ARequest.QueryFields.Values['full'] <> '1'),
          'public, max-age=86400');
      end
      else if (Pos('/api/audio/', URLPath) = 1) and (Method = 'GET') then
      begin
        Id := StrToIntDef(Copy(URLPath, Length('/api/audio/') + 1, MaxInt), -1);
        SendMediaFile(ARequest, AResponse, SongRequests.AudioFile(Id));
      end
      else if (Pos('/api/video/', URLPath) = 1) and (Method = 'GET') then
      begin
        Id := StrToIntDef(Copy(URLPath, Length('/api/video/') + 1, MaxInt), -1);
        JSON := SongRequests.VideoClip(Id, Status);
        if Status = 200 then
          SendMediaFile(ARequest, AResponse, JSON)
        else if Status = 202 then
          SendJSON(AResponse, 202, '{"status":"pending"}')
        else
          SendError(AResponse, 404, 'not_found');
      end
      else if (Pos('/api/icon/', URLPath) = 1) and (Method = 'GET') then
        SendFile(AResponse, SongRequests.IconFile(Copy(URLPath, Length('/api/icon/') + 1, MaxInt)),
          'public, max-age=3600')
      else if (URLPath = '/api/queue') and (Method = 'GET') then
        SendJSON(AResponse, 200, SongRequests.QueueJSON(UserId))
      else if (URLPath = '/api/request') and (Method = 'POST') then
        SendResult(AResponse, SongRequests.RequestSong(UserId, IP, BodyInt('id')))
      else if (URLPath = '/api/device') and (Method = 'POST') then
      begin
        SongRequests.SetDeviceModel(UserId, BodyStr('model'));
        SendResult(AResponse, '');
      end
      else if (URLPath = '/api/unvote') and (Method = 'POST') then
        SendResult(AResponse, SongRequests.WithdrawVote(UserId, BodyInt('id')))
      else if (URLPath = '/api/records') and (Method = 'GET') then
        SendJSON(AResponse, 200, SongRequests.RecordsJSON(UserId))
      else if (URLPath = '/api/mics') and (Method = 'GET') then
        SendJSON(AResponse, 200, SongRequests.MicsJSON(UserId))
      else if (URLPath = '/api/mic') and (Method = 'POST') then
        SendResult(AResponse, SongRequests.RequestMic(UserId, BodyInt('n')))

      // admin API
      else if (URLPath = '/api/admin/login') and (Method = 'POST') then
      begin
        Err := SongRequests.AdminLogin(IP, BodyStr('pin'), Token);
        if Err = '' then
          SetCookie(AResponse, ADMIN_COOKIE, Token, 0);
        if Err = 'wrong_pin' then
          SendError(AResponse, 401, Err)
        else if Err = 'locked' then
          SendError(AResponse, 429, Err)
        else
          SendResult(AResponse, Err);
      end
      else if Pos('/api/admin/', URLPath) = 1 then
      begin
        if not Admin then
          SendError(AResponse, 401, 'login_required')
        else if (URLPath = '/api/admin/state') and (Method = 'GET') then
          SendJSON(AResponse, 200, SongRequests.AdminStateJSON)
        else if (URLPath = '/api/admin/queue') and (Method = 'POST') then
          SendResult(AResponse, SongRequests.AdminQueueAction(BodyStr('action'), BodyStr('key')))
        else if (URLPath = '/api/admin/user') and (Method = 'POST') then
          SendResult(AResponse, SongRequests.AdminUserAction(BodyStr('action'), BodyStr('id'), BodyStr('value')))
        else if (URLPath = '/api/admin/ip') and (Method = 'POST') then
          SendResult(AResponse, SongRequests.AdminIPAction(BodyStr('action'), BodyStr('ip')))
        else if (URLPath = '/api/admin/maintenance') and (Method = 'POST') then
          SendResult(AResponse, SongRequests.AdminMaintenance(BodyStr('action')))
        else if (URLPath = '/api/admin/mics') and (Method = 'GET') then
          SendJSON(AResponse, 200, SongRequests.MicsJSON(''))
        else if (URLPath = '/api/admin/mic') and (Method = 'POST') then
          SendResult(AResponse, SongRequests.AdminSetMic(BodyInt('n'), BodyStr('name')))
        else if (URLPath = '/api/admin/settings') and (Method = 'POST') then
        begin
          if Body = nil then
            SendError(AResponse, 400, 'bad_request')
          else
            SendResult(AResponse, SongRequests.AdminSettings(Body));
        end
        else
          SendError(AResponse, 404, 'not_found');
      end
      else
        SendError(AResponse, 404, 'not_found');
    except
      on E: Exception do
      begin
        Log.LogError('Song request ' + ARequest.URI + ' failed: ' + E.Message, 'TSongRequestsServer');
        SendError(AResponse, 500, 'internal');
      end;
    end;
  finally
    Body.Free;
  end;
end;

end.
