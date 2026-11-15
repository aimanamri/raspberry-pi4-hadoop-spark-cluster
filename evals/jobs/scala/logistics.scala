/*
 * Logistics: shipments joined to carriers.
 * Cleans bad dates, delivery before shipping, null or zero weight and cost, duplicates. Writes:
 *   carrier_performance (transit days, late percent, cost per kg), top_routes (top 10 origin-destination pairs),
 *   monthly_change (shipments per carrier and month, change from the previous month, window lag).
 *
 * Input : <input>/logistics/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/logistics/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i logistics.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/logistics/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/logistics/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=logistics lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/logistics/scala/summary") // kept for the runner
}

try {
val sh0 = read("shipments")
val raw = sh0.count(); val parts = sh0.rdd.getNumPartitions
val sh = sh0.dropDuplicates("shipment_id")
  .withColumn("ship_date", to_date(col("ship_date"), "yyyy-MM-dd"))
  .withColumn("delivery_date", to_date(col("delivery_date"), "yyyy-MM-dd"))
  .withColumn("weight_kg", col("weight_kg").cast("double"))
  .withColumn("cost", col("cost").cast("double"))
  .filter(col("ship_date").isNotNull && col("delivery_date").isNotNull && col("weight_kg") > 0 &&
    col("cost").isNotNull && col("delivery_date") >= col("ship_date"))
  .withColumn("transit_days", datediff(col("delivery_date"), col("ship_date")))
val df = sh.join(read("carriers"), "carrier_id")

save(df.groupBy("carrier_name", "mode")
  .agg(count("*").alias("shipments"), round(avg("transit_days"), 2).alias("avg_transit_days"),
    round(lit(100) * avg((col("transit_days") > 7).cast("int")), 2).alias("late_pct"),
    round(sum("cost") / sum("weight_kg"), 3).alias("cost_per_kg"))
  .orderBy("carrier_name"), "carrier_performance")
save(df.groupBy("origin", "destination").agg(count("*").alias("shipments"))
  .orderBy(desc("shipments"), col("origin"), col("destination")).limit(10), "top_routes")
save(df.groupBy(col("carrier_name"), date_format(col("ship_date"), "yyyy-MM").alias("month")).agg(count("*").alias("shipments"))
  .withColumn("prev", lag("shipments", 1).over(Window.partitionBy("carrier_name").orderBy("month")))
  .withColumn("change", col("shipments") - col("prev")).drop("prev").orderBy("carrier_name", "month"), "monthly_change")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "total_cost" -> fmt(df.agg(sum("cost")).first.getDouble(0), 2),
  "late_shipments" -> df.filter(col("transit_days") > 7).count())
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
