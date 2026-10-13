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

    %% TODO: Start one Coordinator process. Pass N, WorkerNodes, and the
    %% Client PID to it. Do not read the script until the Coordinator reports
    %% that every Worker is ready.
    _ = {N, WorkerNodes},
    Coordinator = erlang:error(todo_start_coordinator),

    Commands = pa2_util:script_commands(ScriptFile),
    InputDirectory = filename:dirname(filename:absname(ScriptFile)),
    %% TODO: Process Analyze requests without waiting for each result. An
    %% Inactive command is a barrier: wait for its acknowledgement before
    %% sending later commands. Append each analysis result when it is received
    %% and record its analysis ID. At EOF, collect every outstanding result.
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

    %% TODO: Stop the Coordinator and wait for its acknowledgement before
    %% returning from run/4.
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

    %% TODO: Send this Analyze request and continue immediately with Rest.
    %% Increment AnalysisCount; do not wait for the result here.
    _ = {Contents, Keyword},
    erlang:error({todo_analyze, Rest, Coordinator, OutputFile,
                  AnalysisCount, Results});
run_commands(
    [[<<"i">>, WorkerIdText] | Rest],
    InputDirectory,
    Coordinator,
    OutputFile,
    AnalysisCount,
    Results
) ->
    WorkerId = binary_to_integer(WorkerIdText),

    %% TODO: Ask the Coordinator to deactivate WorkerId. Wait for an
    %% acknowledgement before processing Rest. If an analysis result arrives
    %% first, append it immediately and record its analysis ID.
    erlang:error({todo_deactivate, WorkerId, Rest, InputDirectory,
                  Coordinator, OutputFile, AnalysisCount, Results});
run_commands([Invalid | _], _InputDirectory, _Coordinator, _OutputFile,
             _Count, _Results) ->
    erlang:error({invalid_command, Invalid}).

collect_results(_Coordinator, _OutputFile, _AnalysisCount, _Results) ->
    %% TODO: Receive until one result exists for every Analyze command.
    %% Append each result with pa2_util:append_result/3 as it arrives.
    erlang:error(todo_collect_results).
