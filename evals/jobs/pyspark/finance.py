"""Finance: card transactions joined to accounts.
Cleans bad dates, null or negative amounts, reversed and duplicate rows. Writes:
  monthly_by_segment (month x segment totals), top_merchants (top 10 by spend),
  flagged_by_category (transactions above 3x the average of the same account, window function).

Input : <input_base>/finance/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/finance/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn finance.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-finance-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/finance/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/finance/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("finance", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/finance/pyspark/summary")
    spark.stop()


tx = read("transactions")
raw = tx.count()
parts = tx.rdd.getNumPartitions()
tx = (tx.dropDuplicates(["txn_id"])
      .withColumn("txn_date", F.to_date("txn_date", "yyyy-MM-dd"))
      .withColumn("amount", F.col("amount").cast("double"))
      .withColumn("category", F.lower(F.trim("category")))
      .filter(F.col("txn_date").isNotNull() & (F.col("amount") > 0) & (F.col("status") != "reversed")))
df = tx.join(read("accounts"), "account_id")  # inner join drops orphan accounts

save(df.groupBy(F.date_format("txn_date", "yyyy-MM").alias("month"), "segment")
     .agg(F.count("*").alias("txns"), F.round(F.sum("amount"), 2).alias("total"), F.round(F.avg("amount"), 2).alias("avg"))
     .orderBy("month", "segment"), "monthly_by_segment")
save(df.groupBy("merchant").agg(F.round(F.sum("amount"), 2).alias("total"), F.count("*").alias("txns"))
     .orderBy(F.desc("total"), "merchant").limit(10), "top_merchants")
flag = df.withColumn("flag", (F.col("amount") > 3 * F.avg("amount").over(Window.partitionBy("account_id"))).cast("int"))
by_cat = (flag.groupBy("category").agg(F.sum("flag").alias("flagged"), F.count("*").alias("txns"))
          .withColumn("flag_pct", F.round(100 * F.col("flagged") / F.col("txns"), 2)).orderBy("category"))
save(by_cat, "flagged_by_category")

total = df.agg(F.sum("amount")).first()[0]
finish(parts, raw_rows=raw, clean_rows=df.count(), total_amount=f"{total:.2f}", flagged=flag.agg(F.sum("flag")).first()[0])
