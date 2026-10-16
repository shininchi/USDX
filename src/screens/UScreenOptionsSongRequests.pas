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

unit UScreenOptionsSongRequests;

{*
 * Options of the song request web server ("Cancionero"). Everything but
 * switching the server on/off and the port works right away; those two
 * restart the server when leaving the screen.
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  UMenu,
  UMusic,
  UThemes,
  sdl2;

type
  TSROptionID = (
    iEnabledSlide,
    iPausedSlide,
    iMaxPendingSlide,
    iCooldownSlide,
    iRecentSlide,
    iQRTimeoutSlide,
    iRemoteSlide,
    iPortButton,
    iPinButton,
    iBackButton
  );

  TScreenOptionsSongRequests = class(TOptionsMenu)
    private
      SelEnabled:    integer;
      SelPaused:     integer;
      SelMaxPending: integer;
      SelCooldown:   integer;
      SelRecent:     integer;
      SelQRTimeout:  integer;
      SelRemote:     integer;

      ButtonPort: integer;
      ButtonPin:  integer;

      Port:    integer;
      Pin:     UTF8String;
      Editing: integer;    // interaction being typed into, -1 = none
      Buffer:  UTF8String; // digits typed so far

      StartEnabled: boolean;
      StartPort:    integer;
      Applied:      array[0..Ord(iRemoteSlide)] of integer; // slide values in effect

      procedure UpdateButtons;
      procedure ApplySlide(Interaction: integer);
      procedure FinishEditing(Accept: boolean);
      procedure Leave;
    public
      constructor Create; override;
      function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
      procedure OnShow; override;
    protected
      procedure LoadWidgets; override;
  end;

implementation

uses
  SysUtils,
  UGraphic,
  ULanguage,
  USongRequests,
  USongRequestsOverlay,
  USongRequestsServer;


const
  MAX_PENDING_VALUES: array[0..7] of integer = (0, 1, 2, 3, 4, 5, 7, 10);
  COOLDOWN_VALUES:    array[0..7] of integer = (0, 15, 30, 60, 120, 180, 300, 600);  // seconds
  RECENT_VALUES:      array[0..7] of integer = (0, 15, 30, 60, 90, 120, 240, 720);   // minutes
  QR_TIMEOUT_VALUES:  array[0..6] of integer = (0, 10, 20, 30, 45, 60, 120);         // seconds

  PIN_MIN_DIGITS = 4;
  PIN_MAX_DIGITS = 8;

var
  IOffOn:      array[0..1] of UTF8String;
  IOpenClosed: array[0..1] of UTF8String;
  IMaxPending: array of UTF8String;
  ICooldown:   array of UTF8String;
  IRecent:     array of UTF8String;
  IQRTimeout:  array of UTF8String;

function Seconds(Value: integer): UTF8String;
begin
  if (Value >= 60) and (Value mod 60 = 0) then
    Result := Format('%d min', [Value div 60])
  else
    Result := Format('%d s', [Value]);
end;

function Minutes(Value: integer): UTF8String;
begin
  if (Value >= 60) and (Value mod 60 = 0) then
    Result := Format('%d h', [Value div 60])
  else if Value >= 60 then
    Result := Format('%d h %d min', [Value div 60, Value mod 60])
  else
    Result := Format('%d min', [Value]);
end;

procedure TranslateValues;
var
  I: integer;
begin
  IOffOn[0] := Language.Translate('OPTION_VALUE_OFF');
  IOffOn[1] := Language.Translate('OPTION_VALUE_ON');
  IOpenClosed[0] := Language.Translate('SING_OPTIONS_SONGREQUESTS_OPEN');
  IOpenClosed[1] := Language.Translate('SING_OPTIONS_SONGREQUESTS_CLOSED');

  SetLength(IMaxPending, Length(MAX_PENDING_VALUES));
  IMaxPending[0] := Language.Translate('SING_OPTIONS_SONGREQUESTS_UNLIMITED');
  for I := 1 to High(MAX_PENDING_VALUES) do
    IMaxPending[I] := IntToStr(MAX_PENDING_VALUES[I]);

  SetLength(ICooldown, Length(COOLDOWN_VALUES));
  ICooldown[0] := Language.Translate('SING_OPTIONS_SONGREQUESTS_NONE');
  for I := 1 to High(COOLDOWN_VALUES) do
    ICooldown[I] := Seconds(COOLDOWN_VALUES[I]);

  SetLength(IRecent, Length(RECENT_VALUES));
  IRecent[0] := Language.Translate('SING_OPTIONS_SONGREQUESTS_NONE');
  for I := 1 to High(RECENT_VALUES) - 1 do
    IRecent[I] := Minutes(RECENT_VALUES[I]);
  IRecent[High(RECENT_VALUES)] := Language.Translate('SING_OPTIONS_SONGREQUESTS_ALL_NIGHT');

  SetLength(IQRTimeout, Length(QR_TIMEOUT_VALUES));
  IQRTimeout[0] := Language.Translate('SING_OPTIONS_SONGREQUESTS_UNTIL_KEY');
  for I := 1 to High(QR_TIMEOUT_VALUES) do
    IQRTimeout[I] := Seconds(QR_TIMEOUT_VALUES[I]);
end;

// index of the listed value closest to Value, so values set in the admin
// web page that are not in the list still show something sensible
function NearestIndex(const Values: array of integer; Value: integer): integer;
var
  I: integer;
begin
  Result := 0;
  for I := 1 to High(Values) do
    if Abs(Values[I] - Value) < Abs(Values[Result] - Value) then
      Result := I;
end;

constructor TScreenOptionsSongRequests.Create;
begin
  inherited Create;
  Description := Language.Translate('SING_OPTIONS_SONGREQUESTS_DESC');
  WhereAmI := Language.Translate('SING_OPTIONS_SONGREQUESTS_WHEREAMI');
  Load;
  Editing := -1;
  Interaction := 0;
end;

procedure TScreenOptionsSongRequests.LoadWidgets;
begin
  TranslateValues;
  // when editing this, also update the TSROptionID enum declaration
  AddSelectSlide('SING_OPTIONS_SONGREQUESTS_ENABLED', SelEnabled, IOffOn);
  AddSelectSlide('SING_OPTIONS_SONGREQUESTS_REQUESTS', SelPaused, IOpenClosed);
  AddSelectSlide('SING_OPTIONS_SONGREQUESTS_MAXPENDING', SelMaxPending, IMaxPending);
  AddSelectSlide('SING_OPTIONS_SONGREQUESTS_COOLDOWN', SelCooldown, ICooldown);
  AddSelectSlide('SING_OPTIONS_SONGREQUESTS_RECENT', SelRecent, IRecent);
  AddSelectSlide('SING_OPTIONS_SONGREQUESTS_QRTIMEOUT', SelQRTimeout, IQRTimeout);
  AddSelectSlide('SING_OPTIONS_SONGREQUESTS_REMOTE', SelRemote, IOffOn);
  ButtonPort := AddButton('');
  ButtonPin := AddButton('');
end;

procedure TScreenOptionsSongRequests.OnShow;
var
  I:        integer;
  Config:   TSongRequestsConfig;
  Settings: TSongRequestsSettings;
begin
  inherited;

  Editing := -1;
  Buffer := '';
  if SongRequests <> nil then
  begin
    Config := SongRequests.Config;
    Settings := SongRequests.Settings;

    SelEnabled := Ord(Config.Enabled);
    SelPaused := Ord(Settings.Paused);
    SelMaxPending := NearestIndex(MAX_PENDING_VALUES, Settings.MaxPendingPerUser);
    SelCooldown := NearestIndex(COOLDOWN_VALUES, Settings.CooldownSeconds);
    SelRecent := NearestIndex(RECENT_VALUES, Settings.RecentMinutes);
    SelQRTimeout := NearestIndex(QR_TIMEOUT_VALUES, Config.QRTimeout);
    SelRemote := Ord(Config.AllowRemote);
    Port := Config.Port;
    Pin := Config.AdminPin;

    SelectsS[Ord(iEnabledSlide)].SelectedOption := SelEnabled;
    SelectsS[Ord(iPausedSlide)].SelectedOption := SelPaused;
    SelectsS[Ord(iMaxPendingSlide)].SelectedOption := SelMaxPending;
    SelectsS[Ord(iCooldownSlide)].SelectedOption := SelCooldown;
    SelectsS[Ord(iRecentSlide)].SelectedOption := SelRecent;
    SelectsS[Ord(iQRTimeoutSlide)].SelectedOption := SelQRTimeout;
    SelectsS[Ord(iRemoteSlide)].SelectedOption := SelRemote;

    StartEnabled := Config.Enabled;
    StartPort := Config.Port;
  end;
  for I := 0 to High(Applied) do
    Applied[I] := SelectsS[I].SelectedOption;
  UpdateButtons;

  Interaction := 0;
end;

procedure TScreenOptionsSongRequests.UpdateButtons;
var
  PortText, PinText: UTF8String;
begin
  if Editing = Ord(iPortButton) then
    PortText := Buffer + '_'
  else
    PortText := IntToStr(Port);

  // the PIN is only shown while typing, the TV is in front of the guests
  if Editing = Ord(iPinButton) then
    PinText := Buffer + '_'
  else
    PinText := StringOfChar('*', Length(Pin));

  Button[ButtonPort].Text[0].Text :=
    Format(Language.Translate('SING_OPTIONS_SONGREQUESTS_PORT'), [PortText]);
  Button[ButtonPin].Text[0].Text :=
    Format(Language.Translate('SING_OPTIONS_SONGREQUESTS_PIN'), [PinText]);
end;

procedure TScreenOptionsSongRequests.ApplySlide(Interaction: integer);
var
  Config:   TSongRequestsConfig;
  Settings: TSongRequestsSettings;
begin
  if (SongRequests = nil) or (Interaction > High(Applied)) then
    Exit;
  Applied[Interaction] := SelectsS[Interaction].SelectedOption;
  Config := SongRequests.Config;
  Settings := SongRequests.Settings;

  case TSROptionID(Interaction) of
    iEnabledSlide:    Config.Enabled := SelEnabled = 1;
    iPausedSlide:     Settings.Paused := SelPaused = 1;
    iMaxPendingSlide: Settings.MaxPendingPerUser := MAX_PENDING_VALUES[SelMaxPending];
    iCooldownSlide:   Settings.CooldownSeconds := COOLDOWN_VALUES[SelCooldown];
    iRecentSlide:     Settings.RecentMinutes := RECENT_VALUES[SelRecent];
    iQRTimeoutSlide:  Config.QRTimeout := QR_TIMEOUT_VALUES[SelQRTimeout];
    iRemoteSlide:     Config.AllowRemote := SelRemote = 1;
  else
    Exit;
  end;

  if TSROptionID(Interaction) in [iPausedSlide, iMaxPendingSlide, iCooldownSlide, iRecentSlide] then
    SongRequests.ChangeSettings(Settings)
  else
    SongRequests.ChangeConfig(Config);
end;

procedure TScreenOptionsSongRequests.FinishEditing(Accept: boolean);
var
  Value:  integer;
  Config: TSongRequestsConfig;
begin
  if Accept and (SongRequests <> nil) then
  begin
    Config := SongRequests.Config;
    if Editing = Ord(iPortButton) then
    begin
      Value := StrToIntDef(Buffer, 0);
      if (Value < 1024) or (Value > 65535) then
      begin
        ScreenPopupError.ShowPopup(Language.Translate('SING_OPTIONS_SONGREQUESTS_PORT_INVALID'));
        Exit;
      end;
      Port := Value;
      Config.Port := Port;
    end
    else
    begin
      if Length(Buffer) < PIN_MIN_DIGITS then
      begin
        ScreenPopupError.ShowPopup(Format(Language.Translate('SING_OPTIONS_SONGREQUESTS_PIN_INVALID'),
          [PIN_MIN_DIGITS, PIN_MAX_DIGITS]));
        Exit;
      end;
      Pin := Buffer;
      Config.AdminPin := Pin;
    end;
    SongRequests.ChangeConfig(Config);
    AudioPlayback.PlaySound(SoundLib.Option);
  end;
  Editing := -1;
  Buffer := '';
  UpdateButtons;
end;

procedure TScreenOptionsSongRequests.Leave;
var
  I: integer;
begin
  // slides changed with the mouse
  for I := 0 to High(Applied) do
    if SelectsS[I].SelectedOption <> Applied[I] then
      ApplySlide(I);

  // switching the server on/off or moving it to another port needs a restart
  if (SongRequests <> nil) and
     ((SongRequests.Config.Enabled <> StartEnabled) or (SongRequests.Config.Port <> StartPort)) then
  begin
    RestartSongRequests;
    SongRequestsResetOverlay;
  end;
  AudioPlayback.PlaySound(SoundLib.Back);
  FadeTo(@ScreenOptions);
end;

function TScreenOptionsSongRequests.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
var
  MaxDigits: integer;
begin
  Result := true;
  if not PressedDown then
    Exit;

  // typing the port or the PIN
  if Editing >= 0 then
  begin
    if Editing = Ord(iPortButton) then
      MaxDigits := 5
    else
      MaxDigits := PIN_MAX_DIGITS;
    case PressedKey of
      SDLK_RETURN, SDLK_KP_ENTER:
        FinishEditing(true);
      SDLK_ESCAPE:
        FinishEditing(false);
      SDLK_BACKSPACE:
        begin
          if Length(Buffer) > 0 then
            Delete(Buffer, Length(Buffer), 1);
          UpdateButtons;
        end;
    else
      if (CharCode >= Ord('0')) and (CharCode <= Ord('9')) and (Length(Buffer) < MaxDigits) then
      begin
        Buffer := Buffer + Chr(CharCode);
        UpdateButtons;
      end;
    end;
    Exit;
  end;

  case PressedKey of
    SDLK_Q:
      begin
        Result := false;
        Exit;
      end;
    SDLK_ESCAPE,
    SDLK_BACKSPACE:
      Leave;
    SDLK_TAB:
      ScreenPopupHelp.ShowPopup();
    SDLK_RETURN:
      begin
        if SelInteraction = Ord(iBackButton) then
          Leave
        else if SelInteraction in [Ord(iPortButton), Ord(iPinButton)] then
        begin
          Editing := SelInteraction;
          // start with the current value, so the PIN can be looked up here
          if Editing = Ord(iPortButton) then
            Buffer := IntToStr(Port)
          else
            Buffer := Pin;
          UpdateButtons;
        end;
      end;
    SDLK_DOWN:
      InteractNext;
    SDLK_UP:
      InteractPrev;
    SDLK_RIGHT:
      if Interactions[SelInteraction].Typ = iSelectS then
      begin
        AudioPlayback.PlaySound(SoundLib.Option);
        InteractInc;
        ApplySlide(SelInteraction);
      end;
    SDLK_LEFT:
      if Interactions[SelInteraction].Typ = iSelectS then
      begin
        AudioPlayback.PlaySound(SoundLib.Option);
        InteractDec;
        ApplySlide(SelInteraction);
      end;
  end;
end;

end.
