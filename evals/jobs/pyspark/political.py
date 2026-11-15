"""Political: opinion polls joined to regions.
Cleans bad dates, support outside 0-100, null or zero sample size, duplicates.
Weighted support = sum(support_pct * sample_size) / sum(sample_size). Writes:
  party_area (weighted support by party and area type), top_unity_regions (top 10 regions for Unity, at least 20 polls),
  region_leader (leading party per region, window row_number, and how many regions each party leads).

Input : <input_base>/political/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/political/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn political.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-political-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/political/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/political/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("political", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/political/pyspark/summary")
    spark.stop()


pl = read("polls")
raw = pl.count()
parts = pl.rdd.getNumPartitions()
pl = (pl.dropDuplicates(["poll_id"])
      .withColumn("poll_date", F.to_date("poll_date", "yyyy-MM-dd"))
      .withColumn("support_pct", F.col("support_pct").cast("double"))
      .withColumn("sample_size", F.col("sample_size").cast("int"))
      .filter(F.col("poll_date").isNotNull() & F.col("support_pct").between(0, 100) & (F.col("sample_size") > 0)))
df = pl.join(read("regions"), "region_id")
weighted = F.round(F.sum(F.col("support_pct") * F.col("sample_size")) / F.sum("sample_size"), 2).alias("weighted_support")

save(df.groupBy("party", "area_type").agg(F.count("*").alias("polls"), weighted).orderBy("party", "area_type"), "party_area")
save(df.filter(F.col("party") == "Unity").groupBy("region_id", "region_name").agg(F.count("*").alias("polls"), weighted)
     .filter(F.col("polls") >= 20).orderBy(F.desc("weighted_support"), "region_id").limit(10), "top_unity_regions")
leader = (df.groupBy("region_id", "party").agg(F.sum(F.col("support_pct") * F.col("sample_size")).alias("w"))
          .withColumn("rn", F.row_number().over(Window.partitionBy("region_id").orderBy(F.desc("w"), "party")))
          .filter(F.col("rn") == 1).groupBy("party").agg(F.count("*").alias("regions_led")).orderBy("party"))
save(leader, "region_leader")

tot = df.agg((F.sum(F.col("support_pct") * F.col("sample_size")) / F.sum("sample_size")).alias("ws")).first()["ws"]
finish(parts, raw_rows=raw, clean_rows=df.count(), weighted_support=f"{tot:.3f}", regions=df.select("region_id").distinct().count())
