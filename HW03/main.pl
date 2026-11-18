:- [songs].
:- [helper].

% ============================================================
% Part 1
% ============================================================
% replace "fail" for your solution. It is simply a placeholder to avoid binding for the starter code.
first_or_empty([], []).
first_or_empty([First|_], [First]).
song_query(Tokens, Songs) :-
    request(Songs, Tokens).

request(Songs,[find, songs, by, Artist]) :-
    findall(Name, song(Name, _, Artist, _), Unsorted),
    sort(Unsorted, Songs).
request(Songs, [find, songs, of, type, Type]) :-
    findall(Name, song(Name, Type, _, _), Unsorted),
    sort(Unsorted, Songs).
request(Songs, [find, songs, shorter, than, N, minutes]) :-
    atom_number(N, NAtom),
    findall(Name, (song(Name, _, _, Duration), Duration < NAtom), Unsorted),
    sort(Unsorted, Songs).
request(Songs, [find, songs, of, type, Type, shorter, than, N, minutes]) :-
    atom_number(N, NAtom),
    findall(Name, (song(Name, Type, _, Duration), Duration < NAtom), Unsorted),
    sort(Unsorted, Songs).
request(Songs, [find, one, song, by, Artist]) :-
    findall(Name, song(Name, _, Artist, _), Unsorted),
    sort(Unsorted, Temp),
    first_or_empty(Temp, Songs).
request(Songs, [find, one, song, of, type, Type]) :-
    findall(Name, song(Name, Type, _, _), Unsorted),
    sort(Unsorted, Temp),
    first_or_empty(Temp, Songs).
request(Songs, [find, one, song, shorter, than, N, minutes]) :-
    atom_number(N, NAtom),
    findall(Name, (song(Name, _, _, Duration), Duration < NAtom), Unsorted),
    sort(Unsorted, Temp),
    first_or_empty(Temp, Songs).
request(Songs, [find, one, song, of, type, Type, shorter, than, N, minutes]) :-
    atom_number(N, NAtom),
    findall(Name, (song(Name, Type, _, Duration), Duration < NAtom), Unsorted),
    sort(Unsorted, Temp),
    first_or_empty(Temp, Songs).
% ============================================================
% Part 2
% ============================================================

% total_duration(+Playlist, -Minutes)
% Minutes is the sum of the durations of every title in Playlist,
% looked up from the song/4 facts (nothing is hardcoded).
%   - The empty playlist has duration 0.
%   - A title with no song/4 fact makes the lookup fail, so the whole
%     predicate fails, as the spec requires for unknown titles.
total_duration([], 0).
total_duration([Name|Rest], Minutes) :-
    song(Name, _, _, D),                    % duration of the first title
    total_duration(Rest, RestDuration),     % total of the remaining titles
    Minutes is D + RestDuration.

% make_playlist(+MinTime, +MaxTime, +MaxSongs, -Playlist)
% Enumerates, one per solution, every playlist satisfying the rules:
%   1. Songs come from song/4 facts (Pairs is built with findall).
%   2. MinTime =< total duration =< MaxTime (inclusive).
%   3. Between 1 and MaxSongs songs.
%   4/5. No repeats, alphabetical order, each combination only once.
% Rules 4 and 5 hold because Pairs is sorted by name and pick/6 only
% chooses songs that come AFTER the previously chosen one. Each set of
% songs can therefore be built in exactly one way.
make_playlist(MinTime, MaxTime, MaxSongs, Playlist) :-
    findall(Name-Dur, song(Name, _, _, Dur), Pairs0),
    sort(Pairs0, Pairs),                                    % alphabetical by name (names are unique)
    pick(Pairs, MaxSongs, MaxTime, 0, Playlist, Total),
    Playlist \== [],                                        % rule 3: at least one song
    Total >= MinTime.                                       % rule 2: lower bound (upper bound is enforced in pick/6)

% pick(+Songs, +Left, +MaxTime, +Acc, -Chosen, -Total)
%   Songs   : remaining candidates (Name-Duration pairs, alphabetical)
%   Left    : how many more songs may still be added
%   MaxTime : upper time limit
%   Acc     : total duration of the songs chosen so far
%   Chosen  : chosen song names, in alphabetical order
%   Total   : final duration of Chosen
%
% Base case: stop here. The final total is the accumulated total, which
% is why Acc and Total are the same variable. This clause lets a playlist
% end after any number of songs, so every length from 0 to MaxSongs is
% generated (the empty one is rejected in make_playlist/4).
pick(_, _, _, Total, [], Total).

% Recursive case: choose a song from the remaining candidates
pick(Songs, Left, MaxTime, Acc, [Name|Names], Total) :-
    Left > 0,                                           % rule 3: respect MaxSongs
    pick_from(Songs, Name-D, Rest),                     % choose a song; Rest = only songs after it
    Acc1 is Acc + D,
    Acc1 =< MaxTime,                                    % rule 2: prune as soon as we go over
    Left1 is Left - 1,
    pick(Rest, Left1, MaxTime, Acc1, Names, Total).

% pick_from(+List, -X, -Tail)
% X is some element of List and Tail is the part of the list AFTER X.
% Passing Tail (not the whole list) to the next pick/6 call is what
% prevents repeats and permutations: a song is never chosen twice, and
% earlier songs are never chosen after later ones.
pick_from([X|Rest], X, Rest).
pick_from([_|Rest], X, Tail) :-
    pick_from(Rest, X, Tail).

% ============================================================
% Main
% ============================================================
main :-
    run_program.
