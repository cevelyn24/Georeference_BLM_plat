## =============================================================================
## Georeference a GLO township plat to BLM PLSS corner coordinates
## Example: T30S R33E, Mount Diablo Meridian, Kern Co., CA (1911 plat) -
##          control tightened around Stud Horse Canyon (Secs 19-21, 28-33)
##
## WHAT IT DOES
##   1. Downloads BLM PLSS corner coordinates for the township (BLM CadNSDI REST
##      service) and keeps the section and quarter corners  -> candidate GCPs.
##   2. You click each corner on the scanned plat. For every corner the script
##      zooms to the spot it predicts (refitted after every click); you click the
##      exact line intersection. Progress is saved after every click.
##   3. Accuracy check: leave-one-out error in metres for every control point.
##   4. Warps the scan with a thin plate spline (GDAL) to a GeoTIFF in
##      NAD83 / UTM zone 11N (EPSG:26911), nearest-neighbour resampling.
##   5. Optionally writes a KMZ overlay for Google Earth.
##
## REQUIREMENTS
##   R with packages: terra, sf, httr, jsonlite   (sf must include GDAL)
##   Developed and tested on R 4.5.x (Windows); older R versions are untested.
##   An INTERACTIVE session with a graphics window (RStudio or the R GUI;
##   not Rscript). Internet access the first time (BLM download).
##   See README.md and REQUIREMENTS.md in this repository.
##
## HOW TO RUN
##   a) Put the scan (see `scan_file`) in a folder, then either set `work_dir`
##      below to that folder or setwd() there first.
##   b) Run the whole file (RStudio: Source). Re-run it any time to resume.
##   c) Open the resulting .tif in QGIS with  Layer > Add Layer > Add RASTER
##      Layer  (NOT "Mesh"). It carries its own CRS, EPSG:26911.
##
## KNOWN LIMITS (read before trusting the numbers)
##   * Accuracy is limited by the plat itself (hand-drawn lines several pixels
##     wide, and the 1911 survey) and by BLM's stated corner reliability, which
##     is in the BLM_RELIABILITY column of the report (feet).
##   * Quarter corners can disagree with the plat by 20-50 m, because the plat
##     draws them at nominal positions. Check `gcp_report.csv`, and list any
##     point you distrust in `exclude_labs`.
##   * Tested only on T30S R33E. The corner-label scheme used here (POINTLAB =
##     3 digits east x 3 digits north; first digit 1-6 = mile lines 0-5 from the
##     SW township corner; 40 = half-mile point; the east and north township
##     lines are stored with the neighbouring townships) was worked out for this
##     township. For another township verify it before use.
##   * The canyon/drainage lines drawn on the plat are sketches. This script
##     places the PLAT accurately; it cannot make the sketch more accurate.
## =============================================================================


## ---- CONFIG: edit this block only ------------------------------------------
work_dir     <- NULL                 # folder holding the scan; NULL = current folder
scan_file    <- "T30S_R33E_Kern_1911_native.jpg"   # scan, any RGB image GDAL reads
township_id  <- "CA210300S0330E0"    # BLM PLSSID of the township
target_epsg  <- 26911                # NAD83 / UTM zone 11N

cand_csv     <- "gcp_candidates_T30S_R33E.csv"   # created automatically if missing
click_csv    <- "gcp_clicks.csv"                 # your clicks (saved as you go)
report_csv   <- "gcp_report.csv"                 # per-point accuracy report
out_vrt      <- "T30S_R33E_gcps.vrt"             # intermediate file (control points)
out_tif      <- "T30S_R33E_georef_TPS_UTM11N.tif"
out_kmz     <- "T30S_R33E_plat.kmz"
make_kmz     <- TRUE                 # also write a Google Earth overlay

half_win     <- 200                  # zoom window half-width, in scan pixels
max_rely_ft  <- Inf                  # e.g. 45 = skip BLM corners rated worse than 45 ft

# Corners left OUT of the fit (they stay in the clicks file). Here: BLM and the
# plat disagree about the quarter corners on the south line (240100, 340100) and
# two interior quarter corners had 20-26 m leave-one-out error (240300, 200240).
exclude_labs <- c("240100", "340100", "240300", "200240")

priority_E   <- 4                    # corners with east/north mile-line <= these
priority_N   <- 4                    #   are clicked first (SW 3x3 sections here)
ask_before_warp <- TRUE
## -----------------------------------------------------------------------------


## ---- Checks ----------------------------------------------------------------
need <- c("terra", "sf", "httr", "jsonlite")
missing_pkgs <- need[!vapply(need, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs))
  stop("Please install: install.packages(c(",
       paste0('"', missing_pkgs, '"', collapse = ", "), "))", call. = FALSE)
