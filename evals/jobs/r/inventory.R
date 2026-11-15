# Inventory: stock movements joined to products.
# Cleans bad dates, null quantities, unknown SKUs, duplicates. Writes:
#   warehouse_category (net units and stock value), top_outbound (top 10 SKUs by units out),
#   stockouts (moves that took running stock below 0, per warehouse, window running sum).
#
# Input : <input_base>/inventory/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/inventory/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn inventory.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-inventory-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/inventory/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/inventory/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=inventory lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/inventory/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

mv <- read("stock_moves")
raw <- count(mv); parts <- getNumPartitions(mv)
mv <- dropDuplicates(mv, "move_id")
mv$move_date <- to_date(mv$move_date, "yyyy-MM-dd")
mv$qty_change <- cast(mv$qty_change, "int")
mv <- filter(mv, isNotNull(mv$move_date) & isNotNull(mv$qty_change))
prod <- read("products")
prod$unit_cost <- cast(prod$unit_cost, "double")
prod$reorder_level <- cast(prod$reorder_level, "int")
df <- ijoin(mv, prod, "sku")  # inner join drops unknown SKUs

g <- agg(groupBy(df, "warehouse", "category"), net_units = sum(df$qty_change), stock_value = rnd(sum(df$qty_change * df$unit_cost), 2))
save(orderBy(g, "warehouse", "category"), "warehouse_category")
out <- filter(df, df$qty_change < 0)
g <- agg(groupBy(out, "sku"), units_out = sum(out$qty_change * -1))
save(limit(arrange(g, desc(g$units_out), asc(g$sku)), 10L), "top_outbound")
# Running sum: the sort key (move_date, move_id) is unique, so the default frame is a plain running total.
df$running <- over(sum(df$qty_change), orderBy(windowPartitionBy("sku", "warehouse"), "move_date", "move_id"))
neg <- filter(df, df$running < 0)
stock <- orderBy(agg(groupBy(neg, "warehouse"), stockout_moves = count(lit(1))), "warehouse")
save(stock, "stockouts")

s <- agg(groupBy(df, "sku", "reorder_level"), stock = sum(df$qty_change))
below <- count(filter(s, s$stock < s$reorder_level))
finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), net_units = num(one(df, sum(df$qty_change))),
       stockout_moves = num(one(stock, sum(stock$stockout_moves))), skus_below_reorder = num(below))
