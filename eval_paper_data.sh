#!/usr/bin/env bash
# Standalone launcher; requires bash and Python 3.8+ (standard library only).
set -euo pipefail
exec python3 -B - "$0" "$@" <<'PY'
import argparse
import csv
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal


UTIL = {'superblue1': '0.8', 'superblue3': '0.87', 'superblue4': '0.9',
        'superblue5': '0.85', 'superblue7': '0.9', 'superblue10': '0.87',
        'superblue16': '0.85', 'superblue18': '0.85'}
# Limits in micrometers, matching the ICCAD15 superblue*-long.rsyn settings.
MAX_DISPLACEMENT_UM = {
    'superblue1': '400', 'superblue3': '400', 'superblue4': '400',
    'superblue5': '400', 'superblue7': '500', 'superblue10': '500',
    'superblue16': '400', 'superblue18': '400',
}
METRICS = ('eWNS_ps', 'eTNS_ps', 'lWNS_ns', 'lTNS_ns', 'STWL_um', 'HPWL_um')


def parse_metrics(text):
    values = []
    for pattern in (r'early WNS, TNS\s*:\s*([^,\n]+),\s*([^\n]+)',
                    r'late\s+WNS, TNS\s*:\s*([^,\n]+),\s*([^\n]+)',
                    r'HPWL, StWL \(um\)\s*:\s*([^,\n]+),\s*([^\n]+)'):
        matches = re.findall(pattern, text)
        if len(matches) != 1:
            raise ValueError('Missing or repeated evaluator metrics: ' + pattern)
        values.extend(Decimal(value.strip()) for value in matches[0])
    if not all(value.is_finite() for value in values):
        raise ValueError('Non-finite timing or wirelength result')
    # The evaluator prints every slack in ps; the paper uses ns for late slacks.
    return dict(zip(METRICS, (values[0], values[1], values[2] / 1000,
                              values[3] / 1000, values[5], values[4])))


def parse_displacement(text):
    matches = re.findall(r'^\s*max displ\. \(um\)\s*:\s*([^\r\n]+)', text, re.MULTILINE)
    if len(matches) != 1:
        raise ValueError('Missing or repeated maximum displacement result')
    value = Decimal(matches[0].strip())
    if not value.is_finite() or value < 0:
        raise ValueError('Invalid maximum displacement result')
    return value


