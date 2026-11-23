-- Example DuckDB queries on the HYSPLIT trajectories stored as GeoParquet
-- (written by Convert_tdump_to_GeoParquet.R in the HYSPLIT array tasks).
--
-- Run all of them:   duckdb < Example_queries.sql
-- or interactively:  duckdb    then   .read Example_queries.sql
-- To keep the views in a small database file for later sessions:
--                    duckdb trajectories.duckdb < Example_queries.sql
--
-- The data are read from ${SCRATCH}/hysplit_parquet (change parquet_root below
-- to use another copy). Nothing is loaded in memory: each query reads only the
-- folders (year/date/height) and row groups it needs.

LOAD spatial;
-- Coordinates are (longitude, latitude) = (x, y). Required in DuckDB 2.0 for
-- spheroid measures (ST_Length_Spheroid...) and GDAL exports; default in 2.1.
SET geometry_always_xy = true;

SET VARIABLE parquet_root = getenv('SCRATCH') || '/hysplit_parquet';

-- ---------------------------------------------------------------------------
-- Views: one row per trajectory, and one row per trajectory and hour.
-- year, date (local EDT date, 'YYYYMMDD') and height (m AGL) come from the
-- folder names. A trajectory is identified by (point_id, start_time_utc, height).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW traj AS
SELECT * FROM read_parquet(getvariable('parquet_root') || '/trajectories/**/*.parquet',
                           hive_partitioning = true,
                           hive_types = {'year': 'INTEGER', 'date': 'VARCHAR', 'height': 'INTEGER'});

CREATE OR REPLACE VIEW pos AS
SELECT * FROM read_parquet(getvariable('parquet_root') || '/positions/**/*.parquet',
                           hive_partitioning = true,
                           hive_types = {'year': 'INTEGER', 'date': 'VARCHAR', 'height': 'INTEGER'});

-- Example study area (lon/lat polygon)
SET VARIABLE area = ST_GeomFromText('POLYGON((-70 48, -66 48, -66 50, -70 50, -70 48))');

.print '== 1. Trajectories per year, date and height (incomplete = left the met grid before 15 h)'
SELECT year, date, height, count(*) AS trajectories, count(*) FILTER (WHERE NOT complete) AS incomplete
FROM traj GROUP BY ALL ORDER BY ALL;

.print '== 2. Time filter: trajectories starting at 22:00 UTC (18:00 EDT) at 1000 m'
SELECT date, count(*) AS n, round(avg(duration_h), 2) AS mean_duration_h,
       round(avg(end_alt_agl_m)) AS mean_end_alt_m
FROM traj
WHERE height = 1000 AND hour(start_time_utc AT TIME ZONE 'UTC') = 22
  AND minute(start_time_utc AT TIME ZONE 'UTC') = 0
GROUP BY ALL ORDER BY ALL;

.print '== 3. Trajectories crossing the study area, by height, weighted by defoliated area'
SELECT height, count(*) AS n_traj, sum(weight_km2) AS weighted_km2
FROM traj
WHERE ST_Intersects(geometry, getvariable('area'))
GROUP BY ALL ORDER BY ALL;

.print '== 4. Hourly positions inside the study area after 15 h, by start time (1000 m)'
SELECT strftime(start_time_utc AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M') AS start_utc, count(*) AS n
FROM pos
WHERE height = 1000 AND age_h = 15 AND ST_Within(geometry, getvariable('area'))
GROUP BY ALL ORDER BY ALL;

.print '== 5. Weighted density of end points on a 0.5 deg grid (top 10 cells, 100 m)'
SELECT floor(end_lon / 0.5) * 0.5 AS lon0, floor(end_lat / 0.5) * 0.5 AS lat0,
       count(*) AS n, sum(weight_km2) AS weighted_km2
FROM traj
WHERE height = 100
GROUP BY ALL ORDER BY weighted_km2 DESC LIMIT 10;

.print '== 6. Join positions and trajectories: altitude profile of trajectories ending north of 52 N (1000 m)'
SELECT p.age_h, count(*) AS n, round(avg(p.alt_agl_m)) AS mean_alt_m
FROM pos p JOIN traj t USING (point_id, start_time_utc, height, year, date)
WHERE t.height = 1000 AND t.end_lat > 52 AND p.age_h IN (0, 5, 10, 15)
GROUP BY ALL ORDER BY ALL;

.print '== 7. Distance travelled along the trajectory (km, on the WGS84 ellipsoid), by height'
SELECT height, round(avg(ST_Length_Spheroid(geometry)) / 1000) AS mean_km,
       round(max(ST_Length_Spheroid(geometry)) / 1000) AS max_km
FROM traj GROUP BY ALL ORDER BY ALL;

.print '== 8. Export the trajectories crossing the study area (1000 m) to GeoPackage (QGIS, R/sf)'
COPY (SELECT point_id, strftime(start_time_utc AT TIME ZONE 'UTC', '%Y-%m-%d %H:%M') AS start_utc,
             height, weight_km2, severity_label, geometry
      FROM traj
      WHERE height = 1000 AND ST_Intersects(geometry, getvariable('area')))
TO 'trajectories_area_1000m.gpkg' WITH (FORMAT GDAL, DRIVER 'GPKG', SRS 'EPSG:4326');
.print 'Wrote trajectories_area_1000m.gpkg'
