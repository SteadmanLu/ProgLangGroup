-module(pa2_util).

-export([
    append_result/3,
    count_word/2,
    ensure_worker_directories/1,
    read_nodes/2,
    reset_output/1,
    script_commands/1,
    split_chunks/2,
    stop_nodes/1,
    stop_nodes_after_start_attempts/1,
    wait_for_nodes/2,
    write_chunk/4
]).

%% This module is supplied support code. Student solutions should not need to
%% change it.

script_commands(Path) ->
    {ok, Contents} = file:read_file(Path),
    Lines = binary:split(Contents, <<"\n">>, [global]),
    commands_from_lines(Lines, []).

commands_from_lines([], Acc) ->
    lists:reverse(Acc);
commands_from_lines([Line | Rest], Acc) ->
    case tokens(Line) of
        [] -> commands_from_lines(Rest, Acc);
        Command -> commands_from_lines(Rest, [Command | Acc])
    end.

%% One valid chunking strategy is supplied for convenience. It creates at
%% most one balanced, contiguous chunk per active Worker. Other valid
%% word-aligned chunk boundaries may be implemented in student code.
split_chunks(Contents, ActiveWorkerCount) when ActiveWorkerCount >= 1 ->
    case tokens(Contents) of
        [] ->
            [];
        Words ->
            ChunkCount = min(length(Words), ActiveWorkerCount),
            balanced_chunks(Words, ChunkCount)
    end.

count_word(Chunk, Keyword) ->
    length([Word || Word <- tokens(Chunk), Word =:= Keyword]).

ensure_worker_directories(N) ->
    lists:foreach(
        fun(Id) ->
            ok = ensure_directory(worker_directory(Id))
        end,
        lists:seq(0, N - 1)
    ),
    ok.

write_chunk(_WorkerId, _AnalysisId, _ChunkId, <<>>) ->
    erlang:error(empty_chunk);
write_chunk(WorkerId, AnalysisId, ChunkId, Chunk) ->
    Directory = worker_directory(WorkerId),
    ok = ensure_directory(Directory),
    FileName = lists:flatten(
        io_lib:format("analysis~B_chunk~B.txt", [AnalysisId, ChunkId])
    ),
    Path = filename:join(Directory, FileName),
    file:write_file(Path, Chunk).

reset_output(Path) ->
    ok = ensure_parent_directory(Path),
    file:write_file(Path, <<>>).

append_result(Path, AnalysisId, error) ->
    append_result_line(Path, AnalysisId, <<"ERROR">>);
append_result(Path, AnalysisId, Count) when is_integer(Count) ->
    append_result_line(Path, AnalysisId, integer_to_binary(Count)).

read_nodes(Path, N) ->
    {ok, Contents} = file:read_file(Path),
    Lines = binary:split(Contents, <<"\n">>, [global]),
    Names = [
        binary_to_list(Trimmed)
        || Line <- Lines,
           Trimmed <- [trim(Line)],
           Trimmed =/= <<>>
    ],
    case Names of
        [] ->
            [];
        _ when length(Names) =:= N ->
            [normalize_node_name(Name) || Name <- Names];
        _ ->
            erlang:error({invalid_node_count, N, length(Names)})
    end.

wait_for_nodes([], _TimeoutMs) ->
    ok;
wait_for_nodes(Nodes, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_for_nodes_until(Nodes, Deadline).

wait_for_nodes_until(Nodes, Deadline) ->
    Missing = [Node || Node <- Nodes, net_adm:ping(Node) =/= pong],
    case Missing of
        [] ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, Missing};
                false ->
                    timer:sleep(100),
                    wait_for_nodes_until(Missing, Deadline)
            end
    end.

stop_nodes(Nodes) ->
    lists:foreach(
        fun(Node) ->
            rpc:cast(Node, init, stop, [])
        end,
        Nodes
    ),
    Deadline = erlang:monotonic_time(millisecond) + 5000,
    wait_for_nodes_down(Nodes, Deadline).

stop_nodes_after_start_attempts(Nodes) ->
    CleanupDeadline = erlang:monotonic_time(millisecond) + 5000,
    stop_attempted_nodes_until(Nodes, CleanupDeadline).

