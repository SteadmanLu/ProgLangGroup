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

        %% A Worker reports the partial count for one chunk of one analysis.
        %% The IDs in the message let us credit the count to the right analysis,
        %% even when results from several analyses arrive interleaved.
        {chunk_result, _WorkerPid, ResultAnalysisId, ChunkId, Count} ->
            %% Look up the bookkeeping note for the analysis this result belongs to.
            Entry = maps:get(ResultAnalysisId, Pending),
            %% Pull out the Client to reply to, the number of chunks we sent out,
            %% and the counts received so far (a map of ChunkId => Count).
            #{client := Client, expected := Expected, results := Results} = Entry,
            %% Record this chunk's count. Keying by ChunkId means a repeated
            %% result for the same chunk overwrites itself instead of being
            %% counted twice, so only unique chunk results are tallied.
            NewResults = Results#{ChunkId => Count},
            %% Variables can't be changed, so build an updated entry and an
            %% updated Pending map that contains it.
            NewEntry = Entry#{results => NewResults},
            NewPending = Pending#{ResultAnalysisId => NewEntry},
            if
                %% Every chunk has reported: this analysis is complete.
                map_size(NewResults) =:= Expected ->
                    %% Sum only this analysis's partial counts.
                    TotalCount = lists:sum(maps:values(NewResults)),
                    %% Send the one final result for this analysis to the Client.
                    Client ! {analysis_result, self(), ResultAnalysisId, TotalCount},
                    %% Drop the finished analysis from Pending, then keep looping.
                    %% AnalysisId is unchanged because this starts no new analysis.
                    loop(AnalysisId, Workers, maps:remove(ResultAnalysisId, NewPending));
                %% Still waiting on other chunks: save the updated counts and
                %% go back to the loop so other messages can be handled.
                true ->
                    loop(AnalysisId, Workers, NewPending)
            end;

        %% The Client asks to permanently deactivate a Worker. The Client blocks
        %% until it gets our reply, so this acts as a barrier: no later command
        %% is processed until the Worker is marked inactive.
        {deactivate, Client, WorkerId} ->
            %% Find this Worker's record in the list.
            W = lists:keyfind(WorkerId, #worker_info.id, Workers),
            case W#worker_info.active of
                %% Currently active: tell the Worker and wait for its
                %% acknowledgement before releasing the Client.
                true ->
                    W#worker_info.pid ! {deactivate, self()},
                    receive
                        {worker_deactivated, _WorkerPid, WorkerId} ->
                            %% Build a new Workers list identical to the old one
                            %% except that this Worker's active flag is false.
                            %% Later analyses take their snapshot from this list,
                            %% so they will skip this Worker.
                            NewWorkers = [if W#worker_info.id =:= WorkerId ->
                                               W#worker_info{active = false};
                                           true -> W
                                       end || W <- Workers],
                            %% Acknowledge to the Client, releasing the barrier.
                            Client ! {deactivated, self(), WorkerId},
                            %% Pending is untouched, so chunks already sent to this
                            %% Worker still complete and count toward their analyses.
                            loop(AnalysisId, NewWorkers, Pending)
                    end;
                %% Already inactive: repeated deactivation is valid and has no
                %% further effect, so just acknowledge without messaging the Worker.
                false ->
                    Client ! {deactivated, self(), WorkerId},
                    loop(AnalysisId, Workers, Pending)
            end;

        %% The Client asks for shutdown, after all results have been collected.
        {stop, Client} ->
            %% Tell every Worker to stop, active or not. Sending to all of them
            %% first lets them shut down in parallel.
            lists:foreach(fun(W) -> W#worker_info.pid ! {stop, self()} end, Workers),
            %% Then wait for one acknowledgement per Worker. Each receive matches
            %% a specific Worker's pid and ID, so arrival order doesn't matter.
            lists:foreach(
                fun(#worker_info{id = Id, pid = Pid}) ->
                    receive
                        {worker_stopped, Pid, Id} -> ok
                    end
                end, Workers),
            %% Every Worker has stopped, so it is now accurate to tell the Client.
            Client ! {coordinator_stopped, self()},
            %% No loop call here: returning ends the Coordinator process.
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