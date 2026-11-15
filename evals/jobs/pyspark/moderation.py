"""Content moderation: abuse reports joined to moderators.
Cleans bad dates, null or negative review time, messy reason text, duplicates. Writes:
  reason_content (reports, review time, removal percent), top_moderators (top 10 by reports),
  slow_moderators (moderators 20 percent slower than their region average, window average).

Input : <input_base>/moderation/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/moderation/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn moderation.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-moderation-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/moderation/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/moderation/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("moderation", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/moderation/pyspark/summary")
    spark.stop()


rp = read("reports")
raw = rp.count()
parts = rp.rdd.getNumPartitions()
rp = (rp.dropDuplicates(["report_id"])
      .withColumn("report_date", F.to_date("report_date", "yyyy-MM-dd"))
      .withColumn("review_seconds", F.col("review_seconds").cast("int"))
      .withColumn("reason", F.lower(F.trim("reason")))
      .filter(F.col("report_date").isNotNull() & (F.col("review_seconds") > 0))
      .withColumn("removed", F.col("action").isin("remove", "ban").cast("int")))
df = rp.join(read("moderators"), "moderator_id")

save(df.groupBy("reason", "content_type")
     .agg(F.count("*").alias("reports"), F.round(F.avg("review_seconds"), 2).alias("avg_review_sec"),
          F.round(100 * F.avg("removed"), 2).alias("removal_pct"))
     .orderBy("reason", "content_type"), "reason_content")
save(df.groupBy("moderator_id", "region").agg(F.count("*").alias("reports"))
     .orderBy(F.desc("reports"), "moderator_id").limit(10), "top_moderators")
slow = (df.withColumn("region_avg", F.avg("review_seconds").over(Window.partitionBy("region")))
        .groupBy("moderator_id", "region").agg(F.avg("review_seconds").alias("avg_sec"), F.first("region_avg").alias("region_avg"))
        .filter(F.col("avg_sec") > 1.2 * F.col("region_avg"))
        .select("moderator_id", "region", F.round("avg_sec", 2).alias("avg_sec"), F.round("region_avg", 2).alias("region_avg"))
        .orderBy("region", "moderator_id"))
save(slow, "slow_moderators")

finish(parts, raw_rows=raw, clean_rows=df.count(), removal_pct=f"{100 * df.agg(F.avg('removed')).first()[0]:.2f}",
       slow_moderators=slow.count())
