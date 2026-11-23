# Build annual coverages of HYSPLIT starting points from spruce budworm (SBW)
# defoliation polygons.
#
# For each year:
#   1. the defoliation polygons are rasterized on a common 1-km grid: a 1-km cell
#      is defoliated if its centre falls inside a defoliated polygon;
#   2. the 1-km grid is aggregated to a 5-km grid ("any + weight" rule): every
#      5-km cell containing at least one defoliated 1-km cell becomes a HYSPLIT
#      starting point (the 5-km cell centre, in WGS84 lat/lon), with a weight
#      equal to its defoliated area (number of defoliated 1-km cells = km2).
#
# Input : ~/data/SBWGeodatabase_individual_years/AnnualDefoliation_<YEAR>.shp
#         (Canada-wide, Web Mercator; field `Severity` = Light / Moderate /
#          Moderate-to-Severe / Severe)
# Output (in OUT_DIR, one set per year):
#   severity_1km_<YEAR>.tif        1-km severity raster (codes below)
#   points_5km_<YEAR>.tif          5-km rasters: weight_km2, severity_max,
#                                  severity_mean
#   hysplit_points_<YEAR>.csv      point_id, lat, lon, height_m, weight_km2,
#                                  km2 by severity class, severity_max (+ label),
#                                  severity_mean, x, y -- one row per point and
#                                  release height
#   hysplit_starts_<YEAR>_<HEIGHT>m.txt   (HEIGHT zero-padded to 4 digits, e.g. 0100m)
#                                  one file per release height: "lat lon height"
#                                  lines, the format of the starting-location lines
#                                  in a HYSPLIT CONTROL file. Line i is the i-th
#                                  point_id of that year in every height file.
#   summary.csv                    points, starts and defoliated km2 per year
#
# Usage: Rscript Create_point_coverage_for_Hysplit_runs.R

suppressPackageStartupMessages({
  library(sf)
  library(terra)
})

# ---- Parameters --------------------------------------------------------------
IN_DIR          <- path.expand("~/data/SBWGeodatabase_individual_years")
OUT_DIR         <- "output/hysplit_start_points"
YEARS           <- 2014:2019
FINE_RES_M      <- 1000     # resolution used to rasterize the polygons (m)
POINT_RES_M     <- 5000     # resolution of the starting-point grid (m)
START_HEIGHTS_M <- c(100, 200, 300, 500, 750, 1000)  # HYSPLIT release heights (m AGL)
MIN_SEVERITY    <- 1        # keep 1-km cells with severity code >= this (1 = all)

AGG <- POINT_RES_M / FINE_RES_M          # aggregation factor (5)
stopifnot(AGG == round(AGG))

# Canada Atlas Lambert (NAD83), conformal, metres. The data cover most of
# Canada, so the Quebec-only EPSG:32198 is not appropriate here.
GRID_CRS <- "EPSG:3978"

# Severity codes (ordered; when polygons overlap within a 1-km cell, the max is kept)
SEVERITY_CODES <- c("Light" = 1, "Moderate" = 2,
                    "Moderate-to-Severe" = 3, "Severe" = 4)
CLASS_COLS <- c("km2_light", "km2_moderate", "km2_mod_to_severe", "km2_severe")

dir.create(OUT_DIR, recursive = TRUE, showWarnings = FALSE)

# ---- Read and prepare one year -----------------------------------------------
read_year <- function(year) {
  f <- file.path(IN_DIR, sprintf("AnnualDefoliation_%d.shp", year))
  if (!file.exists(f)) stop("Missing input file: ", f)

  v <- vect(f)
  v <- makeValid(v)                      # some polygons are self-intersecting
  v <- project(v, GRID_CRS)

  unknown <- setdiff(unique(v$Severity), names(SEVERITY_CODES))
  if (length(unknown) > 0) {
    stop(year, ": unknown Severity value(s): ", paste(unknown, collapse = ", "))
  }
  v$sev_code <- unname(SEVERITY_CODES[v$Severity])
  v
}

message("Reading ", length(YEARS), " years of defoliation polygons...")
polys <- lapply(YEARS, read_year)
names(polys) <- YEARS

# ---- Common grids ------------------------------------------------------------
# One grid for all years, snapped to whole multiples of POINT_RES_M, so that a
# 5-km cell has the same centre (and thus the same starting point) every year,
# and each 5-km cell holds exactly 5 x 5 cells of the 1-km grid.
full_ext <- Reduce(terra::union, lapply(polys, ext))
snap <- function(x, f) f(x / POINT_RES_M) * POINT_RES_M
grid_ext <- ext(snap(xmin(full_ext), floor), snap(xmax(full_ext), ceiling),
                snap(ymin(full_ext), floor), snap(ymax(full_ext), ceiling))
