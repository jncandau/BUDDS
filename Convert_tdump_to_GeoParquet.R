# Convert the HYSPLIT tdump files of one day (one array task) to GeoParquet.
#
# Input : tdump_<YEAR>_<YYYYMMDD>[_<H>m].tar.gz written by the HYSPLIT array
#         (or a directory holding the extracted <H>m/tdump_* files), and
#         hysplit_points_<YEAR>.csv written by Create_point_coverage_for_Hysplit_runs.R
# Output: two GeoParquet datasets (GeoParquet 1.1, WKB geometry, lon/lat WGS84,
#         zstd compression), one file per day and release height, in Hive-style
#         folders that DuckDB, arrow, geopandas... read as one table:
#
#   <OUT_ROOT>/positions/year=<YYYY>/date=<YYYYMMDD>/height=<HHHH>/part-0.parquet
#       one row per trajectory and hour (age 0 to 15 h), POINT geometry:
#       point_id, start_time_utc, height_m, age_h, time_utc, lat, lon,
#       alt_agl_m, <diagnostic variables, e.g. pressure_hpa>, geometry
#
#   <OUT_ROOT>/trajectories/year=<YYYY>/date=<YYYYMMDD>/height=<HHHH>/part-0.parquet
#       one row per trajectory, LINESTRING geometry + bbox (GeoParquet covering):
#       point_id, start_time_utc, height_m, n_positions, duration_h, complete,
#       start_lat, start_lon, end_lat, end_lon, end_alt_agl_m, max_alt_agl_m,
#       weight_km2, km2_light, km2_moderate, km2_mod_to_severe, km2_severe,
#       severity_max, severity_label, severity_mean, bbox, geometry
#
#   "date" is the local (EDT) date of the array task (June 21 to August 21);
#   times are in UTC. A trajectory is identified by (point_id, start_time_utc,
#   height_m); point_id links to hysplit_points_<YEAR>.csv.
#   Rows are sorted along a Z-order (Morton) curve of their location (positions)
#   or of their bounding-box centre (trajectories), so that spatial filters can
#   skip most row groups.
#
# Trajectory -> start point: tdump trajectory i of batch b<NNNN> is line
#   (NNNN - 1) x POINTS_PER_RUN + i of the height file, i.e. of the points with
#   in_nam_domain = TRUE in the CSV (points off the NAM grid are excluded by
#   Flag_NAM_domain.R). This is checked against
#   the start coordinates written in the tdump header; if HYSPLIT dropped points
#   (off the met grid, trajectories renumbered) or the check fails, each
#   trajectory is matched to the nearest start point instead.
#
# Usage: Rscript Convert_tdump_to_GeoParquet.R <tdump tar.gz or dir> <hysplit_points_YEAR.csv> <OUT_ROOT> [POINTS_PER_RUN]

suppressPackageStartupMessages({
  library(data.table)
  library(arrow, warn.conflicts = FALSE)
})

# ---- Arguments ---------------------------------------------------------------
args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 3) {
  stop("Usage: Rscript Convert_tdump_to_GeoParquet.R <tdump tar.gz or dir> ",
       "<hysplit_points_YEAR.csv> <OUT_ROOT> [POINTS_PER_RUN]")
}
INPUT          <- args[1]
POINTS_CSV     <- args[2]
OUT_ROOT       <- args[3]
POINTS_PER_RUN <- if (length(args) >= 4) as.integer(args[4]) else 1000L

MAX_COORD_DIFF <- 0.002     # deg: tdump header coordinates have 3 decimals
ROW_GROUP_SIZE <- 100000L   # rows per Parquet row group (min/max statistics)

# Year and local date from the input name: tdump_<YEAR>_<YYYYMMDD>[_<H>m]
tag <- regmatches(basename(INPUT), regexec("tdump_([0-9]{4})_([0-9]{8})", basename(INPUT)))[[1]]
if (length(tag) != 3) stop("Cannot read YEAR and date from the input name: ", INPUT)
YEAR <- tag[2]
DATE <- tag[3]

# ---- Extract the tdump files -------------------------------------------------
if (dir.exists(INPUT)) {
  TDUMP_DIR <- INPUT
} else {
  tmp_root <- Sys.getenv("SLURM_TMPDIR", tempdir())
  TDUMP_DIR <- file.path(tmp_root, paste0("tdump_extract_", YEAR, "_", DATE))
  unlink(TDUMP_DIR, recursive = TRUE)
  dir.create(TDUMP_DIR, recursive = TRUE)
  if (untar(INPUT, exdir = TDUMP_DIR) != 0) stop("Cannot extract ", INPUT)
  on.exit(unlink(TDUMP_DIR, recursive = TRUE), add = TRUE)
}

files <- list.files(TDUMP_DIR, pattern = "^tdump_[0-9]{8}_[0-9]{4}UTC_[0-9]{4}m_b[0-9]{4}$",
                    recursive = TRUE, full.names = TRUE)
