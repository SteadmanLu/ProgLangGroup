#!/usr/bin/env bash

set -eo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: bash run_erlang.sh <N> <test-directory>" >&2
    exit 1
fi

if ! command -v erlc >/dev/null 2>&1 || ! command -v erl >/dev/null 2>&1; then
    echo "Erlang/OTP is required (commands: erlc and erl)." >&2
    exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "Python 3 is required to run the test validator." >&2
    exit 1
fi

num_workers="$1"
case "$num_workers" in
    ''|*[!0-9]*)
        echo "N must be an integer." >&2
        exit 1
        ;;
esac
if [ "$num_workers" -lt 1 ]; then
    echo "N must be at least 1." >&2
    exit 1
fi

root_directory="$(cd "$(dirname "$0")" && pwd)"
case "$2" in
    /*) test_directory="$2" ;;
    *) test_directory="$root_directory/$2" ;;
esac

input_directory="$test_directory/input"
script_file="$input_directory/test.script"
nodes_file="$input_directory/nodes.txt"
test_output_directory="$test_directory/output"
result_file="$root_directory/results/output.txt"
build_directory="$root_directory/.erlang_build"
cookie="${PA2_ERLANG_COOKIE:-pa2_2026}"

for required_file in "$script_file" "$nodes_file" \
                     "$root_directory/validate_test.py"; do
    if [ ! -f "$required_file" ]; then
        echo "Missing required file: $required_file" >&2
        exit 1
    fi
done

if [[ ! "$cookie" =~ ^[A-Za-z0-9_][A-Za-z0-9_@.-]*$ ]]; then
    echo "PA2_ERLANG_COOKIE contains unsupported characters." >&2
    exit 1
fi

short_hostname="$(hostname -s 2>/dev/null || hostname)"
reported_hostname="$(hostname 2>/dev/null || printf '%s' "$short_hostname")"
controller_long_host="$(hostname -f 2>/dev/null || true)"
if [[ "$controller_long_host" != *.* ]] && [[ "$reported_hostname" == *.* ]]; then
    controller_long_host="$reported_hostname"
fi

node_lines=()
saw_short_name=0
saw_long_name=0
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    node_line="$(printf '%s' "$raw_line" | tr -d '\r' | \
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$node_line" ] && continue

    case "$node_line" in
        *@*@*|@*|*@)
            echo "Invalid Erlang node name: $node_line" >&2
            exit 1
            ;;
        *@*) ;;
        *)
            echo "Invalid Erlang node name: $node_line" >&2
            exit 1
            ;;
    esac

    node_short="${node_line%%@*}"
    node_host="${node_line#*@}"
    if [[ ! "$node_short" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] || \
       [[ ! "$node_host" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
        echo "Invalid Erlang node name: $node_line" >&2
        exit 1
    fi

    node_lines+=("$node_line")
    case "$node_host" in
        localhost|127.0.0.1)
            # Local aliases work in either mode and do not determine it.
            ;;
        *.*)
            saw_long_name=1
            ;;
        *)
            saw_short_name=1
            ;;
    esac
done < "$nodes_file"

nonempty_node_count="${#node_lines[@]}"
if [ "$nonempty_node_count" -ne 0 ] && \
   [ "$nonempty_node_count" -ne "$num_workers" ]; then
    echo "nodes.txt must be empty or contain exactly N node names." >&2
    exit 1
fi
if [ "$saw_short_name" -eq 1 ] && [ "$saw_long_name" -eq 1 ]; then
    echo "nodes.txt must not mix short and long Erlang node names." >&2
    exit 1
fi

naming_mode="short"
node_name_option="-sname"
controller_node_name="pa2_controller_$$"
cleanup_controller_node_name="pa2_cleanup_$$"
if [ "$saw_long_name" -eq 1 ]; then
    naming_mode="long"
    node_name_option="-name"
    if [[ "$controller_long_host" != *.* ]]; then
        echo "Long-name mode requires a fully qualified controller hostname." >&2
        exit 1
    fi
    controller_node_name="pa2_controller_$$@$controller_long_host"
    cleanup_controller_node_name="pa2_cleanup_$$@$controller_long_host"
fi

cd "$root_directory"
rm -rf "$build_directory" "$root_directory/workers" \
       "$root_directory/results" "$root_directory/logs"
mkdir -p "$build_directory" "$root_directory/workers" \
         "$root_directory/results" "$root_directory/logs"

erlc -o "$build_directory" "$root_directory"/src/*.erl

started_nodes_file="$build_directory/started_nodes.txt"
: > "$started_nodes_file"
cleanup_needed=1

cleanup_started_nodes() {
    cleanup_status=$?
    trap - EXIT INT TERM
    set +e

    if [ "$cleanup_needed" -eq 1 ] && [ -s "$started_nodes_file" ]; then
        started_node_count="$(awk 'NF { count++ } END { print count + 0 }' \
            "$started_nodes_file")"
        PA2_CLEANUP_N="$started_node_count" \
        PA2_CLEANUP_LOCATIONS="$started_nodes_file" \
        erl -noshell "$node_name_option" "$cleanup_controller_node_name" \
            -setcookie "$cookie" -pa "$build_directory" -eval '
                N = list_to_integer(os:getenv("PA2_CLEANUP_N")),
                Locations = os:getenv("PA2_CLEANUP_LOCATIONS"),
                Nodes = pa2_util:read_nodes(Locations, N),
                case pa2_util:stop_nodes_after_start_attempts(Nodes) of
                    ok -> ok;
                    {error, StillRunning} ->
                        io:format(
                            standard_error,
                            "Warning: nodes still running: ~p~n",
                            [StillRunning]
                        )
                end,
                halt(0).
            ' || true
    fi

    exit "$cleanup_status"
}

trap cleanup_started_nodes EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ "$nonempty_node_count" -gt 0 ]; then
    printf -v quoted_root '%q' "$root_directory"
    printf -v quoted_build '%q' "$build_directory"
    printf -v quoted_cookie '%q' "$cookie"

    for node_line in "${node_lines[@]}"; do
        node_short="${node_line%%@*}"
        node_host="${node_line#*@}"
        worker_node_name="$node_short"
        if [ "$naming_mode" = "long" ]; then
            worker_node_name="$node_line"
            case "$node_host" in
                localhost|127.0.0.1)
                    worker_node_name="$node_short@$controller_long_host"
                    ;;
            esac
        fi

        # Record the target before launch so the EXIT trap also covers a
        # detached VM that starts just as the launch command is interrupted.
        printf '%s\n' "$node_line" >> "$started_nodes_file"

        case "$node_host" in
            localhost|127.0.0.1|"$short_hostname"|"$reported_hostname"|"$controller_long_host")
                erl -noshell -detached "$node_name_option" "$worker_node_name" \
                    -setcookie "$cookie" -pa "$build_directory"
                ;;
            *)
                if ! command -v ssh >/dev/null 2>&1; then
                    echo "ssh is required to start node $node_line." >&2
                    exit 1
                fi
                printf -v quoted_worker_node_name '%q' "$worker_node_name"
                ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$node_host" \
                    "cd $quoted_root && erl -noshell -detached $node_name_option $quoted_worker_node_name -setcookie $quoted_cookie -pa $quoted_build"
                ;;
        esac

    done

    PA2_N="$num_workers" \
    PA2_SCRIPT="$script_file" \
    PA2_OUTPUT="$result_file" \
    PA2_LOCATIONS="$nodes_file" \
    erl -noshell "$node_name_option" "$controller_node_name" \
        -setcookie "$cookie" -pa "$build_directory" -eval '
            N = list_to_integer(os:getenv("PA2_N")),
            Script = os:getenv("PA2_SCRIPT"),
            Output = os:getenv("PA2_OUTPUT"),
            Locations = os:getenv("PA2_LOCATIONS"),
            Nodes = pa2_util:read_nodes(Locations, N),
            try
                case pa2_util:wait_for_nodes(Nodes, 15000) of
                    ok -> ok;
                    {error, Missing} -> erlang:error({unreachable_nodes, Missing})
                end,
                ok = client:run(N, Script, Output, Locations)
            after
                case pa2_util:stop_nodes(Nodes) of
                    ok -> ok;
                    {error, StillRunning} ->
                        erlang:error({nodes_still_running, StillRunning})
                end
            end,
            halt(0).
        '
else
    PA2_N="$num_workers" \
    PA2_SCRIPT="$script_file" \
    PA2_OUTPUT="$result_file" \
    PA2_LOCATIONS="$nodes_file" \
    erl -noshell -pa "$build_directory" -eval '
            N = list_to_integer(os:getenv("PA2_N")),
            ok = client:run(
                N,
                os:getenv("PA2_SCRIPT"),
                os:getenv("PA2_OUTPUT"),
                os:getenv("PA2_LOCATIONS")
            ),
            halt(0).
        '
fi

# A successful controller return means its try/after completed node shutdown.
cleanup_needed=0

rm -rf "$test_output_directory"
mkdir -p "$test_output_directory"
cp -R "$root_directory/results" "$test_output_directory/results"
cp -R "$root_directory/workers" "$test_output_directory/workers"

python3 "$root_directory/validate_test.py" \
    "$num_workers" \
    "$test_directory" \
    "$test_output_directory/results" \
    "$test_output_directory/workers"

echo "The test succeeded."
