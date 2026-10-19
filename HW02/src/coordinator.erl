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
            %% Get the pending analysis that matches this result's analysis ID.
            %% This is important because results from different analyses can arrive
            %% in any order.
            Entry = maps:get(ResultAnalysisId, Pending),

            %% Extract the client, expected number of chunks, and results received so far.
            #{client := Client, expected := Expected, results := Results} = Entry,

            %% Store the new chunk's count using its ChunkId as the map key.
            %% If this chunk was already received, its previous count is replaced.
            NewResults = Results#{ChunkId => Count},

            %% Update the analysis entry with the newly received results.
            NewEntry = Entry#{results => NewResults},

            %% Update the Pending map with the modified analysis entry.
            NewPending = Pending#{ResultAnalysisId => NewEntry},

            if
                %% Check whether all expected unique chunk results have arrived.
                map_size(NewResults) =:= Expected ->

                    %% Add together the counts from all received chunks.
                    TotalCount = lists:sum(maps:values(NewResults)),

                    %% Send the final total and analysis ID back to the client.
                    Client ! {analysis_result, self(), ResultAnalysisId, TotalCount},

                    %% Remove the completed analysis from Pending and continue the loop.
                    loop(AnalysisId, Workers, maps:remove(ResultAnalysisId, NewPending));

                true ->
                    %% More chunk results are expected, so keep waiting for messages.
                    loop(AnalysisId, Workers, NewPending)
            end;


        {deactivate, Client, WorkerId} ->
            %% Find the worker with the requested ID in the Workers list.
            %% If it is active, tell it to deactivate and wait for its acknowledgement.
            W = lists:keyfind(WorkerId, #worker_info.id, Workers),

            %% Check whether the worker is currently active.
            case W#worker_info.active of
                true ->
                    %% Send the worker a message requesting deactivation.
                    W#worker_info.pid ! {deactivate, self()},

                    %% Wait until the worker confirms that it has deactivated.
                    receive
                        {worker_deactivated, _WorkerPid, WorkerId} ->

                            %% Update the matching worker's active status to false.
                            %% Leave all other workers unchanged.
                            NewWorkers = [if W#worker_info.id =:= WorkerId ->
                                               W#worker_info{active = false};
                                           true -> W
                                       end || W <- Workers],

                            %% Notify the client that deactivation is complete.
                            Client ! {deactivated, self(), WorkerId},

                            %% Continue the loop with the updated worker list.
                            loop(AnalysisId, NewWorkers, Pending)
                    end;

                false ->
                    %% The worker is already inactive, so no message to the worker
                    %% is needed. Repeated deactivation requests are still valid.
                    Client ! {deactivated, self(), WorkerId},

                    %% Continue without changing the worker list.
                    loop(AnalysisId, Workers, Pending)
            end;

        {stop, Client} ->
            %% Send a stop request to every worker.
            lists:foreach(fun(W) -> W#worker_info.pid ! {stop, self()} end, Workers),

            %% Wait for each worker to confirm that it has stopped.
            %% Match both the PID and ID so each acknowledgement belongs
            %% to the correct worker.
            lists:foreach(
                fun(#worker_info{id = Id, pid = Pid}) ->
                    receive
                        {worker_stopped, Pid, Id} -> ok
                    end
                end, Workers),

            %% Tell the client that the coordinator has stopped.
            Client ! {coordinator_stopped, self()},

            %% Return ok to finish the coordinator process.
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