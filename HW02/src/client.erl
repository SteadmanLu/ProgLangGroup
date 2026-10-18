-module(client).

-export([main/1, run/4]).

%% Do not change these supplied function signatures.
main([NText, ScriptFile, OutputFile, LocationsFile]) ->
    run(list_to_integer(NText), ScriptFile, OutputFile, LocationsFile);
main(_) ->
    erlang:error(bad_arguments).

run(N, ScriptFile, OutputFile, LocationsFile) ->
    ok = pa2_util:reset_output(OutputFile),
    ok = pa2_util:ensure_worker_directories(N),
    WorkerNodes = pa2_util:read_nodes(LocationsFile, N),

    %% Start the Coordinator on the local node, as the spec requires. Passing
    %% self() hands it the Client's pid so it knows where to send replies.
    Coordinator = spawn(coordinator, start, [N, WorkerNodes, self()]),
    %% Block until the Coordinator reports that every Worker is ready. No script
    %% command is read before this point. Matching on the bound Coordinator pid
    %% accepts the ready message only from that process.
    receive
        {coordinator_ready, Coordinator} ->
            ok
    end,

    Commands = pa2_util:script_commands(ScriptFile),
    InputDirectory = filename:dirname(filename:absname(ScriptFile)),
    {AnalysisCount, Results0} = run_commands(
        Commands,
        InputDirectory,
        Coordinator,
        OutputFile,
        0,
        #{}
    ),
    _Results = collect_results(
        Coordinator,
        OutputFile,
        AnalysisCount,
        Results0
    ),

    %% All results have been collected. Ask the Coordinator to shut down (it stops
    %% the Workers) and wait for its confirmation so run/4 does not return while
    %% any actor is still running.
    Coordinator ! {stop, self()},
    receive 
        {coordinator_stopped, Coordinator} -> ok
    end,
    ok.

run_commands([], _InputDirectory, _Coordinator, _OutputFile,
             AnalysisCount, Results) ->
    {AnalysisCount, Results};
run_commands(
    [[<<"a">>, FileName, Keyword] | Rest],
    InputDirectory,
    Coordinator,
    OutputFile,
    AnalysisCount,
    Results
) ->
    InputPath = filename:join(InputDirectory, binary_to_list(FileName)),
    {ok, Contents} = file:read_file(InputPath),

    %% Send the request and continue immediately. Analyze never waits for its
    %% result: the Coordinator reports it later as an analysis_result message,
    %% which wait_for_ack or collect_results will record.
    Coordinator ! {analyze, self(), FileName, Contents, Keyword},
    %% One more analysis is outstanding. The Coordinator assigns the analysis IDs
    %% (in the order it receives requests), so the Client only counts them.
    run_commands(Rest, InputDirectory, Coordinator, OutputFile, AnalysisCount + 1, Results);
run_commands(
    [[<<"i">>, WorkerIdText] | Rest],
    InputDirectory,
    Coordinator,
    OutputFile,
    AnalysisCount,
    Results
) ->
    WorkerId = binary_to_integer(WorkerIdText),

    %% Inactive is a barrier: ask the Coordinator to deactivate the Worker, then
    %% block until it acknowledges. No later command is sent before the ack.
    Coordinator ! {deactivate, self(), WorkerId},
    %% Results of earlier analyses may arrive while waiting; wait_for_ack records
    %% them and returns the updated results map.
    NewResults = wait_for_ack(Coordinator, WorkerId, OutputFile, Results),
    %% Inactive commands add no analysis and no output record, so AnalysisCount is
    %% unchanged. Pass NewResults (not Results) so no early result is forgotten.
    run_commands(Rest, InputDirectory, Coordinator, OutputFile,
             AnalysisCount, NewResults);
run_commands([Invalid | _], _InputDirectory, _Coordinator, _OutputFile,
             _Count, _Results) ->
    erlang:error({invalid_command, Invalid}).

%% Wait for every outstanding analysis result. Done when the map holds one
%% result per Analyze command sent. This clause is checked first, so the
%% function returns at once if all results have already arrived.
collect_results(_Coordinator, _OutputFile, AnalysisCount, Results)
    when map_size(Results) =:= AnalysisCount ->
    Results;
collect_results(Coordinator, OutputFile, AnalysisCount, Results) ->
    receive
        %% Results may arrive in any order. Append each to the output file
        %% as it comes in and record it by analysis ID.
        {analysis_result, Coordinator, AId, Res} ->
            ok = pa2_util:append_result(OutputFile, AId, Res),
            collect_results(Coordinator, OutputFile, AnalysisCount,
                            Results#{AId => Res})
    end.

%% Barrier for an Inactive command: block until the Coordinator acknowledges
%% deactivation of WorkerId. Results of earlier analyses can finish in the
%% meantime, so record them here too and return the updated results map.
wait_for_ack(Coordinator, WorkerId, OutputFile, Results) ->
    receive
        %% The acknowledgement: release the barrier.
        {deactivated, Coordinator, WorkerId} ->
            Results;
        %% An earlier analysis finished while waiting: save it, keep waiting.
        {analysis_result, Coordinator, AId, Res} ->
            ok = pa2_util:append_result(OutputFile, AId, Res),
            wait_for_ack(Coordinator, WorkerId, OutputFile,
                         Results#{AId => Res})
    end.