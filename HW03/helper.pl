:- use_module(library(readutil)).

% Split an English request into lowercase, whitespace-separated atoms.
% A numeric word (such as 4) is an atom token ('4'), not an integer.
% Punctuation is not removed.
tokenize_question(Text, Tokens) :-
    string_lower(Text, Lower),
    split_string(Lower, " \t\r\n", " \t\r\n", Words),
    maplist(atom_string, Tokens, Words).

% Read the input filename and mode from the command line.
run_program :-
    current_prolog_flag(argv, Args),
    ( Args = [InputFile, Mode], memberchk(Mode, [part1, part2]) ->
        setup_call_cleanup(
            open(InputFile, read, Stream),
            run_mode(Mode, Stream),
            close(Stream)
        )
    ; format(user_error,
             'Usage: swipl -s main.pl -t main --quiet -- FILE part1|part2~n', []),
      halt(2)
    ).

% Part 1: one sentence per line; skip blanks and # comments.
run_mode(part1, Stream) :-
    read_line_to_string(Stream, Line),
    ( Line == end_of_file ->
        true
    ; normalize_space(string(Clean), Line),
      ( Clean == "" ->
          true
      ; sub_string(Clean, 0, 1, _, "#") ->
          true
      ; tokenize_question(Clean, Tokens),
        ( once(song_query(Tokens, Songs)) ->
            write_term(Songs, [quoted(true)]), nl
        ; writeln(false)
        )
      ),
      run_mode(part1, Stream)
    ).

% Part 2: one Prolog test(...) term per case; finish with a period.
run_mode(part2, Stream) :-
    read_term(Stream, Test, []),
    ( Test == end_of_file ->
        true
    ; run_part2_case(Test),
      run_mode(part2, Stream)
    ).

run_part2_case(test(total_duration(Playlist))) :-
    !,
    format('total_duration(~q) => ', [Playlist]),
    ( once(total_duration(Playlist, Minutes)) ->
        format('~q~n', [Minutes])
    ; writeln(false)
    ).

run_part2_case(test(make_playlist(MinTime, MaxTime, MaxSongs))) :-
    !,
    findall(Playlist,
            make_playlist(MinTime, MaxTime, MaxSongs, Playlist),
            AllPlaylists),
    % msort preserves duplicates, so repeated solutions remain visible.
    msort(AllPlaylists, SortedPlaylists),
    format('make_playlist(~q,~q,~q) =>',
           [MinTime, MaxTime, MaxSongs]),
    print_playlists(SortedPlaylists).

run_part2_case(Unexpected) :-
    format(user_error, 'Invalid Part 2 test case: ~q~n', [Unexpected]),
    halt(2).

% Print sorted playlist results.
print_playlists([]) :-
    !,
    writeln(' []').
print_playlists([First|Rest]) :-
    nl,
    write('  ['),
    write_term(First, [quoted(true)]),
    print_playlist_tail(Rest),
    writeln(']').

print_playlist_tail([]).
print_playlist_tail([Playlist|Rest]) :-
    write(','), nl,
    write('   '),
    write_term(Playlist, [quoted(true)]),
    print_playlist_tail(Rest).