suppressPackageStartupMessages({ library(terra); library(sf) })

if (!interactive())
  stop("Run this in RStudio or the R GUI (it needs a graphics window to click on).",
       call. = FALSE)
if (!is.null(work_dir)) setwd(work_dir)
cat("Working folder:", getwd(), "\n")
if (!file.exists(scan_file))
  stop("Cannot find '", scan_file, "' in ", getwd(),
       ". Set `work_dir` or `scan_file` in the CONFIG block.", call. = FALSE)

r <- suppressWarnings(rast(scan_file))       # no CRS: x = pixel column, y = pixel row counted UP
if (nlyr(r) < 3) stop("The scan must be an RGB image (3 bands).", call. = FALSE)
nc <- ncol(r); nr <- nrow(r)
cat("Scan:", nc, "x", nr, "pixels\n")


## ---- 1. Candidate corners ---------------------------------------------------
build_candidates <- function() {
  cat("Downloading BLM PLSS corners for", township_id, "...\n")
  url  <- "https://gis.blm.gov/caarcgis/rest/services/lands/BLM_CA_CADNSDI/MapServer/0/query"
  resp <- httr::GET(url, httr::timeout(90),
                    query = list(where = sprintf("PLSSID LIKE '%s%%'", township_id),
                                 outFields = "*", outSR = target_epsg,
                                 returnGeometry = "true", f = "json"))
  httr::stop_for_status(resp)
  j <- jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"))
  a <- j$features$attributes
  if (is.null(a) || nrow(a) == 0)
    stop("BLM returned no corners for ", township_id, call. = FALSE)
  if (isTRUE(j$exceededTransferLimit))
    warning("BLM result was truncated; corners may be missing.")
  a <- a[!is.na(a$XCOORD) & !is.na(a$YCOORD), ]
  if (!all(a$HDATUM %in% "NAD83"))
    warning("Not all BLM coordinates are NAD83 (", paste(unique(a$HDATUM), collapse = ","), ").")
  a$lab <- sprintf("%06d", suppressWarnings(as.integer(a$POINTLAB)))
  keep  <- grepl("^[1-7]00[1-7]00$|^[1-7]40[1-7]00$|^[1-7]00[1-7]40$", a$lab)
  a <- a[keep, ]
  p  <- sf::st_transform(sf::st_as_sf(a, coords = c("XCOORD", "YCOORD"), crs = 4269),
                         target_epsg)      # BLM X/Y are NAD83 lon/lat degrees
  xy <- sf::st_coordinates(p)
  data.frame(POINTID = a$POINTID, POINTLAB = a$lab, RELYTXT = a$RELYTXT,
             RELYNUMB = a$RELYNUMB, X = xy[, 1], Y = xy[, 2], stringsAsFactors = FALSE)
}

if (file.exists(cand_csv)) {
  cand <- read.csv(cand_csv, stringsAsFactors = FALSE)
} else {
  cand <- build_candidates()
  write.csv(cand, cand_csv, row.names = FALSE)
}
if (!all(c("POINTLAB", "RELYTXT", "RELYNUMB", "X", "Y") %in% names(cand)))
  stop("'", cand_csv, "' is missing required columns.", call. = FALSE)

cand$lab  <- sprintf("%06d", as.integer(cand$POINTLAB))
# lab = E ht N vt : E,N = mile line + 1; ht/vt = "00" or "40" (half-mile point)
cand$E    <- as.integer(substr(cand$lab, 1, 1)) + (substr(cand$lab, 2, 3) == "40") * 0.5
cand$N    <- as.integer(substr(cand$lab, 4, 4)) + (substr(cand$lab, 5, 6) == "40") * 0.5
cand$type <- ifelse(substr(cand$lab, 2, 3) == "40" | substr(cand$lab, 5, 6) == "40",
                    "quarter", "section")
cand$block <- cand$E <= priority_E & cand$N <= priority_N
cand <- cand[cand$RELYNUMB <= max_rely_ft & !cand$lab %in% exclude_labs, ]

anchors <- c("100100", "600100", "100600", "600600")
if (!all(anchors %in% cand$lab))
  stop("Anchor corners ", paste(setdiff(anchors, cand$lab), collapse = ", "),
       " are missing from the candidate list.", call. = FALSE)
ord <- c(anchors,
         setdiff(cand$lab[cand$block & cand$type == "section"], anchors),
         cand$lab[cand$block & cand$type == "quarter"],
         setdiff(cand$lab[!cand$block & cand$type == "section"], anchors))
cand <- cand[match(unique(ord[ord %in% cand$lab]), cand$lab), ]
cat(nrow(cand), "candidate corners to click.\n")


