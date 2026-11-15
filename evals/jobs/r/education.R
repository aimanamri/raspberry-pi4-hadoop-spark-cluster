# Education: course grades joined to courses.
# Cleans bad dates, scores outside 0-100, null scores, duplicates. Pass mark is 50. Writes:
#   dept_term (average score and pass rate), top_students (top 10 by credit-weighted score, at least 5 grades),
#   top3_per_course (grades ranked 1-3 in their course, window rank, counted per department).
#
# Input : <input_base>/education/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/education/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn education.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-education-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/education/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/education/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=education lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/education/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

gr <- read("grades")
raw <- count(gr); parts <- getNumPartitions(gr)
gr <- dropDuplicates(gr, "grade_id")
gr$graded_date <- to_date(gr$graded_date, "yyyy-MM-dd")
gr$score <- cast(gr$score, "double")
gr <- filter(gr, isNotNull(gr$graded_date) & between(gr$score, c(0, 100)))
co <- read("courses")
co$credits <- cast(co$credits, "int")
df <- ijoin(gr, co, "course_id")

g <- agg(groupBy(df, "department", "term"), grades = count(lit(1)), avg_score = rnd(avg(df$score), 2),
         pass_pct = rnd(avg(cast(df$score >= 50, "int")) * 100, 2))
save(orderBy(g, "department", "term"), "dept_term")
g <- agg(groupBy(df, "student_id"), grades = count(lit(1)), weighted_score = rnd(sum(df$score * df$credits) / sum(df$credits), 2))
g <- filter(g, g$grades >= 5)
save(limit(arrange(g, desc(g$weighted_score), asc(g$student_id)), 10L), "top_students")
df$rank <- over(rank(), orderBy(windowPartitionBy("course_id"), desc(df$score)))
t3 <- agg(groupBy(filter(df, df$rank <= 3), "department"), top3_entries = count(lit(1)))
save(orderBy(t3, "department"), "top3_per_course")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), avg_score = num(one(df, avg(df$score)), 3),
       top3_entries = num(one(t3, sum(t3$top3_entries))))
