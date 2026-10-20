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

unit UScreenEditGenerate;

{*
 * Editor » Generate: lyrics and notes made automatically (USongGenerator),
 * either for a song that has audio but no lyrics yet, or for a new song from
 * an audio/video file or a YouTube link. The generator leaves the lyrics it
 * heard in letra.txt; once corrected, generating again uses them. The generation goes on in the
 * background when leaving the screen.
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
  TGenerateOptionID = (
    iSongSlide,
    iLanguageSlide,
    iSourceButton,
    iStartButton,
    iBackButton
  );

  TScreenEditGenerate = class(TOptionsMenu)
    private
      SelSong:      integer;
      SelLanguage:  integer;
      ButtonSource: integer;
      ButtonStart:  integer;

      SongNames:  array of UTF8String;  // slide options, [0] = new song
      SongFiles:  array of UTF8String;  // txt of each listed song
      SongAudios: array of UTF8String;  // audio of each listed song
      ListedVersion: integer;           // generator version of the song list

      Source:  UTF8String;  // file or link for a new song
      Editing: boolean;
      // the generator's last result was replaced by a new choice: show
      // "Generate" again instead of it
      ResultDismissed: boolean;
      Buffer:  UTF8String;

      procedure FindSongsWithoutLyrics;
      procedure UpdateButtons;
      procedure StartOrCancel;
      procedure Leave;
    public
      constructor Create; override;
      function ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean; override;
      procedure OnShow; override;
      function Draw: boolean; override;
    protected
      procedure LoadWidgets; override;
  end;

implementation

uses
  Classes,
  SysUtils,
  UGraphic,
  ULanguage,
  ULog,
  UPath,
  USong,
  USongGenerator,
  USongs,
  UUnicodeUtils;

const
  LANGUAGE_CODES: array[0..2] of string = ('', 'es', 'en');
  MAX_SHOWN_CHARS = 38;  // longer sources are cut so the button text fits
  MIN_LYRIC_NOTES = 3;   // songs with fewer notes with text count as without lyrics

// the end of long texts, which has the file name
function Shorten(const Text: UTF8String): UTF8String;
var
  Chars: UCS4String;
  I, Start: integer;
begin
  Chars := UTF8ToUCS4String(Text);
  // UCS4 strings end with a 0 char
  if Length(Chars) - 1 <= MAX_SHOWN_CHARS then
  begin
    Result := Text;
    Exit;
  end;
  Result := '...'; // plain dots: the source file is not read as UTF-8
  Start := Length(Chars) - 1 - (MAX_SHOWN_CHARS - 1);
  for I := Start to Length(Chars) - 2 do
    Result := Result + UCS4ToUTF8String(Chars[I]);
end;

// lyrics file the generator uses for this folder (see usdx_generate.py)
var
  ILanguages:      array[0..2] of UTF8String;
  LyricsFolder:    UTF8String;
  LyricsFolderHas: boolean;
  LyricsChecked:   TDateTime;

function HasLyricsFile(const Folder: UTF8String): boolean;
var
  Info: TSearchRec;
  Name: UTF8String;
begin
  // the buttons are updated every frame, look at the folder once a second
  if (Folder = LyricsFolder) and (Now - LyricsChecked < 1 / SecsPerDay) then
  begin
    Result := LyricsFolderHas;
    Exit;
  end;
  Result := false;
  LyricsFolder := Folder;
  LyricsChecked := Now;
  LyricsFolderHas := false;
  if Folder = '' then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Folder) + '*.txt', faAnyFile, Info) = 0 then
  begin
    repeat
      Name := LowerCase(Info.Name);
      if (Name = 'letra.txt') or (Name = 'lyrics.txt') or
         (Copy(Name, Length(Name) - 10, 11) = '.lyrics.txt') then
        Result := true;
    until Result or (FindNext(Info) <> 0);
    FindClose(Info);
  end;
  LyricsFolderHas := Result;
