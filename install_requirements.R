## Installs the R packages needed by T30S_R33E_plat_georeference.R
## Run once:  source("install_requirements.R")
need <- c("terra", "sf", "httr", "jsonlite")
missing <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) install.packages(missing) else cat("All required packages already installed.\n")
cat("R", as.character(getRversion()), "\n")
for (p in need) if (requireNamespace(p, quietly = TRUE))
  cat(sprintf("  %-9s %s\n", p, as.character(packageVersion(p))))
if (requireNamespace("sf", quietly = TRUE)) print(sf::sf_extSoftVersion())
