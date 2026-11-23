#!/bin/bash
#SBATCH --job-name=Hysplit_start_points
#SBATCH --time=01:00:00
#SBATCH --mem=16G
#SBATCH --cpus-per-task=1
#SBATCH --mail-type=ALL
#SBATCH --mail-user=YOUR_EMAIL@example.com

module load r/4.5.0 netcdf gdal udunits gsl

# R script (stays in the project directory)
SCRIPT=/home/jcandau/projects/def-cbataill/jcandau/BUDDS/Create_point_coverage_for_Hysplit_runs.R

# Run from SCRATCH: the R script writes to the relative path
# output/hysplit_start_points/, so results land in ${SCRATCH}/output/hysplit_start_points/
cd ${SCRATCH} || exit 1

echo "Running in $(pwd) on $(hostname), started $(date)"

Rscript ${SCRIPT}

echo "Finished $(date)"

exit
