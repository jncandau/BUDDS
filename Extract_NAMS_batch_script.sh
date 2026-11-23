#!/bin/bash
#SBATCH --job-name=Extract_NAMS
#SBATCH --time=12:00:00
#SBATCH --mem=4G
#SBATCH --cpus-per-task=1
#SBATCH --array=2014-2019
#SBATCH --mail-type=ALL
#SBATCH --mail-user=YOUR_EMAIL@example.com

# Extract the NAM 12 km daily files needed for the HYSPLIT runs from the yearly
# tar files on nearline (tape) to ${SCRATCH}/NAMS/<YEAR>/.
# One array task per year (the array index is the year).
#
# Needed days: June 21 to August 23. The last runs start on August 22 at 01:00 UTC
# (August 21 21:00 EDT), and each run lists the file of its start day and of the
# following day.
#
# Reading a tar file on nearline triggers its recall from tape, which can take
# a while before the extraction starts.

YEAR=${SLURM_ARRAY_TASK_ID}
TAR=/home/jcandau/nearline/def-cbataill/jcandau/Hysplit_data/NAMS/${YEAR}.tar
DEST=${SCRATCH}/NAMS/${YEAR}

echo "Extracting ${TAR} to ${DEST}, started $(date)"

if [[ ! -f ${TAR} ]]; then
   echo "The tar file ${TAR} does not exist"
   exit 1
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
   exit 1
fi

exit
