# IT helpdesk: tickets joined to agents.
# Cleans bad dates, open tickets, closed before opened, satisfaction outside 1-5, duplicates. Writes:
#   team_priority (resolution days and satisfaction), top_agents (top 10 by tickets),
#   best_in_team (top 3 agents per team by satisfaction, window rank, at least 20 tickets).
#
# Input : <input_base>/helpdesk/<table>.csv   (default input_base  = hdfs:///evals)
# Output: <output_base>/helpdesk/r/<name>/  CSV with header (default output_base = hdfs:///evals-out)
# Run   : spark-submit --master yarn helpdesk.R [input_base] [output_base]
# Uses SparkR DataFrame operations only, so R is needed on the driver node and not on the workers.
# Prints: one EVAL_SUMMARY line (same keys in the PySpark and Scala job), EVAL_HOSTS, EVAL_STATUS.
.libPaths(c(file.path(Sys.getenv("SPARK_HOME"), "R", "lib"), .libPaths()))
suppressPackageStartupMessages(library(SparkR))

args <- commandArgs(trailingOnly = TRUE)
IN  <- if (length(args) > 0) args[1] else "hdfs:///evals"
OUT <- if (length(args) > 1) args[2] else "hdfs:///evals-out"
sparkR.session(appName = "eval-helpdesk-r")
sql("SET spark.sql.ansi.enabled=false")  # bad values become null instead of an error

read <- function(name) read.df(paste0(IN, "/helpdesk/", name, ".csv"), source = "csv", header = "true")
save <- function(df, name)
  write.df(coalesce(df, 1L), paste0(OUT, "/helpdesk/r/", name), source = "csv", mode = "overwrite", header = "true")
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
  lines <- c(paste0("EVAL_SUMMARY domain=helpdesk lang=r partitions=", parts, " ", paste(names(kv), unlist(kv), sep = "=", collapse = " ")),
             paste0("EVAL_HOSTS ", paste(sort(unique(hosts)), collapse = ",")), "EVAL_STATUS OK")
  cat(lines, sep = "\n")
  # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
  write.df(coalesce(createDataFrame(data.frame(value = lines, stringsAsFactors = FALSE)), 1L),
           paste0(OUT, "/helpdesk/r/summary"), source = "text", mode = "overwrite")
  sparkR.session.stop()
}

tk <- read("tickets")
raw <- count(tk); parts <- getNumPartitions(tk)
tk <- dropDuplicates(tk, "ticket_id")
tk$opened_date <- to_date(tk$opened_date, "yyyy-MM-dd")
tk$closed_date <- to_date(tk$closed_date, "yyyy-MM-dd")
sat <- cast(tk$satisfaction, "int")
tk$satisfaction <- when(between(sat, c(1, 5)), sat)  # outside 1-5 becomes null
tk <- filter(tk, isNotNull(tk$opened_date) & isNotNull(tk$closed_date) & tk$closed_date >= tk$opened_date)
tk$res_days <- datediff(tk$closed_date, tk$opened_date)
df <- ijoin(tk, read("agents"), "agent_id")

g <- agg(groupBy(df, "team", "priority"), tickets = count(lit(1)), avg_res_days = rnd(avg(df$res_days), 2),
         avg_satisfaction = rnd(avg(df$satisfaction), 2))
save(orderBy(g, "team", "priority"), "team_priority")
g <- agg(groupBy(df, "agent_id", "team"), tickets = count(lit(1)))
save(limit(arrange(g, desc(g$tickets), asc(g$agent_id)), 10L), "top_agents")
s <- agg(groupBy(df, "agent_id", "team"), tickets = count(lit(1)), avg_sat = avg(df$satisfaction))
s <- filter(s, s$tickets >= 20 & isNotNull(s$avg_sat))
s$rank <- over(row_number(), orderBy(windowPartitionBy("team"), desc(s$avg_sat), asc(s$agent_id)))
s <- filter(s, s$rank <= 3)
s$avg_sat <- rnd(s$avg_sat, 3)
save(orderBy(s, "team", "rank"), "best_in_team")

finish(parts, raw_rows = num(raw), clean_rows = num(count(df)), avg_resolution_days = num(one(df, avg(df$res_days)), 3),
       sla_breaches = num(count(filter(df, df$res_days > 5))))
