# =============================================================================
# 00_snapping_and_environmental_data_extraction.R
# Purpose : Spatially snaps the original occurrence coordinates to the
#           Hydrography90m river network, calculates the upstream catchment for
#           each occurrence coordinate and extracts the local and average
#           upstream environmental values from the Environment90m dataset
#           stored in the GeoFRESH PostgreSQL database.
# Input   : WoC_original.csv  (columns: id, long_or, lat_or)
# Output  : WoC_snapped.csv  (columns: long_or, lat_or, long_snap, lat_snap)
#           WoC_snapped_bioclim_period_1981-2010_local.csv,
#           WoC_snapped_landcover_2020_local.csv, WoC_snapped_soil_local.csv,
#           WoC_snapped_topography_hydrography90m_local.csv,
#           WoC_snapped_avg_bioclim_period_1981-2010_upstream.csv,
#           WoC_snapped_avg_landcover_2020_upstream.csv,
#           WoC_snapped_avg_soil_upstream.csv,
#           WoC_snapped_avg_topography_hydrography90m_upstream.csv
# Requires: DBI (1.3.0), readr (2.1.5), dplyr (1.1.4)
# =============================================================================

library(DBI)
library(readr)
library(dplyr)

# --- Database connection -----------------------------------------------------

# Connect to the GeoFRESH PostgreSQL database (internal)
con <- dbConnect(RPostgres::Postgres(),
  dbname = "*************",
  host = "**************",
  port = "****",
  user = "************"
)

# --- Parameters --------------------------------------------------------------

input_file <- "WoC_original.csv"
output_file <- "WoC_snapped.csv"

# Set database table names for World of Crayfish occurrence data import
point_table <- Id(schema = "shiny_user", table = "world_of_crayfish")
part_table <- SQL("world_of_crayfish")
upstream_column <- SQL("upstream")

# Set database view names for environmental data joins (local sub-catchment)
clim_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_clim")
land_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_land")
soil_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_soil")
topo_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_topo")

# Set database view names for environmental data joins (upstream catchment)
clim_upstr_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_clim_upstr")
land_upstr_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_land_upstr")
soil_upstr_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_soil_upstr")
topo_upstr_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_topo_upstr")

# Set GeoFRESH database table names
regional_units_table <- Id(schema = "hydro", table = "regional_units")
lake_table <- Id(schema = "hydro", table = "hydrolakes_poly")
sub_catchments_table <- Id(schema = "hydro", table = "sub_catchments")
stream_table <- Id(schema = "hydro", table = "stream_segments")

# Set short table names for environmental variables tables
clim_table <- SQL("stats_climate")
land_table <- SQL("stats_landuse")
soil_table <- SQL("stats_soil")
topo_table <- SQL("stats_topo")


# --- Load data ---------------------------------------------------------------

message("Reading: ", input_file)
woc_csv <- read_csv(input_file, show_col_types = FALSE)
message("Total records: ", nrow(woc_csv))


# --- Create table with World of Crayfish occurrence points -------------------

# Upload data from CSV file as database table in schema 'shiny_user'
dbWriteTable(con, point_table, woc_csv)

