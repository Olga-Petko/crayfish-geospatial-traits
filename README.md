# Global Crayfish Database of Geospatial Traits — Processing Scripts

[![DOI](https://img.shields.io/badge/Dataset-10.17632/8j6mgp32fx.1-blue)](https://doi.org/10.17632/8j6mgp32fx.1)

R scripts used to produce the Global Crayfish Database of Geospatial Traits, as described in:

> Petko, O. N., Miok, K., Bremerich, V., Ion, M. C., Torres-Cambas, Y., Buurman, M., World of Crayfish® Consortium, Domisch, S. & Pârvulescu, L. Network-aware environmental trait database for global freshwater crayfish. *Scientific Data* (submitted).

## Overview

This repository contains the R scripts for distance calculation, data filtering, and statistical descriptor computation. Environmental extraction and spatial snapping of occurrence records to the Hydrography90m river network were performed by the GeoFRESH team (Leibniz-IGB, Berlin) using the [GeoFRESH platform](https://geofresh.org/) infrastructure; those processing steps are documented in the manuscript Methods section.

## Scripts

| Script | Description |
|--------|-------------|
| `01_distance_calculation.R` | Calculates geodesic distance between original occurrence coordinates and snapped Hydrography90m segment centroids for each record, and derives three binary threshold flags (200 m, 500 m, 1 km). Input: `WoC_snapped.csv`. Output: `WoC_snapped_dist.csv`. |
| `02_data_filtering.R` | Applies the sequential quality filtering pipeline: removal of records without valid scientific names, low-accuracy records, records with snapping distance > 1 km, segment-level deduplication (one record per sub-catchment per species), and exclusion of taxa with fewer than 10 records. Input: `combined_data_master.csv`. Output: `combined_data_filtered.csv` + `filtering_report.csv`. |
| `03_environmental_descriptors.R` | Computes 20 statistical descriptors per taxon per environmental variable, separately for Local (l_) and Upstream (u_) scales: n, SE, CV, min, max, mean, median, range, SD, skewness, kurtosis, IQR, MAD, Q05, Q25, Q75, Q95, occupied range, occupied IQR, standardised range, standardised IQR. Input: `combined_data_final.csv`. Output: one CSV + XLSX per species per scale in `descriptors/` folder. |

## Requirements

- R ≥ 4.5.1
- R packages:
  - `sf` (≥ 1.0.23) — spatial operations and geodesic distance
  - `dplyr` (≥ 1.1.4) — data manipulation
  - `readr` (≥ 2.1.5) — CSV reading/writing
  - `writexl` (≥ 1.5.4) — XLSX export
  - `moments` (≥ 0.14.1) — skewness and kurtosis

## Input data

- **Occurrence records:** extracted from the [World of Crayfish® platform](https://world.crayfish.ro/) (extraction date: 30 September 2025)
- **Environmental variables:** extracted from [GeoFRESH](https://geofresh.org/) / [Hydrography90m](https://hydrography.org/hydrography90m/hydrography90m_layers/) at 90 m resolution

Input data files are not included in this repository. The processed output data are available at Mendeley Data (see below).

## Output data

The scripts produce the data files deposited at Mendeley Data ([DOI: 10.17632/8j6mgp32fx.1](https://doi.org/10.17632/8j6mgp32fx.1)):

1. **File_1_Full_Integrated_Dataset.csv** — 115,191 records × 398 environmental variables (coordinates withheld)
2. **File_2_Statistical_Summary_Tables.csv** — 108,654 rows (273 taxa × 398 variables × 2 scales)
3. **File_3_Data_Quality_Overview.xlsx** — 457 taxa with filtering diagnostics and retention flags

## Licence

[MIT License](LICENSE)

## Contact

Lucian Pârvulescu — lucian.parvulescu@e-uvt.ro
Crayfish Research Centre, West University of Timisoara, Romania
