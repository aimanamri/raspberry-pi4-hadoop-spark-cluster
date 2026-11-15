"""Inventory: stock movements joined to products.
Cleans bad dates, null quantities, unknown SKUs, duplicates. Writes:
  warehouse_category (net units and stock value), top_outbound (top 10 SKUs by units out),
  stockouts (moves that took running stock below 0, per warehouse, window running sum).

Input : <input_base>/inventory/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/inventory/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn inventory.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-inventory-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/inventory/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/inventory/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("inventory", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/inventory/pyspark/summary")
    spark.stop()


mv = read("stock_moves")
raw = mv.count()
parts = mv.rdd.getNumPartitions()
mv = (mv.dropDuplicates(["move_id"])
      .withColumn("move_date", F.to_date("move_date", "yyyy-MM-dd"))
      .withColumn("qty_change", F.col("qty_change").cast("int"))
      .filter(F.col("move_date").isNotNull() & F.col("qty_change").isNotNull()))
prod = (read("products").withColumn("unit_cost", F.col("unit_cost").cast("double"))
        .withColumn("reorder_level", F.col("reorder_level").cast("int")))
df = mv.join(prod, "sku")  # inner join drops unknown SKUs

save(df.groupBy("warehouse", "category")
     .agg(F.sum("qty_change").alias("net_units"), F.round(F.sum(F.col("qty_change") * F.col("unit_cost")), 2).alias("stock_value"))
     .orderBy("warehouse", "category"), "warehouse_category")
save(df.filter(F.col("qty_change") < 0).groupBy("sku").agg(F.sum(-F.col("qty_change")).alias("units_out"))
     .orderBy(F.desc("units_out"), "sku").limit(10), "top_outbound")
w = Window.partitionBy("sku", "warehouse").orderBy("move_date", "move_id").rowsBetween(Window.unboundedPreceding, Window.currentRow)
stock = (df.withColumn("running", F.sum("qty_change").over(w)).filter(F.col("running") < 0)
         .groupBy("warehouse").agg(F.count("*").alias("stockout_moves")).orderBy("warehouse"))
save(stock, "stockouts")

below = (df.groupBy("sku", "reorder_level").agg(F.sum("qty_change").alias("stock"))
         .filter(F.col("stock") < F.col("reorder_level")).count())
finish(parts, raw_rows=raw, clean_rows=df.count(), net_units=df.agg(F.sum("qty_change")).first()[0],
       stockout_moves=stock.agg(F.sum("stockout_moves")).first()[0], skus_below_reorder=below)
