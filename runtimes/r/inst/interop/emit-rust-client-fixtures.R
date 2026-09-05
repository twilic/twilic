#!/usr/bin/env Rscript
suppressPackageStartupMessages({
  pkg_root <- Sys.getenv("TWILIC_R_ROOT", unset = normalizePath("../..", winslash = "/"))
  if (file.exists(file.path(pkg_root, "DESCRIPTION"))) {
    if (requireNamespace("pkgload", quietly = TRUE)) {
      pkgload::load_all(pkg_root, quiet = TRUE)
    } else if (requireNamespace("devtools", quietly = TRUE)) {
      devtools::load_all(pkg_root, quiet = TRUE)
    } else {
      for (f in list.files(file.path(pkg_root, "R"), pattern = "\\.R$", full.names = TRUE)) source(f)
    }
  } else {
    for (f in list.files(file.path(pkg_root, "R"), pattern = "\\.R$", full.names = TRUE)) source(f)
  }
})
cat(emit_interop_fixtures())
