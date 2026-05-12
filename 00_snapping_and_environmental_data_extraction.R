# =============================================================================
# 00_snapping_and_environmental_data_extraction.R
# Purpose : Spatially snaps the original occurrence coordinates to the
#           Hydrography90m river network, calculates the upstream catchment for
#           each occurrence coordinate and extracts the local and average
#           upstream environmental values from the Environment90m dataset
#           stored in the GeoFRESH PostgreSQL database.
# Input   : WoC_original.csv  (columns: id, long_or, lat_or)
# Output  : WoC_snapped.csv  (columns: long_or, lat_or, long_snap, lat_snap)
#           WoC_environmental_values.csv
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

# Set database table names for World of Crayfish occurrence data import
point_table <- Id(schema = "shiny_user", table = "world_of_crayfish")
part_table <- SQL("world_of_crayfish")
upstream_column <- SQL("upstream")

# Set database view names for environmental data joins (local sub-catchment)
clim_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_clim")
land_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_land")
soil_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_soil")
topo_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_topo")
flow_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_flow")
subc_view <- Id(schema = "shiny_user", table = "world_of_crayfish_join_subc_area")

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
flow_table <- SQL("stats_flow1k")
subc_table <- SQL("sub_catchments")

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

# Add columns for HydroLAKES ID and point geometry
sql <- sqlInterpolate(con,
  "ALTER TABLE ?point_table
   ADD COLUMN hylak_id integer,
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
