/*
 * Education: course grades joined to courses.
 * Cleans bad dates, scores outside 0-100, null scores, duplicates. Pass mark is 50. Writes:
 *   dept_term (average score and pass rate), top_students (top 10 by credit-weighted score, at least 5 grades),
 *   top3_per_course (grades ranked 1-3 in their course, window rank, counted per department).
 *
 * Input : <input>/education/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/education/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i education.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/education/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/education/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=education lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/education/scala/summary") // kept for the runner
}

try {
val gr0 = read("grades")
val raw = gr0.count(); val parts = gr0.rdd.getNumPartitions
val gr = gr0.dropDuplicates("grade_id")
  .withColumn("graded_date", to_date(col("graded_date"), "yyyy-MM-dd"))
  .withColumn("score", col("score").cast("double"))
  .filter(col("graded_date").isNotNull && col("score").between(0, 100))
val df = gr.join(read("courses").withColumn("credits", col("credits").cast("int")), "course_id")

save(df.groupBy("department", "term")
  .agg(count("*").alias("grades"), round(avg("score"), 2).alias("avg_score"),
    round(lit(100) * avg((col("score") >= 50).cast("int")), 2).alias("pass_pct"))
  .orderBy("department", "term"), "dept_term")
save(df.groupBy("student_id").agg(count("*").alias("grades"), round(sum(col("score") * col("credits")) / sum("credits"), 2).alias("weighted_score"))
  .filter(col("grades") >= 5).orderBy(desc("weighted_score"), col("student_id")).limit(10), "top_students")
val top3 = df.withColumn("rank", rank().over(Window.partitionBy("course_id").orderBy(desc("score"))))
  .filter(col("rank") <= 3).groupBy("department").agg(count("*").alias("top3_entries")).orderBy("department")
save(top3, "top3_per_course")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "avg_score" -> fmt(df.agg(avg("score")).first.getDouble(0), 3),
  "top3_entries" -> top3.agg(sum("top3_entries")).first.getLong(0))
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
