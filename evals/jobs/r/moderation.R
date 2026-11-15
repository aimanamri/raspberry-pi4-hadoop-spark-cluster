# Content moderation: abuse reports joined to moderators.
# Cleans bad dates, null or negative review time, messy reason text, duplicates. Writes:
#   reason_content (reports, review time, removal percent), top_moderators (top 10 by reports),
#   slow_moderators (moderators 20 percent slower than their region average, window average).
#
# Input : <input_base>/moderation/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/moderation/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn moderation.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-moderation-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/moderation/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/moderation/r/", name), source = "csv", mode = "overwrite", header = "true")
one <- function(df, expr) collect(agg(df, expr))[1, 1]   # one number from an aggregate
# SparkR joins need a Column expression: rename the key on the right side, join, then drop it.
ijoin <- function(x, y, key) {
  y <- withColumnRenamed(y, key, "key_r")
  drop(join(x, y, x[[key]] == y$key_r), "key_r")
}
# SparkR round() ignores the digits argument, so call the Spark SQL function directly.
rnd <- function(x, d) SparkR:::column(SparkR:::callJStatic("org.apache.spark.sql.functions", "round", x@jc, as.integer(d)))
num <- function(x, d = 0) sprintf(paste0("%.", d, "f"), x)
finish <- function(parts, ...) {
  kv <- list(...)
  # Hosts that run a Spark JVM for this application (the driver and the executors).
  jsc <- SparkR:::getSparkContext()
  infos <- SparkR:::callJMethod(SparkR:::callJMethod(jsc, "statusTracker"), "getExecutorInfos")
  hosts <- vapply(infos, function(i) SparkR:::callJMethod(i, "host"), "")
  lines <- c(paste0("EVAL_SUMMARY domain=moderation lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/moderation/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

rp <- read("reports")
raw <- count(rp); parts <- getNumPartitions(rp)
rp <- dropDuplicates(rp, "report_id")
rp$report_date <- to_date(rp$report_date, "yyyy-MM-dd")
rp$review_seconds <- cast(rp$review_seconds, "int")
rp$reason <- lower(trim(rp$reason))
rp <- filter(rp, isNotNull(rp$report_date) & rp$review_seconds > 0)
rp$removed <- cast(rp$action %in% c("remove", "ban"), "int")
df <- ijoin(rp, read("moderators"), "moderator_id")

g <- agg(groupBy(df, "reason", "content_type"), reports = count(lit(1)), avg_review_sec = rnd(avg(df$review_seconds), 2),
         removal_pct = rnd(avg(df$removed) * 100, 2))
save(orderBy(g, "reason", "content_type"), "reason_content")
g <- agg(groupBy(df, "moderator_id", "region"), reports = count(lit(1)))
save(limit(arrange(g, desc(g$reports), asc(g$moderator_id)), 10L), "top_moderators")
df$region_avg <- over(avg(df$review_seconds), windowPartitionBy("region"))
m <- agg(groupBy(df, "moderator_id", "region"), avg_sec = avg(df$review_seconds), region_avg = first(df$region_avg))
slow <- filter(m, m$avg_sec > m$region_avg * 1.2)
slow <- select(slow, slow$moderator_id, slow$region, alias(rnd(slow$avg_sec, 2), "avg_sec"), alias(rnd(slow$region_avg, 2), "region_avg"))
save(orderBy(slow, "region", "moderator_id"), "slow_moderators")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), removal_pct = num(100 * one(df, avg(df$removed)), 2),
       slow_moderators = num(count(slow)))
