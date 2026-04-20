# =============================================================================
# 01_distance_calculation.R
# Purpose : Calculate geodesic distance between original and snapped coordinate pairs for each
#           record, then derive three threshold flags.
# Input   : WoC_snapped.csv  (columns: long_or, lat_or, long_snap, lat_snap)
# Output  : WoC_snapped_dist.csv  (original columns + distance_m, ab_200m,
#                                   ab_500m, ab_1000m)
# Requires: sf (v1.0.23)
# =============================================================================

library(sf)

# --- Input / output paths ----------------------------------------------------
input_file  <- "WoC_snapped.csv"
output_file <- "WoC_snapped_dist.csv"

# --- Load data ---------------------------------------------------------------
data <- read.csv(input_file, stringsAsFactors = FALSE, check.names = FALSE)

# --- Build spatial objects (WGS 84) ------------------------------------------
p_original <- st_as_sf(data, coords = c("long_or",   "lat_or"),   crs = 4326)
p_snapped  <- st_as_sf(data, coords = c("long_snap", "lat_snap"), crs = 4326)

# --- Geodesic distance (metres) ----------------------------------------------
data$distance_m <- as.numeric(
  st_distance(p_original, p_snapped, by_element = TRUE)
)

# --- Binary threshold flags --------------------------------------------------
# TRUE  = the record is displaced by more than the threshold distance
# FALSE = the record is within the threshold distance
data$ab_200m  <- data$distance_m > 200
data$ab_500m  <- data$distance_m > 500
data$ab_1000m <- data$distance_m > 1000

# --- Save result -------------------------------------------------------------
write.csv(data, output_file, row.names = FALSE)

message("Done. Output written to: ", output_file)
message("Records processed: ", nrow(data))
message(
  "Threshold summary (TRUE = exceeds threshold):\n",
  "  ab_200m  : ", sum(data$ab_200m,  na.rm = TRUE), " records\n",
  "  ab_500m  : ", sum(data$ab_500m,  na.rm = TRUE), " records\n",
  "  ab_1000m : ", sum(data$ab_1000m, na.rm = TRUE), " records"
)
