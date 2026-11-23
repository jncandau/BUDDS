#!/bin/bash
#SBATCH --job-name=HYS_2014
#SBATCH --time=00:59:00
#SBATCH --mem=4G
#SBATCH --cpus-per-task=1
#SBATCH --array=1-62
#SBATCH --output=/scratch/jcandau/hysplit_logs/2014/%x_%A_%a.out
#SBATCH --mail-type=ALL
#SBATCH --mail-user=YOUR_EMAIL@example.com

# One task = one day (11 start times):
# 264 HYSPLIT runs of up to 1000 points per task

echo "Running task ID ${SLURM_ARRAY_TASK_ID} on $(hostname), started $(date)"

# Local date of this task (task 1 = June 21) and output file
DAY=$(date -u -d "2014-06-21 + $((SLURM_ARRAY_TASK_ID - 1)) days" +%Y%m%d)
OUT=/scratch/jcandau/hysplit_tdump/2014/tdump_2014_${DAY}.tar.gz

# GeoParquet conversion (step 5), skipped if all files of the day already exist
convert() {
   local missing=0
   for h in 0100 0200 0300 0500 0750 1000 ; do
      for d in positions trajectories; do
         [[ -s /scratch/jcandau/hysplit_parquet/${d}/year=2014/date=${DAY}/height=${h}/part-0.parquet ]] || missing=1
      done
   done
   if [ ${missing} -eq 0 ]; then
      echo "GeoParquet files of ${DAY} already exist"
      return 0
   fi
   /home/jcandau/software/R-4.5.2/bin/Rscript /home/jcandau/projects/def-cbataill/jcandau/BUDDS/Convert_tdump_to_GeoParquet.R ${OUT} /scratch/jcandau/output/hysplit_start_points/hysplit_points_2014.csv /scratch/jcandau/hysplit_parquet 1000
}

if [[ -s ${OUT} ]]; then
   echo "${OUT} already exists, HYSPLIT runs skipped"
   convert || exit 1
   echo "Finished $(date)"
   exit 0
fi

# Directories used by Make_hysplit_CONTROL_files.sh (node-local disk)
export POINTS_PER_RUN=1000
export POINTS_DIR=/scratch/jcandau/output/hysplit_start_points
export MET_ROOT=${SLURM_TMPDIR}/met
export CONTROL_ROOT=${SLURM_TMPDIR}/control
export TDUMP_ROOT=${SLURM_TMPDIR}/tdump
K1=$(( (SLURM_ARRAY_TASK_ID - 1) * 11 + 1 ))
export START_INDEX=${K1}-$(( K1 + 11 - 1 ))
mkdir -p ${MET_ROOT}/2014

# 1. CONTROL files for the start times of this day
bash /home/jcandau/projects/def-cbataill/jcandau/BUDDS/Make_hysplit_CONTROL_files.sh 2014  || exit 1
LIST=${CONTROL_ROOT}/2014/control_list_2014.txt
NCTL=$(wc -l < ${LIST})

# 2. Copy the met files used by these CONTROL files to local disk
#    (3 files: the day, the next day for runs ending/starting after 00 UTC, and the day after)
METFILES=$(while read -r c; do tail -n 6 ${c} | sed -n '2p;4p'; done < ${LIST} | sort -u)
for m in ${METFILES}; do
   cp /scratch/jcandau/NAMS/2014/${m} ${MET_ROOT}/2014/ || exit 1
done
echo "Met files: $(echo ${METFILES})"

# HYSPLIT land-use and roughness files
cat > ${SLURM_TMPDIR}/ASCDATA.CFG <<CFG
-90.0  -180.0  lat/lon of lower left corner
1.0     1.0    lat/lon spacing in degrees between data points
180     360    lat/lon number of data points
2              default land use category
0.2            default roughness length (meters)
'/home/jcandau/software/hysplit.v5.4.2.source/bdyfiles/'  directory location of data files
CFG

# 3. Run HYSPLIT on each CONTROL file
RUNLOG=${TDUMP_ROOT}/2014/run_log_2014_${DAY}.txt
mkdir -p ${TDUMP_ROOT}/2014
NOK=0
NFAIL=0
while read -r CTL; do
   TDIR=$(tail -n 2 ${CTL} | head -1)
   mkdir -p ${TDIR}
   RUNDIR=${SLURM_TMPDIR}/run
   rm -rf ${RUNDIR}; mkdir -p ${RUNDIR}
   cp ${CTL} ${RUNDIR}/CONTROL
   cp ${SLURM_TMPDIR}/ASCDATA.CFG ${RUNDIR}/
   ( cd ${RUNDIR} && /home/jcandau/software/hysplit.v5.4.2.source/exec/hyts_std > stdout.txt 2>&1 )
   if grep -q "Complete Hysplit" ${RUNDIR}/stdout.txt; then
      NOK=$((NOK + 1))
   else
      NFAIL=$((NFAIL + 1))
      echo "FAILED: $(basename ${CTL})" >> ${RUNLOG}
      tail -n 5 ${RUNDIR}/stdout.txt >> ${RUNLOG}
   fi
   # Starting points off the met grid are dropped by HYSPLIT: keep a trace
   if grep -q "sources reduced" ${RUNDIR}/stdout.txt; then
      echo "$(basename ${CTL}): $(grep "sources reduced" ${RUNDIR}/stdout.txt | head -1)" >> ${RUNLOG}
   fi
done < ${LIST}

echo "${DAY} (EDT): ${NOK} runs completed, ${NFAIL} failed out of ${NCTL}" | tee -a ${RUNLOG}

# 4. Pack all tdump files and the run log into one file on scratch.
#    If any run failed, the file is named *_FAILED.tar.gz (for inspection) and the
#    task exits with an error, so resubmitting the array reruns this day.
if [ ${NFAIL} -gt 0 ]; then
   OUT=${OUT%.tar.gz}_FAILED.tar.gz
fi
tar -czf ${SLURM_TMPDIR}/out.tar.gz -C ${TDUMP_ROOT}/2014 . || exit 1
cp ${SLURM_TMPDIR}/out.tar.gz ${OUT}.part && mv ${OUT}.part ${OUT}

echo "Wrote ${OUT}"

if [ ${NFAIL} -gt 0 ]; then
   exit 1
fi

# 5. Convert the tdump files to GeoParquet
convert || exit 1

echo "Finished $(date)"

exit
