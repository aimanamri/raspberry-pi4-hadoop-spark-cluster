/*
 * Restaurant: orders joined to restaurants.
 * Cleans bad dates, impossible hours, null or zero quantity and price, duplicates; null discount counts as 0.
 * Revenue = qty * unit_price * (1 - discount_pct / 100). Writes:
 *   city_cuisine (orders and revenue), top_items (top 10 by revenue),
 *   peak_hour (busiest hour per cuisine by revenue, window row_number).
 *
 * Input : <input>/restaurant/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/restaurant/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i restaurant.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/restaurant/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/restaurant/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=restaurant lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/restaurant/scala/summary") // kept for the runner
}

try {
val od0 = read("orders")
val raw = od0.count(); val parts = od0.rdd.getNumPartitions
val od = od0.dropDuplicates("order_id")
  .withColumn("order_date", to_date(col("order_date"), "yyyy-MM-dd"))
  .withColumn("order_hour", col("order_hour").cast("int"))
  .withColumn("qty", col("qty").cast("int"))
  .withColumn("unit_price", col("unit_price").cast("double"))
  .withColumn("discount_pct", coalesce(col("discount_pct").cast("double"), lit(0.0)))
  .filter(col("order_date").isNotNull && col("order_hour").between(0, 23) && col("qty") > 0 && col("unit_price") > 0)
  .withColumn("revenue", col("qty") * col("unit_price") * (lit(1) - col("discount_pct") / 100))
val df = od.join(read("restaurants"), "restaurant_id")

save(df.groupBy("city", "cuisine")
  .agg(count("*").alias("orders"), round(sum("revenue"), 2).alias("revenue"), round(avg("revenue"), 2).alias("avg_order"))
  .orderBy("city", "cuisine"), "city_cuisine")
save(df.groupBy("item").agg(round(sum("revenue"), 2).alias("revenue"), sum("qty").alias("units"))
  .orderBy(desc("revenue"), col("item")).limit(10), "top_items")
val peak = df.groupBy("cuisine", "order_hour").agg(sum("revenue").alias("revenue"))
  .withColumn("rn", row_number().over(Window.partitionBy("cuisine").orderBy(desc("revenue"), col("order_hour"))))
  .filter(col("rn") === 1).select(col("cuisine"), col("order_hour").alias("peak_hour"), round(col("revenue"), 2).alias("revenue"))
  .orderBy("cuisine")
save(peak, "peak_hour")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "total_revenue" -> fmt(df.agg(sum("revenue")).first.getDouble(0), 2),
  "discounted_orders" -> df.filter(col("discount_pct") > 0).count())
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
