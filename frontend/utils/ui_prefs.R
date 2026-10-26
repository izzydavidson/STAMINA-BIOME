# ── ui_prefs.R ─────────────────────────────────────────────────────────────
# Persist last-used file/directory locations across app sessions.
# Stored in ~/.stbiom_ui_prefs.rds (user home, never committed to repo).
# ─────────────────────────────────────────────────────────────────────────────

.STBIOM_PREFS_FILE <- file.path(Sys.getenv("HOME"), ".stbiom_ui_prefs.rds")

.load_ui_prefs <- function() {
  if (file.exists(.STBIOM_PREFS_FILE)) {
    tryCatch(readRDS(.STBIOM_PREFS_FILE), error = function(e) list())
  } else list()
}

save_ui_pref <- function(key, value) {
  p <- .load_ui_prefs()
  p[[key]] <- value
  tryCatch(saveRDS(p, .STBIOM_PREFS_FILE), error = function(e) NULL)
}

get_ui_pref <- function(key, default = NULL) {
  .load_ui_prefs()[[key]] %||% default
}

# Given an absolute file/directory path and the volumes list, return
# list(root = "VolumeName", rel = "relative/path") for use with
# shinyFileChoose / shinyDirChoose defaultRoot + defaultPath.
vol_for_path <- function(abs_path, volumes) {
  dir_path <- if (dir.exists(abs_path)) abs_path else dirname(abs_path)
  dir_path <- normalizePath(dir_path, mustWork = FALSE)
  sep <- .Platform$file.sep
  for (nm in names(volumes)) {
    vp <- normalizePath(as.character(volumes[[nm]]), mustWork = FALSE)
    if (startsWith(dir_path, paste0(vp, sep)) || dir_path == vp) {
      rel <- sub(paste0("^", vp, sep, "?"), "", dir_path)
      return(list(root = nm, rel = rel))
    }
  }
  list(root = names(volumes)[1], rel = "")
}
