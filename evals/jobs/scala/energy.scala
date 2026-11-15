/*
 * Energy: smart-meter readings joined to meters.
 * Cleans bad dates, bad hours, null or negative kWh, duplicates. Writes:
 *   district_tariff (total and average kWh), top_meters (top 10 by kWh),
 *   anomalies (readings above the meter's mean + 3 standard deviations, window statistics, per district).
 *
 * Input : <input>/energy/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/energy/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i energy.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/energy/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/energy/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=energy lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/energy/scala/summary") // kept for the runner
}

try {
val rd0 = read("readings")
val raw = rd0.count(); val parts = rd0.rdd.getNumPartitions
val rd = rd0.dropDuplicates("reading_id")
  .withColumn("read_date", to_date(col("read_date"), "yyyy-MM-dd"))
  .withColumn("read_hour", col("read_hour").cast("int"))
  .withColumn("kwh", col("kwh").cast("double"))
  .filter(col("read_date").isNotNull && col("read_hour").between(0, 23) && col("kwh") >= 0)
val df = rd.join(read("meters"), "meter_id")

save(df.groupBy("district", "tariff")
  .agg(count("*").alias("readings"), round(sum("kwh"), 2).alias("total_kwh"), round(avg("kwh"), 3).alias("avg_kwh"))
  .orderBy("district", "tariff"), "district_tariff")
save(df.groupBy("meter_id", "district", "tariff").agg(round(sum("kwh"), 2).alias("total_kwh"))
  .orderBy(desc("total_kwh"), col("meter_id")).limit(10), "top_meters")
val w = Window.partitionBy("meter_id")
val an = df.withColumn("anomaly", (col("kwh") > avg("kwh").over(w) + lit(3) * stddev_samp("kwh").over(w)).cast("int"))
save(an.groupBy("district").agg(sum("anomaly").alias("anomalies"), count("*").alias("readings"))
  .withColumn("anomaly_pct", round(lit(100) * col("anomalies") / col("readings"), 3)).orderBy("district"), "anomalies")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "total_kwh" -> fmt(df.agg(sum("kwh")).first.getDouble(0), 2),
  "anomalies" -> an.agg(sum("anomaly")).first.getLong(0))
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
