/*
 * Healthcare: clinic visits joined to patients.
 * Cleans bad dates, null or negative cost, null duration, duplicates. Age is derived from birth_year. Writes:
 *   dept_age (visits, cost, duration by department and age group), top_diagnoses (top 10 by total cost),
 *   readmissions (visits within 30 days of the same patient's previous visit, window lag, per department).
 *
 * Input : <input>/healthcare/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/healthcare/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i healthcare.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/healthcare/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/healthcare/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=healthcare lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/healthcare/scala/summary") // kept for the runner
}

try {
val vs0 = read("visits")
val raw = vs0.count(); val parts = vs0.rdd.getNumPartitions
val vs = vs0.dropDuplicates("visit_id")
  .withColumn("visit_date", to_date(col("visit_date"), "yyyy-MM-dd"))
  .withColumn("cost", col("cost").cast("double"))
  .withColumn("duration_min", col("duration_min").cast("int"))
  .filter(col("visit_date").isNotNull && col("cost") > 0 && col("duration_min") > 0)
val age = year(col("visit_date")) - col("birth_year").cast("int")
val df = vs.join(read("patients"), "patient_id")
  .withColumn("age_group", when(age < 18, "0-17").when(age < 40, "18-39").when(age < 65, "40-64").otherwise("65+"))

save(df.groupBy("department", "age_group")
  .agg(count("*").alias("visits"), round(avg("cost"), 2).alias("avg_cost"), round(avg("duration_min"), 2).alias("avg_duration_min"))
  .orderBy("department", "age_group"), "dept_age")
save(df.groupBy("diagnosis").agg(round(sum("cost"), 2).alias("total_cost"), count("*").alias("visits"))
  .orderBy(desc("total_cost"), col("diagnosis")).limit(10), "top_diagnoses")
val prev = lag("visit_date", 1).over(Window.partitionBy("patient_id").orderBy("visit_date", "visit_id"))
val rea = df.withColumn("readmit", (datediff(col("visit_date"), prev) <= 30).cast("int"))
save(rea.groupBy("department").agg(count("*").alias("visits"), sum("readmit").alias("readmissions"))
  .withColumn("readmit_pct", round(lit(100) * col("readmissions") / col("visits"), 2)).orderBy("department"), "readmissions")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "total_cost" -> fmt(df.agg(sum("cost")).first.getDouble(0), 2),
  "readmissions" -> rea.agg(sum("readmit")).first.getLong(0))
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
