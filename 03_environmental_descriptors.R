# =============================================================================
# 03_environmental_descriptors.R
# Purpose : Compute a full suite of environmental descriptors
#           for every species in the analysis-ready dataset, separately for
#           upstream (u_*) and local (l_*) environmental variables.
#           One CSV and one XLSX file is produced per species per variable set.
# Input   : combined_data_filtered.csv  (output of 02_data_filtering.R)
# Output  : descriptors/<species>_upstream.csv / .xlsx
#           descriptors/<species>_local.csv    / .xlsx
#           descriptors/processing_report.csv  / .xlsx
# Requires: dplyr(1.1.4), readr (2.1.5), writexl(1.5.4), moments (0.14.1)
# =============================================================================

library(dplyr)
library(readr)
library(writexl)
library(moments)

# --- Parameters --------------------------------------------------------------
input_file   <- "combined_data_final.csv"
output_dir   <- "descriptors"

# --- Load data ---------------------------------------------------------------
message("Reading: ", input_file)
data <- read_csv(input_file, show_col_types = FALSE)
message("Total records: ", nrow(data))

# --- Output directory --------------------------------------------------------
if (!dir.exists(output_dir)) dir.create(output_dir)

# --- Species list ------------------------------------------------------------
all_species <- sort(unique(data$Crayfish_scientific_name))
message("Species to process: ", length(all_species))

# --- Statistics function -----------------------------------------------------
calculate_stats <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)

  if (n == 0) return(setNames(rep(NA_real_, 21), stat_names()))

  mean_val   <- mean(x)
  sd_val     <- sd(x)
  se_val     <- sd_val / sqrt(n)
  cv_val     <- if (mean_val != 0) (sd_val / mean_val) * 100 else NA_real_
  min_val    <- min(x)
  max_val    <- max(x)
  median_val <- median(x)
  range_val  <- max_val - min_val
  q05        <- quantile(x, 0.05, names = FALSE)
  q25        <- quantile(x, 0.25, names = FALSE)
  q75        <- quantile(x, 0.75, names = FALSE)
  q95        <- quantile(x, 0.95, names = FALSE)
  iqr_val    <- IQR(x)
  mad_val    <- mad(x)
  skew_val   <- skewness(x)
  kurt_val   <- kurtosis(x)

  # Niche breadth metrics
  occ_range <- max_val - min_val
  occ_iqr   <- q75 - q25
  st_range  <- if (mean_val != 0) occ_range / mean_val else NA_real_
  st_iqr    <- if (mean_val != 0) occ_iqr   / mean_val else NA_real_

  c(n = n, se = se_val, cv = cv_val,
    min = min_val, max = max_val, mean = mean_val, median = median_val,
    range = range_val, sd = sd_val,
    skewness = skew_val, kurtosis = kurt_val,
    iqr = iqr_val, mad = mad_val,
    q05 = q05, q25 = q25, q75 = q75, q95 = q95,
    occ_range = occ_range, occ_iqr = occ_iqr,
    st_range = st_range, st_iqr = st_iqr)
}

stat_names <- function() {
  c("n", "se", "cv", "min", "max", "mean", "median", "range", "sd",
    "skewness", "kurtosis", "iqr", "mad",
    "q05", "q25", "q75", "q95",
    "occ_range", "occ_iqr", "st_range", "st_iqr")
}

# Helper: compute stats table for a set of variable columns
stats_table <- function(df, vars) {
  results <- lapply(vars, function(v) {
    s <- calculate_stats(df[[v]])
    as.data.frame(as.list(s))
  })
  cbind(data.frame(variable = vars, stringsAsFactors = FALSE),
        do.call(rbind, results))
}

# Helper: safe filename from species name
safe_name <- function(x) gsub("[^A-Za-z0-9_]", "", gsub(" ", "_", x))

# --- Processing loop ---------------------------------------------------------
processing_report <- vector("list", length(all_species))

for (i in seq_along(all_species)) {

  sp <- all_species[i]
  message("\n[", i, "/", length(all_species), "] ", sp)

  sp_data <- data %>% filter(Crayfish_scientific_name == sp)

  upstream_vars <- grep("^u_", names(sp_data), value = TRUE)
  local_vars    <- grep("^l_", names(sp_data), value = TRUE)

  upstream_stats <- stats_table(sp_data, upstream_vars)
  local_stats    <- stats_table(sp_data, local_vars)

  fn       <- safe_name(sp)
  up_csv   <- file.path(output_dir, paste0(fn, "_upstream.csv"))
  lo_csv   <- file.path(output_dir, paste0(fn, "_local.csv"))
  up_xlsx  <- file.path(output_dir, paste0(fn, "_upstream.xlsx"))
  lo_xlsx  <- file.path(output_dir, paste0(fn, "_local.xlsx"))

  status <- tryCatch({
    write_csv(upstream_stats, up_csv)
    write_csv(local_stats,    lo_csv)
    write_xlsx(upstream_stats, up_xlsx)
    write_xlsx(local_stats,    lo_xlsx)
    "PROCESSED"
  }, error = function(e) {
    # One retry after closing any stale connections
    closeAllConnections(); Sys.sleep(1)
    tryCatch({
      write_csv(upstream_stats, up_csv)
      write_csv(local_stats,    lo_csv)
      write_xlsx(upstream_stats, up_xlsx)
      write_xlsx(local_stats,    lo_xlsx)
      "PROCESSED (after retry)"
    }, error = function(e2) paste0("ERROR: ", conditionMessage(e2)))
  })

  message("  Status: ", status)

  processing_report[[i]] <- data.frame(
    species_name        = sp,
    n_records           = nrow(sp_data),
    upstream_vars_count = length(upstream_vars),
    local_vars_count    = length(local_vars),
    status              = status,
    stringsAsFactors    = FALSE
  )
}

# --- Save processing report --------------------------------------------------
report_df <- do.call(rbind, processing_report)
write_csv(report_df,  file.path(output_dir, "processing_report.csv"))
write_xlsx(report_df, file.path(output_dir, "processing_report.xlsx"))

message("\n========================================")
message("Processing complete.")
message("  Processed : ", sum(grepl("PROCESSED", report_df$status)))
message("  Errors    : ", sum(grepl("ERROR",     report_df$status)))
message("  Report    : ", file.path(output_dir, "processing_report.csv"))