end;

function LyricNoteCount(const FileName: UTF8String): integer;
var
  Lines: TStringList;
  Line, Text: string;
  I, Field, P: integer;
begin
  Result := 0;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(FileName);
    except
      Exit;
    end;
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Lines[I];
      if (Line = '') or not (Line[1] in [':', '*', 'F', 'R', 'G']) then
        Continue;
      // the text follows type, start, length and pitch
      P := 1;
      for Field := 1 to 4 do
      begin
        while (P <= Length(Line)) and (Line[P] <> ' ') do
          Inc(P);
        while (P <= Length(Line)) and (Line[P] = ' ') do
          Inc(P);
      end;
      Text := Trim(Copy(Line, P, MaxInt));
      if (Text <> '') and (Text <> '~') then
      begin
        Inc(Result);
        if Result >= MIN_LYRIC_NOTES then
          Exit;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

constructor TScreenEditGenerate.Create;
begin
  inherited Create;
  Description := Language.Translate('SING_EDIT_GENERATE_DESC');
  WhereAmI := Language.Translate('SING_EDIT_GENERATE_WHEREAMI');
  SetLength(SongNames, 1);
  SongNames[0] := Language.Translate('SING_EDIT_GENERATE_NEW');
  Load;
  ListedVersion := -1;
  Interaction := 0;
end;

procedure TScreenEditGenerate.LoadWidgets;
begin
  // when editing this, also update the TGenerateOptionID enum declaration
  AddSelectSlide('SING_EDIT_GENERATE_SONG', SelSong, SongNames);
  // Whisper guesses the language from the first seconds, and often wrong
  ILanguages[0] := Language.Translate('SING_EDIT_GENERATE_LANG_AUTO');
  ILanguages[1] := Language.Translate('SING_EDIT_GENERATE_LANG_ES');
  ILanguages[2] := Language.Translate('SING_EDIT_GENERATE_LANG_EN');
  SelLanguage := 1;
  AddSelectSlide('SING_EDIT_GENERATE_LANGUAGE', SelLanguage, ILanguages);
  ButtonSource := AddButton('');
  ButtonStart := AddButton('');
end;

procedure TScreenEditGenerate.FindSongsWithoutLyrics;
var
  I, N:     integer;
  Song:     TSong;
  TxtFile:  IPath;
  Audio:    IPath;
begin
  SetLength(SongNames, 1);
  SetLength(SongFiles, 1);
  SetLength(SongAudios, 1);
  SongFiles[0] := '';
  SongAudios[0] := '';
  if Songs <> nil then
    for I := 0 to Songs.SongList.Count - 1 do
    begin
      Song := TSong(Songs.SongList[I]);
      TxtFile := Song.Path.Append(Song.FileName);
      Audio := Song.Path.Append(Song.Audio);
      if Song.Audio.IsUnset or not Audio.IsFile then
        Continue;
      // songs with a lyrics file stay listed, to generate them again
      // after correcting the lyrics
      if (LyricNoteCount(TxtFile.ToNative) >= MIN_LYRIC_NOTES) and
         not HasLyricsFile(Song.Path.ToNative) then
        Continue;
      N := Length(SongNames);
      SetLength(SongNames, N + 1);
      SetLength(SongFiles, N + 1);
      SetLength(SongAudios, N + 1);
      SongNames[N] := Song.Artist + ' - ' + Song.Title;
      SongFiles[N] := TxtFile.ToNative;
      SongAudios[N] := Audio.ToNative;
    end;
  Log.LogStatus(Format('%d songs without lyrics', [Length(SongNames) - 1]), 'ScreenEditGenerate');

  if SelSong > High(SongNames) then
    SelSong := 0;
  UpdateSelectSlideOptions(Ord(iSongSlide), SongNames, SelSong);
  SelectsS[Ord(iSongSlide)].SelectedOption := SelSong;
  if SongGenerator <> nil then
    ListedVersion := SongGenerator.Version;