grid <- rast(grid_ext, resolution = FINE_RES_M, crs = GRID_CRS)
message(sprintf("1-km grid: %d x %d cells; point grid: %d x %d cells at %g m",
                nrow(grid), ncol(grid), nrow(grid) / AGG, ncol(grid) / AGG,
                POINT_RES_M))

# ---- Per-year rasterization and point export ---------------------------------
summary_rows <- list()

for (yr in YEARS) {
  v <- polys[[as.character(yr)]]

  # 1-km cells: defoliated if their centre falls in a polygon; max severity kept
  sev <- rasterize(v, grid, field = "sev_code", fun = "max")
  names(sev) <- "severity"
  writeRaster(sev, file.path(OUT_DIR, sprintf("severity_1km_%d.tif", yr)),
              overwrite = TRUE, datatype = "INT1U", NAflag = 255)
  sev[sev < MIN_SEVERITY] <- NA

  # 5-km cells: defoliated area (km2) in total and by severity class,
  # highest severity and area-weighted mean severity
  weight <- aggregate(!is.na(sev), AGG, fun = "sum", na.rm = TRUE)
  by_class <- rast(lapply(seq_along(SEVERITY_CODES), function(k)
    aggregate(sev == k, AGG, fun = "sum", na.rm = TRUE)))
  sev_max  <- aggregate(sev, AGG, fun = "max", na.rm = TRUE)
  sev_mean <- aggregate(sev, AGG, fun = "mean", na.rm = TRUE)
  pts5 <- c(weight, by_class, sev_max, sev_mean)
  names(pts5) <- c("weight_km2", CLASS_COLS, "severity_max", "severity_mean")
  pts5 <- mask(pts5, weight, maskvalues = 0)    # keep cells with any defoliation

  writeRaster(pts5[[c("weight_km2", "severity_max", "severity_mean")]],
              file.path(OUT_DIR, sprintf("points_%gkm_%d.tif", POINT_RES_M / 1000, yr)),
              overwrite = TRUE)

  pts <- as.data.frame(pts5, xy = TRUE, na.rm = TRUE)

  if (nrow(pts) == 0) {
    warning(yr, ": no defoliated cells, nothing written")
    next
  }

  # 5-km cell centres -> WGS84 lat/lon for HYSPLIT
  ll <- st_coordinates(st_transform(
    st_as_sf(pts, coords = c("x", "y"), crs = GRID_CRS), 4326))

  pt <- data.frame(
    point_id       = sprintf("%d_%06d", yr, seq_len(nrow(pts))),
    lat            = round(ll[, "Y"], 4),
    lon            = round(ll[, "X"], 4),
    weight_km2     = as.integer(pts$weight_km2),
    pts[, CLASS_COLS],
    severity_max   = as.integer(pts$severity_max),
    severity_label = names(SEVERITY_CODES)[pts$severity_max],
    severity_mean  = round(pts$severity_mean, 3),
    x_3978         = pts$x,
    y_3978         = pts$y
  )

  # One start per point and release height; each point's heights are
  # consecutive rows (point 1 at 100, 200, ... m, then point 2, ...)
  idx <- rep(seq_len(nrow(pt)), each = length(START_HEIGHTS_M))
  attr_cols <- setdiff(names(pt), c("point_id", "lat", "lon"))
  out <- data.frame(pt[idx, c("point_id", "lat", "lon")],
                    height_m = rep(START_HEIGHTS_M, times = nrow(pt)),
                    pt[idx, attr_cols],
                    row.names = NULL)

  write.csv(out, file.path(OUT_DIR, sprintf("hysplit_points_%d.csv", yr)),
            row.names = FALSE)
  # One start file per release height, points in point_id order
  for (h in START_HEIGHTS_M) {
    writeLines(sprintf("%.4f %.4f %g", pt$lat, pt$lon, h),
               file.path(OUT_DIR, sprintf("hysplit_starts_%d_%04dm.txt", yr, as.integer(h))))
  }

  area <- colSums(pt[, CLASS_COLS])
  message(sprintf("%d: %d start points x %d heights = %d starts; %d km2 defoliated (%s)",
                  yr, nrow(pt), length(START_HEIGHTS_M), nrow(out), sum(pt$weight_km2),
                  paste(names(SEVERITY_CODES), area, sep = "=", collapse = ", ")))
  summary_rows[[as.character(yr)]] <- data.frame(year = yr, n_points = nrow(pt),
                                                 n_starts = nrow(out),
                                                 total_km2 = sum(pt$weight_km2),
                                                 t(area))
}

summary_df <- do.call(rbind, summary_rows)
write.csv(summary_df, file.path(OUT_DIR, "summary.csv"), row.names = FALSE)
print(summary_df, row.names = FALSE)