if (length(files) == 0) stop("No tdump files in ", INPUT)
message(sprintf("%s %s: %d tdump files", YEAR, DATE, length(files)))

# ---- Start points ------------------------------------------------------------
pts <- fread(POINTS_CSV)
pts <- unique(pts, by = "point_id")              # the CSV has one row per height
if ("in_nam_domain" %in% names(pts)) {            # points off the NAM grid are not
  pts <- pts[in_nam_domain == TRUE]               # in the start files (Flag_NAM_domain.R)
}
setorder(pts, point_id)                           # = line order of the height files
pts[, row := .I]
attr_cols <- c("weight_km2", "km2_light", "km2_moderate", "km2_mod_to_severe",
               "km2_severe", "severity_max", "severity_label", "severity_mean")
attr_cols <- intersect(attr_cols, names(pts))

# ---- Read one tdump file -----------------------------------------------------
read_tdump <- function(f) {
  lines <- readLines(f)
  n_met <- as.integer(strsplit(trimws(lines[1]), " +")[[1]][1])
  i_ntraj <- 1 + n_met + 1
  n_traj <- as.integer(strsplit(trimws(lines[i_ntraj]), " +")[[1]][1])
  starts <- fread(text = lines[(i_ntraj + 1):(i_ntraj + n_traj)], header = FALSE)
  i_diag <- i_ntraj + n_traj + 1
  diag <- strsplit(trimws(lines[i_diag]), " +")[[1]]
  diag_names <- tolower(diag[-1])
  diag_names[diag_names == "pressure"] <- "pressure_hpa"

  d <- fread(text = lines[-(1:i_diag)], header = FALSE)
  setnames(d, c("traj", "grid", "yy", "mo", "dy", "hh", "mi", "fhour", "age_h",
                "lat", "lon", "alt_agl_m", diag_names))

  # Start time, height and batch from the file name
  p <- regmatches(basename(f), regexec("tdump_([0-9]{8})_([0-9]{4})UTC_([0-9]{4})m_b([0-9]{4})",
                                       basename(f)))[[1]]
  start_time <- as.POSIXct(paste(p[2], p[3]), format = "%Y%m%d %H%M", tz = "UTC")
  height <- as.integer(p[4])
  batch <- as.integer(p[5])

  # Trajectory number -> start point (row of the points table)
  st_lat <- starts[[5]]
  st_lon <- starts[[6]]
  rows <- (batch - 1L) * POINTS_PER_RUN + seq_len(n_traj)
  ok <- all(rows <= nrow(pts)) &&
    max(abs(pts$lat[pmin(rows, nrow(pts))] - st_lat),
        abs(pts$lon[pmin(rows, nrow(pts))] - st_lon)) <= MAX_COORD_DIFF
  if (!ok) {                                      # nearest start point
    rows <- vapply(seq_len(n_traj), function(i)
      which.min(abs(pts$lat - st_lat[i]) + abs(pts$lon - st_lon[i])), integer(1))
    dmax <- max(abs(pts$lat[rows] - st_lat), abs(pts$lon[rows] - st_lon))
    if (dmax > MAX_COORD_DIFF) stop(basename(f), ": start point not found (", dmax, " deg)")
    if (anyDuplicated(rows)) stop(basename(f), ": two trajectories matched to the same point")
    message("  ", basename(f), ": ", n_traj, " trajectories matched by coordinates")
  }

  d[, `:=`(point_id = pts$point_id[rows[traj]],
           start_time_utc = start_time,
           height_m = height,
           time_utc = as.POSIXct(sprintf("%04d-%02d-%02d %02d:%02d", 2000L + yy, mo, dy, hh, mi),
                                 format = "%Y-%m-%d %H:%M", tz = "UTC"))]
  d[, c("traj", "grid", "yy", "mo", "dy", "hh", "mi", "fhour") := NULL]
  d
}

# ---- Geometry helpers --------------------------------------------------------
# Z-order (Morton) key of lon/lat, 16 bits per axis
morton <- function(lon, lat) {
  x <- as.integer(pmin(pmax((lon + 180) / 360, 0), 1) * 65535)
  y <- as.integer(pmin(pmax((lat + 90) / 180, 0), 1) * 65535)
  key <- numeric(length(x))
  for (b in 15:0) {
    key <- key * 4 + bitwAnd(bitwShiftR(y, b), 1L) * 2 + bitwAnd(bitwShiftR(x, b), 1L)
  }
  key
}

# WKB (little endian) POINTs
wkb_points <- function(lon, lat) {
  n <- length(lon)
  hdr <- as.raw(c(1, 1, 0, 0, 0))                                  # LE, type 1
  xy <- writeBin(as.vector(rbind(lon, lat)), raw(), endian = "little")
  m <- rbind(matrix(hdr, 5, n), matrix(xy, 16, n))
  lapply(seq_len(n), function(i) m[, i])
}

