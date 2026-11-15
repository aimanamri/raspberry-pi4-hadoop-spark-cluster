# Finance: card transactions joined to accounts.
# Cleans bad dates, null or negative amounts, reversed and duplicate rows. Writes:
#   monthly_by_segment (month x segment totals), top_merchants (top 10 by spend),
#   flagged_by_category (transactions above 3x the average of the same account, window function).
#
# Input : <input_base>/finance/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/finance/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn finance.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-finance-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/finance/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/finance/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=finance lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/finance/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

tx <- read("transactions")
raw <- count(tx); parts <- getNumPartitions(tx)
tx <- dropDuplicates(tx, "txn_id")
tx$txn_date <- to_date(tx$txn_date, "yyyy-MM-dd")
tx$amount <- cast(tx$amount, "double")
tx$category <- lower(trim(tx$category))
tx <- filter(tx, isNotNull(tx$txn_date) & tx$amount > 0 & tx$status != "reversed")
df <- ijoin(tx, read("accounts"), "account_id")  # inner join drops orphan accounts
df$month <- date_format(df$txn_date, "yyyy-MM")

g <- agg(groupBy(df, "month", "segment"), txns = count(lit(1)), total = rnd(sum(df$amount), 2), avg = rnd(avg(df$amount), 2))
save(orderBy(g, "month", "segment"), "monthly_by_segment")
g <- agg(groupBy(df, "merchant"), total = rnd(sum(df$amount), 2), txns = count(lit(1)))
save(limit(arrange(g, desc(g$total), asc(g$merchant)), 10L), "top_merchants")
flag <- withColumn(df, "flag", cast(df$amount > over(avg(df$amount), windowPartitionBy("account_id")) * 3, "int"))
g <- agg(groupBy(flag, "category"), flagged = sum(flag$flag), txns = count(lit(1)))
g$flag_pct <- rnd(g$flagged * 100 / g$txns, 2)
save(orderBy(g, "category"), "flagged_by_category")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), total_amount = num(one(df, sum(df$amount)), 2),
       flagged = num(one(flag, sum(flag$flag))))
