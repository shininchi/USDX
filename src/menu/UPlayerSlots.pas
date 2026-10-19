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

unit UPlayerSlots;

{*
 * One box per player at the bottom left of the song selection: the
 * player's number in a box of the player's color, filled and with the name
 * below when the player has a name of their own (not the default
 * "PlayerN"), and a crown over the winners of the last song.
 *
 * It also turns taps on the microphones (UMicTaps) into commands: the box
 * of the microphone flashes on each tap, and while singing three taps
 * pause or resume the song and four or more leave it, after a few seconds
 * in which another tap cancels. Outside the songs, two taps listen to the
 * player (UVoiceCommands): a nickname takes the microphone, a goodbye
 * frees it; in the song selection three taps start the selected song.
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

// main loop, every frame: microphone capture and tap commands
procedure PlayerSlotsTick;
// overlay, every frame
procedure PlayerSlotsDraw;
// the score screen tells who won the song
procedure PlayerSlotsSongFinished;

implementation

uses
  Classes,
  Math,
  SysUtils,
  sdl2,
  UDisplay,
  UGraphic,
  UIni,
  ULanguage,
  ULog,
  UMicTaps,
  UMusic,
  UCommon,
  UParty,
  USongs,
  UNote,
  URecord,
  URenderer,
  UText,
  UThemes,
  USongRequests,
  URatings,
  UVoiceCommands;

const
  BOX_SIZE     = 30;
  MAX_SLOT_W   = 64;   // room of each player, less when it would not fit
  BOX_RADIUS   = 6;
  BORDER       = 3;
  ROW_OFFSET   = 116;  // top of the boxes above the screen bottom, clear of the help bar
  FLASH_MS     = 250;
  SERIES_MS    = 1500; // "x3" shown over the box after a series
  LEAVE_MS     = 3000; // time to cancel leaving the song
  VOICE_MS     = 3000; // the answer to a voice command stays this long
  // names wider than their room scroll to the end and start over
  SCROLL_SPEED = 30;   // pixels per second
  SCROLL_WAIT  = 1200; // ms still at the start and at the end

var
  Winner:       array[0..IMaxPlayerCount-1] of boolean;
  WinStreak:    array[0..IMaxPlayerCount-1] of integer; // songs won in a row by the crown holders
  Streaks:      TStringList;  // player (name or #slot) = songs won in a row
  SeriesCount:  array[0..IMaxPlayerCount-1] of integer;
  SeriesTicks:  array[0..IMaxPlayerCount-1] of cardinal;
  LeaveAt:      cardinal;  // SDL ticks when the song is left, 0 = not leaving
  RestartedAt:  cardinal;  // SDL ticks of the last capture restart
  MicsSentAt:   cardinal;  // SDL ticks when the web pages got the microphones
  CaptureOurs:  boolean;   // the song selection started the capture

// ms since Ticks; 0 when Ticks is newer (set by another thread) - plain
// cardinal subtraction would raise an overflow error then
function Elapsed(Ticks: cardinal): int64;
begin
  Result := Max(0, int64(SDL_GetTicks) - int64(Ticks));
end;

function DefaultName(Player: integer): UTF8String;
begin
  Result := 'Player' + IntToStr(Player + 1);
end;

function HasName(Player: integer): boolean;
begin
  Result := (Trim(Ini.Name[Player]) <> '') and
            not SameText(Trim(Ini.Name[Player]), DefaultName(Player));
end;

var
  SlotW: single = MAX_SLOT_W;

// the boxes stay left of the selected song's cover
procedure UpdateSlotWidth(Count: integer);
var
  Right: single;
begin
  Right := Theme.Song.Cover.X - 8;
  if (Right < 200) or (Right > RenderW / 2) then
    Right := 300;
  SlotW := Min(MAX_SLOT_W, (Right - 16) / Count);
end;

function SlotCount: integer;
begin
  Result := Min(PlayersPlay, IMaxPlayerCount);
  if Result < 1 then
    Result := 1;
end;

// players set in the options (the song selection uses the same), also
// before the song selection was shown
function ConfiguredPlayers: integer;
begin
  if Ini.Players <= 3 then
    Result := Ini.Players + 1
  else
    Result := 6;
end;

procedure PlayerSlotsSongFinished;
var
  I, Best, Streak: integer;
  Key: UTF8String;
  Crowns: TStringList;
begin
  // songs sung alone have no winner and keep the crown where it was
  if Length(Player) < 2 then
    Exit;
  Best := 0;
  for I := 0 to High(Player) do
    Best := Max(Best, Player[I].ScoreTotalInt);

  if Streaks = nil then
  begin
    Streaks := TStringList.Create;
    Streaks.CaseSensitive := false;
  end;
  Crowns := TStringList.Create;
  try
    for I := 0 to High(Winner) do
    begin
      Winner[I] := (Best > 0) and (I <= High(Player)) and (Player[I].ScoreTotalInt = Best);
      WinStreak[I] := 0;
      if I > High(Player) then
        Continue;
      // the streak goes with the player, by name (or by microphone without one)
      if HasName(I) then
        Key := Trim(Player[I].Name)
      else
        Key := '#' + IntToStr(I);
      if Winner[I] then
        Streak := StrToIntDef(Streaks.Values[Key], 0) + 1
      else
        Streak := 0;
      Streaks.Values[Key] := IntToStr(Streak);
      if Winner[I] then
      begin
        WinStreak[I] := Streak;
        if HasName(I) then
        begin
          RecordStreak(Key, Streak);
          Crowns.Values[Key] := IntToStr(Streak);
        end;
      end;
    end;
    // losers' streaks end even if they are not on a microphone now
    for I := Streaks.Count - 1 downto 0 do
      if Crowns.IndexOfName(Streaks.Names[I]) < 0 then
        if not ((Copy(Streaks.Names[I], 1, 1) = '#') and
                Winner[StrToIntDef(Copy(Streaks.Names[I], 2, 3), 0)]) then
          Streaks.Delete(I);
    if SongRequests <> nil then
      SongRequests.SetCrowns(Crowns);
  finally
    Crowns.Free;
  end;
end;

{ commands }

procedure SingCommand(Player, Count: integer);
begin
  if LeaveAt <> 0 then
  begin
    // any tap series cancels leaving the song
    LeaveAt := 0;
    Log.LogStatus(Format('Player %d cancelled leaving the song', [Player + 1]), 'MicTaps');
    Exit;
  end;
  if Count = 3 then
  begin
    Log.LogStatus(Format('Player %d paused/resumed the song', [Player + 1]), 'MicTaps');
    ScreenSing.Pause;
  end
  else if Count >= 4 then
  begin
    Log.LogStatus(Format('Player %d is leaving the song', [Player + 1]), 'MicTaps');
    LeaveAt := SDL_GetTicks + LEAVE_MS;
  end;
end;

// like Sing in the main menu: the song selection, or the names first
procedure GoToSongs;
begin
  if Songs.SongList.Count = 0 then
    Exit;
  Party.bPartyGame := false;
  if Ini.Players <= 3 then
    PlayersPlay := Ini.Players + 1
  else
    PlayersPlay := 6;
  if Ini.OnSongClick = sSelectPlayer then
    Display.FadeTo(@ScreenSong)
  else
  begin
    ScreenName.Goto_SingScreen := false;
    Display.FadeTo(@ScreenName);
  end;
end;

// one tap outside the songs
procedure SingleTap(Player: integer);
begin
  if Display.NextScreen <> nil then
    Exit;
  if Display.CurrentScreen = @ScreenMain then
    GoToSongs
  else if Display.CurrentScreen = @ScreenOptionsRecord then
  begin
    // leave the microphone options for the songs, keeping the changes
    Ini.Save;
    GoToSongs;
  end
  else if Display.CurrentScreen = @ScreenName then
    // like Enter: on to the songs with these names
    Display.ParseInput(SDLK_RETURN, 0, true)
  else if Display.CurrentScreen = @ScreenSong then
    // like the N key: the next song request
    Display.ParseInput(SDLK_N, 0, true)
  else if (Display.CurrentScreen = @ScreenScore) or (Display.CurrentScreen = @ScreenHighScores) then
    // like Enter: on to the next screen
    Display.ParseInput(SDLK_RETURN, 0, true);
end;

procedure HandleEvents;
var
  Event: TMicTapEvent;
  Singing: boolean;
begin
  Singing := (Display.CurrentScreen = @ScreenSing) and (Display.NextScreen = nil);
  while MicTapsPop(Event) do
  begin
    if Event.Kind = mtTap then
      Continue;  // the box flashes by itself
    Log.LogStatus(Format('Player %d tapped %d times', [Event.Player + 1, Event.Count]), 'MicTaps');
    if (Event.Player >= 0) and (Event.Player < IMaxPlayerCount) then
    begin
      SeriesCount[Event.Player] := Event.Count;
      SeriesTicks[Event.Player] := SDL_GetTicks;
    end;
    if Singing then
      SingCommand(Event.Player, Event.Count)
    else if Event.Count = 1 then
      SingleTap(Event.Player)
    else if Event.Count = 2 then
      VoiceListen(Event.Player)
    else if (Event.Count = 3) and (Display.CurrentScreen = @ScreenSong) and
            (Display.NextScreen = nil) then
      // like Enter: sing the selected song
      Display.ParseInput(SDLK_RETURN, 0, true);
  end;
end;

// the microphones for the web pages: changes asked for there, and the names
// and colors to show
procedure SyncWebMics;
var
  Changes: TSRMicChanges;
  Mics: array of TSRMic;
  I: integer;
  Col: TRGB;
  Changeable: boolean;
begin
  if SongRequests = nil then
    Exit;
  Changes := SongRequests.TakeMicChanges;
  for I := 0 to High(Changes) do
    if Changes[I].Player < ConfiguredPlayers then
    begin
      Log.LogStatus(Format('Microphone %d set to "%s" in the web page', [Changes[I].Player + 1, Changes[I].Name]), 'MicTaps');
      AssignMic(Changes[I].Player, Changes[I].Name);
    end;
  if (Length(Changes) = 0) and (Elapsed(MicsSentAt) < 250) then
    Exit;
  MicsSentAt := SDL_GetTicks;

  SetLength(Mics, ConfiguredPlayers);
  for I := 0 to High(Mics) do
  begin
    if IsDefaultName(Ini.Name[I]) then
      Mics[I].Name := ''
    else
      Mics[I].Name := Trim(Ini.Name[I]);
    Col := GetPlayerColor(Ini.PlayerColor[I]);
    Mics[I].Color := Format('#%.2x%.2x%.2x', [Round(Col.R * 255), Round(Col.G * 255), Round(Col.B * 255)]);
  end;
  // in the song selection, or with the song paused
  Changeable := (Display.NextScreen = nil) and
    ((Display.CurrentScreen = @ScreenSong) or
     ((Display.CurrentScreen = @ScreenSing) and ScreenSing.Paused));
  SongRequests.SetMics(Mics, Changeable);
end;

procedure PlayerSlotsTick;
var
  OnSongs: boolean;
  Event:   TMicTapEvent;
begin
  SyncWebMics;

  if AudioInput = nil then
    Exit;
  if not MicTapsEnabled then
  begin
    // switched off: stop listening where only the taps needed it
    if CaptureOurs and AudioCaptureRunning and (Display.CurrentScreen <> @ScreenSing) then
      AudioInput.CaptureStop;
    CaptureOurs := false;
    while MicTapsPop(Event) do ;
    Exit;
  end;

  // the song selection listens to the microphones too; singing starts and
  // stops the capture by itself
  // also the scores after a song, where a tap is like Enter
  OnSongs := ((Display.CurrentScreen = @ScreenMain) or (Display.CurrentScreen = @ScreenName) or
              (Display.CurrentScreen = @ScreenSong) or
              (Display.CurrentScreen = @ScreenScore) or (Display.CurrentScreen = @ScreenHighScores)) and
             (Display.NextScreen = nil);
  if OnSongs and not AudioCaptureRunning then
  begin
    // the capture opens the microphones of the players who sing; before the
    // song selection (main menu) that number is not set yet
    if PlayersPlay < ConfiguredPlayers then
      PlayersPlay := ConfiguredPlayers;
    AudioInput.CaptureStart;
    CaptureOurs := true;
  end
  else if CaptureOurs and not OnSongs and (Display.CurrentScreen <> @ScreenSing) and
          (Display.NextScreen = nil) then
  begin
    if AudioCaptureRunning then
      AudioInput.CaptureStop;
    CaptureOurs := false;
  end;
  if Display.CurrentScreen = @ScreenSing then
    CaptureOurs := false;

  // a microphone stopped sending sound (some reset after a hard knock), or
  // none is captured (plugged in after the start): look for the microphones
  // again, like the microphone options do, and reopen the capture
  if AudioCaptureRunning and (Elapsed(RestartedAt) > 5000) and
     (AudioCaptureStalled(1500) or (AudioCaptureDevices = 0)) then
  begin
    if AudioCaptureDevices = 0 then
      Log.LogWarn('No microphone is captured, looking for them again', 'MicTaps')
    else
      Log.LogWarn('A microphone stopped sending sound, looking for the microphones again', 'MicTaps');
    RestartedAt := SDL_GetTicks;
    RefreshAudioInputDevices(aimFast);
    AudioInput.CaptureStart;
  end;

  HandleEvents;
  VoiceTick;

  if (LeaveAt <> 0) and (SDL_GetTicks >= LeaveAt) then
  begin
    LeaveAt := 0;
    if Display.CurrentScreen = @ScreenSing then
      Display.ParseInput(SDLK_ESCAPE, 0, true);
  end;
  if Display.CurrentScreen <> @ScreenSing then
    LeaveAt := 0;
end;

{ drawing }

procedure DrawRoundedBox(X, Y, W, H, R: single; Col: TRGB; Alpha: single);
const
  STEPS = 6;
var
  I, C: integer;
  CX, CY, A1, A2: single;
begin
  // printing text turns the depth test back on, which would hide the
  // shapes behind the song screen's equalizer
  Renderer.DepthTest := false;
  Renderer.DrawQuad(X + R, Y, 0, W - 2 * R, H, Col.R, Col.G, Col.B, Alpha);
  Renderer.DrawQuad(X, Y + R, 0, R, H - 2 * R, Col.R, Col.G, Col.B, Alpha);
  Renderer.DrawQuad(X + W - R, Y + R, 0, R, H - 2 * R, Col.R, Col.G, Col.B, Alpha);
  for C := 0 to 3 do
  begin
    if C in [0, 3] then CX := X + R else CX := X + W - R;
    if C in [0, 1] then CY := Y + R else CY := Y + H - R;
    for I := 0 to STEPS - 1 do
    begin
      A1 := (C * 90 + 180 + I * 90 / STEPS) * Pi / 180;
      A2 := (C * 90 + 180 + (I + 1) * 90 / STEPS) * Pi / 180;
      Renderer.DrawTriangle(CX, CY, CX + R * Cos(A1), CY + R * Sin(A1),
        CX + R * Cos(A2), CY + R * Sin(A2), 0, Col.R, Col.G, Col.B, Alpha);
    end;
  end;
end;

procedure DrawDisc(CX, CY, R: single; ColR, ColG, ColB: single);
const
  STEPS = 10;
var
  I: integer;
  A1, A2: single;
begin
  for I := 0 to STEPS - 1 do
  begin
    A1 := I * 2 * Pi / STEPS;
    A2 := (I + 1) * 2 * Pi / STEPS;
    Renderer.DrawTriangle(CX, CY, CX + R * Cos(A1), CY + R * Sin(A1),
      CX + R * Cos(A2), CY + R * Sin(A2), 0, ColR, ColG, ColB, 1);
  end;
end;

{ A gold crown with a dark outline: a band and three points ending in
  balls, the middle one higher. Shape in a 24 x 18 box, Grow makes it
  bigger all around (for the outline). }
procedure DrawCrownShape(L, T, Grow: single; ColR, ColG, ColB: single; BandDarker: boolean);
const
  // the zigzag of the top, left to right: tip, valley, tip, valley, tip
  ZX: array[0..4] of single = (2.5, 7.5, 12, 16.5, 21.5);
  ZY: array[0..4] of single = (4, 9.5, 2.5, 9.5, 4);
  BAND_TOP = 12;
  BOTTOM = 18;
var
  I: integer;
  G: single;
  PX, PY: array[0..6] of single;
begin
  G := Grow;
  // body: under each piece of the outline down to the band
  PX[0] := 0.5 - G;  PY[0] := BAND_TOP;
  for I := 0 to 4 do
  begin
    PX[I + 1] := ZX[I];
    PY[I + 1] := ZY[I] - G;
  end;
  PX[6] := 23.5 + G; PY[6] := BAND_TOP;
  for I := 0 to 5 do
  begin
    Renderer.DrawTriangle(L + PX[I], T + PY[I], L + PX[I + 1], T + PY[I + 1],
      L + PX[I + 1], T + BAND_TOP + 0.5, 0, ColR, ColG, ColB, 1);
    Renderer.DrawTriangle(L + PX[I], T + PY[I], L + PX[I + 1], T + BAND_TOP + 0.5,
      L + PX[I], T + BAND_TOP + 0.5, 0, ColR, ColG, ColB, 1);
  end;
  // balls on the tips
  for I := 0 to 2 do
    DrawDisc(L + ZX[I * 2], T + ZY[I * 2] - 1, 2.2 + G, ColR, ColG, ColB);
  // band
  if BandDarker then
    Renderer.DrawQuad(L - G, T + BAND_TOP - G, 0, 24 + 2 * G, BOTTOM - BAND_TOP + 2 * G,
      0.96, 0.62, 0.12, 1)
  else
    Renderer.DrawQuad(L - G, T + BAND_TOP - G, 0, 24 + 2 * G, BOTTOM - BAND_TOP + 2 * G,
      ColR, ColG, ColB, 1);
end;

procedure DrawCrown(CX, Bottom: single);
var
  L, T: single;
begin
  Renderer.DepthTest := false;
  L := CX - 12;
  T := Bottom - 18;
  DrawCrownShape(L, T, 1.6, 0.2, 0.12, 0.02, false);   // outline
  DrawCrownShape(L, T, 0, 1.0, 0.80, 0.22, true);      // gold, the band more orange
  // shine on the upper part
  Renderer.DrawQuad(L + 3, T + 11, 0, 18, 1, 1.0, 0.92, 0.6, 0.8);
end;

// offset of a name scrolling from its start to its end and starting over
function ScrollOffset(Overflow: single; Ticks: cardinal): single;
var
  ScrollMs, Cycle, T: cardinal;
begin
  ScrollMs := Round(Overflow * 1000 / SCROLL_SPEED);
  Cycle := 2 * SCROLL_WAIT + ScrollMs;
  T := Ticks mod Cycle;
  if T < SCROLL_WAIT then
    Result := 0
  else if T < SCROLL_WAIT + ScrollMs then
    Result := Overflow * (T - SCROLL_WAIT) / ScrollMs
  else
    Result := Overflow;
end;

procedure DrawName(const Name: UTF8String; Left, Top: single; Col: TRGB; Ticks: cardinal);
var
  W, Room: single;
begin
  SetFontStyle(ftRegular);
  SetFontSize(13);
  SetFontColor(Col.R, Col.G, Col.B, 1);
  W := TextWidth(Name);
  Room := SlotW - 4;
  if W <= Room then
  begin
    SetFontPos(Left + (SlotW - W) / 2, Top);
    PrintText(Name);
    Exit;
  end;
  // too long: show it through the room of the player, scrolling
  Renderer.SetScissorRect(
    Round((Left + 2) * ((ScreenW / RenderW) / Screens) + ((ScreenAct - 1) * (ScreenW / 2))),
    Round((RenderH - (Top + 20)) * (ScreenH / RenderH)),
    Round(Room * ScreenW / RenderW),
    Round(20 * ScreenH / RenderH));
  Renderer.ScissorTest := true;
  SetFontPos(Left + 2 - ScrollOffset(W - Room, Ticks), Top);
  PrintText(Name);
  Renderer.ScissorTest := false;
end;

procedure DrawLeaveNotice;
var
  Seconds: integer;
  Text: UTF8String;
  W, X, Y: single;
  DepthTest: boolean;
begin
  if (LeaveAt = 0) or (Display.CurrentScreen <> @ScreenSing) then
    Exit;
  Seconds := Max(1, (int64(LeaveAt) - int64(SDL_GetTicks) + 999) div 1000);
  Text := Format(Language.Translate('MICTAPS_LEAVING'), [Seconds]);
  SetFontFamily(0);
  SetFontStyle(ftBold);
  SetFontItalic(false);
  SetFontSize(24);
  W := TextWidth(Text) + 40;
  X := (RenderW - W) / 2;
  Y := RenderH / 2 - 24;
  DepthTest := Renderer.DepthTest;
  Renderer.DepthTest := false;
  Renderer.DrawQuad(X, Y, 0, W, 48, 0.05, 0.05, 0.1, 0.85);
  SetFontColor(1, 1, 1, 1);
  SetFontPos(X + 20, Y + 9);
  PrintText(Text);
  Renderer.DepthTest := DepthTest;
end;

// what the voice commands are doing, above the boxes
procedure DrawVoice(Y: single; Ticks: cardinal);
var
  Player: integer;
  Kind: TVoiceResult;
  Name, Text: UTF8String;
  At: cardinal;
  Col: TRGB;
  Alpha, W: single;
begin
  Player := VoiceListeningPlayer;
  Alpha := 1;
  if Player >= 0 then
    Text := Language.Translate('VOICE_LISTENING')
  else if VoiceLastResult(Player, Kind, Name, At) and (Elapsed(At) < VOICE_MS) then
  begin
    Alpha := Min(1, (VOICE_MS - Elapsed(At)) / 500);
    case Kind of
      vrHello:   Text := Format(Language.Translate('VOICE_HELLO'), [Name]);
      vrGoodbye:
        if Name <> '' then
          Text := Format(Language.Translate('VOICE_GOODBYE'), [Name])
        else
          Text := Format(Language.Translate('VOICE_FREE'), [Player + 1]);
      vrNotHeard: Text := Language.Translate('VOICE_NOT_HEARD');
    else
      Text := Language.Translate('VOICE_NOT_UNDERSTOOD');
    end;
  end
  else
    Exit;
  if (Player < 0) or (Player >= IMaxPlayerCount) then
    Exit;

  Col := GetPlayerColor(Ini.PlayerColor[Player]);
  SetFontStyle(ftBold);
  SetFontSize(18);
  W := TextWidth(Text) + 20;
  Renderer.DepthTest := false;
  Renderer.DrawQuad(16, Y, 0, W, 28, 0.05, 0.05, 0.1, 0.85 * Alpha);
  Renderer.DrawQuad(16, Y, 0, 4, 28, Col.R, Col.G, Col.B, Alpha);
  SetFontColor(1, 1, 1, Alpha);
  SetFontPos(28, Y + 3);
  PrintText(Text);
end;

procedure PlayerSlotsDraw;
var
  DX, DY:   integer;
  I, N:     integer;
  X, Y, CX: single;
  Col:      TRGB;
  Black:    TRGB;
  Flash:    single;
  Ticks:    cardinal;
  Text:     UTF8String;
  DepthTest: boolean;
begin
  DrawLeaveNotice;
  if (Display.CurrentScreen <> @ScreenSong) or (Display.NextScreen <> nil) then
    Exit;

  Ticks := SDL_GetTicks;
  N := SlotCount;
  UpdateSlotWidth(N);
  Black.R := 0; Black.G := 0; Black.B := 0;
  Y := RenderH - ROW_OFFSET;

  DepthTest := Renderer.DepthTest;
  Renderer.DepthTest := false;
  SetFontFamily(0);
  SetFontItalic(false);

  for I := 0 to N - 1 do
  begin
    CX := 16 + I * SlotW + SlotW / 2;
    X := CX - BOX_SIZE / 2;
    Col := GetPlayerColor(Ini.PlayerColor[I]);

    // a tap flashes the box white; it pulses while listening to the player
    Flash := 0;
    if VoiceListeningPlayer = I then
      Flash := 0.35 + 0.35 * Sin(Ticks / 120);
    if (MicTapLastTicks(I) <> 0) and (Elapsed(MicTapLastTicks(I)) < FLASH_MS) then
      Flash := 1 - Elapsed(MicTapLastTicks(I)) / FLASH_MS;

    DrawRoundedBox(X, Y, BOX_SIZE, BOX_SIZE, BOX_RADIUS, Col, 1);
    if not HasName(I) then
      DrawRoundedBox(X + BORDER, Y + BORDER, BOX_SIZE - 2 * BORDER, BOX_SIZE - 2 * BORDER,
        BOX_RADIUS - 2, Black, 1);
    if Flash > 0 then
    begin
      Black.R := 1; Black.G := 1; Black.B := 1;
      DrawRoundedBox(X, Y, BOX_SIZE, BOX_SIZE, BOX_RADIUS, Black, 0.8 * Flash);
      Black.R := 0; Black.G := 0; Black.B := 0;
    end;

    if Winner[I] then
    begin
      DrawCrown(CX, Y - 4);
      // songs won in a row
      if WinStreak[I] >= 2 then
      begin
        SetFontStyle(ftBold);
        SetFontSize(16);
        Text := 'x' + IntToStr(WinStreak[I]);
        Renderer.DepthTest := false;
        // right of the crown, its bottom on the crown's base, gold with a
        // dark outline like the crown
        // (close to the crown, leaving room for the next player's one)
        SetFontColor(0.2, 0.12, 0.02, 1);
        for DX := -2 to 2 do
          for DY := -2 to 2 do
            if ((DX <> 0) or (DY <> 0)) and (Abs(DX) + Abs(DY) <= 3) then
            begin
              SetFontPos(CX + 13 + DX * 0.9, Y - 22.5 + DY * 0.9);
              PrintText(Text);
            end;
        SetFontColor(1.0, 0.8, 0.22, 1);
        SetFontPos(CX + 13, Y - 22.5);
        PrintText(Text);
      end;
    end;

    // number in the middle
    SetFontStyle(ftBold);
    SetFontSize(20);
    Text := IntToStr(I + 1);
    SetFontColor(1, 1, 1, 1);
    SetFontPos(CX - TextWidth(Text) / 2, Y + 3);
    PrintText(Text);

    // the player's name below
    if HasName(I) then
      DrawName(Ini.Name[I], CX - SlotW / 2, Y + BOX_SIZE + 1, Col, Ticks);

    // the number of taps of the last series, for a moment
    if (SeriesTicks[I] <> 0) and (Elapsed(SeriesTicks[I]) < SERIES_MS) then
    begin
      SetFontStyle(ftBold);
      SetFontSize(15);
      Text := 'x' + IntToStr(SeriesCount[I]);
      SetFontColor(1, 1, 1, 1 - Elapsed(SeriesTicks[I]) / SERIES_MS);
      SetFontPos(CX - TextWidth(Text) / 2, Y - 34);
      PrintText(Text);
    end;
  end;

  DrawVoice(Y - 66, Ticks);

  Renderer.DepthTest := DepthTest;
end;

end.
