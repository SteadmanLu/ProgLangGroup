-module(worker).

-export([start/2]).

%% Entry point for a spawned Worker. Report readiness (with our ID, so the
%% Coordinator can store Workers in ID order), then serve requests, starting
%% in the active state.
start(WorkerId, Coordinator) ->
    Coordinator ! {worker_ready, WorkerId, self()},
    loop(WorkerId, true).

loop(WorkerId, Active) ->
    receive
        %% Handle one chunk of work from the Coordinator. This clause deliberately has
        %% no `Active` guard: a deactivated Worker must still finish chunks that were
        %% dispatched by earlier analyses.
        {analyze_chunk, Coordinator, AnalysisId, ChunkId, _FileName, Chunk, Keyword} ->
            %% Persist the chunk as workers/worker<Id>/analysis<A>_chunk<C>.txt.
            %% Matching on `ok` crashes the Worker if the write fails.
            ok = pa2_util:write_chunk(WorkerId, AnalysisId, ChunkId, Chunk),

            %% Count exact, case-sensitive, whole-word matches of the keyword.
            Count = pa2_util:count_word(Chunk, Keyword),

            %% Report the partial count, tagged with analysis and chunk IDs so the
            %% Coordinator can credit it to the correct analysis.
            Coordinator ! {chunk_result, self(), AnalysisId, ChunkId, Count},

            %% Wait for the next message; state is unchanged
            loop(WorkerId, Active);

        %% Permanently deactivate this Worker. Acknowledge first so the Coordinator can
        %% release the Inactive barrier, then keep looping with Active = false. The
        %% process stays alive, and no message ever sets Active back to true.
        {deactivate, Coordinator} ->
            Coordinator ! {worker_deactivated, self(), WorkerId},
            loop(WorkerId, false);

        %% Shut down at the end of the run. Acknowledge before exiting so the
        %% Coordinator can confirm every Worker has stopped. Returning without a
        %% recursive call to loop/2 ends this process.
        {stop, Coordinator} ->
            Coordinator ! {worker_stopped, self(), WorkerId},
            ok
    end.
