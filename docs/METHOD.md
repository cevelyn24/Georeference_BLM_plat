# Method notes

## Goal
Place a 1911 GLO plat of T30S R33E (Mount Diablo Meridian, Kern Co., CA) in
real-world coordinates as accurately as the source allows, so that features
(here, Studhorse Canyon) can be located from it.

## Control points
Ground control points are the PLSS section and quarter corners published by the
BLM (CA CadNSDI, "BLM CA PLSS Corners Point", layer 0 of
`.../lands/BLM_CA_CADNSDI/MapServer`). For this township the service returns
878 subdivision points (`PLSSID = CA210300S0330E0`).

* The query returns **attributes only, no geometry**. Coordinates are taken
  from `XCOORD`/`YCOORD` (NAD83 lon/lat, degrees) and transformed to EPSG:26911.
* `POINTLAB` is a 6-digit code: `EEENNN` (3 digits east, 3 digits north).
  The first digit of each half is the mile line + 1 (1..6 = 0..5 miles from the
  SW township corner, so `100100` is the SW township corner). `40` in the tens
  position marks a half-mile point (quarter corner). This was worked out for
  this township from the data; it is **an inference, verify it before reusing
  on another township**.
* The 6x6 section-corner grid is `[1-6]00[1-6]00` (36 points) plus 72 quarter
  corners. The east and north township lines are not in this township's
  records (presumably stored with the neighbouring townships).
* Section number -> corner labels: row from the north R = ceiling(s/6),
  p = (s-1) mod 6 + 1, column C = 7-p for odd R else p. East/west lines are
  labelled C and C+1; south/north lines 7-R and 8-R.

## Warp
Clicks (pixel positions of corners on the scan) and BLM coordinates are given to
GDAL as `-gcp` options; the image is warped with `-tps` (thin plate spline,
exact at every control point), nearest-neighbour resampling, EPSG:26911,
with an alpha band for the empty margin. A KMZ super-overlay is optional.

Conventions: terra raster y counts **up** from the bottom; GDAL "line" counts
**down** from the top, so line = nrow - y.

## Accuracy
Residuals at control points are zero by construction for an exact spline, so the
script reports **leave-one-out (LOO)** error: each point is predicted from all
the others. This folds together click error, plat distortion and BLM coordinate
error.

Example (56 control points, scan 5193 x 4241 px, about 3.5 m/px):

| | metres |
|---|---|
| median LOO | 6.1 |
| 90th percentile | 16.3 |
| max | 21.7 |

Edge corners are higher because they are extrapolated from one side. BLM's own
stated reliability is about 5-6 ft for interior corners, 25-39 ft for edge
corners and up to 50 ft for some quarter corners.

Drawn lines are 4-6 px wide (roughly 15-20 m), so about 3-6 px is the floor for
how well a corner can be clicked.

## Known disagreement: south-line quarter corners
On the south township line BLM's quarter corners lie 40-55 m from the midpoint,
while the plat draws them at the midpoint. They are excluded from the fit
(`exclude_labs`). Two interior quarter corners with 20-26 m LOO error are also
excluded; you can put them back and re-inspect.

## What this does not do
The canyon and drainage lines on the plat are surveyors' sketches. The warp
places the *plat* accurately; it cannot make a sketched feature more accurate
than the sketch. Treat positions read from sketched features as approximate.

## Data sources
* BLM, Cadastral National Spatial Data Infrastructure (CadNSDI) PLSS, California
  corner points (public ArcGIS REST service).
* Plat image: General Land Office / BLM Records (the user supplies the scan; see README).
