"""Education: course grades joined to courses.
Cleans bad dates, scores outside 0-100, null scores, duplicates. Pass mark is 50. Writes:
  dept_term (average score and pass rate), top_students (top 10 by credit-weighted score, at least 5 grades),
  top3_per_course (grades ranked 1-3 in their course, window rank, counted per department).

Input : <input_base>/education/*.csv          (default input_base  = hdfs:///evals)
Output: <output_base>/education/pyspark/<name>/  CSV with header (default output_base = hdfs:///evals-out)
Run   : spark-submit --master yarn education.py [input_base] [output_base]
Prints: one EVAL_SUMMARY line (same keys in the Scala and R job), EVAL_HOSTS, EVAL_STATUS.
"""
import re
import sys

from pyspark.sql import SparkSession, Window, functions as F

IN = sys.argv[1] if len(sys.argv) > 1 else "hdfs:///evals"
OUT = sys.argv[2] if len(sys.argv) > 2 else "hdfs:///evals-out"
spark = SparkSession.builder.appName("eval-education-pyspark").getOrCreate()
spark.conf.set("spark.sql.ansi.enabled", "false")  # bad values become null instead of an error


def read(name):
    return spark.read.option("header", True).csv(f"{IN}/education/{name}.csv")


def save(df, name):
    df.coalesce(1).write.mode("overwrite").option("header", True).csv(f"{OUT}/education/pyspark/{name}")


def finish(parts, **summary):
    # Hosts that run a Spark JVM for this application (the driver and the executors).
    keys = spark.sparkContext._jsc.sc().getExecutorMemoryStatus().keySet().toString()
    lines = ["EVAL_SUMMARY domain=%s lang=pyspark partitions=%d " % ("education", parts) + " ".join(f"{k}={v}" for k, v in summary.items()),
             "EVAL_HOSTS " + ",".join(sorted(set(re.findall(r"([A-Za-z0-9_.-]+):\d+", keys)))),
             "EVAL_STATUS OK"]
    print("\n".join(lines))
    # Also save the lines in the output folder: in cluster mode the driver output stays in the YARN logs.
    spark.createDataFrame([(x,) for x in lines], "value string").coalesce(1).write.mode("overwrite").text(f"{OUT}/education/pyspark/summary")
    spark.stop()


gr = read("grades")
raw = gr.count()
parts = gr.rdd.getNumPartitions()
gr = (gr.dropDuplicates(["grade_id"])
      .withColumn("graded_date", F.to_date("graded_date", "yyyy-MM-dd"))
      .withColumn("score", F.col("score").cast("double"))
      .filter(F.col("graded_date").isNotNull() & F.col("score").between(0, 100)))
df = gr.join(read("courses").withColumn("credits", F.col("credits").cast("int")), "course_id")

save(df.groupBy("department", "term")
     .agg(F.count("*").alias("grades"), F.round(F.avg("score"), 2).alias("avg_score"),
          F.round(100 * F.avg((F.col("score") >= 50).cast("int")), 2).alias("pass_pct"))
     .orderBy("department", "term"), "dept_term")
save(df.groupBy("student_id").agg(F.count("*").alias("grades"),
                                  F.round(F.sum(F.col("score") * F.col("credits")) / F.sum("credits"), 2).alias("weighted_score"))
     .filter(F.col("grades") >= 5).orderBy(F.desc("weighted_score"), "student_id").limit(10), "top_students")
top3 = (df.withColumn("rank", F.rank().over(Window.partitionBy("course_id").orderBy(F.desc("score"))))
        .filter(F.col("rank") <= 3).groupBy("department").agg(F.count("*").alias("top3_entries")).orderBy("department"))
save(top3, "top3_per_course")

finish(parts, raw_rows=raw, clean_rows=df.count(), avg_score=f"{df.agg(F.avg('score')).first()[0]:.3f}",
       top3_entries=top3.agg(F.sum("top3_entries")).first()[0])
