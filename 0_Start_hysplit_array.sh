#!/bin/bash
#
# Write the SLURM array batch script that runs the HYSPLIT trajectories for one year
# (and optionally one release height). The batch script is written but NOT submitted:
# check it, then submit it with sbatch.
#
# One array task = one day (62 per year, June 21 to August 21), i.e. the 11 start
# times of that day (16:00 to 21:00 EDT = 20:00 to 01:00 UTC).
# Each task, on node-local disk (${SLURM_TMPDIR}):
#   1. writes the CONTROL files of its 11 start times (all batches of points, for
#      every height or the requested height) with Make_hysplit_CONTROL_files.sh
#   2. copies the 3 NAM met files it needs from ${SCRATCH}/NAMS/<YEAR>/
#   3. runs hyts_std on each CONTROL file
#   4. packs all tdump files and a run log into ONE tar.gz in
#      ${SCRATCH}/hysplit_tdump/<YEAR>/ (keeps the number of files on /scratch low)
#   5. converts the tdump files to GeoParquet with Convert_tdump_to_GeoParquet.R
#      (${SCRATCH}/hysplit_parquet/{positions,trajectories}/year=/date=/height=/)
# Resubmitting a failed array is safe: steps 1-4 are skipped when the day's tar.gz
# exists, and step 5 when the day's GeoParquet files exist (one per height).
#
# Usage: ./0_Start_hysplit_array.sh YEAR [HEIGHT]
# Then:  sbatch Hysplit_batch_script_<YEAR>[_<HEIGHT>m].sh

###############################
## Parameters
###############################

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Error: The parameters should be: YEAR [HEIGHT]"
  exit 1
fi

YEAR=$1
if [ "$YEAR" -lt 2014 ] || [ "$YEAR" -gt 2019 ]; then
  echo "Error: First argument should be between 2014 and 2019"
  exit 1
fi

if [ "$#" == 2 ]; then
  HEIGHT=$2
  HSUFFIX=$(printf "_%04dm" "${HEIGHT}")
else
  HEIGHT=""
  HSUFFIX=""
fi

POINTS_PER_RUN=1000          # starting locations per HYSPLIT run (CONTROL file)
SEC_PER_RUN=10               # time per 1000-point run (measured: ~5 s), with margin
TIMES_PER_DAY=11             # start times per day = per array task

# Set working directory (where the scripts are)
WORK_DIR="/home/jcandau/projects/def-cbataill/jcandau/BUDDS"
GENERATOR=${WORK_DIR}/Make_hysplit_CONTROL_files.sh
CONVERTER=${WORK_DIR}/Convert_tdump_to_GeoParquet.R
HYTS=/home/jcandau/software/hysplit.v5.4.2.source/exec/hyts_std
BDYFILES=/home/jcandau/software/hysplit.v5.4.2.source/bdyfiles
RSCRIPT=/home/jcandau/software/R-4.5.2/bin/Rscript   # has arrow, data.table, sf

POINTS_DIR=${SCRATCH}/output/hysplit_start_points
POINTS_CSV=${POINTS_DIR}/hysplit_points_${YEAR}.csv
MET_DIR=${SCRATCH}/NAMS/${YEAR}
OUTPUT_DIR=${SCRATCH}/hysplit_tdump/${YEAR}
PARQUET_ROOT=${SCRATCH}/hysplit_parquet
LOG_DIR=${SCRATCH}/hysplit_logs/${YEAR}

# Number of days = array tasks (must match START_MMDD, END_MMDD and START_TIMES_EDT
# in Make_hysplit_CONTROL_files.sh): 62 days x 11 times = 682 start times
NDAYS=$(( ( $(date -u -d "${YEAR}-08-21" +%s) - $(date -u -d "${YEAR}-06-21" +%s) ) / 86400 + 1 ))

###############################
## Checks
###############################

for f in ${GENERATOR} ${CONVERTER} ${HYTS} ${RSCRIPT}; do
  if [[ ! -f $f ]]; then
     echo "The file $f does not exist"
     exit 1
  fi
done

if [[ -n ${HEIGHT} ]]; then
  HFILES=$(ls ${POINTS_DIR}/hysplit_starts_${YEAR}${HSUFFIX}.txt 2>/dev/null)
else
  HFILES=$(ls ${POINTS_DIR}/hysplit_starts_${YEAR}_*m.txt 2>/dev/null)
fi
if [[ -z ${HFILES} ]]; then
   echo "No start-point files for ${YEAR}${HSUFFIX} in ${POINTS_DIR}"
   echo "Run Hysplit_start_points_batch_script.sh first"
   exit 1
fi

