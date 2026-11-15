# Healthcare: clinic visits joined to patients.
# Cleans bad dates, null or negative cost, null duration, duplicates. Age is derived from birth_year. Writes:
#   dept_age (visits, cost, duration by department and age group), top_diagnoses (top 10 by total cost),
#   readmissions (visits within 30 days of the same patient's previous visit, window lag, per department).
#
# Input : <input_base>/healthcare/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/healthcare/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn healthcare.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-healthcare-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/healthcare/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/healthcare/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=healthcare lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/healthcare/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

vs <- read("visits")
raw <- count(vs); parts <- getNumPartitions(vs)
vs <- dropDuplicates(vs, "visit_id")
vs$visit_date <- to_date(vs$visit_date, "yyyy-MM-dd")
vs$cost <- cast(vs$cost, "double")
vs$duration_min <- cast(vs$duration_min, "int")
vs <- filter(vs, isNotNull(vs$visit_date) & vs$cost > 0 & vs$duration_min > 0)
df <- ijoin(vs, read("patients"), "patient_id")
age <- year(df$visit_date) - cast(df$birth_year, "int")
df$age_group <- ifelse(age < 18, "0-17", ifelse(age < 40, "18-39", ifelse(age < 65, "40-64", "65+")))

g <- agg(groupBy(df, "department", "age_group"), visits = count(lit(1)), avg_cost = rnd(avg(df$cost), 2),
         avg_duration_min = rnd(avg(df$duration_min), 2))
save(orderBy(g, "department", "age_group"), "dept_age")
g <- agg(groupBy(df, "diagnosis"), total_cost = rnd(sum(df$cost), 2), visits = count(lit(1)))
save(limit(arrange(g, desc(g$total_cost), asc(g$diagnosis)), 10L), "top_diagnoses")
prev <- over(lag(df$visit_date, 1), orderBy(windowPartitionBy("patient_id"), "visit_date", "visit_id"))
df$readmit <- cast(datediff(df$visit_date, prev) <= 30, "int")
g <- agg(groupBy(df, "department"), visits = count(lit(1)), readmissions = sum(df$readmit))
g$readmit_pct <- rnd(g$readmissions * 100 / g$visits, 2)
save(orderBy(g, "department"), "readmissions")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), total_cost = num(one(df, sum(df$cost)), 2),
       readmissions = num(one(df, sum(df$readmit))))
