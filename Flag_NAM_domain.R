# Flag the HYSPLIT start points that are outside the usable NAM 12 km grid, and
# remove them from the start files.
#
# HYSPLIT (hyts_std 5.4.2) accepts a start point only if its grid cell satisfies
#   2 <= INT(x) < NX - 2   and   2 <= INT(y) < NY - 2
# (library/hysplit/metpos.f). Otherwise the whole run stops with
# "start point not within (x,y,t) any data file". This is stricter than the
# check that writes "source point off grid" in MESSAGE, so points near the grid
# edge are not reported there but still make the run fail.
#
# For each year, this script:
#   1. reads the grid definition (Lambert conformal, 12 km, NX x NY) from the
#      header of the year's NAM file and computes the grid position (x, y) of
#      every start point (same conversion as HYSPLIT, checked to 1e-4 cell);
#   2. flags the points that do not satisfy the rule above, with a safety
#      margin of EDGE_MARGIN grid cell;
#   3. checks with a 1-hour HYSPLIT run from all the remaining points that the
#      run completes (stops with an error otherwise);
#   4. adds the column in_nam_domain (TRUE/FALSE) to hysplit_points_<YEAR>.csv,
#      rewrites hysplit_starts_<YEAR>_<H>m.txt with the in-grid points only
#      (same order, point_id unchanged: line i is the i-th in-grid point_id),
#      writes points_off_NAM_grid_<YEAR>.csv (excluded points, with grid x, y)
#      and nam_domain_summary.csv (all years).
# It can be rerun: it always starts from all the points of the CSV file.
#
# Run after Create_point_coverage_for_Hysplit_runs.R and Extract_NAMS.sh, from a
# login node or a job (a few seconds per year):
#   Rscript Flag_NAM_domain.R [YEAR ...]        (default: 2014-2019)

suppressPackageStartupMessages({
  library(data.table)
  library(sf)
})

# ---- Parameters --------------------------------------------------------------
POINTS_DIR  <- file.path(Sys.getenv("SCRATCH"), "output/hysplit_start_points")
MET_ROOT    <- file.path(Sys.getenv("SCRATCH"), "NAMS")
HYTS        <- "/home/jcandau/software/hysplit.v5.4.2.source/exec/hyts_std"
BDYFILES    <- "/home/jcandau/software/hysplit.v5.4.2.source/bdyfiles"
MET_MMDD    <- "0621"      # met file used (first day of the runs)
EDGE_MARGIN <- 0.05        # grid cells, against rounding differences with HYSPLIT
EARTH_R     <- 6371200     # m, earth radius used by HYSPLIT

args  <- commandArgs(trailingOnly = TRUE)
YEARS <- if (length(args) > 0) as.integer(args) else 2014:2019

# ---- Grid definition from the ARL file header --------------------------------
read_arl_grid <- function(f) {
  h <- substr(rawToChar(readBin(f, "raw", 300)), 51, 300)
  num <- function(i) as.numeric(substr(h, 10 + 7 * (i - 1), 16 + 7 * (i - 1)))
  o <- 10 + 7 * 12
  g <- list(model = substr(h, 1, 4),
            pole_lat = num(1), pole_lon = num(2), tang_lat = num(3), ref_lon = num(4),
            grid_km = num(5), orient = num(6), cone = num(7),
            sync_x = num(8), sync_y = num(9), sync_lat = num(10), sync_lon = num(11),
            nx = as.integer(substr(h, o, o + 2)), ny = as.integer(substr(h, o + 3, o + 5)))
  if (g$tang_lat <= 0 || g$grid_km <= 0) stop(f, ": not a Lambert conformal grid")
  g
}

grid_xy <- function(lat, lon, g) {
  crs <- sprintf("+proj=lcc +lat_1=%g +lat_2=%g +lat_0=%g +lon_0=%g +R=%g +units=m +no_defs",
                 g$tang_lat, g$tang_lat, g$tang_lat, g$ref_lon, EARTH_R)
  p <- st_coordinates(st_transform(st_as_sf(data.frame(lon = c(g$sync_lon, lon),
                                                       lat = c(g$sync_lat, lat)),
                                            coords = c("lon", "lat"), crs = 4326), crs))
  list(x = g$sync_x + (p[-1, 1] - p[1, 1]) / (g$grid_km * 1000),
       y = g$sync_y + (p[-1, 2] - p[1, 2]) / (g$grid_km * 1000))
}

