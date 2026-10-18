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

unit URatings;

{*
 * The ratings of the score screen (Tone Deaf ... Ultrastar), counted per
 * player: in the score database (us_player_ratings) for all time and in
 * memory for this session. The song request page shows them.
 *}

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

const
  RATING_COUNT = 8;
  RATING_TEXTS: array[0..RATING_COUNT-1] of string = (
    'SING_SCORE_TONE_DEAF', 'SING_SCORE_AMATEUR', 'SING_SCORE_WANNABE', 'SING_SCORE_HOPEFUL',
    'SING_SCORE_RISING_STAR', 'SING_SCORE_LEAD_SINGER', 'SING_SCORE_SUPERSTAR', 'SING_SCORE_ULTRASTAR');

type
  TRatingCounts = array[0..RATING_COUNT-1] of integer;

// the rating of a total score (0..10000)
function RatingOf(Score: integer): integer;
// score screen: counts the ratings of the players who just sang
procedure RecordRatings;
// all-time counts of a player, from the score database (any thread)
function StoredRatings(const DBFile, Player: UTF8String): TRatingCounts;
// winning streaks (songs won in a row): keeps a player's best one
procedure RecordStreak(const Player: UTF8String; Streak: integer);
function StoredBestStreak(const DBFile, Player: UTF8String): integer;

implementation

uses
  SysUtils,
  SQLiteTable3,
  ULog,
  UNote,
  UPlatform,
  USongRequests;

const
  RATINGS_TABLE = 'us_player_ratings';
  STREAKS_TABLE = 'us_player_streaks';

function RatingOf(Score: integer): integer;
begin
  case Score of
    0..2009:     Result := 0;
    2010..4009:  Result := 1;
    4010..5009:  Result := 2;
    5010..6009:  Result := 3;
    6010..7509:  Result := 4;
    7510..8509:  Result := 5;
    8510..9009:  Result := 6;
    9010..10000: Result := 7;
  else
    Result := 0;
  end;
end;

function IsDefaultName(const Name: UTF8String): boolean;
begin
  Result := (Trim(Name) = '') or
            ((LowerCase(Copy(Trim(Name), 1, 6)) = 'player') and
             (StrToIntDef(Copy(Trim(Name), 7, 3), -1) > 0));
end;

function Quoted(const S: UTF8String): UTF8String;
begin
  Result := '''' + StringReplace(S, '''', '''''', [rfReplaceAll]) + '''';
end;

procedure CreateTable(DB: TSQLiteDatabase);
begin
  DB.ExecSQL('CREATE TABLE IF NOT EXISTS [' + RATINGS_TABLE + '] (' +
    '[Player] TEXT NOT NULL COLLATE NOCASE, [Rating] INTEGER NOT NULL, ' +
    '[Count] INTEGER NOT NULL DEFAULT 0, PRIMARY KEY ([Player], [Rating]))');
end;

procedure RecordRatings;
var
  DB: TSQLiteDatabase;
  I, Rating: integer;
  Name: UTF8String;
begin
  DB := nil;
  try
    try
      DB := TSQLiteDatabase.Create(Platform.GetGameUserPath.Append('Ultrastar.db').ToUTF8);
      DB.SetTimeout(1000);
      CreateTable(DB);
      for I := 0 to High(Player) do
      begin
        Name := Trim(Player[I].Name);
        if IsDefaultName(Name) then
          Continue;
        Rating := RatingOf(Player[I].ScoreTotalInt);
        DB.ExecSQL(Format('INSERT INTO [%s] ([Player], [Rating], [Count]) VALUES (%s, %d, 1) ' +
          'ON CONFLICT ([Player], [Rating]) DO UPDATE SET [Count] = [Count] + 1',
          [RATINGS_TABLE, Quoted(Name), Rating]));
        if SongRequests <> nil then
          SongRequests.AddSessionRating(Name, Rating);
      end;
    except
      on E: Exception do
        Log.LogError('Could not save the ratings: ' + E.Message, 'URatings');
    end;
  finally
    DB.Free;
  end;
end;

function StoredRatings(const DBFile, Player: UTF8String): TRatingCounts;
var
  DB: TSQLiteDatabase;
  Table: TSQLiteUniTable;
  Rating: integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  DB := nil;
  try
    try
      DB := TSQLiteDatabase.Create(DBFile);
      DB.SetTimeout(500);
      if not DB.TableExists(RATINGS_TABLE) then
        Exit;
      Table := DB.GetUniTable(Format('SELECT [Rating], [Count] FROM [%s] WHERE [Player] = %s',
        [RATINGS_TABLE, Quoted(Trim(Player))]));
      try
        while not Table.EOF do
        begin
          Rating := Table.FieldAsInteger(0);
          if (Rating >= 0) and (Rating < RATING_COUNT) then
            Result[Rating] := Table.FieldAsInteger(1);
          Table.Next;
        end;
      finally
        Table.Free;
      end;
    except
      on E: Exception do
        Log.LogWarn('Could not read the ratings: ' + E.Message, 'URatings');
    end;
  finally
    DB.Free;
  end;
end;

procedure RecordStreak(const Player: UTF8String; Streak: integer);
var
  DB: TSQLiteDatabase;
begin
  if IsDefaultName(Player) or (Streak < 1) then
    Exit;
  DB := nil;
  try
    try
      DB := TSQLiteDatabase.Create(Platform.GetGameUserPath.Append('Ultrastar.db').ToUTF8);
      DB.SetTimeout(1000);
      DB.ExecSQL('CREATE TABLE IF NOT EXISTS [' + STREAKS_TABLE + '] (' +
        '[Player] TEXT NOT NULL COLLATE NOCASE PRIMARY KEY, [Best] INTEGER NOT NULL DEFAULT 0)');
      DB.ExecSQL(Format('INSERT INTO [%s] ([Player], [Best]) VALUES (%s, %d) ' +
        'ON CONFLICT ([Player]) DO UPDATE SET [Best] = MAX([Best], excluded.[Best])',
        [STREAKS_TABLE, Quoted(Trim(Player)), Streak]));
    except
      on E: Exception do
        Log.LogError('Could not save the streak: ' + E.Message, 'URatings');
    end;
  finally
    DB.Free;
  end;
end;

function StoredBestStreak(const DBFile, Player: UTF8String): integer;
var
  DB: TSQLiteDatabase;
  Table: TSQLiteUniTable;
begin
  Result := 0;
  DB := nil;
  try
    try
      DB := TSQLiteDatabase.Create(DBFile);
      DB.SetTimeout(500);
      if not DB.TableExists(STREAKS_TABLE) then
        Exit;
      Table := DB.GetUniTable(Format('SELECT [Best] FROM [%s] WHERE [Player] = %s',
        [STREAKS_TABLE, Quoted(Trim(Player))]));
      try
        if not Table.EOF then
          Result := Table.FieldAsInteger(0);
      finally
        Table.Free;
      end;
    except
      on E: Exception do
        Log.LogWarn('Could not read the streak: ' + E.Message, 'URatings');
    end;
  finally
    DB.Free;
  end;
end;

end.
