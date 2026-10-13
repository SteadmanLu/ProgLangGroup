#!/usr/bin/env python3
"""Validate one PA2 2026 run without requiring a canonical chunk layout.

Usage:
    python3 validate_test.py <N> <test-dir> <results-dir> <workers-dir>
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path


SEPARATORS = re.compile(br"[ \t\r\n]+")
RESULT_LINE = re.compile(rb"analysis(0|[1-9][0-9]*) (ERROR|0|[1-9][0-9]*)\n")
WORKER_DIRECTORY = re.compile(r"worker(0|[1-9][0-9]*)")
CHUNK_FILE = re.compile(r"analysis(0|[1-9][0-9]*)_chunk(0|[1-9][0-9]*)\.txt")


class InvalidTest(ValueError):
    pass


def words(data: bytes) -> tuple[bytes, ...]:
    """Split at ASCII space, tab, LF, or CR characters (including CRLF)."""
    return tuple(part for part in SEPARATORS.split(data) if part)


@dataclass(frozen=True)
class Analysis:
    analysis_id: int
    filename: str
    keyword: bytes
    source_words: tuple[bytes, ...]
    active_workers: tuple[int, ...]

    @property
    def expected_result(self) -> str:
        if not self.active_workers:
            return "ERROR"
        return str(sum(word == self.keyword for word in self.source_words))


@dataclass(frozen=True)
class Chunk:
    worker_id: int
    analysis_id: int
    chunk_id: int
    contents: tuple[bytes, ...]


def script_fields(line: str) -> list[str]:
    return [field for field in re.split(r"[ \t]+", line.rstrip("\r\n")) if field]


def read_analyses(test_directory: Path, worker_count: int) -> list[Analysis]:
    input_directory = test_directory / "input"
    script_path = input_directory / "test.script"
    try:
        script = script_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise InvalidTest(f"cannot read {script_path}: {exc}") from exc

    active = set(range(worker_count))
    analyses: list[Analysis] = []
    for line_number, line in enumerate(script.splitlines(), start=1):
        fields = script_fields(line)
        if not fields:
            continue
        if fields[0] == "i" and len(fields) == 2:
            try:
                worker_id = int(fields[1])
            except ValueError as exc:
                raise InvalidTest(
                    f"line {line_number}: invalid Worker ID {fields[1]!r}"
                ) from exc
            if worker_id < 0 or worker_id >= worker_count:
                raise InvalidTest(
                    f"line {line_number}: Worker ID must be in 0..{worker_count - 1}"
                )
            active.discard(worker_id)
            continue
        if fields[0] == "a" and len(fields) == 3:
            filename, keyword_text = fields[1], fields[2]
            data_path = (input_directory / filename).resolve()
            try:
                data_path.relative_to(input_directory.resolve())
            except ValueError as exc:
                raise InvalidTest(
                    f"line {line_number}: data file leaves the input directory"
                ) from exc
            try:
                data = data_path.read_bytes()
            except OSError as exc:
                raise InvalidTest(
                    f"line {line_number}: cannot read {filename!r}: {exc}"
                ) from exc
            keyword = keyword_text.encode("utf-8")
            if not keyword or SEPARATORS.search(keyword):
                raise InvalidTest(f"line {line_number}: keyword must be one word")
            analyses.append(
                Analysis(
                    len(analyses),
                    filename,
                    keyword,
                    words(data),
                    tuple(sorted(active)),
                )
            )
            continue
        raise InvalidTest(
            f"line {line_number}: expected 'a <FileName> <Keyword>' or 'i <WorkerId>'"
        )
    return analyses


def check_results(
    results_directory: Path, analyses: list[Analysis], issues: list[str]
) -> None:
    output_path = results_directory / "output.txt"
    if not results_directory.is_dir():
        issues.append("missing results directory")
        return
    if not output_path.is_file():
        issues.append("missing results/output.txt")
        return

    data = output_path.read_bytes()
    actual: list[tuple[int, str]] = []
    offset = 0
    while offset < len(data):
        match = RESULT_LINE.match(data, offset)
        if match is None:
            issues.append(
                "results/output.txt must contain only exact lines "
                "'analysis<ID> <COUNT|ERROR>\\n' with canonical decimal integers"
            )
            return
        actual.append((int(match.group(1)), match.group(2).decode("ascii")))
        offset = match.end()

    expected = [
        (analysis.analysis_id, analysis.expected_result) for analysis in analyses
    ]
    if sorted(actual, key=lambda record: record[0]) != expected:
        issues.append(
            f"results/output.txt: expected {expected} in any line order, "
            f"found {actual}"
        )


def read_chunks(
    workers_directory: Path,
    worker_count: int,
    analysis_count: int,
    issues: list[str],
) -> dict[int, list[Chunk]]:
    chunks: dict[int, list[Chunk]] = {
        analysis_id: [] for analysis_id in range(analysis_count)
    }
    if not workers_directory.is_dir():
        issues.append("missing workers directory")
        return chunks

    seen_workers: set[int] = set()
    for worker_path in sorted(workers_directory.iterdir(), key=lambda item: item.name):
        if worker_path.name == ".DS_Store":
            continue
        worker_match = WORKER_DIRECTORY.fullmatch(worker_path.name)
        if worker_match is None or not worker_path.is_dir():
            issues.append(f"unexpected workers entry: {worker_path.name}")
            continue
        worker_id = int(worker_match.group(1))
        if worker_id >= worker_count:
            issues.append(f"unexpected Worker directory: worker{worker_id}")
            continue
        seen_workers.add(worker_id)

        for chunk_path in sorted(worker_path.iterdir(), key=lambda item: item.name):
            if chunk_path.name == ".DS_Store":
                continue
            chunk_match = CHUNK_FILE.fullmatch(chunk_path.name)
            if chunk_match is None or not chunk_path.is_file():
                issues.append(
                    f"unexpected Worker entry: {worker_path.name}/{chunk_path.name}"
                )
                continue
            analysis_id = int(chunk_match.group(1))
            chunk_id = int(chunk_match.group(2))
            if analysis_id >= analysis_count:
                issues.append(
                    f"{worker_path.name}/{chunk_path.name} uses a nonexistent analysis ID"
                )
                continue

            data = chunk_path.read_bytes()
            chunk_words = words(data)
            if not chunk_words or data != b" ".join(chunk_words):
                issues.append(
                    f"{worker_path.name}/{chunk_path.name} is not normalized nonempty text"
                )
            chunks[analysis_id].append(
                Chunk(worker_id, analysis_id, chunk_id, chunk_words)
            )

    missing_workers = sorted(set(range(worker_count)) - seen_workers)
    if missing_workers:
        issues.append(f"missing Worker directories: {missing_workers}")
    return chunks


def check_chunks(
    analyses: list[Analysis],
    chunks: dict[int, list[Chunk]],
    issues: list[str],
) -> None:
    for analysis in analyses:
        assigned = chunks[analysis.analysis_id]
        ordered = sorted(assigned, key=lambda chunk: chunk.chunk_id)
        actual_ids = sorted(chunk.chunk_id for chunk in assigned)
        expected_ids = list(range(len(assigned)))
        if actual_ids != expected_ids or len(set(actual_ids)) != len(actual_ids):
            issues.append(
                f"analysis{analysis.analysis_id}: chunk IDs must occur exactly once "
                f"and be contiguous from 0; found {actual_ids}"
            )

        if not analysis.active_workers:
            if assigned:
                issues.append(
                    f"analysis{analysis.analysis_id}: no Worker was active, so no chunks are allowed"
                )
            continue

        if analysis.source_words and not assigned:
            issues.append(
                f"analysis{analysis.analysis_id}: nonempty input requires at least one chunk"
            )
        if not analysis.source_words and assigned:
            issues.append(
                f"analysis{analysis.analysis_id}: empty input must produce zero chunks"
            )

        reconstructed = tuple(word for chunk in ordered for word in chunk.contents)
        if reconstructed != analysis.source_words:
            issues.append(
                f"analysis{analysis.analysis_id}: chunks do not reconstruct "
                f"{analysis.filename} in word order"
            )

        active = set(analysis.active_workers)
        loads = {worker_id: 0 for worker_id in analysis.active_workers}
        for chunk in assigned:
            if chunk.worker_id not in active:
                issues.append(
                    f"analysis{analysis.analysis_id}: chunk{chunk.chunk_id} is on "
                    f"inactive worker{chunk.worker_id}"
                )
            else:
                loads[chunk.worker_id] += len(chunk.contents)
        if loads and max(loads.values()) - min(loads.values()) > 1:
            issues.append(
                f"analysis{analysis.analysis_id}: Worker word loads are not balanced: {loads}"
            )


def validate(
    worker_count: int,
    test_directory: Path,
    results_directory: Path,
    workers_directory: Path,
) -> list[str]:
    if worker_count < 1:
        raise InvalidTest("N must be at least 1")
    analyses = read_analyses(test_directory, worker_count)
    issues: list[str] = []
    check_results(results_directory, analyses, issues)
    chunks = read_chunks(
        workers_directory, worker_count, len(analyses), issues
    )
    check_chunks(analyses, chunks, issues)
    return issues


def main(arguments: list[str]) -> int:
    if len(arguments) != 4:
        print(
            "Usage: python3 validate_test.py "
            "<N> <test-dir> <results-dir> <workers-dir>",
            file=sys.stderr,
        )
        return 2
    try:
        worker_count = int(arguments[0])
    except ValueError:
        print("VALIDATOR ERROR: N must be an integer", file=sys.stderr)
        return 2

    try:
        issues = validate(
            worker_count,
            Path(arguments[1]),
            Path(arguments[2]),
            Path(arguments[3]),
        )
    except InvalidTest as exc:
        print(f"VALIDATOR ERROR: {exc}", file=sys.stderr)
        return 2
    except OSError as exc:
        print(f"VALIDATOR ERROR: {exc}", file=sys.stderr)
        return 2

    if issues:
        print("FAIL")
        for issue in issues:
            print(f"- {issue}")
        return 1
    print("PASS: results and Worker files are valid.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
