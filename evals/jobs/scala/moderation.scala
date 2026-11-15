/*
 * Content moderation: abuse reports joined to moderators.
 * Cleans bad dates, null or negative review time, messy reason text, duplicates. Writes:
 *   reason_content (reports, review time, removal percent), top_moderators (top 10 by reports),
 *   slow_moderators (moderators 20 percent slower than their region average, window average).
 *
 * Input : <input>/moderation/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/moderation/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i moderation.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/moderation/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/moderation/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=moderation lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/moderation/scala/summary") // kept for the runner
}

try {
val rp0 = read("reports")
val raw = rp0.count(); val parts = rp0.rdd.getNumPartitions
val rp = rp0.dropDuplicates("report_id")
  .withColumn("report_date", to_date(col("report_date"), "yyyy-MM-dd"))
  .withColumn("review_seconds", col("review_seconds").cast("int"))
  .withColumn("reason", lower(trim(col("reason"))))
  .filter(col("report_date").isNotNull && col("review_seconds") > 0)
  .withColumn("removed", col("action").isin("remove", "ban").cast("int"))
val df = rp.join(read("moderators"), "moderator_id")

save(df.groupBy("reason", "content_type")
  .agg(count("*").alias("reports"), round(avg("review_seconds"), 2).alias("avg_review_sec"),
    round(lit(100) * avg("removed"), 2).alias("removal_pct"))
  .orderBy("reason", "content_type"), "reason_content")
save(df.groupBy("moderator_id", "region").agg(count("*").alias("reports"))
  .orderBy(desc("reports"), col("moderator_id")).limit(10), "top_moderators")
val slow = df.withColumn("region_avg", avg("review_seconds").over(Window.partitionBy("region")))
  .groupBy("moderator_id", "region").agg(avg("review_seconds").alias("avg_sec"), first("region_avg").alias("region_avg"))
  .filter(col("avg_sec") > lit(1.2) * col("region_avg"))
  .select(col("moderator_id"), col("region"), round(col("avg_sec"), 2).alias("avg_sec"), round(col("region_avg"), 2).alias("region_avg"))
  .orderBy("region", "moderator_id")
save(slow, "slow_moderators")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "removal_pct" -> fmt(100 * df.agg(avg("removed")).first.getDouble(0), 2),
  "slow_moderators" -> slow.count())
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
