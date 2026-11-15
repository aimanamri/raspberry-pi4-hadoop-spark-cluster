"""Restaurant: orders joined to restaurants.
Cleans bad dates, impossible hours, null or zero quantity and price, duplicates; null discount counts as 0.
Revenue = qty * unit_price * (1 - discount_pct / 100). Writes:
  city_cuisine (orders and revenue), top_items (top 10 by revenue),
  peak_hour (busiest hour per cuisine by revenue, window row_number).

Input : <input_base>/restaurant/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/restaurant/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn restaurant.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-restaurant-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/restaurant/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/restaurant/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("restaurant", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/restaurant/pyspark/summary")
    spark.stop()


od = read("orders")
raw = od.count()
parts = od.rdd.getNumPartitions()
od = (od.dropDuplicates(["order_id"])
      .withColumn("order_date", F.to_date("order_date", "yyyy-MM-dd"))
      .withColumn("order_hour", F.col("order_hour").cast("int"))
      .withColumn("qty", F.col("qty").cast("int"))
      .withColumn("unit_price", F.col("unit_price").cast("double"))
      .withColumn("discount_pct", F.coalesce(F.col("discount_pct").cast("double"), F.lit(0.0)))
      .filter(F.col("order_date").isNotNull() & F.col("order_hour").between(0, 23) & (F.col("qty") > 0) & (F.col("unit_price") > 0))
      .withColumn("revenue", F.col("qty") * F.col("unit_price") * (1 - F.col("discount_pct") / 100)))
df = od.join(read("restaurants"), "restaurant_id")

save(df.groupBy("city", "cuisine")
     .agg(F.count("*").alias("orders"), F.round(F.sum("revenue"), 2).alias("revenue"), F.round(F.avg("revenue"), 2).alias("avg_order"))
     .orderBy("city", "cuisine"), "city_cuisine")
save(df.groupBy("item").agg(F.round(F.sum("revenue"), 2).alias("revenue"), F.sum("qty").alias("units"))
     .orderBy(F.desc("revenue"), "item").limit(10), "top_items")
peak = (df.groupBy("cuisine", "order_hour").agg(F.sum("revenue").alias("revenue"))
        .withColumn("rn", F.row_number().over(Window.partitionBy("cuisine").orderBy(F.desc("revenue"), "order_hour")))
        .filter(F.col("rn") == 1).select("cuisine", F.col("order_hour").alias("peak_hour"), F.round("revenue", 2).alias("revenue"))
        .orderBy("cuisine"))
save(peak, "peak_hour")

finish(parts, raw_rows=raw, clean_rows=df.count(), total_revenue=f"{df.agg(F.sum('revenue')).first()[0]:.2f}",
       discounted_orders=df.filter(F.col("discount_pct") > 0).count())
