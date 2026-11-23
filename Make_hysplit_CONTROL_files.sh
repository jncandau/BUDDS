#!/bin/bash
#
# Generate HYSPLIT trajectory (hyts_std) CONTROL files for SBW dispersal runs.
#
# One CONTROL file per: date x start time x release height x batch of points
#   - dates       : June 21 to August 21 (inclusive)
#   - start times : 16:00 to 21:00 EDT every 30 min (= 20:00 to 01:00 UTC)
#   - run length  : 15 h, forward
#   - heights     : one hysplit_starts_<YEAR>_<HEIGHT>m.txt file per height
#                   (written by Create_point_coverage_for_Hysplit_runs.R)
#   - batches     : POINTS_PER_RUN starting locations per CONTROL file
#
# Meteorology: NAM 12 km daily files YYYYMMDD_hysplit.t00z.namsa, extracted from
#   ~/nearline/def-cbataill/jcandau/Hysplit_data/NAMS/<YEAR>.tar into MET_DIR.
#   Each run lists the file of its UTC start day and of the following day.
#
# Usage: Make_hysplit_CONTROL_files.sh YEAR [HEIGHT]
#   YEAR   : 2014-2019
#   HEIGHT : optional, one release height in m (e.g. 500); default = all heights
#   Environment variables (optional): POINTS_PER_RUN, POINTS_DIR, MET_ROOT,
#   CONTROL_ROOT, TDUMP_ROOT, START_INDEX (see Parameters below)
#
# Output:
#   ${CONTROL_ROOT}/<YEAR>/<HEIGHT>m/CONTROL_<YYYYMMDD>_<HHMM>UTC_<HEIGHT>m_b<NNNN>
#   ${CONTROL_ROOT}/<YEAR>/control_list_<YEAR>[_<HEIGHT>m].txt  (one path per line,
#       to be read by a SLURM array: line SLURM_ARRAY_TASK_ID = one run)
#   ${CONTROL_ROOT}/<YEAR>/batches/<HEIGHT>m/points_b<NNNN>.txt  (batch contents)
#
# Batch b<NNNN> holds lines ((NNNN-1)*POINTS_PER_RUN + 1) to NNNN*POINTS_PER_RUN of
# the height file, i.e. the same point_id range in hysplit_points_<YEAR>.csv.
# NOTE: HYSPLIT silently drops starting points outside the NAM grid, which shifts
# the trajectory numbers in tdump; check the MESSAGE file for "sources reduced".

set -euo pipefail

###############################
## Parameters
###############################

POINTS_PER_RUN=${POINTS_PER_RUN:-1000}      # starting locations per CONTROL file
RUN_HOURS=15                                # forward run time (h)
VERT_MOTION=0                               # 0 = use vertical velocity from data
TOP_OF_MODEL=15500                          # m AGL (as in Test_hrdps CONTROL)

START_MMDD="06-21"                          # first date (local)
END_MMDD="08-21"                            # last date (local)
START_TIMES_EDT="16:00 16:30 17:00 17:30 18:00 18:30 19:00 19:30 20:00 20:30 21:00"
UTC_OFFSET="-0400"                          # EDT

# Directories: defaults below, can be overridden with environment variables
# (the SLURM array tasks set them to node-local disk, ${SLURM_TMPDIR})
POINTS_DIR="${POINTS_DIR:-${SCRATCH}/output/hysplit_start_points}"  # hysplit_starts_*.txt
MET_ROOT="${MET_ROOT:-${SCRATCH}/NAMS}"                   # MET_DIR = ${MET_ROOT}/<YEAR>/
CONTROL_ROOT="${CONTROL_ROOT:-${SCRATCH}/hysplit_control}"  # CONTROL files written here
TDUMP_ROOT="${TDUMP_ROOT:-${SCRATCH}/hysplit_tdump}"        # tdump outputs (set in CONTROL)

# Optional: START_INDEX=k (1-682) writes only the k-th start time, and
# START_INDEX=k1-k2 the start times k1 to k2
# (k = 1 is June 21 16:00 EDT, k = 11 is June 21 21:00 EDT, k = 12 is June 22 16:00 EDT...)
START_INDEX="${START_INDEX:-}"

###############################
## Arguments
###############################

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: $0 YEAR [HEIGHT]"
  exit 1
fi

YEAR=$1
if [ "$YEAR" -lt 2014 ] || [ "$YEAR" -gt 2019 ]; then
  echo "Error: YEAR should be between 2014 and 2019"
  exit 1
fi

# Height files for this year (all, or the one requested)
if [ "$#" == 2 ]; then
  HFILES=$(printf "%s/hysplit_starts_%d_%04dm.txt" "${POINTS_DIR}" "${YEAR}" "$2")
  SUFFIX=$(printf "_%04dm" "$2")
else
  HFILES=$(ls ${POINTS_DIR}/hysplit_starts_${YEAR}_*m.txt 2>/dev/null || true)
  SUFFIX=""
fi

