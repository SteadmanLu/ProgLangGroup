# PA2 Erlang Starter

Group members: TODO

Implemented features: TODO

Known bugs: TODO

Implement the assignment in these files:

- `src/client.erl`
- `src/coordinator.erl`
- `src/worker.erl`

The supplied `run_erlang.sh` compiles and runs the tests. Do not modify it,
`src/pa2_util.erl`, `validate_test.py`, or files under `tests/`.

Run the supplied tests from this directory:

```sh
bash run_erlang.sh 3 tests/test1
bash run_erlang.sh 4 tests/test2
bash run_erlang.sh 12 tests/test3
bash run_erlang.sh 3 tests/test4
bash run_erlang.sh 5 tests/test5
```

Tests 1--3 use concurrent mode. Tests 4--5 use distributed mode. The runner
starts and stops the required Erlang nodes.

Analysis results may be appended as they arrive. Their lines in
`results/output.txt` may appear in any order.

The runner compiles the modules, starts any Erlang nodes required by the
selected test, validates the final results and Worker files, and saves that
test's generated files under its own `output/` directory.
