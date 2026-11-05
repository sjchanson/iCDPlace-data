# iCDPlace: Final Placement Results

Due to storage limitations, the original files in the benchmark and paper-final-output directories of iCDPlace are available for download from
[Google Drive](https://drive.google.com/drive/folders/1APH9IsgAq1snn3QAXGcu38Y8qmpNLpfW?usp=drive_link).

This dataset contains the final placement solutions and official evaluation
reports for three configurations evaluated in the following paper:

**iCDPlace: Incremental Timing-Driven Placement through Integrated Clock and Data Path Optimization**  
Shijian Chen, Mingyu Chen, and Biwei Xie  
Institute of Computing Technology, Chinese Academy of Sciences; Peng Cheng
Laboratory; University of Chinese Academy of Sciences

iCDPlace is built on the open-source
[Rsyn framework](https://github.com/RsynTeam/rsyn-x).

The dataset covers eight ICCAD 2015 benchmarks and three methods, giving 24
method/benchmark pairs. Each pair provides a final DEF, its corresponding OPS,
and the official evaluator report for that solution. `result.csv` summarizes
the reported timing and wirelength metrics.

## Directory layout

```text
.
├── README.md
├── eval_paper_data.sh
├── result.csv
├── benchmark/
│   ├── Origin/<benchmark>.tar.gz
│   └── Evaluator/
├── paper-final-output/
│   └── <method>/<benchmark>.tar.gz
└── paper-evaluation-log/
    └── <method>/<benchmark>.log
```

`<method>` is `Ours`, `Ours-CSS`, or `Ours-Early-CSS`. `<benchmark>` is
`superblue1`, `superblue3`, `superblue4`, `superblue5`, `superblue7`,
`superblue10`, `superblue16`, or `superblue18`.

- `benchmark/Origin/`: original ICCAD 2015 inputs. Each archive contains a
  benchmark directory with its `.iccad2015` wrapper, Verilog netlist, DEF, LEF,
  SDC, and Early/Late Liberty files.
- `benchmark/Evaluator/`: evaluator source code, executable, parameter file,
  timing library, and FLUTE lookup tables.
- `paper-final-output/`: final solutions for the three methods. Each archive
  contains `<benchmark>/final.def` and `<benchmark>/final.ops`.
- `paper-evaluation-log/`: reference evaluation logs for all 24 solutions.
- `result.csv`: timing and Steiner wirelength metrics summarized from the
  reference logs.
- `eval_paper_data.sh`: reevaluates selected solutions and checks their maximum
  displacement. It creates `Re-confirm/<method>/` by default, containing one
  log per evaluated benchmark and `summary.csv`.

## Re-evaluate the paper results

Run from the dataset root with Bash and Python 3.8 or later:

```bash
# Extract the original inputs and final solutions (required before evaluation).
for archive in benchmark/Origin/superblue*.tar.gz paper-final-output/*/superblue*.tar.gz; do
    tar -xzf "$archive" -C "$(dirname "$archive")"
done

# Evaluate all eight benchmarks for each method.
./eval_paper_data.sh                    # Defaults: Ours All ./Re-confirm
./eval_paper_data.sh Ours-CSS
./eval_paper_data.sh Ours-Early-CSS
```

Each method produces eight logs and `summary.csv` under `Re-confirm/<method>/`,
including the maximum displacement check. Reference results are in
`paper-evaluation-log/` and `result.csv`.

To evaluate one benchmark or choose another output directory:

```bash
./eval_paper_data.sh Ours-CSS superblue1 ./Re-confirm-single
```

Arguments are `[method] [benchmark|All] [output-directory]`. Existing method
reports are not overwritten; use a new output directory for another run.
