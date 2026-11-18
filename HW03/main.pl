:- [songs].
:- [helper].

% ============================================================
% Part 1
% ============================================================
% replace "fail" for your solution. It is simply a placeholder to avoid binding for the starter code.

song_query(_Tokens, _Songs) :-
    fail.

% ============================================================
% Part 2
% ============================================================

total_duration([], 0).
total_duration([Name|Rest], Minutes) :-
    song(Name, Duration),
    total_duration(Rest, RestDuration),
    Minutes is Duration + RestDuration.

make_playlist(MinTime, MaxTime, MaxSongs, Playlist) :-
    findall(Name-Dur, song(Name, _, _, Dur), Pairs0),
    sort(Pairs0, Pairs),
    pick(Pairs, MaxSongs, 0, Playlist, Total),
    Playlist \== [],
    Total >= MinTime.

pick(_, _, _, Total, [], Total).
pick(Songs, Left, MaxTime, Acc, [Name|Names], Total) :-
    Left > 0,
    pick_from(Songs, Name-D, Rest),
    Acc1 is Acc + D,
    Acc1 =< MaxTime,
    Left1 is Left - 1,
    pick(Rest, Left1, MaxTime, Acc1, Names, Total).

pick_from([X|Rest], X, Rest).
pick_from([_|Rest], X, Tail) :-
    pick_from(Rest, X, Tail).

% ============================================================
% Main
% ============================================================
main :-
    run_program.
