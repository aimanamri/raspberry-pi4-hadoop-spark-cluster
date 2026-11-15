# Energy: smart-meter readings joined to meters.
# Cleans bad dates, bad hours, null or negative kWh, duplicates. Writes:
#   district_tariff (total and average kWh), top_meters (top 10 by kWh),
#   anomalies (readings above the meter's mean + 3 standard deviations, window statistics, per district).
#
# Input : <input_base>/energy/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/energy/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn energy.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-energy-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/energy/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/energy/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=energy lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/energy/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

rd <- read("readings")
raw <- count(rd); parts <- getNumPartitions(rd)
rd <- dropDuplicates(rd, "reading_id")
rd$read_date <- to_date(rd$read_date, "yyyy-MM-dd")
rd$read_hour <- cast(rd$read_hour, "int")
rd$kwh <- cast(rd$kwh, "double")
rd <- filter(rd, isNotNull(rd$read_date) & between(rd$read_hour, c(0, 23)) & rd$kwh >= 0)
df <- ijoin(rd, read("meters"), "meter_id")

g <- agg(groupBy(df, "district", "tariff"), readings = count(lit(1)), total_kwh = rnd(sum(df$kwh), 2), avg_kwh = rnd(avg(df$kwh), 3))
save(orderBy(g, "district", "tariff"), "district_tariff")
g <- agg(groupBy(df, "meter_id", "district", "tariff"), total_kwh = rnd(sum(df$kwh), 2))
save(limit(arrange(g, desc(g$total_kwh), asc(g$meter_id)), 10L), "top_meters")
w <- windowPartitionBy("meter_id")
df$anomaly <- cast(df$kwh > over(avg(df$kwh), w) + over(stddev_samp(df$kwh), w) * 3, "int")
g <- agg(groupBy(df, "district"), anomalies = sum(df$anomaly), readings = count(lit(1)))
g$anomaly_pct <- rnd(g$anomalies * 100 / g$readings, 3)
save(orderBy(g, "district"), "anomalies")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), total_kwh = num(one(df, sum(df$kwh)), 2),
       anomalies = num(one(df, sum(df$anomaly))))
