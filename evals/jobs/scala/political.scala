/*
 * Political: opinion polls joined to regions.
 * Cleans bad dates, support outside 0-100, null or zero sample size, duplicates.
 * Weighted support = sum(support_pct * sample_size) / sum(sample_size). Writes:
 *   party_area (weighted support by party and area type), top_unity_regions (top 10 regions for Unity, at least 20 polls),
 *   region_leader (leading party per region, window row_number, and how many regions each party leads).
 *
 * Input : <input>/political/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/political/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i political.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/political/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/political/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=political lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/political/scala/summary") // kept for the runner
}

try {
val pl0 = read("polls")
val raw = pl0.count(); val parts = pl0.rdd.getNumPartitions
val pl = pl0.dropDuplicates("poll_id")
  .withColumn("poll_date", to_date(col("poll_date"), "yyyy-MM-dd"))
  .withColumn("support_pct", col("support_pct").cast("double"))
  .withColumn("sample_size", col("sample_size").cast("int"))
  .filter(col("poll_date").isNotNull && col("support_pct").between(0, 100) && col("sample_size") > 0)
val df = pl.join(read("regions"), "region_id")
val wsum = sum(col("support_pct") * col("sample_size"))
val weighted = round(wsum / sum("sample_size"), 2).alias("weighted_support")

save(df.groupBy("party", "area_type").agg(count("*").alias("polls"), weighted).orderBy("party", "area_type"), "party_area")
save(df.filter(col("party") === "Unity").groupBy("region_id", "region_name").agg(count("*").alias("polls"), weighted)
  .filter(col("polls") >= 20).orderBy(desc("weighted_support"), col("region_id")).limit(10), "top_unity_regions")
val leader = df.groupBy("region_id", "party").agg(wsum.alias("w"))
  .withColumn("rn", row_number().over(Window.partitionBy("region_id").orderBy(desc("w"), col("party"))))
  .filter(col("rn") === 1).groupBy("party").agg(count("*").alias("regions_led")).orderBy("party")
save(leader, "region_leader")

val tot = df.agg((wsum / sum("sample_size")).alias("ws")).first.getDouble(0)
finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "weighted_support" -> fmt(tot, 3), "regions" -> df.select("region_id").distinct().count())
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
