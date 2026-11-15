"""Logistics: shipments joined to carriers.
Cleans bad dates, delivery before shipping, null or zero weight and cost, duplicates. Writes:
  carrier_performance (transit days, late percent, cost per kg), top_routes (top 10 origin-destination pairs),
  monthly_change (shipments per carrier and month, change from the previous month, window lag).

Input : <input_base>/logistics/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/logistics/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn logistics.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-logistics-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/logistics/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/logistics/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("logistics", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/logistics/pyspark/summary")
    spark.stop()


sh = read("shipments")
raw = sh.count()
parts = sh.rdd.getNumPartitions()
sh = (sh.dropDuplicates(["shipment_id"])
      .withColumn("ship_date", F.to_date("ship_date", "yyyy-MM-dd"))
      .withColumn("delivery_date", F.to_date("delivery_date", "yyyy-MM-dd"))
      .withColumn("weight_kg", F.col("weight_kg").cast("double"))
      .withColumn("cost", F.col("cost").cast("double"))
      .filter(F.col("ship_date").isNotNull() & F.col("delivery_date").isNotNull()
              & (F.col("weight_kg") > 0) & F.col("cost").isNotNull() & (F.col("delivery_date") >= F.col("ship_date")))
      .withColumn("transit_days", F.datediff("delivery_date", "ship_date")))
df = sh.join(read("carriers"), "carrier_id")

save(df.groupBy("carrier_name", "mode")
     .agg(F.count("*").alias("shipments"), F.round(F.avg("transit_days"), 2).alias("avg_transit_days"),
          F.round(100 * F.avg((F.col("transit_days") > 7).cast("int")), 2).alias("late_pct"),
          F.round(F.sum("cost") / F.sum("weight_kg"), 3).alias("cost_per_kg"))
     .orderBy("carrier_name"), "carrier_performance")
save(df.groupBy("origin", "destination").agg(F.count("*").alias("shipments"))
     .orderBy(F.desc("shipments"), "origin", "destination").limit(10), "top_routes")
monthly = (df.groupBy("carrier_name", F.date_format("ship_date", "yyyy-MM").alias("month")).agg(F.count("*").alias("shipments"))
           .withColumn("prev", F.lag("shipments").over(Window.partitionBy("carrier_name").orderBy("month")))
           .withColumn("change", F.col("shipments") - F.col("prev")).drop("prev").orderBy("carrier_name", "month"))
save(monthly, "monthly_change")

finish(parts, raw_rows=raw, clean_rows=df.count(), total_cost=f"{df.agg(F.sum('cost')).first()[0]:.2f}",
       late_shipments=df.filter(F.col("transit_days") > 7).count())