## ---- 2. Click loop (resumable) ----------------------------------------------
# Predict where a corner is in the scan from corners clicked so far.
predict_xy <- function(done, X, Y) {
  mx <- mean(done$X); my <- mean(done$Y)
  d  <- data.frame(u = (done$X - mx) / 1000, v = (done$Y - my) / 1000,
                   px = done$px, py = done$py)
  nd <- data.frame(u = (X - mx) / 1000, v = (Y - my) / 1000)
  f  <- if (nrow(d) >= 12) ~ u + v + I(u^2) + I(u * v) + I(v^2) else ~ u + v
  c(predict(lm(update(f, px ~ .), d), nd), predict(lm(update(f, py ~ .), d), nd))
}

# Zoom window centred on (cx, cy); returns the clicked c(x, y) or NULL (skip).
pick_one <- function(lab, info, cx, cy, half) {
  repeat {
    e <- ext(max(0, cx - half), min(nc, cx + half), max(0, cy - half), min(nr, cy + half))
    plotRGB(crop(r, e), r = 1, g = 2, b = 3, stretch = "lin", axes = TRUE,
            main = sprintf("%s  (%s corner)   BLM reliability: %s", lab, info$type, info$RELYTXT))
    points(cx, cy, pch = 3, col = "red", cex = 3)             # predicted position
    pt <- locator(1)
    if (is.null(pt)) return(NULL)                             # right-click = skip
    points(pt$x, pt$y, pch = 1, col = "cyan", cex = 3, lwd = 2)
    ans <- tolower(trimws(readline("Enter = accept, r = redo, s = skip: ")))
    if (ans == "s") return(NULL)
    if (ans != "r") return(c(pt$x, pt$y))
  }
}

clicks <- NULL
if (file.exists(click_csv)) {
  clicks <- read.csv(click_csv, stringsAsFactors = FALSE)
  clicks$lab <- sprintf("%06d", as.integer(clicks$lab))
}

seed <- NULL
if (is.null(clicks) || nrow(clicks) < 4) {
  cat("\nSEED STEP - click these four township corners COARSELY on the whole sheet:\n",
      " 100100 = SW corner of the township (SW corner of Sec 31)\n",
      " 600100 = south boundary, 5 miles east (SW corner of Sec 36)\n",
      " 100600 = west boundary, 5 miles north (SW corner of Sec 6)\n",
      " 600600 = SW corner of Sec 1\n")
  for (l in anchors) {
    i <- cand[cand$lab == l, ][1, ]
    plotRGB(r, r = 1, g = 2, b = 3, stretch = "lin", main = paste("Seed: click", l))
    pt <- locator(1)
    if (is.null(pt)) stop("Seed click cancelled.", call. = FALSE)
    seed <- rbind(seed, data.frame(X = i$X, Y = i$Y, px = pt$x, py = pt$y))
  }
}

for (k in seq_len(nrow(cand))) {
  i <- cand[k, ]
  if (!is.null(clicks) && i$lab %in% clicks$lab) next
  have  <- rbind(seed, if (!is.null(clicks)) clicks[, c("X", "Y", "px", "py")])
  guess <- predict_xy(have, i$X, i$Y)
  cat(sprintf("[%d/%d] %s\n", k, nrow(cand), i$lab))
  res <- pick_one(i$lab, i, guess[1], guess[2], half_win)
  if (is.null(res)) next
  clicks <- rbind(clicks, data.frame(lab = i$lab, type = i$type, RELYNUMB = i$RELYNUMB,
                                     X = i$X, Y = i$Y, px = res[1], py = res[2]))
  write.csv(clicks, click_csv, row.names = FALSE)
}


## ---- 3. Accuracy check: leave-one-out thin plate spline ---------------------
g <- read.csv(click_csv, stringsAsFactors = FALSE)
g$lab <- sprintf("%06d", as.integer(g$lab))
g <- g[!g$lab %in% exclude_labs, ]
if (nrow(g) < 10) stop("Need at least 10 control points; have ", nrow(g), ".", call. = FALSE)
g$pixel <- g$px
g$line  <- nr - g$py                      # GDAL "line" counts DOWN from the top
n <- nrow(g)
cat("\n", n, "control points\n")

# Exact thin plate spline (zero residual at the control points, like GDAL -tps).
# Plain base R, so no extra packages and no warnings.
tps_kernel <- function(d) ifelse(d == 0, 0, d^2 * log(d))
tps_fit <- function(xy, z) {
  ctr <- colMeans(xy); u <- (xy - rep(ctr, each = nrow(xy))) / 1000
  z   <- as.matrix(z); zm <- colMeans(z)
  P   <- cbind(1, u)
  A   <- rbind(cbind(tps_kernel(as.matrix(dist(u))), P), cbind(t(P), matrix(0, 3, 3)))
  list(ctr = ctr, u = u, zm = zm,
       coef = solve(A, rbind(z - rep(zm, each = nrow(z)), matrix(0, 3, ncol(z)))))
}
tps_predict <- function(fit, new) {
  v <- (matrix(new, ncol = 2) - rep(fit$ctr, each = nrow(matrix(new, ncol = 2)))) / 1000
  d <- sqrt(outer(v[, 1], fit$u[, 1], "-")^2 + outer(v[, 2], fit$u[, 2], "-")^2)
  M <- cbind(tps_kernel(d), 1, v)
  M %*% fit$coef + rep(fit$zm, each = nrow(v))
}