def main():
    launcher = Path(sys.argv[1]).resolve()
    parser = argparse.ArgumentParser(
        prog=launcher.name,
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        description='Reevaluate paper DEF/OPS using benchmark/Evaluator. '
                    'Inputs are read-only; all generated files stay in OUTPUT.',
        epilog='Relative OUTPUT paths are resolved against the dataset root. '
               'All means the eight benchmarks of one method. Existing method '
               'reports are preserved: choose a new OUTPUT to rerun. '
               'Outputs: one evaluation log per benchmark and summary.csv. '
               'Maximum displacement limits: 500 um for superblue7/10; '
               '400 um for all other benchmarks. The reported displacement '
               'must be <= its limit, without tolerance. '
               'Four concurrent cases, four OpenMP threads each. Exit codes: '
               '0 evaluated successfully; 1 evaluation/input failure or displacement violation; '
               '2 invalid command-line arguments.')
    parser.add_argument('method', nargs='?', default='Ours',
                        choices=('Ours', 'Ours-CSS', 'Ours-Early-CSS'),
                        help='Method to evaluate')
    parser.add_argument('benchmark', nargs='?', default='All', choices=('All', *UTIL),
                        help='One benchmark or all eight benchmarks')
    parser.add_argument('output', nargs='?', default='./Re-confirm',
                        help='Report directory, relative to the dataset root')
    args = parser.parse_args(sys.argv[2:])
    root = next((p for p in launcher.parents
                 if (p / 'benchmark/Evaluator').is_dir()
                 and (p / 'paper-final-output').is_dir()), None)
    if root is None:
        raise ValueError('Place this script inside the data-opensource dataset tree')
    output = Path(args.output).expanduser()
    output = (root / output).resolve() if not output.is_absolute() else output.resolve()
    # Never allow evaluator artifacts to enter input or reference directories.
    protected = [root / p for p in ('benchmark', 'paper-final-output',
                                    'paper-evaluation-log')]
    if output == root or any(p == output or p in output.parents for p in protected):
        raise ValueError('OUTPUT must be a separate report directory, outside inputs')
    report_dir = output / args.method
    if report_dir.exists():
        raise ValueError(f'Reports already exist at {report_dir}; choose another OUTPUT')
    evaluator = root / 'benchmark/Evaluator'
    executable = evaluator / 'iccad2015_evaluate_solution'
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError(f'Evaluator executable is missing or not executable: {executable}')
    cases = list(UTIL) if args.benchmark == 'All' else [args.benchmark]
    limits = {benchmark: Decimal(MAX_DISPLACEMENT_UM[benchmark]) for benchmark in cases}
    if any(not limit.is_finite() or limit < 0 for limit in limits.values()):
        raise ValueError('Maximum displacement limits must be finite and nonnegative')
    inputs = [executable] + [evaluator / name for name in
                            ('ICCAD15.parm', 'POWV9.dat', 'PORT9.dat')]
    for benchmark in cases:
        origin = root / 'benchmark/Origin' / benchmark
        wrapper = origin / (benchmark + '.iccad2015')
        names = [benchmark + suffix for suffix in
                 ('.v', '.sdc', '.lef', '.def', '_Early.lib', '_Late.lib')]
        if not wrapper.is_file() or wrapper.read_text().split() != names:
            raise ValueError(f'Unexpected original-input wrapper: {wrapper}')
        inputs.extend([wrapper] + [origin / name for name in names])
        final = root / 'paper-final-output' / args.method / benchmark
        inputs.extend(final / name for name in ('final.def', 'final.ops'))
    for path in inputs:
        if not path.is_file():
            raise ValueError(f'Missing input: {path}')
    report_dir.mkdir(parents=True)
    environment = dict(os.environ, OMP_NUM_THREADS='4', OMP_THREAD_LIMIT='4', LC_ALL='C')
    print(f'Method={args.method}; benchmarks={args.benchmark}; output={output}', flush=True)
    print('Using packaged evaluator; 4 OpenMP threads per case.', flush=True)

    def evaluate(benchmark, work):
        start = time.monotonic()
        wd = work / benchmark
        wd.mkdir()
        for name in ('ICCAD15.parm', 'POWV9.dat', 'PORT9.dat'):
            (wd / name).symlink_to(evaluator / name)
        (wd / 'input').symlink_to(root / 'benchmark/Origin' / benchmark,
                                 target_is_directory=True)
        for name in ('final.def', 'final.ops'):
            (wd / name).symlink_to(root / 'paper-final-output' / args.method / benchmark / name)
        command = [str(executable), 'ICCAD15.parm', f'input/{benchmark}.iccad2015',
                   UTIL[benchmark], 'final.def', 'final.ops']
        log = report_dir / (benchmark + '.log')
        limit = limits[benchmark]
        result = {'Method': args.method, 'Benchmark': benchmark,
                  'Evaluation': 'FAILED', 'Legal': False,
                  'MaxDisplacementLimit_um': limit, 'DisplacementOK': ''}
        try:
            with log.open('w') as stream:
                stream.write(f'# OMP_NUM_THREADS=4 OMP_THREAD_LIMIT=4; target_util={UTIL[benchmark]}; '
                             f'max_displacement_limit_um={limit}\n')
                stream.flush()
                process = subprocess.run(command, cwd=wd, env=environment,
                                         stdout=stream, stderr=subprocess.STDOUT)
                stream.write(f'\n# Evaluator exit code: {process.returncode} '
                             '(normal completion returns 1)\n')
            text = log.read_text(errors='replace')
            result['ExitCode'] = process.returncode
            result['Legal'] = 'Placement is LEGAL.' in text
            displacement = parse_displacement(text)
            result['MaxDisplacement_um'] = displacement
            result['DisplacementOK'] = displacement <= limit
            with log.open('a') as stream:
                stream.write(f'# Displacement check: actual={displacement} um; limit={limit} um; '
                             f'{"PASS" if result["DisplacementOK"] else "FAIL"}\n')
            if process.returncode != 1 or not result['Legal'] or 'Timer failed' in text:
                raise ValueError('Evaluator failed or placement is illegal; see case log')
            metrics = parse_metrics(text)
            result.update(metrics)
            if not result['DisplacementOK']:
                raise ValueError(f'Maximum displacement {displacement} um exceeds limit {limit} um')
            result['Evaluation'] = 'OK'
        except (OSError, ValueError, ArithmeticError) as error:
            result['Evaluation'] = 'FAILED'
            result['Error'] = str(error)
            with log.open('a') as stream:
                stream.write(f'# Evaluation error: {error}\n')
        finally:
            legality = wd / 'check_legality.log'
            if legality.is_file():
                with log.open('a') as stream:
                    stream.write('\n# Evaluator legality details\n')
                    stream.write(legality.read_text(errors='replace'))
        result['Seconds'] = round(time.monotonic() - start, 3)
        print(f'{benchmark}: {result["Evaluation"]}; '
              f'displacement={result.get("MaxDisplacement_um", "unavailable")}/{limit} um; '
              f'{result["Seconds"]}s', flush=True)
        return result

    with tempfile.TemporaryDirectory(prefix='.eval-work-', dir=output) as temporary:
        with ThreadPoolExecutor(max_workers=min(4, len(cases))) as pool:
            completed = list(pool.map(lambda b: evaluate(b, Path(temporary)), cases))
    summary_fields = ['Method', 'Benchmark', *METRICS,
                      'MaxDisplacement_um', 'MaxDisplacementLimit_um', 'DisplacementOK',
                      'Legal', 'Evaluation',
                      'ExitCode', 'Seconds', 'Error']
    with (report_dir / 'summary.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=summary_fields)
        writer.writeheader()
        writer.writerows(completed)
    failed = sum(r['Evaluation'] != 'OK' for r in completed)
    print(f'Completed {len(cases)} cases: failed={failed}. Reports: {report_dir}')
    return 1 if failed else 0


try:
    sys.exit(main())
except (OSError, ValueError, ArithmeticError) as error:
    print(f'ERROR: {error}', file=sys.stderr)
    sys.exit(1)
PY