end;

procedure TScreenEditGenerate.OnShow;
begin
  inherited;
  if SongGenerator = nil then
    SongGenerator := TSongGenerator.Create;

  Editing := false;
  Buffer := '';
  SongGeneratorDroppedFile := '';
  SDL_EventState(SDL_DROPFILE, SDL_ENABLE);

  if ListedVersion <> SongGenerator.Version then
    FindSongsWithoutLyrics;
  // an empty song folder has nothing to fill in; start with a new song
  if Length(SongNames) = 1 then
    Interaction := Ord(iSourceButton)
  else
    Interaction := 0;
  UpdateButtons;
end;

procedure TScreenEditGenerate.UpdateButtons;
var
  SourceText, StartText, Stage: UTF8String;
  Seconds: integer;
begin
  if Editing then
    SourceText := Shorten(Buffer + '_')
  else if SelSong > 0 then
    SourceText := ExtractFileName(SongAudios[SelSong])
  else if Source <> '' then
    // a file shows its name; a link, its end
    if FileExists(Source) then
      SourceText := Shorten(ExtractFileName(Source))
    else
      SourceText := Shorten(Source)
  else
    SourceText := Language.Translate('SING_EDIT_GENERATE_SOURCE_HINT');
  if (not Editing) and
     (((SelSong > 0) and HasLyricsFile(ExtractFileDir(SongFiles[SelSong]))) or
      ((SelSong = 0) and (Source <> '') and FileExists(Source) and HasLyricsFile(ExtractFileDir(Source)))) then
    SourceText := Format(Language.Translate('SING_EDIT_GENERATE_WITH_LYRICS'), [SourceText]);
  Button[ButtonSource].Text[0].Text :=
    Format(Language.Translate('SING_EDIT_GENERATE_SOURCE'), [SourceText]);

  StartText := Language.Translate('SING_EDIT_GENERATE_START');
  if (SongGenerator <> nil) and
     ((SongGenerator.State = gsRunning) or not ResultDismissed) then
    case SongGenerator.State of
      gsRunning:
        begin
          Stage := SongGenerator.Stage;
          if Stage = '' then
            Stage := 'start';
          Seconds := SongGenerator.ElapsedSeconds;
          StartText := Format(Language.Translate('SING_EDIT_GENERATE_RUNNING'),
            [Language.Translate('SING_EDIT_GENERATE_STAGE_' + UpperCase(Stage)),
             Seconds div 60, Seconds mod 60]);
        end;
      gsDone:
        if SongGenerator.LyricsSource = 'lrclib' then
          StartText := Language.Translate('SING_EDIT_GENERATE_DONE_LRCLIB')
        else if SongGenerator.LyricsSource = 'user' then
          StartText := Language.Translate('SING_EDIT_GENERATE_DONE_USER')
        else
          StartText := Language.Translate('SING_EDIT_GENERATE_DONE');
      gsFailed:
        if SongGenerator.Message = 'cancelled' then
          StartText := Language.Translate('SING_EDIT_GENERATE_CANCELLED')
        else
          StartText := Format(Language.Translate('SING_EDIT_GENERATE_FAILED'),
            [Shorten(SongGenerator.Message)]);
    end;
  Button[ButtonStart].Text[0].Text := StartText;
end;

function TScreenEditGenerate.Draw: boolean;
begin
  // a file dropped onto the window
  if SongGeneratorDroppedFile <> '' then
  begin
    Source := SongGeneratorDroppedFile;
    SongGeneratorDroppedFile := '';
    Editing := false;
    SelSong := 0;
    SelectsS[Ord(iSongSlide)].SelectedOption := 0;
    Interaction := Ord(iStartButton);
    ResultDismissed := true;
  end;

  if (SongGenerator <> nil) and (ListedVersion <> SongGenerator.Version) then
    FindSongsWithoutLyrics;
  UpdateButtons;
  Result := inherited Draw;
