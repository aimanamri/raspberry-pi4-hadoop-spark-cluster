# Political: opinion polls joined to regions.
# Cleans bad dates, support outside 0-100, null or zero sample size, duplicates.
# Weighted support = sum(support_pct * sample_size) / sum(sample_size). Writes:
#   party_area (weighted support by party and area type), top_unity_regions (top 10 regions for Unity, at least 20 polls),
#   region_leader (leading party per region, window row_number, and how many regions each party leads).
#
# Input : <input_base>/political/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/political/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn political.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-political-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/political/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/political/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=political lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/political/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

pl <- read("polls")
raw <- count(pl); parts <- getNumPartitions(pl)
pl <- dropDuplicates(pl, "poll_id")
pl$poll_date <- to_date(pl$poll_date, "yyyy-MM-dd")
pl$support_pct <- cast(pl$support_pct, "double")
pl$sample_size <- cast(pl$sample_size, "int")
pl <- filter(pl, isNotNull(pl$poll_date) & between(pl$support_pct, c(0, 100)) & pl$sample_size > 0)
df <- ijoin(pl, read("regions"), "region_id")
df$w <- df$support_pct * df$sample_size

g <- agg(groupBy(df, "party", "area_type"), polls = count(lit(1)), weighted_support = rnd(sum(df$w) / sum(df$sample_size), 2))
save(orderBy(g, "party", "area_type"), "party_area")
u <- filter(df, df$party == "Unity")
g <- agg(groupBy(u, "region_id", "region_name"), polls = count(lit(1)), weighted_support = rnd(sum(u$w) / sum(u$sample_size), 2))
g <- filter(g, g$polls >= 20)
save(limit(arrange(g, desc(g$weighted_support), asc(g$region_id)), 10L), "top_unity_regions")
l <- agg(groupBy(df, "region_id", "party"), w = sum(df$w))
l$rn <- over(row_number(), orderBy(windowPartitionBy("region_id"), desc(l$w), asc(l$party)))
l <- filter(l, l$rn == 1)
save(orderBy(agg(groupBy(l, "party"), regions_led = count(lit(1))), "party"), "region_leader")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), weighted_support = num(one(df, sum(df$w) / sum(df$sample_size)), 3),
       regions = num(count(distinct(select(df, "region_id")))))
