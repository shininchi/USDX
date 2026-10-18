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

unit UMicTaps;

{*
 * Taps on the microphones, used as commands (two taps, three taps...).
 *
 * A tap is a very loud and very short sound: the level jumps from what the
 * microphone heard just before to near the maximum and falls again within
 * a few milliseconds, which singing never does. Taps less than a moment
 * apart make a series; when no tap follows, the series is reported with
 * its number of taps.
 *
 * The audio threads feed the samples of each player's microphone
 * (MicTapsProcess); the main thread reads the events (MicTapsPop).
 *
 * config.ini, section [MicTaps]:
 *   Enabled    On/Off
 *   Level      how loud a tap must be, 0..1 of the maximum (default 0.25)
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

type
  TMicTapKind = (mtTap, mtSeries);

  TMicTapEvent = record
    Kind:   TMicTapKind;
    Player: integer;
    Count:  integer;  // taps in the series (mtSeries)
    Peak:   single;   // level of the tap, 0..1 (mtTap)
    DecayMs: integer; // how fast it faded (mtTap)
  end;

var
  MicTapsEnabled: boolean = true;
  MicTapLevel:    single = 0.25;

procedure MicTapsLoadConfig;
// audio thread: new samples of a player's microphone (signed 16 bit, mono)
procedure MicTapsProcess(Player: integer; Samples: PSmallInt; Count, SampleRate: integer);
// main thread: next event, false when there is none
function MicTapsPop(out Event: TMicTapEvent): boolean;
// SDL ticks of the player's last tap, 0 = none yet
function MicTapLastTicks(Player: integer): cardinal;
procedure MicTapsReset;

implementation

uses
  IniFiles,
  SyncObjs,
  SysUtils,
  sdl2,
  UIni;

const
  MAX_PLAYERS    = 12;
  BLOCK_MS       = 5;     // the level is looked at in blocks of this length
  ATTACK_RATIO   = 4.0;   // a tap is this much louder than the moment before
  DECAY_RATIO    = 0.25;  // and falls below this share of its peak ...
  MAX_DECAY_MS   = 60;    // ... within this time
  REFRACTORY_MS  = 90;    // the ringing after a tap is not another tap
  MIN_GAP_MS     = 90;    // taps of a series are at least this far apart ...
  MAX_GAP_MS     = 650;   // ... and at most this far
  QUEUE_SIZE     = 64;

type
  TTapState = (tsIdle, tsCandidate, tsRefractory);

  TPlayerTaps = record
    Clock:      int64;   // samples seen
    BlockPeak:  integer;
    BlockFill:  integer;
    PrevLevel:  single;  // level of the previous block
    Background: single;  // slow average level
    State:      TTapState;
    StateStart: int64;   // Clock when the state began
    Peak:       single;
    LastTap:    int64;   // Clock of the last tap, -1 = none
    Count:      integer; // taps of the current series
    LastTicks:  cardinal;
  end;

var
  Players: array[0..MAX_PLAYERS-1] of TPlayerTaps;
  Queue:   array[0..QUEUE_SIZE-1] of TMicTapEvent;
  QueueHead, QueueTail: integer;
  Lock:    TCriticalSection;

procedure Push(const Event: TMicTapEvent);
begin
  Lock.Enter;
  try
    Queue[QueueTail] := Event;
    QueueTail := (QueueTail + 1) mod QUEUE_SIZE;
    if QueueTail = QueueHead then  // full: drop the oldest
      QueueHead := (QueueHead + 1) mod QUEUE_SIZE;
  finally
    Lock.Leave;
  end;
end;

function MicTapsPop(out Event: TMicTapEvent): boolean;
begin
  Lock.Enter;
  try
    Result := QueueHead <> QueueTail;
    if Result then
    begin
      Event := Queue[QueueHead];
      QueueHead := (QueueHead + 1) mod QUEUE_SIZE;
    end;
  finally
    Lock.Leave;
  end;
end;

function MicTapLastTicks(Player: integer): cardinal;
begin
  Result := 0;
  if (Player >= 0) and (Player < MAX_PLAYERS) then
    Result := Players[Player].LastTicks;
end;

procedure MicTapsReset;
var
  I: integer;
begin
  Lock.Enter;
  try
    for I := 0 to MAX_PLAYERS - 1 do
    begin
      FillChar(Players[I], SizeOf(TPlayerTaps), 0);
      Players[I].LastTap := -1;
    end;
    QueueHead := 0;
    QueueTail := 0;
  finally
    Lock.Leave;
  end;
end;

procedure MicTapsLoadConfig;
var
  IniFile: TMemIniFile;
begin
  IniFile := TMemIniFile.Create(Ini.Filename.ToNative);
  try
    MicTapsEnabled := not SameText(IniFile.ReadString('MicTaps', 'Enabled', 'On'), 'Off');
    MicTapLevel := StrToFloatDef(IniFile.ReadString('MicTaps', 'Level', '0.25'), 0.25,
      DefaultFormatSettings);
  finally
    IniFile.Free;
  end;
  if (MicTapLevel < 0.05) or (MicTapLevel > 1) then
    MicTapLevel := 0.25;
end;

function Ms(const P: TPlayerTaps; Since: int64; SampleRate: integer): int64;
begin
  Result := (P.Clock - Since) * 1000 div SampleRate;
end;

procedure EndBlock(Player: integer; var P: TPlayerTaps; SampleRate: integer);
var
  Level: single;
  Event: TMicTapEvent;
begin
  Level := P.BlockPeak / 32768;

  case P.State of
    tsIdle:
      if (Level >= MicTapLevel) and (Level >= ATTACK_RATIO * P.PrevLevel) and
         (Level >= ATTACK_RATIO * P.Background) then
      begin
        P.State := tsCandidate;
        P.StateStart := P.Clock;
        P.Peak := Level;
      end;
    tsCandidate:
      begin
        if Level > P.Peak then
          P.Peak := Level;
        if Level < DECAY_RATIO * P.Peak then
        begin
          // a tap: loud, sudden and over at once
          Event.Kind := mtTap;
          Event.Player := Player;
          Event.Count := 0;
          Event.Peak := P.Peak;
          Event.DecayMs := Ms(P, P.StateStart, SampleRate);
          Push(Event);
          P.LastTicks := SDL_GetTicks;

          if (P.LastTap >= 0) and (Ms(P, P.LastTap, SampleRate) >= MIN_GAP_MS) and
             (Ms(P, P.LastTap, SampleRate) <= MAX_GAP_MS) then
            Inc(P.Count)
          else
            P.Count := 1;
          P.LastTap := P.StateStart;
          P.State := tsRefractory;
          P.StateStart := P.Clock;
        end
        else if Ms(P, P.StateStart, SampleRate) > MAX_DECAY_MS then
        begin
          // still loud: a shout or a note, not a tap
          P.State := tsRefractory;
          P.StateStart := P.Clock;
        end;
      end;
    tsRefractory:
      if Ms(P, P.StateStart, SampleRate) >= REFRACTORY_MS then
        P.State := tsIdle;
  end;

  // the series ends when no tap follows
  if (P.Count > 0) and (Ms(P, P.LastTap, SampleRate) > MAX_GAP_MS) then
  begin
    Event.Kind := mtSeries;
    Event.Player := Player;
    Event.Count := P.Count;
    Event.Peak := 0;
    Event.DecayMs := 0;
    Push(Event);
    P.Count := 0;
  end;

  if P.State <> tsCandidate then
    P.Background := 0.97 * P.Background + 0.03 * Level;
  P.PrevLevel := Level;
  P.BlockPeak := 0;
  P.BlockFill := 0;
end;

procedure MicTapsProcess(Player: integer; Samples: PSmallInt; Count, SampleRate: integer);
var
  I, V, BlockSize: integer;
begin
  if (not MicTapsEnabled) or (Player < 0) or (Player >= MAX_PLAYERS) or (SampleRate <= 0) then
    Exit;
  BlockSize := SampleRate * BLOCK_MS div 1000;
  for I := 0 to Count - 1 do
  begin
    V := Abs(integer(Samples[I]));
    if V > Players[Player].BlockPeak then
      Players[Player].BlockPeak := V;
    Inc(Players[Player].BlockFill);
    Inc(Players[Player].Clock);
    if Players[Player].BlockFill >= BlockSize then
      EndBlock(Player, Players[Player], SampleRate);
  end;
end;

initialization
  Lock := TCriticalSection.Create;
  MicTapsReset;

finalization
  Lock.Free;

end.