NMET=$(ls ${MET_DIR}/*_hysplit.t00z.namsa 2>/dev/null | wc -l)
if [[ ${NMET} -lt $(( NDAYS + 2 )) ]]; then
   echo "Warning: only ${NMET} NAM files in ${MET_DIR} ($(( NDAYS + 2 )) needed)"
   echo "         Run Extract_NAMS.sh (on a login node) first"
fi

if [[ ! -f ${POINTS_CSV} ]]; then
   echo "${POINTS_CSV} does not exist (needed for the GeoParquet conversion)"
   exit 1
fi

# Start points off the NAM grid make HYSPLIT runs fail: they must have been
# removed from the start files by Flag_NAM_domain.R
if ! head -1 ${POINTS_CSV} | grep -q "in_nam_domain"; then
   echo "The start points of ${YEAR} have not been checked against the NAM grid:"
   echo "run  Rscript ${WORK_DIR}/Flag_NAM_domain.R ${YEAR}  first"
   exit 1
fi

# Heights of this array (zero-padded, e.g. "0100 0200"), to check the GeoParquet output
HEIGHTS=$(for f in ${HFILES}; do basename $f .txt | sed -E 's/.*_([0-9]{4})m$/\1/'; done | tr '\n' ' ')

# Runs per task = start times per day x sum over heights of the number of batches
RUNS_PER_TIME=0
for f in ${HFILES}; do
  n=$(wc -l < $f)
  RUNS_PER_TIME=$(( RUNS_PER_TIME + (n + POINTS_PER_RUN - 1) / POINTS_PER_RUN ))
  echo "$(basename $f): ${n} points"
done
RUNS_PER_TASK=$(( RUNS_PER_TIME * TIMES_PER_DAY ))

# Wall time per task: runs x SEC_PER_RUN + 15 min for setup, packing and conversion
SECS=$(( RUNS_PER_TASK * SEC_PER_RUN + 900 ))
MINS=$(( (SECS + 59) / 60 ))
WALLTIME=$(printf "%02d:%02d:00" $(( MINS / 60 )) $(( MINS % 60 )))

mkdir -p ${OUTPUT_DIR} ${PARQUET_ROOT} ${LOG_DIR}

###############################
## Write the batch script
###############################

BATCH=${WORK_DIR}/Hysplit_batch_script_${YEAR}${HSUFFIX}.sh

cat > ${BATCH} <<EOF
#!/bin/bash
#SBATCH --job-name=HYS_${YEAR}${HSUFFIX}
#SBATCH --time=${WALLTIME}
#SBATCH --mem=4G
#SBATCH --cpus-per-task=1
#SBATCH --array=1-${NDAYS}
#SBATCH --output=${LOG_DIR}/%x_%A_%a.out
#SBATCH --mail-type=ALL
#SBATCH --mail-user=YOUR_EMAIL@example.com

# One task = one day (${TIMES_PER_DAY} start times):
# ${RUNS_PER_TASK} HYSPLIT runs of up to ${POINTS_PER_RUN} points per task

echo "Running task ID \${SLURM_ARRAY_TASK_ID} on \$(hostname), started \$(date)"

# Local date of this task (task 1 = June 21) and output file
DAY=\$(date -u -d "${YEAR}-06-21 + \$((SLURM_ARRAY_TASK_ID - 1)) days" +%Y%m%d)
OUT=${OUTPUT_DIR}/tdump_${YEAR}_\${DAY}${HSUFFIX}.tar.gz

# GeoParquet conversion (step 5), skipped if all files of the day already exist
convert() {
   local missing=0
   for h in ${HEIGHTS}; do
      for d in positions trajectories; do
         [[ -s ${PARQUET_ROOT}/\${d}/year=${YEAR}/date=\${DAY}/height=\${h}/part-0.parquet ]] || missing=1
      done
   done
   if [ \${missing} -eq 0 ]; then
      echo "GeoParquet files of \${DAY} already exist"
      return 0
   fi
   ${RSCRIPT} ${CONVERTER} \${OUT} ${POINTS_CSV} ${PARQUET_ROOT} ${POINTS_PER_RUN}
}

if [[ -s \${OUT} ]]; then
   echo "\${OUT} already exists, HYSPLIT runs skipped"
   convert || exit 1
   echo "Finished \$(date)"
   exit 0
fi

# Directories used by Make_hysplit_CONTROL_files.sh (node-local disk)
export POINTS_PER_RUN=${POINTS_PER_RUN}
export POINTS_DIR=${POINTS_DIR}
export MET_ROOT=\${SLURM_TMPDIR}/met
export CONTROL_ROOT=\${SLURM_TMPDIR}/control
export TDUMP_ROOT=\${SLURM_TMPDIR}/tdump
K1=\$(( (SLURM_ARRAY_TASK_ID - 1) * ${TIMES_PER_DAY} + 1 ))
export START_INDEX=\${K1}-\$(( K1 + ${TIMES_PER_DAY} - 1 ))
mkdir -p \${MET_ROOT}/${YEAR}

# 1. CONTROL files for the start times of this day
bash ${GENERATOR} ${YEAR} ${HEIGHT} || exit 1
LIST=\${CONTROL_ROOT}/${YEAR}/control_list_${YEAR}${HSUFFIX}.txt
NCTL=\$(wc -l < \${LIST})

# 2. Copy the met files used by these CONTROL files to local disk
#    (3 files: the day, the next day for runs ending/starting after 00 UTC, and the day after)
METFILES=\$(while read -r c; do tail -n 6 \${c} | sed -n '2p;4p'; done < \${LIST} | sort -u)
for m in \${METFILES}; do
   cp ${MET_DIR}/\${m} \${MET_ROOT}/${YEAR}/ || exit 1
done
echo "Met files: \$(echo \${METFILES})"

# HYSPLIT land-use and roughness files
cat > \${SLURM_TMPDIR}/ASCDATA.CFG <<CFG
-90.0  -180.0  lat/lon of lower left corner
1.0     1.0    lat/lon spacing in degrees between data points
180     360    lat/lon number of data points
2              default land use category
0.2            default roughness length (meters)
'${BDYFILES}/'  directory location of data files
CFG

# 3. Run HYSPLIT on each CONTROL file
RUNLOG=\${TDUMP_ROOT}/${YEAR}/run_log_${YEAR}_\${DAY}${HSUFFIX}.txt
mkdir -p \${TDUMP_ROOT}/${YEAR}
NOK=0
NFAIL=0
while read -r CTL; do
   TDIR=\$(tail -n 2 \${CTL} | head -1)
   mkdir -p \${TDIR}
   RUNDIR=\${SLURM_TMPDIR}/run
   rm -rf \${RUNDIR}; mkdir -p \${RUNDIR}
   cp \${CTL} \${RUNDIR}/CONTROL
   cp \${SLURM_TMPDIR}/ASCDATA.CFG \${RUNDIR}/
   ( cd \${RUNDIR} && ${HYTS} > stdout.txt 2>&1 )
   if grep -q "Complete Hysplit" \${RUNDIR}/stdout.txt; then
      NOK=\$((NOK + 1))
   else
      NFAIL=\$((NFAIL + 1))
      echo "FAILED: \$(basename \${CTL})" >> \${RUNLOG}
      tail -n 5 \${RUNDIR}/stdout.txt >> \${RUNLOG}
   fi
   # Starting points off the met grid are dropped by HYSPLIT: keep a trace
   if grep -q "sources reduced" \${RUNDIR}/stdout.txt; then
      echo "\$(basename \${CTL}): \$(grep "sources reduced" \${RUNDIR}/stdout.txt | head -1)" >> \${RUNLOG}
   fi
done < \${LIST}

echo "\${DAY} (EDT): \${NOK} runs completed, \${NFAIL} failed out of \${NCTL}" | tee -a \${RUNLOG}

# 4. Pack all tdump files and the run log into one file on scratch.
#    If any run failed, the file is named *_FAILED.tar.gz (for inspection) and the
#    task exits with an error, so resubmitting the array reruns this day.
if [ \${NFAIL} -gt 0 ]; then
   OUT=\${OUT%.tar.gz}_FAILED.tar.gz
fi
tar -czf \${SLURM_TMPDIR}/out.tar.gz -C \${TDUMP_ROOT}/${YEAR} . || exit 1
cp \${SLURM_TMPDIR}/out.tar.gz \${OUT}.part && mv \${OUT}.part \${OUT}

echo "Wrote \${OUT}"

if [ \${NFAIL} -gt 0 ]; then
   exit 1
fi

# 5. Convert the tdump files to GeoParquet
convert || exit 1

echo "Finished \$(date)"

exit
EOF

echo
echo "Wrote ${BATCH}"
echo "  ${NDAYS} array tasks (days), ${RUNS_PER_TASK} HYSPLIT runs per task"
echo "  wall time per task: ${WALLTIME}"
echo "  output: ${OUTPUT_DIR}/tdump_${YEAR}_<YYYYMMDD>${HSUFFIX}.tar.gz"
echo "          ${PARQUET_ROOT}/{positions,trajectories}/year=${YEAR}/date=<YYYYMMDD>/height=<H>/"
echo "  logs  : ${LOG_DIR}/"
echo "Check it, then submit with: sbatch ${BATCH}"
