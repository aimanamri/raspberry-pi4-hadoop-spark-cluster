"""Energy: smart-meter readings joined to meters.
Cleans bad dates, bad hours, null or negative kWh, duplicates. Writes:
  district_tariff (total and average kWh), top_meters (top 10 by kWh),
  anomalies (readings above the meter's mean + 3 standard deviations, window statistics, per district).

Input : <input_base>/energy/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/energy/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn energy.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-energy-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/energy/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/energy/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("energy", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/energy/pyspark/summary")
    spark.stop()


rd = read("readings")
raw = rd.count()
parts = rd.rdd.getNumPartitions()
rd = (rd.dropDuplicates(["reading_id"])
      .withColumn("read_date", F.to_date("read_date", "yyyy-MM-dd"))
      .withColumn("read_hour", F.col("read_hour").cast("int"))
      .withColumn("kwh", F.col("kwh").cast("double"))
      .filter(F.col("read_date").isNotNull() & F.col("read_hour").between(0, 23) & (F.col("kwh") >= 0)))
df = rd.join(read("meters"), "meter_id")

save(df.groupBy("district", "tariff")
     .agg(F.count("*").alias("readings"), F.round(F.sum("kwh"), 2).alias("total_kwh"), F.round(F.avg("kwh"), 3).alias("avg_kwh"))
     .orderBy("district", "tariff"), "district_tariff")
save(df.groupBy("meter_id", "district", "tariff").agg(F.round(F.sum("kwh"), 2).alias("total_kwh"))
     .orderBy(F.desc("total_kwh"), "meter_id").limit(10), "top_meters")
w = Window.partitionBy("meter_id")
an = df.withColumn("anomaly", (F.col("kwh") > F.avg("kwh").over(w) + 3 * F.stddev_samp("kwh").over(w)).cast("int"))
by_d = (an.groupBy("district").agg(F.sum("anomaly").alias("anomalies"), F.count("*").alias("readings"))
        .withColumn("anomaly_pct", F.round(100 * F.col("anomalies") / F.col("readings"), 3)).orderBy("district"))
save(by_d, "anomalies")

finish(parts, raw_rows=raw, clean_rows=df.count(), total_kwh=f"{df.agg(F.sum('kwh')).first()[0]:.2f}",
       anomalies=an.agg(F.sum("anomaly")).first()[0])
