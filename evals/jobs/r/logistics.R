# Logistics: shipments joined to carriers.
# Cleans bad dates, delivery before shipping, null or zero weight and cost, duplicates. Writes:
#   carrier_performance (transit days, late percent, cost per kg), top_routes (top 10 origin-destination pairs),
#   monthly_change (shipments per carrier and month, change from the previous month, window lag).
#
# Input : <input_base>/logistics/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/logistics/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn logistics.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-logistics-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/logistics/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/logistics/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=logistics lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/logistics/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

sh <- read("shipments")
raw <- count(sh); parts <- getNumPartitions(sh)
sh <- dropDuplicates(sh, "shipment_id")
sh$ship_date <- to_date(sh$ship_date, "yyyy-MM-dd")
sh$delivery_date <- to_date(sh$delivery_date, "yyyy-MM-dd")
sh$weight_kg <- cast(sh$weight_kg, "double")
sh$cost <- cast(sh$cost, "double")
sh <- filter(sh, isNotNull(sh$ship_date) & isNotNull(sh$delivery_date) & sh$weight_kg > 0 &
               isNotNull(sh$cost) & sh$delivery_date >= sh$ship_date)
sh$transit_days <- datediff(sh$delivery_date, sh$ship_date)
df <- ijoin(sh, read("carriers"), "carrier_id")
df$month <- date_format(df$ship_date, "yyyy-MM")

g <- agg(groupBy(df, "carrier_name", "mode"), shipments = count(lit(1)), avg_transit_days = rnd(avg(df$transit_days), 2),
         late_pct = rnd(avg(cast(df$transit_days > 7, "int")) * 100, 2), cost_per_kg = rnd(sum(df$cost) / sum(df$weight_kg), 3))
save(orderBy(g, "carrier_name"), "carrier_performance")
g <- agg(groupBy(df, "origin", "destination"), shipments = count(lit(1)))
save(limit(arrange(g, desc(g$shipments), asc(g$origin), asc(g$destination)), 10L), "top_routes")
g <- agg(groupBy(df, "carrier_name", "month"), shipments = count(lit(1)))
g$prev <- over(lag(g$shipments, 1), orderBy(windowPartitionBy("carrier_name"), "month"))
g$change <- g$shipments - g$prev
save(orderBy(drop(g, "prev"), "carrier_name", "month"), "monthly_change")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), total_cost = num(one(df, sum(df$cost)), 2),
       late_shipments = num(count(filter(df, df$transit_days > 7))))
