"""IT helpdesk: tickets joined to agents.
Cleans bad dates, open tickets, closed before opened, satisfaction outside 1-5, duplicates. Writes:
  team_priority (resolution days and satisfaction), top_agents (top 10 by tickets),
  best_in_team (top 3 agents per team by satisfaction, window rank, at least 20 tickets).

Input : <input_base>/helpdesk/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/helpdesk/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn helpdesk.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-helpdesk-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/helpdesk/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/helpdesk/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("helpdesk", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/helpdesk/pyspark/summary")
    spark.stop()


tk = read("tickets")
raw = tk.count()
parts = tk.rdd.getNumPartitions()
sat = F.col("satisfaction").cast("int")
tk = (tk.dropDuplicates(["ticket_id"])
      .withColumn("opened_date", F.to_date("opened_date", "yyyy-MM-dd"))
      .withColumn("closed_date", F.to_date("closed_date", "yyyy-MM-dd"))
      .withColumn("satisfaction", F.when(sat.between(1, 5), sat))
      .filter(F.col("opened_date").isNotNull() & F.col("closed_date").isNotNull() & (F.col("closed_date") >= F.col("opened_date")))
      .withColumn("res_days", F.datediff("closed_date", "opened_date")))
df = tk.join(read("agents"), "agent_id")

save(df.groupBy("team", "priority")
     .agg(F.count("*").alias("tickets"), F.round(F.avg("res_days"), 2).alias("avg_res_days"),
          F.round(F.avg("satisfaction"), 2).alias("avg_satisfaction"))
     .orderBy("team", "priority"), "team_priority")
save(df.groupBy("agent_id", "team").agg(F.count("*").alias("tickets")).orderBy(F.desc("tickets"), "agent_id").limit(10), "top_agents")
stats = (df.groupBy("agent_id", "team").agg(F.count("*").alias("tickets"), F.avg("satisfaction").alias("avg_sat"))
         .filter((F.col("tickets") >= 20) & F.col("avg_sat").isNotNull())
         .withColumn("rank", F.row_number().over(Window.partitionBy("team").orderBy(F.desc("avg_sat"), "agent_id")))
         .filter(F.col("rank") <= 3).withColumn("avg_sat", F.round("avg_sat", 3)).orderBy("team", "rank"))
save(stats, "best_in_team")

finish(parts, raw_rows=raw, clean_rows=df.count(), avg_resolution_days=f"{df.agg(F.avg('res_days')).first()[0]:.3f}",
       sla_breaches=df.filter(F.col("res_days") > 5).count())
