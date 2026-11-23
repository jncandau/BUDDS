# BUDDS: HYSPLIT trajectories of spruce budworm moths (2014-2019)

Forward HYSPLIT trajectories from 5-km cells with SBW defoliation, on the
Alliance cluster Fir. `Readme.txt` is the full documentation: read its
"CURRENT STATUS / NEXT STEPS" section first, then sections 4-7 as needed.

## Rules
- Never commit the user's email. SLURM scripts use
  `#SBATCH --mail-user=YOUR_EMAIL@example.com`; the real address is passed on
  the `sbatch` command line. Before each commit, check that
  `git grep -nE "[[:alnum:]._-]+@[[:alnum:].-]+\.[a-z]{2,}"` shows only the
  placeholder (and `noreply` attribution lines).
- Show generated SLURM batch scripts to the user before submitting them.
- Jobs run in `$SCRATCH`. `/nearline` is not mounted on compute nodes:
  `Extract_NAMS.sh` runs on a login node.
- Keep `Readme.txt` up to date (status section, history in section 8) when the
  pipeline changes.

## Locations
- Repo: `/project/6075019/jcandau/BUDDS` (GitHub: jncandau/BUDDS, SSH remote)
- Start points: `$SCRATCH/output/hysplit_start_points/`
- NAM met files: `$SCRATCH/NAMS/<YEAR>/` (from
  `~/nearline/def-cbataill/jcandau/Hysplit_data/NAMS/<YEAR>.tar`)
- Outputs: `$SCRATCH/hysplit_tdump/<YEAR>/`, `$SCRATCH/hysplit_parquet/`,
  logs `$SCRATCH/hysplit_logs/<YEAR>/`
- Backup of the outputs (scratch is purged after ~60 days):
  `/project/6075019/jcandau/BUDDS_outputs/`

## Tools
- R: `/home/jcandau/software/R-4.5.2/bin/Rscript` (sf, terra, arrow,
  data.table, ggplot2, ragg, geodata; no duckdb package). In jobs:
  `module load r/4.5.0 netcdf gdal udunits gsl`.
- HYSPLIT 5.4.2: `/home/jcandau/software/hysplit.v5.4.2.source/exec/hyts_std`
- DuckDB 2.0.1 CLI: `~/bin/duckdb` (spatial extension; `~/.duckdbrc` sets
  `LOAD spatial; SET geometry_always_xy = true;`). Example queries in
  `Example_queries.sql`.

## Gotchas
- HYSPLIT start points must satisfy `2 <= INT(x) < NX-2` (and same for y) on
  the NAM grid, or the whole run fails: `Flag_NAM_domain.R` removes the others
  (`in_nam_domain` column).
- DuckDB 2.0: GADM (EPSG:4326) vs GeoParquet (OGC:CRS84) CRS labels differ;
  cast both sides to `::GEOMETRY` before spatial predicates. `hive_types` values
  must be quoted strings. Timestamps display in local time unless
  `SET TimeZone='UTC'`.
