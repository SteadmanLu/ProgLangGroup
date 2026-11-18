Team Names - Lucas Steadman, Colin Labrie

Implementaion notes - 

Part 2: 
    total_duration/2 is a simple implementation of the sum of the durations of all the songs in a playlist. 
    make_playlist/4 songs are collected with findall/3 as Name-Duration pairs and sorted alphabetically by name. The helper predicate pick/6 then builds a playlist left to right. After choosing a song, pick_from/3 returns only the songs that come after it in the sorted list, and only those are candidates for the next choice. This guarantees:
        - no song is repeated,
        - names within a playlist are in alphabetical order,
        - each combination is generated exactly once (no permutations), so there are no duplicate solutions.
    The running total is checked against MaxTime after every choice, so branches that exceed the limit are pruned early.

Testing Notes - Ran both public examples and compared the output with the exptected files and saw that they were correct.

Known Limitations - make_playlist/4 enumerates every valid combination, so the number of solutions grows quickly with a large database and large MaxSongs. The time bound prunes the search, but a very wide range on a big database may be slow.