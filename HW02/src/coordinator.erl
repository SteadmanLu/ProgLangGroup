-module(coordinator).

-export([start/3]).

-record(worker_info, {
    id,
    pid,
    active = true
}).

%% Do not change this supplied function signature.
start(N, WorkerNodes, Client) ->
    Workers = create_workers(N, WorkerNodes),

    Client ! {coordinator_ready, self()},
    loop(0, Workers, #{}).

loop(AnalysisId, Workers, Pending) ->
    receive
        %% Handle one Analyze request from the Client. This clause never waits for
        %% partial counts: it dispatches chunks and returns to the receive loop, so
        %% later requests are accepted while earlier analyses are still running.
        {analyze, Client, _FileName, Contents, Keyword} ->
            %% Snapshot of the active Workers at this moment, in Worker-ID order.
            %% Later deactivations do not affect this analysis.
            Active = [W || W <- Workers, W#worker_info.active],
            %% Split the words into at most one balanced chunk per active Worker.
            %% No active Workers means nothing to split.
            Chunks = case Active of
                         [] -> [];
                         _  -> pa2_util:split_chunks(Contents, length(Active))
                     end,
            case {Active, Chunks} of
                %% No active Workers: report ERROR. The analysis still uses its ID.
                {[], _} ->
                    Client ! {analysis_result, self(), AnalysisId, error},
                    loop(AnalysisId + 1, Workers, Pending);
                %% File has no words: the count is 0 and no chunks are created, so
                %% there is nothing to track in Pending.
                {_, []} ->
                    Client ! {analysis_result, self(), AnalysisId, 0},
                    loop(AnalysisId + 1, Workers, Pending);
                %% Normal case: send chunk i to the i-th active Worker. If there are
                %% fewer chunks than Workers, the extras receive nothing, which still
                %% satisfies the balanced-load rule (loads differ by at most 1).
                _ ->
                    Targets = lists:sublist(Active, length(Chunks)),
                    Numbered = lists:zip3(lists:seq(0, length(Chunks) - 1),
                                          Chunks, Targets),
                    lists:foreach(
                        fun({ChunkId, Chunk, W}) ->
                            W#worker_info.pid !
                                {analyze_chunk, self(), AnalysisId, ChunkId,
                                 <<>>, Chunk, Keyword}
                        end, Numbered),
                    %% Track this analysis so chunk_result can match replies to it
                    %% by analysis ID, independently of any other running analysis.
                    Entry = #{client => Client,
                              expected => length(Chunks),
                              results => #{}},
                    loop(AnalysisId + 1, Workers, Pending#{AnalysisId => Entry})
            end;

        {chunk_result, _WorkerPid, ResultAnalysisId, ChunkId, Count} ->
            Entry = maps:get(ResultAnalysisId, Pending),
            %% TODO: Update the matching Pending analysis. Once every unique
            %% chunk result has arrived, send the total and analysis ID to its
            %% Client. Results from different analyses may be interleaved.
            _ = {ResultAnalysisId, ChunkId, Count},
            loop(AnalysisId, Workers, Pending);

        {deactivate, Client, WorkerId} ->
            %% TODO: Permanently mark WorkerId inactive. If it is currently
            %% active, notify that Worker and wait for its acknowledgement.
            %% Repeated deactivation is valid.
            W=lists:keyfind(WorkerId, #worker_info.id, Workers),
             case W#worker_info.active of
                true ->
                    W#worker_info.pid ! {deactivate, self()},
                    receive
                        {worker_deactivated, _WorkerPid, WorkerId} -> ok
                    end;
                false ->
                    ok
            end,
            NewWorkers = [case X#worker_info.id of
                            WorkerId -> X#worker_info{active = false};
                            _        -> X
                        end || X <- Workers],
            Client ! {deactivated, self(), WorkerId},
            loop(AnalysisId, NewWorkers, Pending);

        {stop, Client} ->
            lists:foreach(fun(W) -> W#worker_info.pid ! {stop, self()} end, Workers),
            lists:foreach(
                fun(#worker_info{id = Id, pid = Pid}) ->
                    receive
                        {worker_stopped, Pid, Id} -> ok
                    end
                end, Workers),
            Client ! {coordinator_stopped, self()},
            ok
    end.

%% Create N Workers and return their records in Worker-ID order. Returns only
%% after every Worker has reported ready, so the caller can safely tell the
%% Client that initialization is complete.
create_workers(N, WorkerNodes) ->
    Coordinator = self(),
    Ids = lists:seq(0, N - 1),
    %% Start all Workers first so they initialize in parallel.
    lists:foreach(fun(Id) -> spawn_worker(Id, WorkerNodes, Coordinator) end, Ids),
    %% Collect one ready message per Worker, by ID. Selective receive holds
    %% out-of-order arrivals in the mailbox, so the result is in ID order.
    [receive
        {worker_ready, Id, Pid} -> #worker_info{id = Id, pid = Pid}
    end || Id<- Ids].

%% Spawn one Worker. An empty node list means concurrent mode (local spawn).
%% Otherwise Worker Id runs on the Id-th node of the list (lists:nth is
%% 1-indexed, hence Id + 1).
spawn_worker(Id, [], Coordinator) ->
    spawn(worker, start, [Id, Coordinator]);
spawn_worker(Id, WorkerNodes, Coordinator) ->
    Node = lists:nth(Id + 1, WorkerNodes),
    spawn(Node, worker, start, [Id, Coordinator]).