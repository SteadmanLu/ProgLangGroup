-module(worker).

-export([start/2]).

%% Do not change this supplied function signature.
start(WorkerId, Coordinator) ->
    %% TODO: Perform any Worker initialization needed before reporting ready.
    Coordinator ! {worker_ready, WorkerId, self()},
    loop(WorkerId, true).

loop(WorkerId, Active) ->
    receive
        {
            analyze_chunk,
            Coordinator,
            AnalysisId,
            ChunkId,
            _FileName,
            Chunk,
            Keyword
        } when Active =:= true ->
            %% TODO: Save this chunk with pa2_util:write_chunk/4, count exact
            %% keyword matches with pa2_util:count_word/2, and return a message
            %% containing AnalysisId, ChunkId, and the partial count.
            _ = {Coordinator, AnalysisId, ChunkId, Chunk, Keyword},
            loop(WorkerId, Active);

        {deactivate, Coordinator} ->
            %% TODO: Acknowledge the command, then remain alive but inactive.
            Coordinator ! {worker_deactivated, self(), WorkerId},
            loop(WorkerId, false);

        {stop, Coordinator} ->
            %% TODO: Acknowledge before terminating this process.
            Coordinator ! {worker_stopped, self(), WorkerId},
            ok
    end.