%% A detached VM may still be starting when the runner begins cleanup. Keep
%% checking every attempted node for the entire cleanup window; an early pang
%% therefore cannot hide a VM that becomes reachable a moment later.
stop_attempted_nodes_until(Nodes, CleanupDeadline) ->
    Running = [Node || Node <- Nodes, net_adm:ping(Node) =:= pong],
    lists:foreach(
        fun(Node) ->
            rpc:cast(Node, init, stop, [])
        end,
        Running
    ),
    case erlang:monotonic_time(millisecond) >= CleanupDeadline of
        true ->
            case Running of
                [] -> ok;
                _ -> {error, Running}
            end;
        false ->
            timer:sleep(100),
            stop_attempted_nodes_until(Nodes, CleanupDeadline)
    end.

wait_for_nodes_down(Nodes, Deadline) ->
    StillRunning = [Node || Node <- Nodes, net_adm:ping(Node) =:= pong],
    case StillRunning of
        [] ->
            ok;
        _ ->
            case erlang:monotonic_time(millisecond) >= Deadline of
                true -> {error, StillRunning};
                false ->
                    timer:sleep(100),
                    wait_for_nodes_down(StillRunning, Deadline)
            end
    end.

tokens(Contents) ->
    Separators = [<<" ">>, <<"\t">>, <<"\r">>, <<"\n">>],
    [Part || Part <- binary:split(Contents, Separators, [global]), Part =/= <<>>].

join_words([]) ->
    <<>>;
join_words(Words) ->
    iolist_to_binary(lists:join(<<" ">>, Words)).

balanced_chunks(Words, ChunkCount) ->
    WordCount = length(Words),
    MinimumSize = WordCount div ChunkCount,
    LargerChunkCount = WordCount rem ChunkCount,
    balanced_chunks(
        Words,
        ChunkCount,
        MinimumSize,
        LargerChunkCount,
        []
    ).

balanced_chunks([], 0, _MinimumSize, _LargerChunkCount, Acc) ->
    lists:reverse(Acc);
balanced_chunks(Words, Remaining, MinimumSize, LargerChunkCount, Acc) ->
    Extra = case LargerChunkCount > 0 of
        true -> 1;
        false -> 0
    end,
    Size = MinimumSize + Extra,
    {ChunkWords, Rest} = lists:split(Size, Words),
    balanced_chunks(
        Rest,
        Remaining - 1,
        MinimumSize,
        max(0, LargerChunkCount - 1),
        [join_words(ChunkWords) | Acc]
    ).

worker_directory(Id) ->
    filename:join("workers", "worker" ++ integer_to_list(Id)).

ensure_parent_directory(Path) ->
    Parent = filename:dirname(Path),
    ensure_directory(Parent).

ensure_directory(Path) ->
    Placeholder = filename:join(Path, ".keep"),
    case filelib:ensure_dir(Placeholder) of
        ok -> ok;
        {error, eexist} -> ok;
        Error -> Error
    end.

append_line(Path, Line) ->
    ok = ensure_parent_directory(Path),
    file:write_file(Path, [Line, <<"\n">>], [append]).

append_result_line(Path, AnalysisId, Value) ->
    Line = iolist_to_binary([
        <<"analysis">>,
        integer_to_binary(AnalysisId),
        <<" ">>,
        Value
    ]),
    append_line(Path, Line).

trim(Binary) ->
    list_to_binary(string:trim(binary_to_list(Binary))).

normalize_node_name(Name) ->
    case string:split(Name, "@", all) of
        [ShortName, Host] ->
            NormalizedHost = case Host of
                "localhost" -> controller_host();
                "127.0.0.1" -> controller_host();
                _ -> Host
            end,
            list_to_atom(ShortName ++ "@" ++ NormalizedHost);
        _ ->
            erlang:error({invalid_node_name, Name})
    end.

controller_host() ->
    case string:split(atom_to_list(node()), "@", all) of
        [_Name, Host] -> Host;
        _ -> net_adm:localhost()
    end.