# Run ANALYZE to update database table statistics
sql <- sqlInterpolate(con,
  "ANALYZE ?point_table",
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Create primary key on id column
sql <- sqlInterpolate(con,
  "ALTER TABLE ?point_table ADD PRIMARY KEY (id)",
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Add columns for HydroLAKES ID, point geometry and is_coastal flag
sql <- sqlInterpolate(con,
  "ALTER TABLE ?point_table
   ADD COLUMN hylak_id integer,
   ADD COLUMN is_coastal boolean,
   ADD COLUMN geom_orig geometry(POINT, 4326)",
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Create point geometry from latitude and longitude
sql <- sqlInterpolate(con,
  "UPDATE ?point_table
   SET geom_orig = ST_MakePoint(longitude, latitude)",
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Create a spatial index on column geom_orig
sql <- sqlInterpolate(con,
  "CREATE INDEX ?idx ON ?point_table
   USING GIST (geom_orig)",
  idx = dbQuoteIdentifier(con, paste0(part_table, "_geom_orig_idx")),
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Update occurrence point table with ID of the regional unit the point lies in
sql <- sqlInterpolate(con,
  "UPDATE ?point_table poi
     SET reg_id = reg.reg_id
   FROM ?reg_table reg
   WHERE st_intersects(poi.geom_orig, reg.geom)",
  reg_table = dbQuoteIdentifier(con, regional_units_table),
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Update occurrence point table with ID of HydroLAKES lake the point lies in
sql <- sqlInterpolate(con,
  "UPDATE ?point_table poi
     SET hylak_id = lak.hylak_id
   FROM ?lake_table lak
   WHERE st_intersects(poi.geom_orig, lak.geom)",
  lake_table = dbQuoteIdentifier(con, lake_table),
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Set `is_coastal` flag to TRUE for all records that do not lie inside a
# Hydrography90m sub-catchment. These may include occurrences in coastal
# regions as well as endorheic lakes.
sql <- sqlInterpolate(con,
  "UPDATE ?point_table AS poi
     SET is_coastal = TRUE
   WHERE subc_id IS NULL",
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)


# --- Snap occurrence records to nearest Hydrography90m stream segment --------

# Add columns for distance-based snapping
sql <- sqlInterpolate(con,
  "ALTER TABLE ?point_table
     ADD COLUMN subc_id_dist integer,
     ADD COLUMN basin_id_dist integer,
     ADD COLUMN strahler_order_dist smallint,
     ADD COLUMN reg_id_dist smallint,
     ADD COLUMN geom_dist geometry(POINT, 4326),
     ADD COLUMN upstream_dist bigint[]",
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# Run snapping to nearest stream segment
sql <- sqlInterpolate(con,
  "UPDATE ?point_table AS poi
    SET
      subc_id_dist = seg2.subc_id,
      basin_id_dist = seg2.basin_id,
      strahler_order_dist = seg2.strahler,
      reg_id_dist = seg2.reg_id,
      geom_dist = ST_LineInterpolatePoint(
         seg2.geom,
         ST_LineLocatePoint(seg2.geom, poi.geom_orig)
      )
    FROM (
      SELECT
        poi_inner.id AS poi_id,
        seg1.subc_id,
        seg1.basin_id,
        seg1.strahler,
        seg1.reg_id,
        seg1.geom
      FROM ?point_table poi_inner
      CROSS JOIN LATERAL (
        SELECT
          seg.subc_id,
          seg.basin_id,
          seg.strahler,
          seg.reg_id,
          seg.geom,
          seg.geom <-> poi_inner.geom_orig AS dist
        FROM ?segments_table seg
        WHERE seg.geom IS NOT NULL
        ORDER BY dist
        LIMIT 1
      ) seg1
    ) seg2
    WHERE poi.id = seg2.poi_id",
  segments_table = dbQuoteIdentifier(con, stream_table),
  point_table = dbQuoteIdentifier(con, point_table)
)
dbExecute(con, sql)

# --- Export snapped occurrence records to CSV --------------------------------

# Query database table with snapped occurrence coordinates
sql <- sqlInterpolate(con,
  "SELECT
    id,
    latitude AS lat_or,
    longitude AS long_or,
    round(st_y(geom_dist)::numeric, 6) AS lat_snap,
    round(st_x(geom_dist)::numeric, 6) AS long_snap,
    reg_id_dist AS reg_id,
    basin_id_dist AS basin_id,
    subc_id_dist AS subc_id,
    hylak_id,
    strahler_order_dist AS strahler_order,
    is_coastal
   FROM ?point_table
   ORDER BY id",
  point_table = dbQuoteIdentifier(con, point_table)
)
woc_snapped <- dbGetQuery(con, sql)

# Export to CSV
write.csv(woc_snapped, output_file, row.names = FALSE)

# --- Calculate upstream areas for all snapped occurrence records -------------

# Get all regional units that contain occurrence records snapped to stream
# segments that are not headwaters (Strahler order > 1)
sql <- sqlInterpolate(con,
  "SELECT DISTINCT reg_id_dist
    FROM ?point_table
    WHERE subc_id_dist IS NOT NULL
    AND strahler_order > 1
    AND upstream_dist IS NULL
    ORDER BY reg_id_dist",
  point_table = dbQuoteIdentifier(con, point_table)
)
woc_reg_ids_dist <- dbGetQuery(con, sql)

# Run upstream catchment calculation per regional_unit
for (reg_unit in woc_reg_ids_dist$reg_id_dist) {

  message("Processing upstream for regional unit:", reg_unit)

  sql <- sqlInterpolate(con,
    "WITH unique_subcs AS (
      SELECT DISTINCT
        subc_id_dist,
        reg_id_dist,
        basin_id_dist
      FROM ?point_table
      WHERE reg_id_dist = ?reg_unit
      AND subc_id_dist IS NOT NULL
      AND upstream_dist IS NULL
      AND strahler_order_dist > 1
    ),
    upstream_results AS (
      SELECT
        subc.subc_id_dist,
        upc.nodes
      FROM unique_subcs subc,
         LATERAL hydro.pgr_upstreamcomponent(
         subc.subc_id_dist, subc.reg_id_dist, subc.basin_id_dist) upc
    )
    UPDATE ?point_table poi
      SET upstream_dist = upstr.nodes
    FROM upstream_results upstr
      WHERE poi.subc_id_dist = upstr.subc_id_dist
      AND poi.reg_id_dist = ?reg_unit
      AND poi.upstream_dist IS NULL
      AND poi.strahler_order_dist > 1",
    reg_unit = dbQuoteLiteral(con, reg_unit),
    point_table = dbQuoteIdentifier(con, point_table)
  )
  dbExecute(con, sql)
}


# --- Extract environmental data (Environment90m) for local subcatchment ------

# Set output file names
output_file_bioclim <- "WoC_snapped_bioclim_period_1981-2010_local.csv"
output_file_landcover <- "WoC_snapped_landcover_2020_local.csv"
output_file_soil <- "WoC_snapped_soil_local.csv"
output_file_topography <- "WoC_snapped_topography_hydrography90m_local.csv"


## 1. Bioclim

# Create a view to join environmental data for Bioclim
sql <- sqlInterpolate(con,
  "CREATE VIEW ?point_view AS
    SELECT
      poi.id,
      poi.basin_id_dist,
      poi.strahler_order_dist,
      env.*
    FROM ?point_table poi
      LEFT JOIN ?env_table env ON
        poi.subc_id_dist = env.subc_id
        AND poi.reg_id_dist = env.reg_id
   ORDER BY poi.id",
  point_view = dbQuoteIdentifier(con, clim_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, clim_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, clim_view)
)
bioclim_data <- dbGetQuery(con, sql)

# Export to CSV
write.csv(bioclim_data, output_file_bioclim, row.names = FALSE)


## 2. Landcover

# Create a view to join environmental data for landcover (year 2020)
sql <- sqlInterpolate(con,
  "CREATE VIEW ?point_view AS
    SELECT
      poi.id,
      poi.basin_id_dist,
      poi.strahler_order_dist,
      env.*
    FROM ?point_table poi
    LEFT JOIN ?env_table env ON
      poi.subc_id_dist = env.subc_id
      AND poi.reg_id_dist = env.reg_id
   ORDER BY poi.id",
  point_view = dbQuoteIdentifier(con, land_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, land_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, land_view)
)
landcover_data <- dbGetQuery(con, sql)

# Export to CSV
write.csv(landcover_data, output_file_landcover, row.names = FALSE)


## 3. Soil

# Create a view to join environmental data for soil
sql <- sqlInterpolate(con,
  "CREATE OR REPLACE VIEW ?point_view AS
      SELECT
        poi.id,
        poi.basin_id_dist,
        poi.strahler_order_dist,
        env.*
    FROM ?point_table poi
    LEFT JOIN ?env_table env ON
      poi.subc_id_dist = env.subc_id
      AND poi.reg_id_dist = env.reg_id
    ORDER BY poi.id",
  point_view = dbQuoteIdentifier(con, soil_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, soil_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, soil_view)
)
soil_data <- dbGetQuery(con, sql)

# Export to CSV
write.csv(soil_data, output_file_soil, row.names = FALSE)


## 4. Topography/Hydrography90m

# Create a view to join environmental data for topography (local subcatchment)
sql <- sqlInterpolate(con,
  "CREATE VIEW ?point_view AS
    SELECT
      poi.id,
      poi.basin_id_dist,
      poi.strahler_order_dist,
      env.*
    FROM ?point_table poi
    LEFT JOIN ?env_table env ON
      poi.subc_id_dist = env.subc_id
      AND poi.reg_id_dist = env.reg_id
    ORDER BY poi.id",
  point_view = dbQuoteIdentifier(con, topo_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, topo_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, topo_view)
)
topo_data <- dbGetQuery(con, sql)

# Remove flowpos and other unused columns from result
topo_data <- topo_data |> dplyr::select(
  !c(
    scheidegger, drwal_old,
    flowpos_min, flowpos_max, flowpos_mean, flowpos_sd,
    flow_min, flow_max, flow_mean, flow_sd
  )
)

# Export to CSV
write.csv(topo_data, output_file_topography, row.names = FALSE)


# --- Extract environmental data (Environment90m) for upstream catchment ------

# Set output file names
output_file_bioclim_upstream <- "WoC_snapped_avg_bioclim_period_1981-2010_upstream.csv"
output_file_landcover_upstream <- "WoC_snapped_avg_landcover_2020_upstream.csv"
output_file_soil_upstream <- "WoC_snapped_avg_soil_upstream.csv"
output_file_topography_upstream <- "WoC_snapped_avg_topography_hydrography90m_upstream.csv"

## 1. Bioclim

# Get column names from Bioclim view for local sub-catchment
bioclim_fields <- dbListFields(con, dbQuoteIdentifier(con, clim_view))

# Select only the columns names that contain '_mean'
bioclim_columns <- bioclim_fields[grepl("_mean", bioclim_fields)]

# Create SQL strings for calculation of average
bioclim_columns_upstr_query <- sapply(
  bioclim_columns, function(x) {
    paste0("round(avg(", x, ")::numeric, 4) AS ", x)
  },
  USE.NAMES = FALSE
)

# Create a view to join environmental data for Bioclim (upstream catchment)
sql_string <- paste(
  "CREATE VIEW ?point_view AS
    SELECT
      poi.id,
      min(poi.basin_id_dist) AS basin_id_dist,
      min(poi.strahler_order_dist) AS strahler_order_dist,",
      paste0(clim_columns_upstr_query, collapse = ", "),
   "FROM ?env_table env
    RIGHT JOIN ?point_table poi
      ON env.subc_id = ANY (poi.upstream_dist)
      AND env.reg_id = poi.reg_id_dist
    GROUP BY poi.id
    ORDER BY poi.id"
)
sql <- sqlInterpolate(con,
  sql_string,
  point_view = dbQuoteIdentifier(con, clim_upstr_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, clim_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, clim_upstr_view)
)
bioclim_data_upstr <- dbGetQuery(con, sql)

# Export to CSV
write.csv(bioclim_data_upstr, output_file_bioclim_upstream, row.names = FALSE)

## 2. Landcover

# Get column names from landcover view for local sub-catchment
land_fields <- dbListFields(con, dbQuoteIdentifier(con, land_view))

# Select only the column names that contain '0'
land_columns <- land_fields[grepl("0", land_fields)]

# Create SQL strings for calculation of average
land_columns_upstr_query <- sapply(
  land_columns, function(x) {
    paste0("round(avg(", x, ")::numeric, 4) AS ", x)
  },
  USE.NAMES = FALSE
)

# Create a view to join environmental data for landcover (upstream catchment)
sql_string <- paste(
  "CREATE VIEW ?point_view AS
   SELECT
     poi.id,
     min(poi.basin_id_dist) AS basin_id_dist,
     min(poi.strahler_order_dist) AS strahler_order_dist,",
     paste0(land_columns_upstr_query, collapse = ", "),
   "FROM ?env_table env
    RIGHT JOIN ?point_table poi
      ON env.subc_id = ANY (poi.upstream_dist)
      AND env.reg_id = poi.reg_id_dist
    GROUP BY poi.id
    ORDER BY poi.id"
)
sql <- sqlInterpolate(con,
  sql_string,
  point_view = dbQuoteIdentifier(con, land_upstr_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, land_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, land_upstr_view)
)
land_data_upstr <- dbGetQuery(con, sql)

# Export to CSV
write.csv(land_data_upstr, output_file_landcover_upstream, row.names = FALSE)


## 3. Soil

# Get column names from soil view for local sub-catchment
soil_fields <- dbListFields(con, dbQuoteIdentifier(con, soil_view))

# Select only the columns names that contain '_mean'
soil_columns <- soil_fields[grepl("_mean", soil_fields)]

# Create SQL strings for calculation of average
soil_columns_upstr_query <- sapply(
  soil_columns, function(x) {
    paste0("round(avg(", x, ")::numeric, 4) AS ", x)
  },
  USE.NAMES = FALSE
)

# Create a view to join stats for soil (upstream catchment)
sql_string <- paste(
  "CREATE OR REPLACE VIEW ?point_view AS
    SELECT
      poi.id,
      min(poi.basin_id_dist) AS basin_id_dist,
      min(poi.strahler_order_dist) AS strahler_order_dist,",
      paste0(soil_columns_upstr_query, collapse = ", "),
   "FROM ?env_table env
    RIGHT JOIN ?point_table poi
      ON env.subc_id = ANY (poi.upstream_dist)
      AND env.reg_id = poi.reg_id_dist
    GROUP BY poi.id
    ORDER BY poi.id"
)
sql <- sqlInterpolate(con,
  sql_string,
  point_view = dbQuoteIdentifier(con, soil_upstr_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, soil_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, soil_upstr_view)
)
soil_data_upstr <- dbGetQuery(con, sql)

# Remove texmht columns (not valid)
soil_upstr_filtered <- soil_data_upstr |> dplyr::select(!starts_with("texmht_"))

# Export to CSV
write.csv(soil_upstr_filtered, output_file_soil_upstream, row.names = FALSE)


## 4. Topography/Hydrography90m

# These topography columns contain categorical values, excluded here
# topo_categorical <- c("strahler", "shreve", "horton", "hack", "topo_dim")

# These topography columns are only valid for local sub-catchment, excluded here:
# topo_local <- c("cum_length", "source_elev", "outlet_elev", "out_drop")


# Column names without '_mean'
topo_without_stats <- c(
  "length", "stright", "sinusoid", "flow_accum", "out_dist", "elev_drop", "gradient"
)

# Get column names from topography/hydrography view for local sub-catchment
topo_fields <- dbListFields(con, dbQuoteIdentifier(con, topo_view))

# Select only the columns names that contain '_mean'
topo_fields_mean <- topo_fields[grepl("_mean", topo_fields)]

# Remove flowpos and flow from selected columns, not used
topo_remove <- c("flowpos_mean", "flow_mean")
topo_fields_mean <- topo_fields_mean[!(topo_fields_mean %in% topo_remove)]

# Combine selected column names
topo_columns <- c(topo_without_stats, topo_fields_mean)

# Create SQL strings for calculation of average
topo_columns_upstr_query <- sapply(
  topo_columns, function(x) {
    paste0("round(avg(", x, ")::numeric, 4) AS ", x)
  },
  USE.NAMES = FALSE
)

# Create a view to join stats for topography (upstream catchment)
sql_string <- paste(
  "CREATE OR REPLACE VIEW ?point_view AS
    SELECT poi.id,
      min(poi.basin_id_dist) AS basin_id_dist,
      min(poi.strahler_order_dist) AS strahler_order_dist,",
      paste0(topo_columns_upstr_query, collapse = ", "),
   "FROM ?env_table env
    RIGHT JOIN ?point_table poi
      ON env.subc_id = ANY (poi.upstream_dist)
      AND env.reg_id = poi.reg_id_dist
    GROUP BY poi.id
    ORDER BY poi.id"
)
sql <- sqlInterpolate(con,
  sql_string,
  point_view = dbQuoteIdentifier(con, topo_upstr_view),
  point_table = dbQuoteIdentifier(con, point_table),
  env_table = dbQuoteIdentifier(con, topo_table)
)
dbExecute(con, sql)

# Query data from view
sql <- sqlInterpolate(con,
  "SELECT * FROM ?point_view",
  point_view = dbQuoteIdentifier(con, topo_upstr_view)
)
topo_data_upstr <- dbGetQuery(con, sql)

# Export to CSV
write.csv(topo_data_upstr, output_file_topography_upstream, row.names = FALSE)

