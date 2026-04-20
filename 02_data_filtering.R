# =============================================================================
# 02_data_filtering.R
# Purpose : Read the master dataset, apply sequential quality filters,
#           deduplicate by sub-catchment ID, and export the final analysis-
#           ready dataset.
# Filters applied (in order):
#   1. Valid scientific name (non-empty, non-NA)
#   2. Accuracy == "High"
#   3. ab_1000m == FALSE  (snapping displacement ≤ 1 000 m)
#   4. Deduplicate by subc_id (one record per sub-catchment per species)
#   5. Minimum sample size: species with n < MIN_N are excluded
# Input   : combined_data_master.csv (Full Integrated Dataset)
# Output  : combined_data_filtered.csv  +  filtering_report.csv
# Requires: dplyr(1.1.4), readr (2.1.5)
# =============================================================================

library(dplyr)
library(readr)

# --- Parameters --------------------------------------------------------------
input_file  <- "combined_data_master.csv"
output_file <- "combined_data_final.csv"
report_file <- "filtering_report.csv"
MIN_N       <- 10     # minimum records required to retain a species

# --- Load data ---------------------------------------------------------------
message("Reading: ", input_file)
data <- read_csv(input_file, show_col_types = FALSE)
message("Total records in master dataset: ", nrow(data))

# --- Filter 1: valid scientific name -----------------------------------------
data <- data %>%
  filter(
    !is.na(Crayfish_scientific_name),
    trimws(Crayfish_scientific_name) != ""
  )
message("After name filter: ", nrow(data), " records")

# --- Filter 2: high accuracy only --------------------------------------------
data <- data %>%
  filter(Accuracy == "High")
message("After accuracy filter (High): ", nrow(data), " records")

# --- Filter 3: snapping displacement ≤ 1 000 m -------------------------------
data <- data %>%
  filter(ab_1000m == FALSE)
message("After displacement filter (ab_1000m == FALSE): ", nrow(data), " records")

# --- Filter 4: deduplicate by sub-catchment per species ----------------------
data <- data %>%
  distinct(Crayfish_scientific_name, subc_id, .keep_all = TRUE)
message("After deduplication by subc_id: ", nrow(data), " records")

# --- Filter 5: minimum sample size -------------------------------------------
species_counts <- data %>%
  group_by(Crayfish_scientific_name) %>%
  summarise(n = n(), .groups = "drop")

retained_species <- species_counts %>%
  filter(n >= MIN_N) %>%
  pull(Crayfish_scientific_name)

excluded_species <- species_counts %>%
  filter(n < MIN_N)

data_final <- data %>%
  filter(Crayfish_scientific_name %in% retained_species)

message(
  "After minimum sample size filter (n >= ", MIN_N, "): ",
  nrow(data_final), " records | ",
  length(retained_species), " species retained | ",
  nrow(excluded_species), " species excluded"
)

# --- Filtering report --------------------------------------------------------
report <- species_counts %>%
  mutate(status = ifelse(n >= MIN_N, "RETAINED", paste0("EXCLUDED (n < ", MIN_N, ")")))

write_csv(report, report_file)
message("Filtering report written to: ", report_file)

# --- Save final dataset ------------------------------------------------------
write_csv(data_final, output_file)
message("Filtered dataset written to: ", output_file)
message("Species in final dataset: ", length(unique(data_final$Crayfish_scientific_name)))