if [ -z "${HFILES}" ]; then
  echo "Error: no start-point files for ${YEAR} in ${POINTS_DIR}"
  exit 1
fi
for f in ${HFILES}; do
  [[ -f $f ]] || { echo "Error: missing $f"; exit 1; }
done

MET_DIR="${MET_ROOT}/${YEAR}/"
if [[ ! -d ${MET_DIR} ]]; then
  echo "Warning: ${MET_DIR} does not exist yet (extract ${YEAR}.tar there before running HYSPLIT)"
fi

OUT_DIR="${CONTROL_ROOT}/${YEAR}"
LIST_FILE="${OUT_DIR}/control_list_${YEAR}${SUFFIX}.txt"
mkdir -p "${OUT_DIR}"
: > "${LIST_FILE}"

###############################
## Start times in UTC (computed once)
###############################

# Each entry: "YY MM DD HH MM|YYYYMMDD_HHMM|METDAY1|METDAY2"
STARTS=()
d=$(date -u -d "${YEAR}-${START_MMDD}" +%F)
last=$(date -u -d "${YEAR}-${END_MMDD}" +%F)
while [[ "$d" < "$last" || "$d" == "$last" ]]; do
  for t in ${START_TIMES_EDT}; do
    epoch=$(date -u -d "${d} ${t} ${UTC_OFFSET}" +%s)
    ctl_time=$(date -u -d "@${epoch}" "+%y %m %d %H %M")
    tag=$(date -u -d "@${epoch}" "+%Y%m%d_%H%M")
    met1=$(date -u -d "@${epoch}" +%Y%m%d)
    met2=$(date -u -d "@$((epoch + 86400))" +%Y%m%d)
    STARTS+=("${ctl_time}|${tag}|${met1}|${met2}")
  done
  d=$(date -u -d "${d} + 1 day" +%F)
done

echo "${YEAR}: ${#STARTS[@]} start times"

if [ -n "${START_INDEX}" ]; then
  K1=${START_INDEX%-*}            # "k" or "k1-k2"
  K2=${START_INDEX#*-}
  if [ "${K1}" -lt 1 ] || [ "${K2}" -gt "${#STARTS[@]}" ] || [ "${K1}" -gt "${K2}" ]; then
    echo "Error: START_INDEX must be k or k1-k2, between 1 and ${#STARTS[@]}"
    exit 1
  fi
  STARTS=("${STARTS[@]:$((K1 - 1)):$((K2 - K1 + 1))}")
  echo "Only start times ${K1} to ${K2}: ${STARTS[0]%%|*} to ${STARTS[-1]%%|*} (UTC)"
fi

###############################
## CONTROL files
###############################

n_ctl=0
for HFILE in ${HFILES}; do
  H=$(basename "${HFILE}" .txt | sed -E 's/.*_([0-9]{4})m$/\1/')   # zero-padded height
  NPTS=$(wc -l < "${HFILE}")

  # Split the height file into batches of POINTS_PER_RUN lines
  BATCH_DIR="${OUT_DIR}/batches/${H}m"
  rm -rf "${BATCH_DIR}"
  mkdir -p "${BATCH_DIR}" "${OUT_DIR}/${H}m"
  split -l "${POINTS_PER_RUN}" -d -a 4 --numeric-suffixes=1 \
        --additional-suffix=.txt "${HFILE}" "${BATCH_DIR}/points_b"
  BATCHES=$(ls "${BATCH_DIR}"/points_b*.txt)
  NB=$(echo "${BATCHES}" | wc -l)
  echo "  ${H}m: ${NPTS} points -> ${NB} batches of up to ${POINTS_PER_RUN}"

  for s in "${STARTS[@]}"; do
    IFS='|' read -r ctl_time tag met1 met2 <<< "${s}"
    TDUMP_DIR="${TDUMP_ROOT}/${YEAR}/${H}m/"

    for BFILE in ${BATCHES}; do
      b=$(basename "${BFILE}" .txt | sed 's/points_//')       # bNNNN
      CTL="${OUT_DIR}/${H}m/CONTROL_${tag}UTC_${H}m_${b}"
      {
        echo "${ctl_time}"
        wc -l < "${BFILE}"
        cat "${BFILE}"
        echo "${RUN_HOURS}"
        echo "${VERT_MOTION}"
        echo "${TOP_OF_MODEL}"
        echo "2"
        echo "${MET_DIR}"
        echo "${met1}_hysplit.t00z.namsa"
        echo "${MET_DIR}"
        echo "${met2}_hysplit.t00z.namsa"
        echo "${TDUMP_DIR}"
        echo "tdump_${tag}UTC_${H}m_${b}"
      } > "${CTL}"
      echo "${CTL}" >> "${LIST_FILE}"
      n_ctl=$((n_ctl + 1))
    done
  done
done

echo "${YEAR}: ${n_ctl} CONTROL files written under ${OUT_DIR}"
echo "List of CONTROL files: ${LIST_FILE}"
echo "tdump files will be written to ${TDUMP_ROOT}/${YEAR}/<HEIGHT>m/ (create it before running)"
