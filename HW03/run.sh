#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
swipl -s main.pl -t main --quiet -- example_part1.txt part1 > result_1.txt
swipl -s main.pl -t main --quiet -- example_part2.txt part2 > result_2.txt
printf 'Wrote result_1.txt and result_2.txt\n'
