"""Healthcare: clinic visits joined to patients.
Cleans bad dates, null or negative cost, null duration, duplicates. Age is derived from birth_year. Writes:
  dept_age (visits, cost, duration by department and age group), top_diagnoses (top 10 by total cost),
  readmissions (visits within 30 days of the same patient's previous visit, window lag, per department).

Input : <input_base>/healthcare/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/healthcare/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn healthcare.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-healthcare-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/healthcare/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/healthcare/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("healthcare", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/healthcare/pyspark/summary")
    spark.stop()


vs = read("visits")
raw = vs.count()
parts = vs.rdd.getNumPartitions()
vs = (vs.dropDuplicates(["visit_id"])
      .withColumn("visit_date", F.to_date("visit_date", "yyyy-MM-dd"))
      .withColumn("cost", F.col("cost").cast("double"))
      .withColumn("duration_min", F.col("duration_min").cast("int"))
      .filter(F.col("visit_date").isNotNull() & (F.col("cost") > 0) & (F.col("duration_min") > 0)))
df = vs.join(read("patients"), "patient_id")
age = F.year("visit_date") - F.col("birth_year").cast("int")
df = df.withColumn("age_group", F.when(age < 18, "0-17").when(age < 40, "18-39").when(age < 65, "40-64").otherwise("65+"))

save(df.groupBy("department", "age_group")
     .agg(F.count("*").alias("visits"), F.round(F.avg("cost"), 2).alias("avg_cost"), F.round(F.avg("duration_min"), 2).alias("avg_duration_min"))
     .orderBy("department", "age_group"), "dept_age")
save(df.groupBy("diagnosis").agg(F.round(F.sum("cost"), 2).alias("total_cost"), F.count("*").alias("visits"))
     .orderBy(F.desc("total_cost"), "diagnosis").limit(10), "top_diagnoses")
prev = F.lag("visit_date").over(Window.partitionBy("patient_id").orderBy("visit_date", "visit_id"))
rea = df.withColumn("readmit", (F.datediff("visit_date", prev) <= 30).cast("int"))
by_dept = (rea.groupBy("department").agg(F.count("*").alias("visits"), F.sum("readmit").alias("readmissions"))
           .withColumn("readmit_pct", F.round(100 * F.col("readmissions") / F.col("visits"), 2)).orderBy("department"))
save(by_dept, "readmissions")

finish(parts, raw_rows=raw, clean_rows=df.count(), total_cost=f"{df.agg(F.sum('cost')).first()[0]:.2f}",
       readmissions=rea.agg(F.sum("readmit")).first()[0])