# ---- 1-hour HYSPLIT check from a set of points -------------------------------
hysplit_check <- function(yr, lat, lon, met) {
  wd <- tempfile(sprintf("nam_domain_%d_", yr))
  dir.create(wd)
  on.exit(unlink(wd, recursive = TRUE), add = TRUE)
  writeLines(c("-90.0  -180.0  lat/lon of lower left corner",
               "1.0     1.0    lat/lon spacing in degrees between data points",
               "180     360    lat/lon number of data points",
               "2              default land use category",
               "0.2            default roughness length (meters)",
               sprintf("'%s/'  directory location of data files", BDYFILES)),
             file.path(wd, "ASCDATA.CFG"))
  writeLines(c(sprintf("%02d %s 20 00", yr %% 100, sub("(..)(..)", "\\1 \\2", MET_MMDD)),
               length(lat), sprintf("%.4f %.4f 100", lat, lon),
               "1", "0", "15500", "1",
               paste0(file.path(MET_ROOT, yr), "/"), basename(met),
               paste0(wd, "/"), "tdump"),
             file.path(wd, "CONTROL"))
  out <- suppressWarnings(system(sprintf("cd %s && %s 2>&1", shQuote(wd), HYTS), intern = TRUE))
  n_warn <- sum(grepl("source point off grid", readLines(file.path(wd, "MESSAGE"))))
  list(ok = any(grepl("Complete Hysplit", out)) && n_warn == 0,
       msg = paste(tail(out, 3), collapse = "\n"))
}

# ---- One year ----------------------------------------------------------------
flag_year <- function(yr) {
  csv <- file.path(POINTS_DIR, sprintf("hysplit_points_%d.csv", yr))
  met <- file.path(MET_ROOT, yr, sprintf("%d%s_hysplit.t00z.namsa", yr, MET_MMDD))
  if (!file.exists(csv)) stop("Missing ", csv)
  if (!file.exists(met)) stop("Missing ", met)

  all <- fread(csv)                              # one row per point and height
  if ("in_nam_domain" %in% names(all)) all[, in_nam_domain := NULL]   # recomputed
  pts <- unique(all, by = "point_id")
  setorder(pts, point_id)                        # = line order of the start files

  # Grid position of each point and HYSPLIT start-point rule (with margin)
  g <- read_arl_grid(met)
  xy <- grid_xy(pts$lat, pts$lon, g)
  pts[, `:=`(grid_x = xy$x, grid_y = xy$y)]
  pts[, in_nam_domain := grid_x >= 2 + EDGE_MARGIN & grid_x < g$nx - 2 - EDGE_MARGIN &
                         grid_y >= 2 + EDGE_MARGIN & grid_y < g$ny - 2 - EDGE_MARGIN]
  ok <- pts[in_nam_domain == TRUE]

  # HYSPLIT must accept all the remaining points
  chk <- hysplit_check(yr, ok$lat, ok$lon, met)
  if (!chk$ok) stop(yr, ": HYSPLIT does not accept all the in-grid points:\n", chk$msg)

  # Outputs
  all <- merge(all, pts[, .(point_id, in_nam_domain)], by = "point_id", sort = FALSE)
  setorder(all, point_id, height_m)
  fwrite(all, csv)
  for (h in sort(unique(all$height_m))) {
    writeLines(sprintf("%.4f %.4f %g", ok$lat, ok$lon, h),
               file.path(POINTS_DIR, sprintf("hysplit_starts_%d_%04dm.txt", yr, as.integer(h))))
  }
  off <- pts[in_nam_domain == FALSE, !"in_nam_domain"]
  off[, `:=`(grid_x = round(grid_x, 3), grid_y = round(grid_y, 3))]
  fwrite(off, file.path(POINTS_DIR, sprintf("points_off_NAM_grid_%d.csv", yr)))

  s <- data.table(year = yr, grid = sprintf("%s %dx%d %gkm", g$model, g$nx, g$ny, g$grid_km),
                  n_points = nrow(pts), n_off_grid = nrow(off), n_in_grid = nrow(ok),
                  km2_total = sum(pts$weight_km2), km2_off_grid = sum(off$weight_km2))
  s[, pct_km2_off_grid := round(100 * km2_off_grid / km2_total, 2)]
  message(sprintf("%d: %d of %d points off the usable NAM grid (%d km2, %.2f%% of the area); HYSPLIT check OK",
                  yr, s$n_off_grid, s$n_points, s$km2_off_grid, s$pct_km2_off_grid))
  s
}

summary_df <- rbindlist(lapply(YEARS, flag_year))
sum_file <- file.path(POINTS_DIR, "nam_domain_summary.csv")
if (file.exists(sum_file)) {                     # keep the years not rerun
  old <- fread(sum_file)
  if ("grid" %in% names(old)) {
    summary_df <- rbind(old[!year %in% YEARS], summary_df)
    setorder(summary_df, year)
  }
}
fwrite(summary_df, sum_file)
print(summary_df)
