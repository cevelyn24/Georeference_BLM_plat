# Requirements

## Software

| Component | Needed for | Notes |
|---|---|---|
| R | everything | Developed and tested on R 4.5.x (Windows). Older versions are untested. |
| `terra` | showing the scan, zoom window, clicking | tested with 1.9.50 |
| `sf` | BLM coordinate transform, GDAL warp | built with GDAL; tested with GDAL 3.12.1, GEOS 3.14.1, PROJ 9.7.1 |
| `httr`, `jsonlite` | downloading BLM corner coordinates | any recent version |

Install with `source("install_requirements.R")`. On Windows and macOS the CRAN
binaries of `sf` and `terra` bundle GDAL/PROJ, so nothing else is needed.
On Linux, install the system GDAL/GEOS/PROJ development libraries first.

No other packages are used. The thin plate spline used for the accuracy check is
implemented in base R inside the script.

## Environment

* An **interactive R session with a graphics window** (RStudio or the R GUI).
  The click step does not work under `Rscript`.
* **Internet access** the first time you run it (BLM download). The download is
  cached in `gcp_candidates_<...>.csv`; later runs work offline. The repository
  already includes that file for T30S R33E.
* The **scan image** (not in the repository; see README, "Getting the scan").
  About 5200 x 4200 px, i.e. a few tens of MB as PNG. Memory needs are modest (< 2 GB).

## Not needed

`check_example_accuracy.R` needs only base R (no scan, GDAL or internet).
