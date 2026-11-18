Team Names - Lucas Steadman, Colin Labrie

Implementaion notes - 

Part 1:
    first_or_empty/2 returns the first item of a list as a one-element list. If the original list is empty, it returns an empty list.
    song_query/2 takes the user's input tokens and passes them to request/2 to find matching songs.
    request/2 handles the different types of song searches:
        - Finds all songs by a specific artist.
        - Finds all songs of a specific genre.
        - Finds all songs shorter than a specified duration.
        - Finds all songs of a specific genre shorter than a specified duration.
        - Supports the same searches when requesting only one song.
    findall/3 collects all matching song names into a list. sort/2 sorts the results alphabetically and removes duplicates.
    For requests asking for one song, the results are sorted first and then passed to first_or_empty/2, which returns only the first matching song.
    atom_number/2 converts the requested duration from an atom into a number so it can be compared against the song durations.

Part 2: 
    total_duration/2 is a simple implementation of the sum of the durations of all the songs in a playlist. 
    make_playlist/4 songs are collected with findall/3 as Name-Duration pairs and sorted alphabetically by name. The helper predicate pick/6 then builds a playlist left to right. After choosing a song, pick_from/3 returns only the songs that come after it in the sorted list, and only those are candidates for the next choice. This guarantees:
        - no song is repeated,
        - names within a playlist are in alphabetical order,
        - each combination is generated exactly once (no permutations), so there are no duplicate solutions.
    The running total is checked against MaxTime after every choice, so branches that exceed the limit are pruned early.

Testing Notes - Ran both public examples and compared the output with the exptected files and saw that they were correct.

Known Limitations - make_playlist/4 enumerates every valid combination, so the number of solutions grows quickly with a large database and large MaxSongs. The time bound prunes the search, but a very wide range on a big database may be slow.