# Leave-one-out: predict every point from all the others.
# Returns an n x 2 matrix of (east, north) errors in metres = predicted - BLM.
tps_loo <- function(xy, z) {
  t(vapply(seq_len(nrow(xy)), function(i) {
    f <- tps_fit(xy[-i, , drop = FALSE], z[-i, , drop = FALSE])
    as.vector(tps_predict(f, xy[i, , drop = FALSE])) - z[i, ]
  }, numeric(2)))
}
err <- tps_loo(cbind(g$pixel, g$line), cbind(g$X, g$Y))
g$loo_dE_m <- err[, 1]; g$loo_dN_m <- err[, 2]
g$loo_m    <- sqrt(err[, 1]^2 + err[, 2]^2)

cat(sprintf("Leave-one-out error (m): median %.1f | 90th percentile %.1f | max %.1f\n",
            median(g$loo_m), quantile(g$loo_m, 0.9), max(g$loo_m)))
cat("(Each point is predicted from all the others, so this is a realistic position error:\n",
    " click error + plat distortion + BLM coordinate error. Edge points read high.)\n")
worst <- head(g[order(-g$loo_m), c("lab", "type", "RELYNUMB", "loo_m")], 10)
names(worst)[3] <- "BLM_rely_ft"
print(worst, row.names = FALSE)

report <- g[, c("lab", "type", "RELYNUMB", "X", "Y", "px", "py", "loo_dE_m", "loo_dN_m", "loo_m")]
names(report)[c(1, 3)] <- c("corner", "BLM_RELIABILITY_ft")
write.csv(report, report_csv, row.names = FALSE)
cat("Per-point report written to", report_csv, "\n")

if (ask_before_warp) {
  ans <- tolower(trimws(readline(
    "Press Enter to warp, or type q to stop (then fix points / edit exclude_labs): ")))
  if (ans %in% c("q", "quit", "n", "no")) stop("Stopped before warping.", call. = FALSE)
}


## ---- 4. Warp (GDAL thin plate spline) ---------------------------------------
gcp_opts <- unlist(lapply(seq_len(n), function(i)
  c("-gcp", sprintf("%.3f", g$pixel[i]), sprintf("%.3f", g$line[i]),
    sprintf("%.3f", g$X[i]), sprintf("%.3f", g$Y[i]))))
sf::gdal_utils("translate", source = scan_file, destination = out_vrt,
               options = c("-of", "VRT", "-a_srs", paste0("EPSG:", target_epsg), gcp_opts))
sf::gdal_utils("warp", source = out_vrt, destination = out_tif,
               options = c("-tps", "-r", "near", "-t_srs", paste0("EPSG:", target_epsg),
                           "-dstalpha", "-overwrite",
                           "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES"))
if (!file.exists(out_tif)) stop("GDAL did not produce ", out_tif, call. = FALSE)

rf <- rast(out_tif)
cat("\nWrote", out_tif, "\n  CRS:", crs(rf, describe = TRUE)$name,
    "| size:", ncol(rf), "x", nrow(rf), "| pixel:", round(res(rf)[1], 2), "m\n")
tryCatch({
  plotRGB(rf, r = 1, g = 2, b = 3, stretch = "lin", main = "Georeferenced plat (red = control points)")
  points(g$X, g$Y, col = "red", pch = 3, cex = 1.2)
}, error = function(e) NULL)


## ---- 5. Optional Google Earth overlay ---------------------------------------
if (make_kmz) {
  tryCatch({
    wgs <- tempfile(fileext = ".tif")
    sf::gdal_utils("warp", source = out_tif, destination = wgs,
                   options = c("-t_srs", "EPSG:4326", "-r", "near", "-overwrite"))
    sf::gdal_utils("translate", source = wgs, destination = out_kmz,
                   options = c("-of", "KMLSUPEROVERLAY", "-co", "FORMAT=PNG"))
    cat("Wrote", out_kmz, "(open in Google Earth)\n")
  }, error = function(e) message("KMZ step skipped: ", conditionMessage(e)))
}

cat("\nDone. Open ", out_tif, " in QGIS with Layer > Add Layer > Add RASTER Layer.\n", sep = "")
