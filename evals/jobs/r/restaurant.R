# Restaurant: orders joined to restaurants.
# Cleans bad dates, impossible hours, null or zero quantity and price, duplicates; null discount counts as 0.
# Revenue = qty * unit_price * (1 - discount_pct / 100). Writes:
#   city_cuisine (orders and revenue), top_items (top 10 by revenue),
#   peak_hour (busiest hour per cuisine by revenue, window row_number).
#
# Input : <input_base>/restaurant/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/restaurant/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn restaurant.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-restaurant-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/restaurant/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/restaurant/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=restaurant lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/restaurant/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

od <- read("orders")
raw <- count(od); parts <- getNumPartitions(od)
od <- dropDuplicates(od, "order_id")
od$order_date <- to_date(od$order_date, "yyyy-MM-dd")
od$order_hour <- cast(od$order_hour, "int")
od$qty <- cast(od$qty, "int")
od$unit_price <- cast(od$unit_price, "double")
od$discount_pct <- coalesce(cast(od$discount_pct, "double"), lit(0))
od <- filter(od, isNotNull(od$order_date) & between(od$order_hour, c(0, 23)) & od$qty > 0 & od$unit_price > 0)
od$revenue <- od$qty * od$unit_price * (lit(1) - od$discount_pct / 100)
df <- ijoin(od, read("restaurants"), "restaurant_id")

g <- agg(groupBy(df, "city", "cuisine"), orders = count(lit(1)), revenue = rnd(sum(df$revenue), 2), avg_order = rnd(avg(df$revenue), 2))
save(orderBy(g, "city", "cuisine"), "city_cuisine")
g <- agg(groupBy(df, "item"), revenue = rnd(sum(df$revenue), 2), units = sum(df$qty))
save(limit(arrange(g, desc(g$revenue), asc(g$item)), 10L), "top_items")
h <- agg(groupBy(df, "cuisine", "order_hour"), revenue = sum(df$revenue))
h$rn <- over(row_number(), orderBy(windowPartitionBy("cuisine"), desc(h$revenue), asc(h$order_hour)))
h <- filter(h, h$rn == 1)
peak <- select(h, h$cuisine, alias(h$order_hour, "peak_hour"), alias(rnd(h$revenue, 2), "revenue"))
save(orderBy(peak, "cuisine"), "peak_hour")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), total_revenue = num(one(df, sum(df$revenue)), 2),
       discounted_orders = num(count(filter(df, df$discount_pct > 0))))
