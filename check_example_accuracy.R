## =============================================================================
## check_example_accuracy.R
##
## Re-computes the leave-one-out accuracy of the bundled example control points
## (data/T30S_R33E/gcp_clicks.csv) using the SAME spline functions that are in
## T30S_R33E_plat_georeference.R. Base R only: no scan, GDAL, terra, sf, or
## internet needed. Use it to confirm your R install reproduces the published
## numbers, or to inspect your own clicks file.
##
## Run from the repository root:   source("check_example_accuracy.R")
## Expected for the bundled example (56 points):
##   median 6.1 m | 90th percentile 16.3 m | max 21.7 m
## =============================================================================

script_file <- "T30S_R33E_plat_georeference.R"
clicks_file <- "data/T30S_R33E/gcp_clicks.csv"
scan_height <- 4241     # pixel height of the example scan (needed to flip image rows)

stopifnot(file.exists(script_file), file.exists(clicks_file))

# Pull the exact definitions we need out of the main script (no copies to drift).
wanted <- c("exclude_labs", "tps_kernel", "tps_fit", "tps_predict", "tps_loo")
for (e in parse(script_file)) {
  if (is.call(e) && identical(e[[1]], as.name("<-")) &&
      is.name(e[[2]]) && as.character(e[[2]]) %in% wanted) eval(e)
}
stopifnot(all(vapply(wanted, exists, logical(1))))

g <- read.csv(clicks_file, stringsAsFactors = FALSE)
g$lab <- sprintf("%06d", as.integer(g$lab))
g <- g[!g$lab %in% exclude_labs, ]
err <- tps_loo(cbind(g$px, scan_height - g$py), cbind(g$X, g$Y))
g$loo_m <- sqrt(rowSums(err^2))

cat(nrow(g), "control points (excluded:", paste(exclude_labs, collapse = ", "), ")\n")
cat(sprintf("Leave-one-out error (m): median %.1f | 90th percentile %.1f | max %.1f\n",
            median(g$loo_m), quantile(g$loo_m, 0.9), max(g$loo_m)))
ok <- abs(median(g$loo_m) - 6.1) < 0.1 && abs(max(g$loo_m) - 21.7) < 0.1
cat(if (ok) "OK: matches the published example numbers.\n"
    else "NOTE: differs from the published example (expected if you changed the clicks or exclusions).\n")
