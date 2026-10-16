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

unit USongRequestsOverlay;

{*
 * In-game parts of the song request system:
 * - QR code with the address of the web client. It is hidden by default and
 *   toggled with the I key on menu screens. It hides itself after
 *   Config.QRTimeout seconds so it does not burn into OLED screens.
 * - Badge with the number of pending requests on the song selection screen,
 *   which pulses when a new request arrives.
 * - Jumping to the requested songs from the song selection screen.
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

{* Returns true if the key press was used to toggle the QR code. *}
function SongRequestsHandleKey(Key: cardinal; Repeated: boolean): boolean;

{* Draws the QR code if it is visible. Called after the screen was drawn. *}
procedure SongRequestsDrawOverlay;

{* Hides the QR code immediately. *}
procedure SongRequestsHideQR;

{* Selects the next request in queue order on the song selection screen, or a
 * random one. *}
procedure SongRequestsJump(RandomPick: boolean);

{* Shows a message at the bottom center of the song selection screen. *}
procedure SongRequestsShowNotice(const Text: UTF8String);

implementation

uses
  SysUtils,
  Math,
  sdl2,
  fpqrcodegen,
  UDisplay,
  UGraphic,
  ULanguage,
  URenderer,
  UScreenSong,
  USongRequests,
  USongRequestsServer,
  USkins,
  USongs,
  UText,
  UThemes,
  UCommon,
  UPathUtils,
  UPlaylist;

const
  FADE_MS   = 250;
  PULSE_MS  = 1500;
  NOTICE_MS = 4000;
  ROW_OFFSET = 96;   // the badge and notices sit this far above the screen bottom,
                     // clear of the theme's help bar

var
  Visible:   boolean;
  ShownAt:   cardinal; // SDL ticks when the QR code was shown
  HiddenAt:  cardinal; // SDL ticks when hiding started, 0 = not hiding
  URL:       UTF8String;
  QRSize:    integer;
  QRModules: array of boolean;

  LastSeenSeq: integer = -1; // NewRequestSeq that was already announced
  PulseStart:  cardinal;     // SDL ticks of the last new request
  LastJumpKey: UTF8String;   // song key of the last request jumped to
  SyncedVersion: integer = -1; // SongRequests.Version of the "Requests" playlist
  NoticeText:  UTF8String;   // message shown below the song list
  BadgeLeft:   single;       // left edge of the badge, notices stay left of it
  NoticeStart: cardinal;

function OverlayAllowed: boolean;
begin
  // never cover the lyrics while singing or editing
  Result := (SongRequests <> nil) and SongRequests.Config.Enabled and
            (Display.NextScreen = nil) and
            (Display.CurrentScreen <> @ScreenSing) and
            (Display.CurrentScreen <> @ScreenJukebox) and
            (Display.CurrentScreen <> @ScreenEdit) and
            (Display.CurrentScreen <> @ScreenEditSub) and
            (Display.CurrentScreen <> @ScreenEditConvert);
end;

procedure GenerateQR;
var
  Generator: TQRCodeGenerator;
  X, Y:      integer;
begin
  URL := SongRequestsURL;
  Generator := TQRCodeGenerator.Create;
  try
    Generator.Generate(URL);
    QRSize := Generator.Size;
    SetLength(QRModules, QRSize * QRSize);
    for Y := 0 to QRSize - 1 do
      for X := 0 to QRSize - 1 do
        QRModules[Y * QRSize + X] := Generator.Bits[X, Y];
  finally
    Generator.Free;
  end;
end;

procedure ShowQR;
begin
  GenerateQR;
  Visible := true;
  ShownAt := SDL_GetTicks;
  HiddenAt := 0;
end;

procedure SongRequestsHideQR;
begin
  Visible := false;
  HiddenAt := 0;
end;

procedure StartHiding;
begin
  if Visible and (HiddenAt = 0) then
    HiddenAt := SDL_GetTicks;
end;

function SongRequestsHandleKey(Key: cardinal; Repeated: boolean): boolean;
const
  MODIFIERS = KMOD_SHIFT or KMOD_CTRL or KMOD_ALT or KMOD_GUI;
begin
  Result := false;
  if (Key <> SDLK_I) or Repeated then
    Exit;
  if (SDL_GetModState and MODIFIERS) <> 0 then
    Exit;
  // typing a name or a search term must still be possible
  if SDL_IsTextInputActive = SDL_TRUE then
    Exit;
  if not OverlayAllowed then
    Exit;

  if Visible and (HiddenAt = 0) then
    StartHiding
  else
    ShowQR;
  Result := true;
end;

procedure DrawQR;
var
  Ticks:       cardinal;
  Alpha:     single;
  PanelW, PanelH, PanelX, PanelY: single;
  QRArea, Module, QRX, QRY: single;
  X, Y, RunStart: integer;
  Remaining: single;
  Text:      UTF8String;
  DepthTest: boolean;
  Accent:    TRGB;
begin
  if not Visible then
    Exit;

  if not OverlayAllowed then
  begin
    SongRequestsHideQR;
    Exit;
  end;

  Ticks := SDL_GetTicks;
  if (HiddenAt = 0) and (SongRequests.Config.QRTimeout > 0) and
     (Ticks - ShownAt >= cardinal(SongRequests.Config.QRTimeout) * 1000) then
    StartHiding;

  // fade in and out
  Alpha := Min(1, (Ticks - ShownAt) / FADE_MS);
  if HiddenAt <> 0 then
  begin
    Alpha := Min(Alpha, 1 - (Ticks - HiddenAt) / FADE_MS);
    if Alpha <= 0 then
    begin
      SongRequestsHideQR;
      Exit;
    end;
  end;

  DepthTest := Renderer.DepthTest;
  Renderer.DepthTest := false;

  // panel on the right side, vertically centered
  PanelW := 260;
  PanelH := 330;
  PanelX := RenderW - PanelW - 20;
  PanelY := (RenderH - PanelH) / 2;
  Renderer.DrawQuad(PanelX, PanelY, 0, PanelW, PanelH, 0.05, 0.05, 0.1, 0.85 * Alpha);

  // white square with the code and its quiet zone
  QRArea := PanelW - 40;
  QRX := PanelX + 20;
  QRY := PanelY + 46;
  Renderer.DrawQuad(QRX, QRY, 0, QRArea, QRArea, 1, 1, 1, Alpha);
  if QRSize > 0 then
  begin
    Module := QRArea / (QRSize + 4);
    for Y := 0 to QRSize - 1 do
    begin
      // draw runs of dark modules as one quad
      RunStart := -1;
      for X := 0 to QRSize do
      begin
        if (X < QRSize) and QRModules[Y * QRSize + X] then
        begin
          if RunStart < 0 then
            RunStart := X;
        end
        else if RunStart >= 0 then
        begin
          Renderer.DrawQuad(QRX + (RunStart + 2) * Module, QRY + (Y + 2) * Module, 0,
            (X - RunStart) * Module + 0.5, Module + 0.5, 0, 0, 0, Alpha);
          RunStart := -1;
        end;
      end;
    end;
  end;

  // title and address
  SetFontFamily(0);
  SetFontStyle(ftBold);
  SetFontItalic(false);
  SetFontSize(24);
  SetFontColor(1, 1, 1, Alpha);
  Text := Language.Translate('SONG_REQUESTS_QR_TITLE');
  SetFontPos(PanelX + (PanelW - TextWidth(Text)) / 2, PanelY + 10);
  PrintText(Text);

  SetFontStyle(ftRegular);
  SetFontSize(18);
  SetFontColor(0.8, 0.85, 1, Alpha);
  SetFontPos(PanelX + (PanelW - TextWidth(URL)) / 2, QRY + QRArea + 10);
  PrintText(URL);

  // remaining time
  if (SongRequests.Config.QRTimeout > 0) and (HiddenAt = 0) then
  begin
    Accent := GetSystemColor(Skin.Color);
    Remaining := 1 - (Ticks - ShownAt) / (SongRequests.Config.QRTimeout * 1000);
    Renderer.DrawQuad(PanelX, PanelY + PanelH - 4, 0, PanelW * Max(0, Remaining), 4,
      Accent.R, Accent.G, Accent.B, Alpha);
  end;

  Renderer.DepthTest := DepthTest;
end;

{* Shows a message at the bottom center of the song selection screen. The
 * theme's message box is not used because it covers the song cover. *}
procedure ShowNotice(const Text: UTF8String);
begin
  NoticeText := Text;
  NoticeStart := SDL_GetTicks;
end;

procedure SongRequestsShowNotice(const Text: UTF8String);
begin
  ShowNotice(Text);
end;

{* Index of the song in CatSongs; of a solo and a duet version of the same
 * song the duet version is preferred, like in the web client. *}
function FindCatSong(const Key: UTF8String): integer;
var
  I: integer;
begin
  Result := -1;
  for I := 0 to High(CatSongs.Song) do
    if (not CatSongs.Song[I].Main) and
       (SongRequestKey(CatSongs.Song[I].Artist, CatSongs.Song[I].Title) = Key) then
    begin
      if (Result < 0) or (CatSongs.Song[I].isDuet and not CatSongs.Song[Result].isDuet) then
        Result := I;
      if CatSongs.Song[Result].isDuet then
        Exit;
    end;
end;

procedure SongRequestsJump(RandomPick: boolean);
var
  Entries: TSRQueueEntries;
  Order:   array of integer;
  I, J, T, Start, Target: integer;
  Entry:   TSRQueueEntry;
  By:      UTF8String;
begin
  if (SongRequests = nil) or not SongRequests.Config.Enabled then
    Exit;

  Entries := SongRequests.QueueSnapshot;
  SetLength(Order, Length(Entries));
  for I := 0 to High(Order) do
    Order[I] := I;

  // start after the request selected last time
  Start := 0;
  for I := 0 to High(Entries) do
    if Entries[I].Key = LastJumpKey then
      Start := I + 1;

  if RandomPick then
  begin
    for I := High(Order) downto 1 do
    begin
      J := Random(I + 1);
      T := Order[I];
      Order[I] := Order[J];
      Order[J] := T;
    end;
    // avoid picking the same song again
    if (Length(Order) > 1) and (Entries[Order[0]].Key = LastJumpKey) then
    begin
      T := Order[0];
      Order[0] := Order[High(Order)];
      Order[High(Order)] := T;
    end;
    Start := 0;
  end;

  for I := 0 to High(Order) do
  begin
    J := Order[(Start + I) mod Length(Order)];
    Entry := Entries[J];
    Target := FindCatSong(Entry.Key);
    if Target < 0 then
      Continue; // not in the library any more

    ScreenSong.SelectCatSong(Target);
    LastJumpKey := Entry.Key;

    By := Entry.By;
    if Length(By) > 30 then
      By := Copy(By, 1, 27) + '...';
    ShowNotice(Format('%s %d/%d: %s - %s (%s)',
      [Language.Translate('SONG_REQUESTS_REQUEST'), J + 1, Length(Entries),
       Entry.Artist, Entry.Title, By]));
    Exit;
  end;

  ShowNotice(Language.Translate('SONG_REQUESTS_EMPTY'));
end;

procedure DrawBadge;
var
  Ticks:     cardinal;
  Seq, Count: integer;
  NewText, Text: UTF8String;
  Pulse:     single;
  W, H, X, Y, Grow: single;
  Accent:    TRGB;
  DepthTest: boolean;
begin
  if (SongRequests = nil) or not SongRequests.Config.Enabled or
     (Display.NextScreen <> nil) or (Display.CurrentScreen <> @ScreenSong) then
    Exit;

  Ticks := SDL_GetTicks;

  // announce new requests once, also those that arrived while singing
  Seq := SongRequests.NewRequestSeq(NewText);
  if LastSeenSeq < 0 then
    LastSeenSeq := Seq
  else if Seq <> LastSeenSeq then
  begin
    LastSeenSeq := Seq;
    PulseStart := Ticks;
    ShowNotice(Language.Translate('SONG_REQUESTS_NEW') + ': ' + NewText);
  end;

  Count := SongRequests.PendingCount;
  if Count = 0 then
    Exit;

  SetFontFamily(0);
  SetFontStyle(ftBold);
  SetFontItalic(false);
  SetFontSize(20);
  Text := Format('%s: %d', [Language.Translate('SONG_REQUESTS_BADGE'), Count]);

  W := TextWidth(Text) + 24;
  H := 32;
  // bottom right, above the theme's help bar; the top holds the logo
  X := RenderW - W - 16;
  Y := RenderH - ROW_OFFSET;
  BadgeLeft := X;
  Accent := GetSystemColor(Skin.Color);

  Pulse := 0;
  if (PulseStart <> 0) and (Ticks - PulseStart < PULSE_MS) then
    Pulse := 1 - (Ticks - PulseStart) / PULSE_MS;

  DepthTest := Renderer.DepthTest;
  Renderer.DepthTest := false;

  // glow that grows and fades out after a new request
  if Pulse > 0 then
  begin
    Grow := (1 - Pulse) * 14;
    Renderer.DrawQuad(X - Grow, Y - Grow, 0, W + 2 * Grow, H + 2 * Grow, Accent.R, Accent.G, Accent.B, 0.6 * Pulse);
  end;
  Renderer.DrawQuad(X, Y, 0, W, H, 0.05, 0.05, 0.1, 0.85);
  Renderer.DrawQuad(X, Y, 0, 4, H, Accent.R, Accent.G, Accent.B, 1);

  SetFontColor(1, 1, 1, 1);
  SetFontPos(X + 14, Y + 4);
  PrintText(Text);

  Renderer.DepthTest := DepthTest;
end;

procedure DrawNotice;
var
  Ticks:     cardinal;
  Alpha:     single;
  W, H, X, Y: single;
  DepthTest: boolean;
  Accent:    TRGB;
begin
  if (NoticeText = '') or (Display.NextScreen <> nil) or (Display.CurrentScreen <> @ScreenSong) then
    Exit;

  Ticks := SDL_GetTicks;
  if Ticks - NoticeStart >= NOTICE_MS then
  begin
    NoticeText := '';
    Exit;
  end;
  Alpha := Min(1, Min((Ticks - NoticeStart) / FADE_MS, (NOTICE_MS - (Ticks - NoticeStart)) / (2 * FADE_MS)));

  SetFontFamily(0);
  SetFontStyle(ftBold);
  SetFontItalic(false);
  SetFontSize(20);

  W := Min(TextWidth(NoticeText) + 32, RenderW - 40);
  H := 32;
  X := (RenderW - W) / 2;
  Y := RenderH - ROW_OFFSET; // same row as the badge
  // keep clear of the badge when the text is long
  if (SongRequests.PendingCount > 0) and (X + W > BadgeLeft - 8) then
    X := Max(20, BadgeLeft - 8 - W);
  Accent := GetSystemColor(Skin.Color);

  DepthTest := Renderer.DepthTest;
  Renderer.DepthTest := false;
  Renderer.DrawQuad(X, Y, 0, W, H, 0.05, 0.05, 0.1, 0.9 * Alpha);
  Renderer.DrawQuad(X, Y + H - 3, 0, W, 3, Accent.R, Accent.G, Accent.B, Alpha);

  SetFontColor(1, 1, 1, Alpha);
  SetFontPos(X + 16, Y + 5);
  PrintText(NoticeText);
  Renderer.DepthTest := DepthTest;
end;

{* Keeps a playlist with the requested songs in queue order, so the queue can
 * also be browsed with the playlist menu (P). It is not changed while it is
 * shown, so the selection does not jump; it catches up afterwards. *}
procedure SyncPlaylist;
var
  Name:    UTF8String;
  Idx, I, Target, N: integer;
  Entries: TSRQueueEntries;
  FileName: UTF8String;
begin
  if (SongRequests = nil) or not SongRequests.Config.Enabled or (PlayListMan = nil) or
     (Songs = nil) or Songs.Processing or (Length(CatSongs.Song) = 0) or
     (SongRequests.Version = SyncedVersion) then
    Exit;

  Name := Language.Translate('SONG_REQUESTS_PLAYLIST');
  Idx := -1;
  for I := 0 to High(PlayListMan.Playlists) do
    if PlayListMan.Playlists[I].Name = Name then
      Idx := I;

  if (Idx >= 0) and (CatSongs.CatNumShow = -3) and (PlayListMan.CurPlayList = Idx) then
    Exit;

  if Idx < 0 then
  begin
    Idx := PlayListMan.AddPlaylist(Name);
    // playlists are kept sorted, so the shown one may have moved
    if (PlayListMan.CurPlayList >= Idx) then
      PlayListMan.CurPlayList := PlayListMan.CurPlayList + 1;
  end;

  Entries := SongRequests.QueueSnapshot;
  with PlayListMan.Playlists[Idx] do
  begin
    FixedOrder := true;
    SetLength(Items, 0);
    for I := 0 to High(Entries) do
    begin
      Target := FindCatSong(Entries[I].Key);
      if Target < 0 then
        Continue;
      N := Length(Items);
      SetLength(Items, N + 1);
      Items[N].Artist := CatSongs.Song[Target].Artist;
      Items[N].Title := CatSongs.Song[Target].Title;
      Items[N].SongID := Target;
    end;
  end;
  PlayListMan.SavePlayList(Idx);
  // the file was written by us, it does not need to be read again
  FileName := PlaylistPath.Append(PlayListMan.Playlists[Idx].Filename).ToNative;
  PlayListMan.Playlists[Idx].LastRead := FileAge(FileName);
  SyncedVersion := SongRequests.Version;
end;

procedure SongRequestsDrawOverlay;
begin
  SyncPlaylist;
  DrawBadge;
  DrawNotice;
  DrawQR;
end;

end.
