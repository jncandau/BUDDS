#!/bin/bash
#
# Extract the NAM 12 km daily files needed for the HYSPLIT runs from the yearly
# tar files on nearline (tape) to ${SCRATCH}/NAMS/<YEAR>/.
#
# RUN ON A LOGIN NODE, NOT WITH SBATCH: nearline is not mounted on the compute
# nodes (a SLURM job cannot see the tar files).
#
# Usage: bash Extract_NAMS.sh YEAR [YEAR ...]
#   e.g. in the background, so it survives a disconnection:
#   nohup bash Extract_NAMS.sh 2014 > ${SCRATCH}/NAMS/extract_2014.log 2>&1 &
#
# Needed days: June 21 to August 23. The last runs start on August 22 at 01:00 UTC
# (August 21 21:00 EDT), and each run lists the file of its start day and of the
# following day.
#
# Reading a tar file on nearline triggers its recall from tape, which can take
# a while before the extraction starts.

NEARLINE_DIR=/home/jcandau/nearline/def-cbataill/jcandau/Hysplit_data/NAMS

if [ "$#" -lt 1 ]; then
   echo "Usage: $0 YEAR [YEAR ...]"
   exit 1
fi

if [[ ! -d ${NEARLINE_DIR} ]]; then
   echo "${NEARLINE_DIR} is not visible: run this script on a login node"
   exit 1
fi

STATUS=0
for YEAR in "$@"; do

   TAR=${NEARLINE_DIR}/${YEAR}.tar
   DEST=${SCRATCH}/NAMS/${YEAR}

   echo "Extracting ${TAR} to ${DEST}, started $(date)"

   if [[ ! -f ${TAR} ]]; then
      echo "The tar file ${TAR} does not exist"
      STATUS=1
      continue
   fi
   mkdir -p ${DEST}

   # List of needed files (as wildcards, so the path inside the tar does not matter)
   PATTERNS=()
   d=$(date -u -d "${YEAR}-06-21" +%F)
   while [[ "$d" < "${YEAR}-08-24" ]]; do
      PATTERNS+=("*$(date -u -d "$d" +%Y%m%d)_hysplit.t00z.namsa")
      d=$(date -u -d "$d + 1 day" +%F)
   done
   echo "${#PATTERNS[@]} daily files to extract"

   # --transform removes any directory from the member names (files land directly in DEST)
   tar -xvf ${TAR} -C ${DEST} --wildcards --transform='s,^.*/,,' "${PATTERNS[@]}"

   # Check that every needed file is there
   MISSING=0
   for p in "${PATTERNS[@]}"; do
      f=${DEST}/${p#\*}
      if [[ ! -s $f ]]; then
         echo "MISSING: $f"
         MISSING=$((MISSING + 1))
      fi
   done

   echo "${YEAR}: $(ls ${DEST} | wc -l) files in ${DEST}, ${MISSING} missing, finished $(date)"
   if [ ${MISSING} -gt 0 ]; then
      STATUS=1
   fi
done

exit ${STATUS}
