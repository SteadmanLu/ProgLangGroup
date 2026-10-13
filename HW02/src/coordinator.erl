-module(coordinator).

-export([start/3]).

-record(worker_info, {
    id,
    pid,
    active = true
}).

%% Do not change this supplied function signature.
start(N, WorkerNodes, Client) ->
    %% TODO: Create N Workers. In concurrent mode WorkerNodes is empty and
    %% every Worker is local. In distributed mode, Worker i must be spawned on
    %% element i of WorkerNodes. Store Workers in ascending ID order.
    Workers = create_workers(N, WorkerNodes),

    %% TODO: Wait for all Workers to report ready before notifying the Client.
    Client ! {coordinator_ready, self()},
    loop(0, Workers, #{}).

loop(AnalysisId, Workers, Pending) ->
    receive
        {analyze, Client, FileName, Contents, Keyword} ->
            %% TODO:
            %% 1. Form the active-Worker list in Worker-ID order.
            %% 2. If it is empty, return error.
            %% 3. Otherwise choose valid, nonempty, word-aligned chunk
            %%    boundaries. Empty input produces no chunks and count 0.
            %% 4. Distribute the chunks across the active Workers so the work
            %%    is reasonably balanced, then send them asynchronously.
            %% 5. Record this analysis in Pending and return to this receive
            %%    loop immediately; do not wait for its chunks here.
            %% AnalysisId increases even when the result is error.
            _ = {FileName, Contents, Keyword},
            Client ! {analysis_result, self(), AnalysisId, error},
            loop(AnalysisId + 1, Workers, Pending);

        {chunk_result, _WorkerPid, ResultAnalysisId, ChunkId, Count} ->
            %% TODO: Update the matching Pending analysis. Once every unique
            %% chunk result has arrived, send the total and analysis ID to its
            %% Client. Results from different analyses may be interleaved.
            _ = {ResultAnalysisId, ChunkId, Count},
            loop(AnalysisId, Workers, Pending);

        {deactivate, Client, WorkerId} ->
            %% TODO: Permanently mark WorkerId inactive. If it is currently
            %% active, notify that Worker and wait for its acknowledgement.
            %% Repeated deactivation is valid.
            Client ! {deactivated, self(), WorkerId},
            loop(AnalysisId, Workers, Pending);

        {stop, Client} ->
            %% TODO: Stop every Worker and wait for their acknowledgements.
            Client ! {coordinator_stopped, self()},
            ok
    end.

create_workers(_N, _WorkerNodes) ->
    %% Replace this placeholder. The record above is supplied for storing each
    %% Worker's ID, PID, and active state.
    _Example = #worker_info{id = 0, pid = self(), active = true},
    [].