# WKB (little endian) LINESTRINGs, one per group of consecutive rows
wkb_lines <- function(lon, lat, group) {
  idx <- split(seq_along(lon), group)
  lapply(idx, function(i) {
    c(as.raw(c(1, 2, 0, 0, 0)),                                     # LE, type 2
      writeBin(length(i), raw(), size = 4, endian = "little"),
      writeBin(as.vector(rbind(lon[i], lat[i])), raw(), endian = "little"))
  })
}

geo_metadata <- function(type, bbox, covering = FALSE) {
  cov <- if (covering) {
    paste0(', "covering": {"bbox": {"xmin": ["bbox", "xmin"], "ymin": ["bbox", "ymin"], ',
           '"xmax": ["bbox", "xmax"], "ymax": ["bbox", "ymax"]}}')
  } else ""
  sprintf(paste0('{"version": "1.1.0", "primary_column": "geometry", "columns": ',
                 '{"geometry": {"encoding": "WKB", "geometry_types": ["%s"], ',
                 '"bbox": [%.6f, %.6f, %.6f, %.6f]%s}}}'),
          type, bbox[1], bbox[2], bbox[3], bbox[4], cov)
}

write_geoparquet <- function(df, geometry, type, bbox, path, covering = FALSE) {
  tbl <- arrow_table(df)
  tbl$geometry <- Array$create(geometry, type = binary())
  tbl$metadata$geo <- geo_metadata(type, bbox, covering)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  # Write under a temporary name, then rename: no half-written file if killed
  tmp <- paste0(path, ".part")
  write_parquet(tbl, tmp, compression = "zstd", chunk_size = ROW_GROUP_SIZE)
  if (!file.rename(tmp, path)) stop("Cannot rename ", tmp, " to ", path)
}

# ---- Convert, one height at a time -------------------------------------------
heights <- sort(unique(as.integer(sub(".*_([0-9]{4})m_b[0-9]{4}$", "\\1", basename(files)))))

for (h in heights) {
  fh <- files[grepl(sprintf("_%04dm_b[0-9]{4}$", h), basename(files))]
  pos <- rbindlist(lapply(fh, read_tdump), use.names = TRUE)
  setorder(pos, start_time_utc, point_id, age_h)
  part <- sprintf("year=%s/date=%s/height=%04d/part-0.parquet", YEAR, DATE, h)

  # Trajectories (one row each), before re-sorting the positions spatially
  pos[, traj := .GRP, by = .(start_time_utc, point_id)]
  trj <- pos[, .(n_positions = .N,
                 duration_h = max(age_h),
                 start_lat = lat[1], start_lon = lon[1],
                 end_lat = lat[.N], end_lon = lon[.N],
                 end_alt_agl_m = alt_agl_m[.N],
                 max_alt_agl_m = max(alt_agl_m),
                 xmin = min(lon), ymin = min(lat), xmax = max(lon), ymax = max(lat)),
             by = .(traj, point_id, start_time_utc, height_m)]
  run_hours <- max(trj$duration_h)
  trj[, complete := duration_h == run_hours]
  trj <- merge(trj, pts[, c("point_id", attr_cols), with = FALSE], by = "point_id",
               all.x = TRUE, sort = FALSE)
  lines_wkb <- wkb_lines(pos$lon, pos$lat, pos$traj)     # names = traj
  trj[, geometry := lines_wkb[as.character(traj)]]
  trj <- trj[order(morton((xmin + xmax) / 2, (ymin + ymax) / 2))]
  trj_df <- as.data.frame(trj[, !c("traj", "geometry", "xmin", "ymin", "xmax", "ymax")])
  trj_df$bbox <- data.frame(xmin = trj$xmin, ymin = trj$ymin, xmax = trj$xmax, ymax = trj$ymax)
  write_geoparquet(trj_df, trj$geometry, "LineString",
                   c(min(trj$xmin), min(trj$ymin), max(trj$xmax), max(trj$ymax)),
                   file.path(OUT_ROOT, "trajectories", part), covering = TRUE)

  # Positions (one row per hour), sorted spatially
  pos[, traj := NULL]
  pos <- pos[order(morton(lon, lat))]
  setcolorder(pos, c("point_id", "start_time_utc", "height_m", "age_h", "time_utc",
                     "lat", "lon", "alt_agl_m"))
  write_geoparquet(as.data.frame(pos), wkb_points(pos$lon, pos$lat), "Point",
                   c(min(pos$lon), min(pos$lat), max(pos$lon), max(pos$lat)),
                   file.path(OUT_ROOT, "positions", part))

  message(sprintf("  %04d m: %d trajectories (%d incomplete), %d positions",
                  h, nrow(trj), sum(!trj$complete), nrow(pos)))
}

message("GeoParquet written to ", OUT_ROOT)