end;

procedure TScreenEditGenerate.StartOrCancel;
var
  Input, Replace: UTF8String;
begin
  if SongGenerator.State = gsRunning then
  begin
    SongGenerator.Cancel;
    AudioPlayback.PlaySound(SoundLib.Back);
    Exit;
  end;

  if not SongGenerator.Available then
  begin
    ScreenPopupError.ShowPopup(Format(Language.Translate('SING_EDIT_GENERATE_MISSING'),
      [SongGenerator.PythonPath]));
    Exit;
  end;

  if SelSong > 0 then
  begin
    Input := SongAudios[SelSong];
    Replace := SongFiles[SelSong];
  end
  else
  begin
    Input := Trim(Source);
    Replace := '';
    if Input = '' then
    begin
      ScreenPopupError.ShowPopup(Language.Translate('SING_EDIT_GENERATE_NO_INPUT'));
      Exit;
    end;
    if (Pos('://', Input) = 0) and not FileExists(Input) then
    begin
      ScreenPopupError.ShowPopup(Format(Language.Translate('SING_EDIT_GENERATE_BAD_INPUT'),
        [Shorten(Input)]));
      Exit;
    end;
  end;

  ResultDismissed := false;
  if SongGenerator.Start(Input, Replace, LANGUAGE_CODES[SelLanguage]) then
    AudioPlayback.PlaySound(SoundLib.Start);
end;

procedure TScreenEditGenerate.Leave;
begin
  SDL_EventState(SDL_DROPFILE, SDL_DISABLE);
  AudioPlayback.PlaySound(SoundLib.Back);
  FadeTo(@ScreenEdit);
end;

function TScreenEditGenerate.ParseInput(PressedKey: cardinal; CharCode: UCS4Char; PressedDown: boolean): boolean;
var
  Clip: PAnsiChar;
begin
  Result := true;
  if not PressedDown then
    Exit;

  // typing or pasting a file name or link
  if Editing then
  begin
    if (PressedKey = SDLK_V) and
       ((SDL_GetModState and (KMOD_CTRL or KMOD_GUI)) <> 0) then
    begin
      Clip := SDL_GetClipboardText();
      if Clip <> nil then
      begin
        Buffer := Buffer + Trim(UTF8String(Clip));
        SDL_free(Clip);
      end;
      Exit;
    end;
    if CharCode >= 32 then
    begin
      // Cmd+V also sends a "v" on some systems
      if (SDL_GetModState and (KMOD_CTRL or KMOD_GUI)) = 0 then
        Buffer := Buffer + UCS4ToUTF8String(CharCode);
      Exit;
    end;
    case PressedKey of
      SDLK_RETURN:
        begin
          Source := Trim(Buffer);
          ResultDismissed := true;
          Editing := false;
          if Source <> '' then
            Interaction := Ord(iStartButton);
        end;
      SDLK_ESCAPE:
        Editing := false;
      SDLK_BACKSPACE:
        if Length(Buffer) > 0 then
          Buffer := UCS4ToUTF8String(Copy(UTF8ToUCS4String(Buffer), 0, Length(UTF8ToUCS4String(Buffer)) - 2));
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
        else if SelInteraction = Ord(iSourceButton) then
        begin
          // a new song from a file or link
          SelSong := 0;
          SelectsS[Ord(iSongSlide)].SelectedOption := 0;
          Editing := true;
          Buffer := Source;
        end
        else if SelInteraction = Ord(iStartButton) then
          StartOrCancel;
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
        ResultDismissed := true;
      end;
    SDLK_LEFT:
      if Interactions[SelInteraction].Typ = iSelectS then
      begin
        AudioPlayback.PlaySound(SoundLib.Option);
        InteractDec;
        ResultDismissed := true;
      end;
  end;
end;

end.
